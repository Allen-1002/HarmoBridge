import { notificationExtensionSubscription, NotificationSubscriberExtensionAbility } from '@kit.NotificationKit';
import { ExtForwarder } from '../common/ExtForwarder';
import { Logger, maskText } from '../common/Logger';
import { appendRecord, deleteLegacyRecords, EventRecord } from '../common/NotificationStore';
import { MacInfo, pairedComputers } from '../common/PairingStore';
import { decide, Decision, loadSettings, SyncSettings } from '../common/PhoneFilter';

/**
 * 系统通知服务在订阅成功、用户已授权后，把本机通知转发到这里。
 * 生命周期由系统管理：有通知时拉起，一段时间无新通知会被系统自动销毁，不做任何保活。
 *
 * 收到通知后：手机端过滤（暂停 → 按应用屏蔽 → 验证码 → 敏感过滤）→ 通过已配对的加密连接转发到每台电脑
 * → 只把元数据写入本地记录（不含标题和正文；敏感内容不记录）。
 */
export default class NotificationSubscriberExtAbility extends NotificationSubscriberExtensionAbility {
  private forwarder: ExtForwarder | undefined = undefined;
  private legacyChecked: boolean = false;

  private getForwarder(): ExtForwarder {
    if (this.forwarder === undefined) {
      this.forwarder = new ExtForwarder(this.context);
    }
    return this.forwarder;
  }

  onReceiveMessage(notificationInfo: notificationExtensionSubscription.NotificationInfo): void {
    if (!this.legacyChecked) {
      this.legacyChecked = true;
      deleteLegacyRecords(this.context.filesDir);
    }
    const title = notificationInfo.content?.title ?? '';
    const text = notificationInfo.content?.text ?? '';
    // 日志只输出元数据，标题/正文脱敏
    Logger.info(`onReceiveMessage hash=${notificationInfo.hashCode} bundle=${notificationInfo.bundleName} ` +
      `slot=${notificationInfo.notificationSlotType} title=${maskText(title)} text=${maskText(text)}`);
    const appName = notificationInfo.appName ?? notificationInfo.bundleName;
    let result = '';
    let targets = '';
    let record = true;
    try {
      const settings: SyncSettings = loadSettings(this.context);
      const d: Decision = decide(settings, notificationInfo.bundleName, title, text);
      result = d.reason;
      record = d.record;
      const computers: Array<MacInfo> = pairedComputers(this.context);
      if (d.action !== 'drop') {
        if (computers.length === 0) {
          result = '未配对电脑';
        } else {
          targets = computers.map((m: MacInfo) => m.macName).join('、');
          if (d.action === 'otp') {
            Logger.info(`otp detected hash=${notificationInfo.hashCode} len=${d.otp.length}`);
            this.getForwarder().forwardOtp({
              id: notificationInfo.hashCode,
              bundleName: notificationInfo.bundleName,
              appName: appName,
              code: d.otp,
            });
          } else {
            this.getForwarder().forward({
              id: notificationInfo.hashCode,
              bundleName: notificationInfo.bundleName,
              appName: appName,
              title: title,
              text: text,
              time: notificationInfo.deliveryTime ?? Date.now(),
              test: false,
            });
          }
        }
      } else {
        Logger.info(`not forwarded hash=${notificationInfo.hashCode}: ${d.reason}`);
      }
    } catch (e) {
      result = '转发失败';
      Logger.error(`forward failed: ${JSON.stringify(e)}`);
    }
    if (record) {
      const r: EventRecord = {
        kind: 'publish',
        recordTime: Date.now(),
        hashCode: notificationInfo.hashCode,
        bundleName: notificationInfo.bundleName,
        appName: appName,
        deliveryTime: notificationInfo.deliveryTime,
        result: result,
        targets: targets,
      };
      appendRecord(this.context.filesDir, r);
    }
  }

  onCancelMessages(hashCodes: Array<string>): void {
    Logger.info(`onCancelMessages count=${hashCodes.length}`);
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
  }
}
