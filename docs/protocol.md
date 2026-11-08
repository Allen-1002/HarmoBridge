# HarmoBridge 局域网协议 v1.1

手机（WebSocket 客户端）→ 电脑（Mac 或 Windows，WebSocket 服务端，默认端口 47800，mDNS / DNS-SD 类型 `_harmobridge._tcp`）。
所有帧为 UTF-8 JSON 文本帧。只在本地局域网内传输，不经过任何第三方服务器。
下文中的“Mac”指任一电脑端，Mac 与 Windows 客户端实现完全相同的协议，手机不需要区分。

## 多设备拓扑（v1.1）

- 一台手机可以配对多台电脑：手机为每台电脑分别保存配对密钥（按电脑 `macId` 区分），每台电脑一条独立的加密连接，
  每条通知同时转发给所有已配对的电脑；某台电脑离线不影响其他电脑。
- 一台电脑可以配对多台手机：电脑为每台手机分别保存密钥（按手机 `deviceId` 区分），可同时有多台手机在线。
  电脑端用“手机 deviceId + 通知 id”作为通知标识和去重键，不同手机的通知 id 相同也不会互相覆盖。
- 连接始终由手机发起（手机后台无法长期监听端口）；连接建立后消息双向流动。
- 服务广播的 TXT 记录：`id=<macId>`、`platform=mac|windows`。手机据此识别已配对的电脑，电脑换 IP 后自动更新地址。
  服务实例名为 `HarmoBridge-<电脑名>`。

## 密码学约定（两端必须完全一致）

| 项 | 定义 |
|---|---|
| 密钥交换 | X25519，公钥用 32 字节原始格式，Base64 传输 |
| transcript | `phonePub(32) ‖ macPub(32)` |
| salt | `SHA-256(transcript)` |
| 配对密钥 | `HKDF-SHA256(ikm = X25519 共享密钥, salt, info = UTF8("HarmoBridge-pair-v1|" + PIN), 32 字节)` |
| 校验码 SAS | `salt` 前 3 字节的大写十六进制（6 位），两端同时显示，供用户肉眼比对，防中间人 |
| 加密 `seal(k, s)` | AES-256-GCM，IV 12 字节随机，AAD = UTF8("HB1")，输出 `Base64(iv ‖ ciphertext ‖ tag16)` |

PIN 为 Mac 端显示的 6 位数字，2 分钟有效，错误 3 次后作废重新生成。

## 配对

```
手机 → {"t":"pair_req","deviceId":"<uuid>","deviceName":"<手机名称>","pub":"<b64>"}
Mac  → {"t":"pair_chal","macId":"<uuid>","macName":"<电脑名称>","platform":"mac|windows","pub":"<b64>"}
        （双方各自计算 key 与 SAS；用户在手机上输入 PIN、核对 SAS）
手机 → {"t":"pair_confirm","box":seal(key,"pair-confirm-phone")}
Mac  → {"t":"pair_ok","box":seal(key,"pair-confirm-mac")}   或 {"t":"error","code":"bad_pin"}
```

成功后：Mac 把 `deviceId → key` 存入钥匙串；手机把 key 存入 Asset Store（系统安全存储）。

## 会话认证（每次连接）

```
手机 → {"t":"hello","deviceId":"<uuid>","nonce":"<b64 16B>"}
Mac  → {"t":"challenge","nonce":"<b64 16B>"}         未配对设备 → {"t":"error","code":"unknown_device"} 并断开
手机 → {"t":"auth","box":seal(key,"auth|<phoneNonce>|<macNonce>")}
Mac  → {"t":"auth_ok","box":seal(key,"ok|<macNonce>|<phoneNonce>")}
```

认证前 Mac 不接受任何业务消息；认证失败立即断开。

## 业务消息（认证后）

```
{"t":"msg","box":seal(key, <inner JSON>)}
```

inner JSON 必带 `sid`（= 本次会话 macNonce）和递增 `seq`，Mac 拒绝 sid 不符或 seq 不递增的消息（防重放）。

| kind | 方向 | 字段 |
|---|---|---|
| `notify` | 手机→Mac | `id`(通知 hashCode)、`bundleName`、`appName`、`title`、`text`、`time`(ms)、`test`(bool，true 表示手动测试消息，不是系统通知) |
| `cancel` | 手机→Mac | `ids`: string[] |
| `otp` | 手机→Mac | `id`、`bundleName`、`appName`、`code`（4~8 位数字，只发验证码，不发短信全文）；Mac 复制到剪贴板，2 分钟后清除 |
| `ping` | 手机→Mac | — |
| `ack` | Mac→手机 | `seq`、`result`: `shown` / `duplicate` / `filtered` / `paused` / `removed` / `copied` / `pong` |
| `settings` | 双向 | `paused`、`blockSensitive`、`copyOtp`、`updatedAt`(ms)。按 `updatedAt` “后改的为准”。手机连上后先发一次；电脑回传合并结果（`seq` 沿用手机的）。电脑上改了开关时主动推送给所有在线手机（`seq` 用电脑自己的递增序号），并把某台手机发来的更新转发给其他在线手机 |

手机不校验电脑发来消息的 `seq`，只校验 `sid`。

## 扩展预留

`kind` 以 `call.` 开头的消息保留给 ESP32 通话模块（接听/拨号/挂断/状态），通知模块忽略这些消息。
