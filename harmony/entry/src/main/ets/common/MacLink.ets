import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { b64, fromB64, open, PRIMITIVES, PROTOCOL_VERSION, randomBytes, seal, x25519 } from './Crypto';
import { constantTimeEqual, PairingContext, pairingGenerator, pairingKeys, PairingKeys } from './Cpace';
import { Logger, maskText } from './Logger';
import { addUnpairNotice, deviceId, findComputer, forgetComputer, loadKeyFor, MacInfo, saveComputer } from './PairingStore';
import { loadSettings, SyncSettings, writeSettings } from './PhoneFilter';
import { rediscover } from './Rediscover';

/** 外层帧，字段见 docs/protocol.md */
interface Envelope {
  t: string;
  v?: number;
  deviceId?: string;
  deviceName?: string;
  macId?: string;
  macName?: string;
  platform?: string;
  pub?: string;
  nonce?: string;
  box?: string;
  code?: string;
  confirm?: string;
}

interface Inner {
  kind: string;
  sid: string;
  seq: number;
  cseq?: number;
  id?: string;
  bundleName?: string;
  appName?: string;
  title?: string;
  text?: string;
  time?: number;
  test?: boolean;
  ids?: Array<string>;
  result?: string;
  code?: string;
  // kind = 'settings'：两端共有的同步开关
  paused?: boolean;
  blockSensitive?: boolean;
  copyOtp?: boolean;
  updatedAt?: number;
}

/** 发往电脑的一条通知（字段来自真实 NotificationInfo，或用户手动发出的测试消息）。 */
export interface OutgoingNotification {
  id: string;
  bundleName: string;
  appName: string;
  title: string;
  text: string;
  time: number;
  test: boolean;
}

export type LinkState = 'idle' | 'connecting' | 'pairing' | 'awaitingSasConfirm' | 'authenticating' | 'online' |
  'error';

export interface LinkListener {
  onState: (state: LinkState, detail: string) => void;
  onLog: (ok: boolean, msg: string) => void;
  onSas: (sas: string) => void;
  onAck: (seq: number, result: string) => void;
  /** 电脑同步过来的设置已写入本机（可选，界面用来刷新开关） */
  onSettingsChanged?: () => void;
  /** v1.2：这台电脑已在电脑端取消配对，手机已自动把它从列表中删除（可选，界面用来刷新列表） */
  onUnpairedByComputer?: (mac: MacInfo) => void;
}

const CONNECT_TIMEOUT_MS = 10000;

/** 对方是 1.0.x（协议 v1） */
export const OUTDATED_TEXT = '对方版本过旧，请把电脑和手机都更新到 1.1.0';
/** 电脑回 unknown_device：v2 起只提示、不自动删除（这个回复未经认证，局域网上任何人都能伪造） */
export const UNKNOWN_DEVICE_TEXT = '这台电脑可能已取消配对，请重新配对或手动删除';
const PHONE_PLATFORM = 'harmony';

const ERROR_TEXT: Map<string, string> = new Map<string, string>([
  ['unknown_device', UNKNOWN_DEVICE_TEXT],
  ['upgrade_required', OUTDATED_TEXT],
  ['outdated', OUTDATED_TEXT],
  ['bad_point', '配对数据无效，请重试'],
  ['pairing_closed', '电脑未开启配对或配对码已过期，请在电脑上点“添加设备”'],
  ['bad_pin', '配对码错误'],
  ['auth_failed', '认证失败：密钥不匹配，请重新配对'],
  ['replay', '电脑拒绝了重复或乱序的消息'],
  ['bad_msg', '电脑无法解密消息'],
]);

/**
 * 手机 → 一台电脑（Mac 或 Windows）的局域网 WebSocket 链路。每台已配对的电脑各用一个 MacLink。
 * 前台使用时断线后有限次退避重连；通知订阅扩展里按需连接，不做后台保活。
 */
export class MacLink {
  private ws: webSocket.WebSocket | undefined = undefined;
  private state: LinkState = 'idle';
  private ctx: common.Context;
  private listener: LinkListener;

  // 配对过程中的临时数据
  private pairPin: string = '';
  private pairNonce: Uint8Array | undefined = undefined;
  private pairKeys: PairingKeys | undefined = undefined;
  private pendingMac: MacInfo | undefined = undefined;

  // 会话数据
  private key: Uint8Array | undefined = undefined;
  private phoneNonce: string = '';
  private sid: string = '';
  private seq: number = 0;
  /** 电脑发来的最后一个 cseq（防重放：必须严格递增） */
  private lastCseq: number = 0;
  private pingTimer: number = -1;
  private reconnectTimer: number = -1;
  private retries: number = 0;
  private autoReconnect: boolean = false;

  // foreground=false 用于通知订阅扩展：不发心跳、不自动重连，由调用方按需连接
  private foreground: boolean;
  // v1.2：只为通知电脑“手机已删除它”而连接（密钥来自待通知列表），认证后只发 unpair
  private unpairOnly: boolean = false;
  // 这条链路对应的电脑；配对新电脑时为空，配对成功后填上
  private target: MacInfo | undefined;

  constructor(ctx: common.Context, listener: LinkListener, foreground: boolean = true, target?: MacInfo) {
    this.ctx = ctx;
    this.listener = listener;
    this.foreground = foreground;
    this.target = target;
  }

  getState(): LinkState {
    return this.state;
  }

  /** 这条链路对应的、仍处于配对状态的电脑（地址取最新保存的）。 */
  pairedMac(): MacInfo | undefined {
    if (this.target === undefined) {
      return undefined;
    }
    return findComputer(this.ctx, this.target.macId);
  }

  // ---------- 配对 ----------

  startPairing(host: string, port: number, pin: string): void {
    if (!/^\d{6}$/.test(pin)) {
      this.listener.onLog(false, '配对码应为 6 位数字');
      return;
    }
    this.stop();
    this.pairPin = pin;
    const nonce = randomBytes(16);
    this.pairNonce = nonce;
    this.pairKeys = undefined;
    this.pendingMac = { host: host, port: port, macId: '', macName: '', platform: 'mac' };
    this.open(host, port, 'pairing', () => {
      const req: Envelope = {
        t: 'pair_req',
        v: PROTOCOL_VERSION,
        deviceId: deviceId(this.ctx),
        deviceName: deviceInfo.marketName,
        platform: PHONE_PLATFORM,
        nonce: b64(nonce),
      };
      this.sendFrame(req);
    });
  }

  /** 用户确认两端校验码一致后调用：发出确认码（电脑核对通过才保存配对）。 */
  confirmSas(): void {
    if (this.state !== 'awaitingSasConfirm' || this.pairKeys === undefined) {
      return;
    }
    this.sendFrame({ t: 'pair_confirm', confirm: b64(this.pairKeys.confirmPhone) });
    this.setState('pairing', '等待电脑确认');
  }

  // ---------- 会话 ----------

  connect(): void {
    const mac = this.pairedMac();
    const key = mac === undefined ? undefined : loadKeyFor(mac.macId);
    if (mac === undefined || key === undefined) {
      this.listener.onLog(false, '尚未与这台电脑配对');
      return;
    }
    this.closeSocket();
    this.key = key;
    this.autoReconnect = this.foreground;
    this.phoneNonce = b64(randomBytes(16));
    this.open(mac.host, mac.port, 'authenticating', () => {
      this.sendFrame({ t: 'hello', v: PROTOCOL_VERSION, deviceId: deviceId(this.ctx), nonce: this.phoneNonce });
    });
  }

  /**
   * v1.2：手机上已删除这台电脑，用保留的密钥连接并认证，然后发送 unpair 让电脑也取消配对。
   * 电脑回 ack result=unpaired 后会主动断开。
   */
  connectForUnpair(mac: MacInfo, key: Uint8Array): void {
    this.closeSocket();
    this.target = mac;
    this.key = key;
    this.unpairOnly = true;
    this.autoReconnect = false;
    this.phoneNonce = b64(randomBytes(16));
    this.open(mac.host, mac.port, 'authenticating', () => {
      this.sendFrame({ t: 'hello', v: PROTOCOL_VERSION, deviceId: deviceId(this.ctx), nonce: this.phoneNonce });
    });
  }

  stop(): void {
    this.autoReconnect = false;
    this.clearReconnect();
    this.closeSocket();
    this.setState('idle', '已断开');
  }

  sendNotification(n: OutgoingNotification): boolean {
    if (this.state !== 'online') {
      this.listener.onLog(false, '未连接到电脑，消息未发送');
      return false;
    }
    const inner: Inner = {
      kind: 'notify',
      sid: this.sid,
      seq: ++this.seq,
      id: n.id,
      bundleName: n.bundleName,
      appName: n.appName,
      title: n.title,
      text: n.text,
      time: n.time,
      test: n.test,
    };
    this.sendInner(inner);
    Logger.info(`notify sent seq=${inner.seq} id=${n.id} test=${n.test} title=${maskText(n.title)}`);
    return true;
  }

  /** 验证码：只发送提取出的验证码本身，不发送短信全文。 */
  sendOtp(id: string, bundleName: string, appName: string, code: string): void {
    if (this.state !== 'online') {
      return;
    }
    this.sendInner({
      kind: 'otp',
      sid: this.sid,
      seq: ++this.seq,
      id: id,
      bundleName: bundleName,
      appName: appName,
      code: code,
      time: Date.now(),
    });
    Logger.info(`otp sent id=${id} len=${code.length}`);
  }

  sendCancel(ids: Array<string>): void {
    if (this.state !== 'online') {
      return;
    }
    this.sendInner({ kind: 'cancel', sid: this.sid, seq: ++this.seq, ids: ids });
  }

  // ---------- 内部 ----------

  private open(host: string, port: number, initial: LinkState, onOpen: () => void): void {
    const ws = webSocket.createWebSocket();
    this.ws = ws;
    this.setState('connecting', `连接 ${host}:${port}`);
    ws.on('open', () => {
      if (this.ws !== ws) {
        return;
      }
      this.retries = 0;
      this.setState(initial, '已建立连接');
      onOpen();
    });
    ws.on('message', (err: BusinessError, data: string | ArrayBuffer) => {
      if (this.ws !== ws || err) {
        return;
      }
      if (typeof data === 'string') {
        this.onFrame(data);
      }
    });
    ws.on('close', (err: BusinessError, res: webSocket.CloseResult) => {
      if (this.ws !== ws) {
        return;
      }
      this.ws = undefined;
      this.clearPing();
      if (this.state !== 'error' && this.state !== 'idle') {
        this.setState('idle', `连接关闭 (${res.code})`);
      }
      this.scheduleReconnect();
    });
    ws.on('error', (err: BusinessError) => {
      if (this.ws !== ws) {
        return;
      }
      this.listener.onLog(false, `WebSocket 错误 ${err.code}: ${err.message}（检查电脑地址、端口、是否同一 Wi-Fi）`);
      if (this.state === 'connecting' || this.state === 'authenticating') {
        this.closeSocket();
        this.setState('error', '连接出错');
        this.scheduleReconnect();
        this.onConnectFailed();
      }
    });
    // 看门狗：扩展进程可能在连接过程中被系统冻结，事件丢失后会一直停在“连接中”。
    // 超过 10 秒仍未完成连接/认证，就主动关闭并报错，交给调用方重连。
    setTimeout(() => {
      if (this.ws === ws && (this.state === 'connecting' || this.state === 'authenticating')) {
        this.listener.onLog(false, '连接超时（10 秒未完成连接或认证）');
        this.closeSocket();
        this.setState('error', '连接超时');
        this.scheduleReconnect();
        this.onConnectFailed();
      }
    }, CONNECT_TIMEOUT_MS);
    ws.connect(`ws://${host}:${port}`).catch((err: BusinessError) => {
      this.listener.onLog(false, `连接失败 ${err.code}: ${err.message}`);
      this.setState('error', '连接失败');
      this.scheduleReconnect();
      this.onConnectFailed();
    });
  }

  /**
   * 连不上已配对的电脑：可能是电脑换了 IP。按电脑 ID 在局域网里重新查找，找到新地址就立即重连。
   * 配对过程中不触发（配对时地址由用户选择）。
   */
  private onConnectFailed(): void {
    const mac = this.target;
    if (mac === undefined || this.key === undefined || this.pairNonce !== undefined || this.unpairOnly) {
      return;
    }
    rediscover(this.ctx, mac).then((moved: boolean) => {
      if (moved && this.state === 'error' && this.target !== undefined && this.target.macId === mac.macId) {
        this.listener.onLog(true, `${mac.macName} 的地址已变化，正在用新地址重连`);
        this.retries = 0;
        this.connect();
      }
    });
  }

  private onFrame(text: string): void {
    let env: Envelope;
    try {
      env = JSON.parse(text) as Envelope;
    } catch (e) {
      this.listener.onLog(false, '收到无法解析的帧');
      return;
    }
    try {
      switch (env.t) {
        case 'pair_chal':
          this.onPairChallenge(env);
          break;
        case 'pair_ok':
          this.onPairOk(env);
          break;
        case 'challenge':
          this.onChallenge(env);
          break;
        case 'auth_ok':
          this.onAuthOk(env);
          break;
        case 'msg':
          this.onMsg(env);
          break;
        case 'error':
          this.onError(env.code === undefined ? '' : env.code);
          break;
        default:
          this.listener.onLog(false, `未知帧类型 ${env.t}`);
      }
    } catch (e) {
      const be = e as BusinessError;
      this.listener.onLog(false, `处理 ${env.t} 失败：${be.message}`);
      this.fail('协议处理失败');
    }
  }

  /** v2：收到电脑的 nonce 和 Yb，按 PIN 算 CPace 生成元、Ya 和共享点 K，发 pair_key，显示 SAS。 */
  private onPairChallenge(env: Envelope): void {
    const nonce = this.pairNonce;
    if (nonce === undefined || this.state !== 'pairing' || this.pairKeys !== undefined) {
      this.fail('配对数据缺失');
      return;
    }
    if (env.v !== PROTOCOL_VERSION) {
      this.outdated();
      return;
    }
    const macNonce = env.nonce === undefined ? new Uint8Array(0) : fromB64(env.nonce);
    const yb = env.pub === undefined ? new Uint8Array(0) : fromB64(env.pub);
    if (macNonce.length !== 16 || yb.length !== 32) {
      this.fail('电脑的配对数据不完整');
      return;
    }
    const pc: PairingContext = {
      deviceId: deviceId(this.ctx),
      deviceName: deviceInfo.marketName,
      phonePlatform: PHONE_PLATFORM,
      macId: env.macId === undefined ? '' : env.macId,
      macName: env.macName === undefined ? '' : env.macName,
      macPlatform: env.platform === undefined ? '' : env.platform,
      phoneNonce: nonce,
      macNonce: macNonce,
    };
    const ya = randomBytes(32);
    let keys: PairingKeys;
    try {
      const yaPub = x25519(ya, pairingGenerator(PRIMITIVES, pc, this.pairPin));
      const k = x25519(ya, yb);
      keys = pairingKeys(PRIMITIVES, k, pc, yaPub, yb);
      this.sendFrame({ t: 'pair_key', pub: b64(yaPub) });
    } catch (e) {
      this.fail('电脑发来的配对公钥无效');
      return;
    }
    this.pairKeys = keys;
    if (this.pendingMac !== undefined) {
      this.pendingMac.macId = pc.macId;
      this.pendingMac.macName = pc.macName.length === 0 ? '电脑' : pc.macName;
      this.pendingMac.platform = pc.macPlatform.length === 0 ? 'mac' : pc.macPlatform;
    }
    this.setState('awaitingSasConfirm', `请核对校验码 ${keys.sas}`);
    this.listener.onSas(keys.sas);
  }

  /** 核对电脑的确认码：通过才保存配对密钥（冒充电脑、不知道 PIN 的一方算不出来）。 */
  private onPairOk(env: Envelope): void {
    const keys = this.pairKeys;
    if (keys === undefined || env.confirm === undefined ||
      !constantTimeEqual(fromB64(env.confirm), keys.confirmComputer)) {
      this.fail('电脑的配对确认无效');
      return;
    }
    if (this.pendingMac !== undefined) {
      if (this.pendingMac.macId.length === 0) {
        this.pendingMac.macId = `host-${this.pendingMac.host}`;
      }
      saveComputer(this.ctx, this.pendingMac, keys.pairKey);
      this.target = this.pendingMac;
    }
    this.listener.onLog(true, `与 ${this.pendingMac?.macName} 配对成功`);
    this.clearPairing();
    this.closeSocket();
    this.setState('idle', '配对成功，可以连接');
  }

  private onChallenge(env: Envelope): void {
    if (this.key === undefined || env.nonce === undefined) {
      this.fail('认证数据缺失');
      return;
    }
    if (env.v !== PROTOCOL_VERSION) {
      this.outdated();
      return;
    }
    this.sid = env.nonce;
    this.sendFrame({ t: 'auth', box: seal(this.key, `auth|${this.phoneNonce}|${this.sid}`, 'toComputer') });
  }

  private onAuthOk(env: Envelope): void {
    if (this.key === undefined || env.box === undefined ||
      open(this.key, env.box, 'toPhone') !== `ok|${this.sid}|${this.phoneNonce}`) {
      this.fail('电脑身份校验失败');
      return;
    }
    this.seq = 0;
    this.lastCseq = 0;
    if (this.unpairOnly) {
      this.setState('online', '已认证，正在通知电脑取消配对');
      this.sendInner({ kind: 'unpair', sid: this.sid, seq: ++this.seq });
      return;
    }
    this.setState('online', '已认证，在线');
    // 每次连上都交换一次设置，双方按修改时间“后改的为准”
    this.sendSettings();
    if (this.foreground) {
      this.startPing();
    }
  }

  /** 把本机的同步开关发给电脑。 */
  sendSettings(): void {
    if (this.state !== 'online') {
      return;
    }
    const st: SyncSettings = loadSettings(this.ctx);
    this.sendInner({
      kind: 'settings',
      sid: this.sid,
      seq: ++this.seq,
      paused: st.paused,
      blockSensitive: st.blockSensitive,
      copyOtp: st.copyOtp,
      updatedAt: st.updatedAt,
    });
  }

  private applyRemoteSettings(inner: Inner): void {
    if (inner.updatedAt === undefined) {
      return;
    }
    const st: SyncSettings = loadSettings(this.ctx);
    if (inner.updatedAt <= st.updatedAt) {
      return;
    }
    st.paused = inner.paused === undefined ? st.paused : inner.paused;
    st.blockSensitive = inner.blockSensitive === undefined ? st.blockSensitive : inner.blockSensitive;
    st.copyOtp = inner.copyOtp === undefined ? st.copyOtp : inner.copyOtp;
    st.updatedAt = inner.updatedAt;
    writeSettings(this.ctx, st);
    Logger.info(`settings synced from computer paused=${st.paused} blockSensitive=${st.blockSensitive} copyOtp=${st.copyOtp}`);
    if (this.listener.onSettingsChanged !== undefined) {
      this.listener.onSettingsChanged();
    }
  }

  private onMsg(env: Envelope): void {
    if (this.key === undefined || env.box === undefined) {
      return;
    }
    const inner = JSON.parse(open(this.key, env.box, 'toPhone')) as Inner;
    if (inner.sid !== this.sid) {
      this.listener.onLog(false, '忽略会话不匹配的消息');
      return;
    }
    // v2 防重放：电脑发来的每条消息 cseq 必须严格递增，重复或乱序的（尤其 unpair、settings）一律丢弃
    const cseq = inner.cseq === undefined ? 0 : inner.cseq;
    if (cseq <= this.lastCseq) {
      this.listener.onLog(false, `忽略重放或乱序的电脑消息 cseq=${cseq}`);
      return;
    }
    this.lastCseq = cseq;
    if (inner.kind === 'ack') {
      this.listener.onAck(inner.seq, inner.result === undefined ? '' : inner.result);
    } else if (inner.kind === 'settings') {
      this.applyRemoteSettings(inner);
    } else if (inner.kind === 'unpair' && !this.unpairOnly) {
      // v1.2：电脑上取消了与这台手机的配对
      this.onUnpairedByComputer();
    }
  }

  /** 电脑已不再认这台手机：删除本机的配对，提示用户。 */
  private onUnpairedByComputer(): void {
    const mac = this.target;
    if (mac === undefined) {
      return;
    }
    this.autoReconnect = false;
    this.clearReconnect();
    forgetComputer(this.ctx, mac.macId);
    addUnpairNotice(this.ctx, mac.macName);
    Logger.info(`computer ${mac.macId.substring(0, 8)} unpaired this phone; removed locally`);
    this.closeSocket();
    this.setState('idle', '已在电脑上取消配对');
    if (this.listener.onUnpairedByComputer !== undefined) {
      this.listener.onUnpairedByComputer(mac);
    }
  }

  private onError(code: string): void {
    // v2：unknown_device 未经认证，只提示，不自动删除这台电脑（见 docs/protocol.md “取消配对”）
    if (code === 'upgrade_required' ||
      (code === 'bad_pair_req' && this.pairNonce !== undefined && this.pairKeys === undefined)) {
      // 旧版电脑不认识 v2 的 pair_req（缺 pub）会回 bad_pair_req
      this.outdated();
      return;
    }
    const desc = ERROR_TEXT.get(code);
    this.listener.onLog(false, `电脑返回错误 ${code}：${desc === undefined ? '未知错误' : desc}`);
    if (code === 'unknown_device' || code === 'auth_failed' || code === 'bad_pin' || code === 'pairing_closed') {
      this.autoReconnect = false; // 这些错误重连也不会成功
    }
    this.fail(code);
  }

  /** 对方是 1.0.x（协议 v1）：停止重连并提示双方都更新 */
  private outdated(): void {
    this.autoReconnect = false;
    this.listener.onLog(false, OUTDATED_TEXT);
    this.fail('outdated');
  }

  private sendInner(inner: Inner): void {
    if (this.key === undefined) {
      return;
    }
    this.sendFrame({ t: 'msg', box: seal(this.key, JSON.stringify(inner), 'toComputer') });
  }

  private sendFrame(env: Envelope): void {
    const ws = this.ws;
    if (ws === undefined) {
      return;
    }
    ws.send(JSON.stringify(env)).catch((err: BusinessError) => {
      this.listener.onLog(false, `发送失败 ${err.code}: ${err.message}`);
    });
  }

  private startPing(): void {
    this.clearPing();
    this.pingTimer = setInterval(() => {
      if (this.state === 'online') {
        this.sendInner({ kind: 'ping', sid: this.sid, seq: ++this.seq });
      }
    }, 25000);
  }

  private clearPing(): void {
    if (this.pingTimer !== -1) {
      clearInterval(this.pingTimer);
      this.pingTimer = -1;
    }
  }

  private scheduleReconnect(): void {
    if (!this.autoReconnect || this.reconnectTimer !== -1 || this.retries >= 5) {
      if (this.autoReconnect && this.retries >= 5) {
        this.listener.onLog(false, '多次重连失败，已停止自动重连');
        this.autoReconnect = false;
      }
      return;
    }
    const delay = Math.min(30000, 2000 * Math.pow(2, this.retries));
    this.retries++;
    this.listener.onLog(false, `${delay / 1000} 秒后第 ${this.retries} 次重连`);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      if (this.autoReconnect) {
        this.connect();
      }
    }, delay);
  }

  private clearReconnect(): void {
    if (this.reconnectTimer !== -1) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
    this.retries = 0;
  }

  private fail(detail: string): void {
    this.clearPairing();
    this.setState('error', detail);
    this.closeSocket();
  }

  private clearPairing(): void {
    this.pairPin = '';
    this.pairNonce = undefined;
    this.pairKeys = undefined;
  }

  private closeSocket(): void {
    this.clearPing();
    const ws = this.ws;
    this.ws = undefined;
    if (ws !== undefined) {
      ws.close().catch(() => {
      });
    }
  }

  private setState(s: LinkState, detail: string): void {
    this.state = s;
    this.listener.onState(s, detail);
    Logger.info(`MacLink[${this.target === undefined ? 'new' : this.target.macId.substring(0, 8)}] state=${s} ${detail}`);
  }
}
