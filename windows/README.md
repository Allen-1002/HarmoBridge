# HarmoBridge for Windows

把鸿蒙手机通知同步到 Windows 电脑，功能与 Mac 版一致，和 Mac 版使用**同一套局域网加密协议**（[docs/protocol.md](../docs/protocol.md)）。
手机端还是同一个 HarmoBridge App：一台手机可以同时连接多台电脑（Mac、Windows 混用都可以），一台电脑也可以配对多台手机。

## 功能

- 托盘常驻（任务栏右下角），关闭窗口不退出；左键打开主窗口，右键菜单可暂停同步、配对新手机、复制最近的验证码
- 手机通知显示在 Windows 通知中心，带原应用图标（电脑上装了同名应用就用它的图标，否则用彩色首字母）；手机上清除后电脑上也移除
- 验证码自动复制到剪贴板，2 分钟后自动清除，不进入“剪贴板历史（Win+V）”和云剪贴板
- 6 位配对码 + 校验码核对，X25519 + AES-256-GCM，配对密钥用 Windows DPAPI 加密保存，只有当前 Windows 账户能解密
- 局域网自动发现（系统自带 DNS-SD 广播 `_harmobridge._tcp`），找不到时手机上可手动输入 IP
- 白名单 / 黑名单 / 敏感关键词过滤；“暂停同步”“敏感过滤”“验证码复制”三个开关与所有在线手机双向同步
- 首次启动引导、开机启动（当前用户 Run 注册表项，不需要管理员权限）

系统要求：Windows 10 1809 或更新（推荐 Windows 11），x64。

## 编译

需要 [.NET 10 SDK](https://dotnet.microsoft.com/download)。可以在 Windows 上编译，也可以在 Mac 上交叉编译：

```bash
# macOS：brew install --cask dotnet-sdk
cd windows
./build.sh            # Windows 上用 .\build.ps1
```

产物是 `windows/dist/HarmoBridge.exe`（单文件，约 85 MB，自带 .NET 运行时，复制到 Windows 上直接运行即可）。
加 `-p:SelfContained=false` 可以打出依赖系统 .NET 10 桌面运行时的小体积版本（约 30 MB，压缩后约 10 MB）。

只跑协议单元测试（任何系统都可以）：

```bash
cd windows && dotnet test tests/HarmoBridge.Core.Tests
```

测试包括：与 Mac 端相同的协议场景、用独立实现（Python cryptography）算出的密码学测试向量、以及两台模拟手机同时通过真实 WebSocket 连接同一台电脑的端到端测试。

## 首次运行

1. 双击 `HarmoBridge.exe`。SmartScreen 提示“未知发布者”时点“更多信息 → 仍要运行”（程序未做代码签名）。
   程序会询问是否安装到这台电脑：选“是”会复制到 `%LOCALAPPDATA%\Programs\HarmoBridge\`，
   在开始菜单和桌面创建快捷方式，并出现在“设置 > 应用 > 已安装的应用”里（不需要管理员权限）。
   之后下载的压缩包可以删掉。选“否”就直接从当前位置运行，以后可以在“设置 > 关于”里再安装。
   运行新版本 exe 时会提示更新已安装的版本。加 `--portable` 参数运行则不提示安装。
2. Windows 防火墙弹窗时勾选**专用网络**并允许。当前 Wi-Fi 被设为“公用网络”时手机连不上，需要在 设置 > 网络和 Internet 里改为“专用”。
3. 按引导发送一条测试通知，确认右下角能弹出（专注助手 / 勿扰模式会拦截通知）。
4. 手机 HarmoBridge →“电脑连接”→“添加电脑”，选择这台电脑，输入电脑上显示的配对码，核对校验码。

鸿蒙系统要求“读取通知”必须绑定一台已配对的蓝牙设备。手机已经绑定过其他电脑（比如 Mac）的话不用再配对蓝牙；
否则可以在 Windows“设置 > 蓝牙和其他设备”里和手机配对，再在手机 App 里选择这台电脑。通知本身走局域网，平时不需要蓝牙连接。

## 数据位置

| 内容 | 位置 |
|---|---|
| 设置 | `%APPDATA%\HarmoBridge\settings.json` |
| 已配对手机（密钥经 DPAPI 加密） | `%APPDATA%\HarmoBridge\paired.json` |
| 应用图标缓存、错误日志 | `%LOCALAPPDATA%\HarmoBridge\` |

通知内容只保存在内存里，不写磁盘；日志不记录通知标题和正文。

## 卸载

在“设置 > 应用 > 已安装的应用”里找到 HarmoBridge 点“卸载”，或在程序“设置 > 关于”里点“卸载 HarmoBridge”。
卸载会退出程序、移除开机启动、通知注册、快捷方式和程序文件，并询问是否同时删除配对和设置数据。
没有安装、直接运行 exe 的话：运行 `HarmoBridge.exe --uninstall`，再删除 exe。

## 代码结构

```
windows/
├── src/HarmoBridge.Core/        # 跨平台协议核心（net10.0，可在 Mac/Linux 上测试）
│   ├── BridgeCrypto.cs          # X25519 / HKDF / AES-GCM / 校验码，对应 BridgeCrypto.swift
│   ├── Messages.cs              # 协议帧
│   ├── SessionMachine.cs        # 每个连接的配对/认证/防重放状态机，对应 SessionMachine.swift
│   ├── SyncPolicy.cs            # 过滤与去重
│   └── BridgeServer.cs          # WebSocket 服务端（TcpListener，不需要管理员权限），多连接
├── src/HarmoBridge.Windows/     # WPF 界面（Fluent 主题）、托盘、Toast 通知、DPAPI、DNS-SD、开机启动
└── tests/HarmoBridge.Core.Tests # xUnit
```
