import { notificationExtensionSubscription, NotificationSubscriberExtensionAbility } from '@kit.NotificationKit';
import { ExtForwarder } from '../common/ExtForwarder';
import { Logger, maskText } from '../common/Logger';
import { appendRecord, EventRecord } from '../common/NotificationStore';
import { blockReason, extractOtp, loadSettings, SyncSettings } from '../common/PhoneFilter';

/**
 * 系统通知服务在订阅成功、用户已授权后，把本机通知转发到这里。
 * 生命周期由系统管理：有通知时拉起，一段时间无新通知会被系统自动销毁，不做任何保活。
 *
 * 收到通知后：写入本地记录（App 首页可见）→ 手机端过滤 → 通过已配对的加密连接转发到 Mac。
 */
export default class NotificationSubscriberExtAbility extends NotificationSubscriberExtensionAbility {
  private forwarder: ExtForwarder | undefined = undefined;

  private getForwarder(): ExtForwarder {
    if (this.forwarder === undefined) {
      this.forwarder = new ExtForwarder(this.context);
    }
    return this.forwarder;
  }

  onReceiveMessage(notificationInfo: notificationExtensionSubscription.NotificationInfo): void {
    const title = notificationInfo.content?.title ?? '';
    const text = notificationInfo.content?.text ?? '';
    // 日志只输出元数据，标题/正文脱敏
    Logger.info(`onReceiveMessage hash=${notificationInfo.hashCode} bundle=${notificationInfo.bundleName} ` +
      `slot=${notificationInfo.notificationSlotType} title=${maskText(title)} text=${maskText(text)}`);
    const record: EventRecord = {
      kind: 'publish',
      recordTime: Date.now(),
      hashCode: notificationInfo.hashCode,
      bundleName: notificationInfo.bundleName,
      appName: notificationInfo.appName,
      title: title,
      text: text,
      deliveryTime: notificationInfo.deliveryTime,
      slotType: notificationInfo.notificationSlotType,
      appIndex: notificationInfo.appIndex,
    };
    appendRecord(this.context.filesDir, record);

    try {
      const settings: SyncSettings = loadSettings(this.context);
      if (this.tryForwardOtp(settings, notificationInfo, title, text)) {
        return;
      }
      const reason = blockReason(settings, notificationInfo.bundleName, title, text);
      if (reason.length > 0) {
        Logger.info(`not forwarded hash=${notificationInfo.hashCode}: ${reason}`);
        return;
      }
      this.getForwarder().forward({
        id: notificationInfo.hashCode,
        bundleName: notificationInfo.bundleName,
        appName: notificationInfo.appName ?? notificationInfo.bundleName,
        title: title,
        text: text,
        time: notificationInfo.deliveryTime ?? Date.now(),
        test: false,
      });
    } catch (e) {
      Logger.error(`forward failed: ${JSON.stringify(e)}`);
    }
  }

  /** 验证码类通知：只把验证码发到 Mac 复制到剪贴板，不转发全文。返回 true 表示已按验证码处理。 */
  private tryForwardOtp(settings: SyncSettings, info: notificationExtensionSubscription.NotificationInfo,
    title: string, text: string): boolean {
    if (!settings.copyOtp || settings.paused || settings.blockedBundles.indexOf(info.bundleName) >= 0) {
      return false;
    }
    const code = extractOtp(title, text);
    if (code.length === 0) {
      return false;
    }
    Logger.info(`otp detected hash=${info.hashCode} len=${code.length}`);
    this.getForwarder().forwardOtp({
      id: info.hashCode,
      bundleName: info.bundleName,
      appName: info.appName ?? info.bundleName,
      code: code,
    });
    return true;
  }

  onCancelMessages(hashCodes: Array<string>): void {
    Logger.info(`onCancelMessages count=${hashCodes.length} hashes=${JSON.stringify(hashCodes)}`);
    const record: EventRecord = {
      kind: 'cancel',
      recordTime: Date.now(),
      cancelHashCodes: hashCodes,
    };
    appendRecord(this.context.filesDir, record);
    try {
      this.getForwarder().cancel(hashCodes);
    } catch (e) {
      Logger.error(`forward cancel failed: ${JSON.stringify(e)}`);
    }
  }

  onDestroy(): void {
    Logger.info('NotificationSubscriberExtAbility onDestroy');
    this.forwarder?.close();
    const record: EventRecord = {
      kind: 'destroy',
      recordTime: Date.now(),
    };
    appendRecord(this.context.filesDir, record);
  }
}
