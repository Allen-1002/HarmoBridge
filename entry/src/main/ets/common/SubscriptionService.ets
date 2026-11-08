import { abilityAccessCtrl, bundleManager, common, Permissions } from '@kit.AbilityKit';
import { access, connection } from '@kit.ConnectivityKit';
import { notificationExtensionSubscription } from '@kit.NotificationKit';
import { deviceInfo } from '@kit.BasicServicesKit';

export const PERM_SUBSCRIBE: Permissions = 'ohos.permission.SUBSCRIBE_NOTIFICATION';
export const PERM_BLUETOOTH: Permissions = 'ohos.permission.ACCESS_BLUETOOTH';

export interface PairedDevice {
  addr: string;
  name: string;
  bonded: boolean;
}

export class SystemInfo {
  osFullName: string = deviceInfo.osFullName;
  displayVersion: string = deviceInfo.displayVersion;
  marketName: string = deviceInfo.marketName;
  productModel: string = deviceInfo.productModel;
  sdkApiVersion: number = deviceInfo.sdkApiVersion;
  distributionOSApiVersion: number = deviceInfo.distributionOSApiVersion;
}

/** API 22 起提供订阅接口；openSubscriptionSettingsWithResult 需 26.0.0 起。 */
export function supportsSubscription(): boolean {
  return deviceInfo.sdkApiVersion >= 22;
}

export function supportsSettingsWithResult(): boolean {
  return deviceInfo.sdkApiVersion >= 26;
}

function selfTokenId(): number {
  const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
  return info.appInfo.accessTokenId;
}

/** 检查权限是否已授予（对 system_grant 的受限权限，取决于签名 Profile 是否带 ACL）。 */
export function isPermissionGranted(perm: Permissions): boolean {
  const atManager = abilityAccessCtrl.createAtManager();
  return atManager.checkAccessTokenSync(selfTokenId(), perm) === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
}

export async function requestBluetoothPermission(context: common.UIAbilityContext): Promise<boolean> {
  const atManager = abilityAccessCtrl.createAtManager();
  const result = await atManager.requestPermissionsFromUser(context, [PERM_BLUETOOTH]);
  return result.authResults.length > 0 && result.authResults[0] === 0;
}

export function isBluetoothOn(): boolean {
  return access.getState() === access.BluetoothState.STATE_ON;
}

/** 列出系统中已配对的蓝牙设备（真实配对，地址由系统提供，不做任何伪造）。 */
export function listPairedDevices(): Array<PairedDevice> {
  const ids = connection.getPairedDevices();
  const list: Array<PairedDevice> = [];
  for (const id of ids) {
    let name = '';
    try {
      name = connection.getRemoteDeviceName(id);
    } catch (e) {
      name = '';
    }
    let bonded = false;
    try {
      bonded = connection.getPairState(id) === connection.BondState.BOND_STATE_BONDED;
    } catch (e) {
      bonded = false;
    }
    list.push({ addr: id, name: name.length > 0 ? name : '(未知名称)', bonded: bonded });
  }
  return list;
}

export async function openGrantSettings(context: common.UIAbilityContext): Promise<string> {
  if (supportsSettingsWithResult()) {
    const setting = await notificationExtensionSubscription.openSubscriptionSettingsWithResult(context);
    const count = setting.grantedBundleInfos === undefined ? 0 : setting.grantedBundleInfos.length;
    return `授权页已关闭：总开关=${setting.userGrantEnabled}，已授权应用数=${count}`;
  }
  await notificationExtensionSubscription.openSubscriptionSettings(context);
  return '授权页已关闭（当前系统 API < 26，无返回结果，请点“刷新授权状态”查看）';
}

export async function isUserGranted(): Promise<boolean> {
  return notificationExtensionSubscription.isUserGranted();
}

export async function getGrantedBundles(): Promise<Array<notificationExtensionSubscription.GrantedBundleInfo>> {
  return notificationExtensionSubscription.getUserGrantedEnabledBundles();
}

export async function subscribe(addr: string): Promise<void> {
  const info: notificationExtensionSubscription.NotificationExtensionSubscriptionInfo = {
    addr: addr,
    type: notificationExtensionSubscription.SubscribeType.BLUETOOTH,
  };
  await notificationExtensionSubscription.subscribe([info]);
}

export async function unsubscribe(): Promise<void> {
  await notificationExtensionSubscription.unsubscribe();
}

export async function getSubscribeInfo(): Promise<Array<notificationExtensionSubscription.NotificationExtensionSubscriptionInfo>> {
  return notificationExtensionSubscription.getSubscribeInfo();
}
