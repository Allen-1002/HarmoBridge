# NotiBridge 局域网协议 v2（NotiBridge 1.1.0 起）

手机（WebSocket 客户端）→ 电脑（Mac 或 Windows，WebSocket 服务端，默认端口 47800，mDNS / DNS-SD 类型 `_notibridge._tcp`）。
所有帧为 UTF-8 JSON 文本帧。只在本地局域网内传输，不经过任何第三方服务器。
下文中的“电脑”指 Mac 或 Windows 客户端，两者实现完全相同的协议，手机不需要区分。

> **v2 与 v1（1.0.x）不兼容。** v1 的配对密钥由 PIN 直接参与 HKDF 派生，抓到一次配对流量就可以离线穷举 6 位 PIN；
> v2 改用 PAKE（CPace），并加了密钥确认、双向防重放和方向分离。升级到 1.1.0 时四端都会**清除旧配对**（只清一次，
> 以本机保存的 `pairingSchema = 2` 为准），需要在电脑和手机上重新配对。

## 版本协商

- v2 的 `pair_req`、`hello`、`pair_chal`、`challenge`、`info`（电脑的回复）都带 `"v":2`。
- 电脑收到不带 `"v":2` 的 `pair_req` / `hello`（旧版手机）→ 回 `{"t":"error","code":"upgrade_required"}` 并断开，
  界面提示“有旧版手机尝试连接，请把手机更新到 1.1.0”。
- 手机收到不带 `"v":2` 的 `pair_chal` / `challenge`，或旧版电脑对 v2 `pair_req` 的回复 `bad_pair_req`，
  或 `upgrade_required` → 停止并提示“对方版本过旧，请把电脑和手机都更新到 1.1.0”。

## 多设备拓扑

- 一台手机可以配对多台电脑：手机为每台电脑分别保存配对密钥（按电脑 `macId` 区分），每台电脑一条独立的加密连接，
  每条通知同时转发给所有已配对的电脑；某台电脑离线不影响其他电脑。
- 一台电脑可以配对多台手机：电脑为每台手机分别保存密钥（按手机 `deviceId` 区分），可同时有多台手机在线。
  电脑端用“手机 deviceId + 通知 id”作为通知标识和去重键。
- 连接始终由手机发起；连接建立后消息双向流动。
- 服务广播的 TXT 记录：`id=<macId>`、`platform=mac|windows`。手机据此识别已配对的电脑，电脑换 IP 后自动更新地址。
  TXT 记录未经认证，只用来找地址，**从不**用来决定删除配对等操作。

## 密码学约定（四端必须逐字节一致）

| 记号 | 定义 |
|---|---|
| `lv_cat(a, b, …)` | CPace 的长度前缀拼接：每项前加 LEB128 编码的字节长度（草案 draft-irtf-cfrg-cpace 附录 A.1） |
| `u(s)` | 字符串 s 的 UTF-8 字节，按线路上收到/发出的原样（不做 Unicode 规范化；缺失字段视为空串） |
| `sid` | `phoneNonce(16) ‖ macNonce(16)`，两个 nonce 分别来自 `pair_req` 和 `pair_chal` |
| `CI` | `lv_cat(u(deviceId), u(macId))` |
| `PRS` | `u(PIN)`，PIN 为电脑显示的 6 位数字 |
| 生成元 `g` | CPace `calculate_generator`（CPACE-X25519-SHA512）：`gen_str = lv_cat("CPace255", PRS, zero_pad, CI, sid)`（`zero_pad` 使前三项填满 SHA-512 的 128 字节块），`u = decodeUCoordinate(SHA-512(gen_str)[0..32])`（清最高位），`g = Elligator2_Curve25519(u)` 的 u 坐标（32 字节小端） |
| `Ya` / `Yb` | 手机随机 32 字节 `ya`、电脑随机 `yb`；`Ya = X25519(ya, g)`，`Yb = X25519(yb, g)` |
| `K` | 手机 `X25519(ya, Yb)`，电脑 `X25519(yb, Ya)`；**结果全 0（低阶点）立即中止** |
| transcript `T` | `lv_cat("NotiBridge-pair-v2", sid, u(deviceId), u(deviceName), u(phonePlatform), u(macId), u(macName), u(macPlatform), Ya, Yb)` |
| `th` | `SHA-256(T)` |
| 配对密钥 | `HKDF-SHA256(ikm = K, salt = th, info = "NotiBridge-v2 pair key", 32)` |
| 确认密钥 | `kcPhone = HKDF(K, th, "NotiBridge-v2 confirm phone")`，`kcComputer = HKDF(K, th, "NotiBridge-v2 confirm computer")` |
| 确认码 | `confirmPhone = HMAC-SHA256(kcPhone, th ‖ "phone")`，`confirmComputer = HMAC-SHA256(kcComputer, th ‖ "computer")`，常量时间比较 |
| 校验码 SAS | `th` 前 5 字节按大端整数 mod 10⁸，补齐 8 位，显示为 `1234 5678` |
| `seal(k, s)` | AES-256-GCM，IV 12 字节随机，输出 `Base64(iv ‖ ciphertext ‖ tag16)`；**AAD 按方向区分**：手机→电脑 `"NB2|p2c"`，电脑→手机 `"NB2|c2p"` |

测试向量：`docs/test-vectors/pairing-v2.json`（由 `generate_pairing_v2.py` 独立计算，并已用 CPace 草案附录 B.1 的官方向量自检），
四端单元测试都读取它；文件里同时包含草案的官方 CPace 向量（生成元、Ya/Yb、K、低阶点）。

### 为什么这样能防住离线猜 PIN 和中间人

- PIN 只用来生成 CPace 的生成元 `g`，线路上只出现 `Ya`、`Yb`，它们与 PIN 在计算上无关：
  被动抓包的人拿到整段配对流量，也无法离线验证任何一个 PIN 猜测。
- 主动攻击者（冒充电脑或手机、或在中间转发）每次配对只能验证**一个** PIN 猜测，而且猜错会让确认码校验失败：
  电脑对一次配对窗口最多接受 3 次失败（之后 PIN 作废、需要重新生成），PIN 2 分钟过期。猜中的概率 ≤ 3/10⁶。
- 双方在保存任何东西之前先互相验证确认码（手机先发，电脑核对通过后才保存并回自己的确认码，手机核对后才保存）。
- 8 位 SAS 是额外的人工核对：中间人如果分别和两端完成了 CPace（需要猜中 PIN），两端的 transcript 不同，SAS 就对不上。
  CPace 本身已经把主动攻击限制为每次一次在线猜测，SAS 只是多一道保险。

## 配对（v2）

电脑在用户点“配对新手机”后生成 6 位 PIN（2 分钟有效、错误 3 次作废重新生成）。手机先让用户输入 PIN，再连接：

```
手机 → {"t":"pair_req","v":2,"deviceId":"<uuid>","deviceName":"<手机名称>","platform":"android|harmony","nonce":"<b64 16B>"}
电脑 → {"t":"pair_chal","v":2,"macId":"<uuid>","macName":"<电脑名称>","platform":"mac|windows","nonce":"<b64 16B>","pub":"<b64 Yb>"}
手机 → {"t":"pair_key","pub":"<b64 Ya>"}
        （双方各自得到 K、th、SAS；两端界面同时显示 8 位 SAS，用户核对后在手机上点“一致”）
手机 → {"t":"pair_confirm","confirm":"<b64 confirmPhone>"}
电脑 → {"t":"pair_ok","confirm":"<b64 confirmComputer>"}      或 {"t":"error","code":"bad_pin"}（计一次失败）
```

- 电脑在发出 `pair_chal` 时就用当前 PIN 算出 `g`、`Yb`；收到 `pair_key` 后算 `K`，`K` 全 0 → `bad_point` 并断开（计一次失败）。
- 电脑核对 `confirmPhone` 失败计为一次 PIN 错误；第 3 次失败后 PIN 作废。核对通过才保存 `deviceId → 配对密钥`。
- 手机核对 `confirmComputer` 通过后才保存配对密钥（鸿蒙 Asset Store / Android Keystore 包装 / 见各端说明）。
- 一条连接只能配对一次；配对阶段收到其他任何帧、重复的 `pair_key`、或旧的 `pair_confirm`（来自另一次配对，`th` 不同）都会失败。

## 身份探测（未认证）

```
手机 → {"t":"info"}
电脑 → {"t":"info","v":2,"macId":"<uuid>","macName":"<电脑名称>","platform":"mac|windows"}   随后断开
```

只返回公开信息，不涉及密钥。用于局域网发现时判断平台、连不上时按电脑 ID 重新查找新地址（仅限同一局域网）。

## 会话认证（每次连接）

```
手机 → {"t":"hello","v":2,"deviceId":"<uuid>","nonce":"<b64 16B phoneNonce>"}
电脑 → {"t":"challenge","v":2,"nonce":"<b64 16B macNonce>"}        未配对设备 → {"t":"error","code":"unknown_device"} 并断开
手机 → {"t":"auth","box":seal_p2c(key,"auth|<phoneNonce>|<macNonce>")}
电脑 → {"t":"auth_ok","box":seal_c2p(key,"ok|<macNonce>|<phoneNonce>")}
```

认证前电脑不接受任何业务消息；认证失败立即断开。`sid` = 本次会话的 `macNonce`（Base64 字符串）。

## 业务消息（认证后）

```
{"t":"msg","box":seal(key, <inner JSON>)}      手机→电脑用 seal_p2c，电脑→手机用 seal_c2p
```

**防重放（双向）**

- 手机 → 电脑：inner 必带 `sid` 和递增 `seq`（每次连接从 1 开始）。电脑拒绝 `sid` 不符或 `seq` 不严格递增的消息，回 `replay` 并断开。
- 电脑 → 手机：inner 必带 `sid` 和 `cseq`（电脑自己的计数，每次连接从 1 开始，**每一条**电脑发出的消息都加 1，包括 ack）。
  手机拒绝 `sid` 不符、缺少 `cseq` 或 `cseq` 不严格递增的消息（记日志并丢弃；`unpair`、`settings` 这类控制消息绝不会被重复执行）。
  `ack` 里的 `seq` 是被确认的手机消息的 `seq`，手机只用它对应回执，不用来防重放。
- AAD 按方向区分，所以把一方发出的消息原样反射回去也解不开。

| kind | 方向 | 字段 |
|---|---|---|
| `notify` | 手机→电脑 | `id`(通知 hashCode)、`bundleName`、`appName`、`title`、`text`、`time`(ms)、`test`(bool，手动测试消息) |
| `cancel` | 手机→电脑 | `ids`: string[] |
| `otp` | 手机→电脑 | `id`、`bundleName`、`appName`、`code`（4~8 位数字，只发验证码，不发短信全文）；电脑复制到剪贴板，2 分钟后清除 |
| `ping` | 手机→电脑 | — |
| `unpair` | 双向 | —。见下文“取消配对” |
| `ack` | 电脑→手机 | `seq`（被确认的手机 seq）、`cseq`、`result`: `shown` / `duplicate` / `filtered` / `paused` / `removed` / `copied` / `pong` / `unpaired` |
| `settings` | 双向 | `paused`、`blockSensitive`、`copyOtp`、`updatedAt`(ms)。按 `updatedAt` “后改的为准”。手机连上后先发一次；电脑回传合并结果；电脑上改了开关时主动推送给所有在线手机 |

`copyOtp` 两端含义一致，都表示“验证码同步”：手机上关掉就不再提取和发送验证码，电脑上关掉就不再复制到剪贴板。

## 取消配对

只通过**已认证、加密**的 `unpair` 消息让对方删除配对。未认证的错误码（`unknown_device`、`auth_failed`）
或 TXT 记录**不会**让手机自动删除任何电脑（v1 里根据 `unknown_device` 自动删除的逻辑已移除，因为局域网上任何人都能伪造这个回复）。

**手机上删除电脑**
1. 手机删除列表项，但把这台电脑的密钥转存到“待通知”列表。
2. 手机用这把密钥连接、认证，发送 `unpair`。电脑删除该手机的密钥，回 `ack result=unpaired`，然后断开。
3. 电脑不在线时，手机以后打开 App、转发通知、局域网发现到这台电脑时自动重试。
4. 送达后删除保留的密钥。电脑回 `unknown_device` / `auth_failed`（可能电脑上早已删除，也可能是伪造的）时不立即放弃：
   最多重试 7 天，之后删除保留的密钥并提示用户到电脑上确认是否已取消。
5. 手机重新配对同一台电脑时，清掉它的待通知记录。

**电脑上取消手机配对**
1. 手机在线：电脑先发 `unpair`（带 `cseq`），约 0.5 秒后断开；手机校验 `sid` / `cseq` 后删除这台电脑并提示用户。
2. 手机不在线：电脑直接删除密钥。手机下次 `hello` 收到 `unknown_device`，**只提示**
   “这台电脑可能已取消配对，请重新配对或手动删除”，由用户决定。

## 电脑端连接限制（防滥用）

| 项 | 限制 |
|---|---|
| 同时连接数 | 最多 16 条（含未认证），超过的新连接直接关闭 |
| 新连接速率 | 同一 IP 每分钟最多 10 条新连接 |
| 握手 / 认证超时 | 连接后 10 秒内必须完成 WebSocket 握手和 `hello`→`auth`；配对中（已收到 `pair_req`）放宽到 90 秒，给用户核对 SAS |
| 帧大小 | 认证前单帧最多 16 KB，认证后最多 256 KB；超过立即断开 |
| 失败退避 | 同一 IP 认证/配对失败（`bad_pin`、`auth_failed`、`bad_point`、`replay`、`bad_frame`…）累计 3 次后封禁 30 秒，之后每次再失败封禁时间翻倍，最长 1 小时；成功认证后清零 |
| 资源释放 | 连接关闭时立即释放会话状态和计时器 |

## 存储（各端）

| 端 | 配对密钥存放 |
|---|---|
| Mac | `~/Library/Application Support/com.xsh.notibridge.desktop/pairing.dat`：AES-GCM 加密，文件密钥 = HKDF(本机硬件 UUID ‖ 电脑 ID)。复制到别的电脑上无法解密；但**同一用户账户下运行的其他程序理论上可以算出文件密钥并解密**。这是为了避免每次更新都弹钥匙串授权（App 没有 Apple 开发者 ID 签名，自签名证书无法让钥匙串在更新后保持授权）而做的取舍 |
| Windows | DPAPI（当前用户）加密的文件 |
| Android | 应用私有目录，用 Android Keystore 中不可导出的 AES 密钥加密 |
| 鸿蒙 | 系统 Asset Store（首次解锁后可读） |

## 发布签名（自动更新）

Release 附带 `SHA256SUMS.txt` 和 `SHA256SUMS.txt.sig`（对 `SHA256SUMS.txt` 原始字节的 Ed25519 签名，64 字节，Base64）。
Mac、Windows、Android 的更新器内置发布公钥，**先验证签名，再信任 SHA256SUMS 里的哈希**，签名缺失或不对就拒绝安装。
签名私钥只在发布者的电脑上（`~/.config/notibridge/release-signing-ed25519.pem`），发布脚本 `scripts/sign_release.sh` 自动签名。
Windows 安装包没有 Authenticode 代码签名证书（未购买），Windows 可能显示“未知发布者”，完整性由上面的 Ed25519 签名保证。

## 扩展预留

`kind` 以 `call.` 开头的消息保留给 ESP32 通话模块，通知模块忽略这些消息。

## ESP32 模块

电脑通过 USB 串口（115200 8N1）连接 ESP32。检测固件：电脑发送 `HB?\n`，NotiBridge 固件回复一行 `HB-ESP32 <版本> ...`，2 秒内收到即视为已刷写。
完整的串口命令和事件见 [esp32-serial.md](esp32-serial.md)。目前固件把 iPhone 的通知（BLE ANCS）转给电脑；通话（HFP）在开发中。
