# 可行性调研：鸿蒙读取通知的官方方式与限制

本文记录 HarmoBridge 在 HarmonyOS（API 22+）上读取其他应用通知的调研结论，所有结论来自华为官方 SDK 声明文件与官方文档，并在 HarmonyOS 7（API 26）真机上验证过。

## 唯一可行的官方方式

| 方式 | 结论 |
|---|---|
| `notificationExtensionSubscription` + `NotificationSubscriberExtensionAbility` | **可行**。普通应用可用，需受限权限 `ohos.permission.SUBSCRIBE_NOTIFICATION` 和一台已配对的蓝牙设备 |
| `notificationManager.subscribe()` | 不可行：需要 `NOTIFICATION_CONTROLLER`（system_core），仅系统应用 |
| 无障碍扩展 `AccessibilityExtensionAbility` | 不可行：需要 `ACCESSIBILITY_EXTENSION_ABILITY`，设备上的权限定义为仅系统应用可用 |
| hdc / hidumper 导出通知 | 不可行：量产系统无输出 |
| 安卓容器（卓易通等） | 只能看到容器内安卓应用的通知，且不在本项目范围 |

## 相关接口（API 22 起）

| 接口 | 说明 |
|---|---|
| `openSubscriptionSettingsWithResult(context)` | API 26 起。打开系统“允许获取本机通知”半模态页，返回用户选择 |
| `openSubscriptionSettings(context)` | API 22 起的旧版本，无返回值 |
| `subscribe([{ addr, type: SubscribeType.BLUETOOTH }])` | 订阅。`addr` 必须是已配对蓝牙设备的地址，目前只支持蓝牙类型 |
| `unsubscribe()` / `getSubscribeInfo()` | 取消订阅 / 查询订阅 |
| `isUserGranted()` / `getUserGrantedEnabledBundles()` | 查询用户授权状态与已授权应用 |
| `NotificationSubscriberExtensionAbility` | `onReceiveMessage(NotificationInfo)`、`onCancelMessages(hashCodes)`、`onDestroy()`；module.json5 中 `type: "notificationSubscriber"` |

`NotificationInfo` 包含：`hashCode`、`notificationSlotType`、`content.title`、`content.text`、`bundleName`、`appName`、`deliveryTime`、`groupName`、`appIndex`。

## 权限与签名

- `ohos.permission.SUBSCRIBE_NOTIFICATION`：受限开放权限，system_basic、系统授权（不会弹窗），官方列出的使用场景是“支持展示通知的智能手表使用的穿戴应用”。
- **上架**：需要在 AppGallery Connect 申请并通过人工审核（约 3 个工作日），非穿戴场景大概率不通过。
- **自用调试**：DevEco Studio 6.0.2 Beta1 起，自动签名支持该 ACL，生成的调试 Profile 中会包含它（实测有效）。调试 Profile 与调试证书有效期 14 天，只对签名时登记的设备有效，到期需重新签名（见 [renew-signing.md](renew-signing.md)）。

## 蓝牙设备要求

- 官方前提：用户已与一台蓝牙设备**配对**，并在系统授权页中开启“允许获取本机通知”。
- 实测：使用一台已配对的 Mac 作为订阅设备即可成功订阅并收到通知；订阅建立后只需保持配对，不需要一直保持蓝牙连接。
- 支持 HFP 的设备，官方要求保持 HFP 连接。
- 不使用、也不支持伪造蓝牙地址。

## 后台行为（实测）

- `NotificationSubscriberExtensionAbility` 由系统按需拉起，主应用被清理出后台、手机熄屏后仍能收到并转发通知；一段时间无通知会被系统销毁。
- 不需要、也不应该使用长时任务保活。

## 错误码

| 错误码 | 含义 | 诊断 |
|---|---|---|
| 201 | 权限被拒绝或设备不支持 | 检查签名 Profile 是否包含 `SUBSCRIBE_NOTIFICATION` |
| 1600001 | 内部错误 | 重试，查看 hilog |
| 1600003 | 连接通知服务失败 | 稍后重试 |
| 1600018 | 授权页已打开 | 关闭后重试 |
| 1600023 | 未实现 NotificationSubscriberExtensionAbility | 检查 module.json5 的 `notificationSubscriber` 扩展配置 |
| 2900003 | 蓝牙未打开 | 打开蓝牙 |

## 通话（实验结论）

macOS 自带的 `IOBluetoothHandsFreeDevice` 理论上可以让 Mac 作为 HFP 免提设备，但实测手机拒绝了 Mac 发起的 HFP RFCOMM 连接。通话功能计划改用 ESP32（经典蓝牙 HFP + USB 串口），Mac 端已预留 `CallBridge` 接口。
