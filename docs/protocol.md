# HarmoBridge 局域网协议 v1

手机（WebSocket 客户端）→ Mac（WebSocket 服务端，默认端口 47800，Bonjour 类型 `_harmobridge._tcp`）。
所有帧为 UTF-8 JSON 文本帧。只在本地局域网内传输，不经过任何第三方服务器。

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
Mac  → {"t":"pair_chal","macId":"<uuid>","macName":"<Mac 名称>","pub":"<b64>"}
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
| `ack` | Mac→手机 | `seq`、`result`: `shown` / `duplicate` / `filtered` / `paused` / `removed` / `copied` |

## 扩展预留

`kind` 以 `call.` 开头的消息保留给 ESP32 通话模块（接听/拨号/挂断/状态），通知模块忽略这些消息。
