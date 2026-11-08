# 每 14 天续签

自用不上架时，`SUBSCRIBE_NOTIFICATION` 来自 DevEco 自动签名生成的**调试** Profile。实测：Profile 和调试证书都只有 14 天有效期，只对已登记的手机有效。官方文档中，更长有效期的 Profile 只有在 AGC 正式审批通过 ACL 后才能拿到，手动签名同样需要在 AGC 申请 ACL，所以自用没有更长期的官方方式。

## 查看剩余天数

```bash
./scripts/install_phone.sh --check
```

## 续签（约 1 分钟）

1. 打开 DevEco Studio 中的 HarmoBridge 工程，手机通过 USB 或无线调试连接（`hdc list targets` 能看到设备）。
2. File > Project Structure > Project > Signing Configs：取消勾选再重新勾选 **Automatically generate signature**，点 OK（需已登录华为账号，本机时间与北京时间一致）。
3. 运行：

```bash
./scripts/install_phone.sh
```

脚本会检查新 Profile 的到期时间和 ACL，然后构建、用 `install -r` 覆盖安装（保留 App 数据）并启动。

覆盖安装后，正常情况下 Mac 配对和蓝牙订阅都还在。如果首页显示未订阅，点一次“开始订阅”；如果 Mac 显示无法认证，就重新配对。

Profile 过期后手机上的 App 可能无法启动，通知也会停止转发，建议在到期前 1～2 天续签。
