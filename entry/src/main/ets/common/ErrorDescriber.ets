import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 错误码 -> 可读说明 + 诊断建议。
 * 来源：notificationExtensionSubscription / bluetooth.connection 的 d.ts 与华为官方错误码文档。
 */
const DESCRIPTIONS: Map<number, string> = new Map<number, string>([
  [201, '权限被拒绝或当前设备不支持。检查签名 Profile 是否包含 ohos.permission.SUBSCRIBE_NOTIFICATION（ACL），或蓝牙权限是否已授权'],
  [202, '调用了系统接口，三方应用不可用'],
  [401, '参数错误（如蓝牙地址格式不对）'],
  [801, '设备不支持该能力'],
  [1600001, '通知服务内部错误，可稍后重试，并用 hilog 查看系统侧日志'],
  [1600003, '连接通知服务失败（服务繁忙或异常），稍后重试'],
  [1600018, '通知授权页面已经打开，请先关闭再试'],
  [1600023, '应用未实现或未正确配置 NotificationSubscriberExtensionAbility（检查 module.json5 中 type: notificationSubscriber）'],
  [2900001, '蓝牙服务已停止'],
  [2900003, '蓝牙未打开'],
  [2900099, '蓝牙操作失败'],
  [12100001, '权限参数无效'],
]);

export function describeError(err: Object): string {
  const be = err as BusinessError;
  const code: number = be.code === undefined ? -1 : Number(be.code);
  const known = DESCRIPTIONS.get(code);
  const msg = be.message === undefined ? '' : be.message;
  return `错误码 ${code}: ${known !== undefined ? known : '未收录的错误'}${msg.length > 0 ? `（系统信息: ${msg}）` : ''}`;
}
