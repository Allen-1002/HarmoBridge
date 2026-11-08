# HarmoBridge

把 **HarmonyOS（鸿蒙）手机** 上的通知同步到 **Mac**，在 macOS 通知中心显示；验证码自动复制到 Mac 剪贴板。全部在局域网内端到端加密传输，不经过任何服务器，也不依赖安卓容器。

- 鸿蒙端：ArkTS + ArkUI（Stage 模型，API 22+，推荐 API 26）
- Mac 端：Swift + SwiftUI 菜单栏应用（macOS 14+，macOS 26 上使用 Liquid Glass 界面）

## 功能

- **通知镜像**：微信、QQ、短信、邮件等通知实时出现在 macOS 通知中心；手机上撤销后，Mac 上同步移除。通知右侧会显示原应用图标：Mac 上装了对应应用的用它的图标，否则显示彩色首字母
- **验证码自动复制**：识别验证码短信后只发送验证码数字（不发全文），Mac 自动复制到剪贴板，2 分钟后清除
- **过滤**：默认不转发银行、支付类通知；手机端和 Mac 端都可以按应用屏蔽，Mac 端支持白名单/黑名单
- **去重与暂停**：同一条通知不重复弹出；两端都可以一键暂停同步
- **后台可靠**：手机端通知由系统按需拉起的扩展进程转发，清理后台、熄屏后依然有效，不做任何保活
- **安全配对**：6 位配对码 + 两端校验码核对；之后每次连接双向认证，所有消息 AES-256-GCM 加密并防重放

## 工作原理

```
鸿蒙手机                                                Mac
┌────────────────────────────────┐   局域网 WebSocket    ┌───────────────────────────┐
│ NotificationSubscriber 扩展    │ ───(X25519 + AES-GCM)──▶ │ 菜单栏应用                │
│  · 系统按需拉起，收到通知      │     Bonjour 自动发现    │  · 认证、解密、去重、过滤 │
│  · 过滤 / 提取验证码 / 转发    │                         │  · macOS 通知中心 / 剪贴板│
└────────────────────────────────┘                         └───────────────────────────┘
        ▲ 系统要求：订阅时绑定一台已配对的蓝牙设备（可以就是这台 Mac）
```

鸿蒙读取第三方通知的**唯一官方方式**是“通知订阅扩展能力”（`notificationExtensionSubscription` + `NotificationSubscriberExtensionAbility`）。它有两个硬性前提：

1. 受限权限 `ohos.permission.SUBSCRIBE_NOTIFICATION`
2. 一台**已配对**的蓝牙设备（系统设计给“手表配套应用”使用）

详见 [docs/feasibility.md](docs/feasibility.md)。

## ⚠️ 使用前必读：鸿蒙端需要自己签名安装

`SUBSCRIBE_NOTIFICATION` 是受限权限，只有两种获得方式：

| 方式 | 说明 |
|---|---|
| **DevEco Studio 自动签名（调试）** | 用自己的华为开发者账号自动签名，生成的调试 Profile 会包含该权限。**只对你登记的手机有效，每 14 天到期**，到期后重新签名安装即可（约 1 分钟，见 [docs/renew-signing.md](docs/renew-signing.md)） |
| AppGallery Connect 正式申请 | 需人工审核，官方场景是智能手表配套应用，本项目这类用途大概率无法通过 |

因此 Release 里的鸿蒙安装包是**未签名**的，不能直接安装；推荐直接用 DevEco Studio 打开源码运行。

## 安装

### Mac 端

1. 在 [Releases](../../releases) 下载 `HarmoBridge-<版本>-macOS.dmg`，把 HarmoBridge 拖到“应用程序”。
2. 安装包没有经过 Apple 公证。第一次打开时，在“应用程序”里**右键 HarmoBridge →“打开”**，或者在“系统设置 > 隐私与安全性”中点“仍要打开”。
3. 首次启动会进入引导，按提示授予权限并生成配对码。

### 鸿蒙端

需要：DevEco Studio 6.0.2 或更高版本、华为开发者账号、HarmonyOS API 22 或更高版本的手机（推荐 API 26）。

1. 手机开启开发者模式和 USB 调试，连接电脑。
2. 用 DevEco Studio 打开本仓库根目录，等待同步完成。
3. **File > Project Structure > Project > Signing Configs**，勾选 **Automatically generate signature**，登录华为账号。签名完成后，把鼠标悬停在 Profile 上，确认 ACL 中包含 `ohos.permission.SUBSCRIBE_NOTIFICATION`。
4. 点 Run 安装到手机，或者在终端运行 `./scripts/install_phone.sh`。

> 也可以用自己的证书，给 Release 中的 `*-HarmonyOS-unsigned.hap` 签名后再安装，但同样需要包含上述 ACL 的 Profile。

## 首次使用

两端第一次打开都会进入引导：

1. **手机**：允许读取通知（在系统页面里选择要同步的应用）→ 选择或扫描配对一台蓝牙设备（推荐这台 Mac）→ 输入 Mac 上显示的配对码，并核对两端校验码一致。
2. **Mac**：授予权限 → 显示配对码 → 完成。

让手机通过蓝牙找到 Mac：在 Mac 上打开“系统设置 > 蓝牙”并保持页面打开，然后在手机 HarmoBridge 的“蓝牙设备 > 扫描”里配对。订阅成功后只需保持配对，不需要一直连接。

## 权限说明

### 鸿蒙端

| 权限 | 类型 | 用途 |
|---|---|---|
| `ohos.permission.SUBSCRIBE_NOTIFICATION` | 受限，随签名授予 | 读取你在系统授权页中选择的应用的通知 |
| 系统授权页“允许获取本机通知” | 用户授权 | 由你逐个选择允许读取哪些应用 |
| `ohos.permission.ACCESS_BLUETOOTH` | 用户授权 | 读取已配对设备列表、扫描并配对，用于选择订阅所需的蓝牙设备 |
| `ohos.permission.INTERNET` | 系统授权 | 通过局域网连接自己的 Mac |

### Mac 端

| 权限 | 必要性 | 用途 |
|---|---|---|
| 通知 | 必需 | 显示手机通知和“验证码已复制”提示 |
| 本地网络 | 必需 | 被同一 Wi-Fi 下的手机发现，接收加密通知 |
| 钥匙串 | 必需 | 保存配对密钥（系统询问时选“始终允许”） |
| 蓝牙 | 推荐 | 让 Mac 作为鸿蒙订阅所需的蓝牙配对设备 |
| 登录时启动 | 推荐 | 开机后自动在菜单栏运行 |
| 麦克风 | 可选 | 仅用于实验性通话功能 |

## 隐私与安全

- 只在你的手机和你的 Mac 之间通过局域网传输，没有服务器，没有统计或上报
- 配对：X25519 密钥交换 + 配对码派生密钥，两端显示 6 位校验码供人工比对，防中间人
- 每次连接双向挑战应答，未配对或密钥不对的设备直接断开；业务消息 AES-256-GCM 加密，带会话 ID 和递增序号防重放
- 密钥分别存放在 Mac 钥匙串和鸿蒙 Asset Store（系统安全存储）中
- 两端日志都不记录通知标题和正文；通知列表默认隐藏内容

协议细节见 [docs/protocol.md](docs/protocol.md)。

## 从源码构建

```bash
# Mac 端：构建 .app（ad-hoc 签名）并安装到 /Applications
cd mac
./build_app.sh release install

# Mac 端：协议单元测试
swift test

# 鸿蒙端：命令行构建（需要 DevEco Studio）
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export PATH=/Applications/DevEco-Studio.app/Contents/tools/node/bin:$PATH
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap --mode module -p product=default -p buildMode=debug
```

## 目录结构

```
entry/src/main/ets/
├── extensionability/NotificationSubscriberExtAbility.ets  # 系统拉起的通知订阅扩展
├── common/       # 订阅、蓝牙、加密、配对存储、过滤、转发
├── components/   # 通用 UI 组件、蓝牙面板、Mac 配对面板
└── pages/        # 引导、首页（首页/通知/设置）、蓝牙、Mac 连接、应用屏蔽、调试
mac/
├── Sources/HarmoBridgeCore/   # 协议、加密、会话状态机、过滤与去重（可单元测试）
├── Sources/HarmoBridgeMac/    # 菜单栏应用、WebSocket 服务、通知、首次引导
└── Tests/
docs/             # 可行性调研、协议、续签说明
scripts/          # 手机端构建安装脚本
```

## 已知限制

- 鸿蒙端依赖调试签名，每 14 天需要重新签名一次
- 必须有一台已配对的蓝牙设备（系统规定）
- Mac 端未经 Apple 公证，首次打开需要手动放行
- 手机和 Mac 需要在同一局域网内

## 计划

- 通话桥接：ESP32（经典蓝牙 HFP + USB 串口）让 Mac 接听手机来电。Mac 端已预留 `CallBridge` 接口；实测表明 macOS 自身无法作为 HFP 免提设备连接鸿蒙手机。

## 许可证

[MIT](LICENSE) © 2026 Shenghao Xu (徐晟皓)
