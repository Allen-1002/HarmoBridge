# ESP32 模块串口协议

电脑通过 USB 串口（115200 8N1）连接 ESP32（固件在 `firmware/esp32`）。每行以 `\n` 结尾，UTF-8。

固件输出的行分三种，电脑只解析前两种：

- `HB-ESP32 <版本> chip=esp32 ble=<蓝牙地址> proto=1`：对 `HB?` 的回复（握手、检测固件）。
- `@{json}`：事件。
- 其他行：ESP-IDF 日志，忽略。

打开串口后电脑要把 DTR、RTS 都置为无效，否则开发板的自动下载电路会让 ESP32 停在复位或下载模式。

## 命令（电脑 → ESP32）

| 命令 | 作用 |
| --- | --- |
| `HB?` | 握手，回复 `HB-ESP32 ...` |
| `STATE?` | 立即输出一条 `state` 事件 |
| `PAIR` | 打开配对窗口 3 分钟，允许新的 iPhone 配对（还没有任何配对时一直允许） |
| `UNPAIR` | 删除所有 iPhone 配对并断开 |
| `UNPAIR <地址>` | 删除一台 iPhone 的配对（地址取自 `bonds` 事件），正连着的会断开 |
| `BONDS?` | 立即输出一条 `bonds` 事件 |
| `ACT <uid> <0或1>` | 对通知执行操作：0 正向（如接听），1 负向（如清除、拒接） |
| `REBOOT` | 重启 ESP32 |

## 事件（ESP32 → 电脑）

```text
@{"t":"state","ble":"advertising","peer":"","bonds":1,"pairing":false}
@{"t":"notif","ev":"add","uid":12,"flags":0,"cat":4,"app":"com.tencent.xin","appName":"微信","title":"张三","sub":"","msg":"晚上吃饭？","date":"20261110T094500","pos":"","neg":"清除","peer":"51:a8:27:cd:73:e0"}
@{"t":"bonds","list":[{"addr":"51:a8:27:cd:73:e0","name":"Allen 的 iPhone","connected":true,"ready":true}]}
@{"t":"removed","uid":12,"peer":"51:a8:27:cd:73:e0"}
@{"t":"acted","uid":12,"action":1}
@{"t":"err","code":"pairing_closed","msg":"有新 iPhone 请求配对，但配对窗口未打开"}
```

- `ble`：`idle` / `advertising`（等待 iPhone）/ `connected` / `encrypted` / `ready`（已订阅 ANCS，可以收通知）。
- `bonds`：所有配对过的 iPhone。`name` 是 iPhone 自己的设备名（连上后读取 GAP 设备名并存在 ESP32 上，第一次连上之前为空），`ready` 表示这台正连着且已订阅通知。连接、断开、配对、删除、读到名字时自动输出。
- `notif.peer` / `removed.peer`：发来通知的 iPhone 地址，对应 `bonds` 里的 `addr`（固件 1.2.3 起），电脑端据此显示 iPhone 的名字。
- `notif.flags`：ANCS EventFlags。1 静默、2 重要、4 已存在（连接时补发的旧通知，电脑不弹出）、8 有正向操作、16 有负向操作。
- `notif.cat`：ANCS CategoryID。1 来电、2 未接来电、3 语音留言、4 社交、5 日程、6 邮件、7 新闻、8 健康、9 商务、10 位置、11 娱乐、0 其他。
- `date`：iPhone 本地时间 `yyyyMMdd'T'HHmmSS`。
- 标题、副标题、正文分别最多 128、128、512 字节（iPhone 截断）。

## iPhone 连接方式（BLE ANCS）

ESP32 以名字 `NotiBridge` 广播，并带 ANCS 服务请求 UUID。iPhone 在「设置 › 蓝牙」里连接并配对（Just Works + 绑定）后，
ESP32 作为 GATT 客户端订阅 ANCS 的 Data Source 和 Notification Source。断开后 ESP32 持续广播，已配对的 iPhone 会自动重新连接。

已有配对时，新的 iPhone 只能在电脑上点“配对新的 iPhone”（`PAIR`）后的 3 分钟内配对，防止附近的陌生设备占用连接。

## 刷写

App 内置 ESP32 ROM 下载协议（与 esptool 相同的串口协议，不上传 stub）：RTS/DTR 复位进入下载模式 → SYNC →
SPI_ATTACH → SPI_SET_PARAMS → 切换到 460800 → FLASH_BEGIN/FLASH_DATA → SPI_FLASH_MD5 校验 → RTS 复位。
固件镜像是 `firmware/esp32/build_firmware.sh` 合并出的单个文件，从 0x1000 写入；板子上已是 NotiBridge 固件时跳过 [0x9000, 0x10000)（NVS 和 phy_init），保留 iPhone 配对。

## 固件发布

固件版本独立于 App（`firmware/esp32/CMakeLists.txt` 的 `PROJECT_VER`），用 `scripts/release_firmware.sh <版本> <说明.md>` 单独发布为
GitHub Release `firmware-v<版本>`，不标记为 Latest（App 的自动更新只看 Latest）。Release 里有 `NotiBridge-ESP32-<版本>.bin`、
`SHA256SUMS.txt` 和 `SHA256SUMS.txt.sig`（与 App 同一把 Ed25519 发布密钥）。电脑端安装包不带固件：点“刷写固件”时查询
`/releases` 里最新的 `firmware-v*`，下载并校验签名和哈希后刷写，并缓存一份供离线使用。
