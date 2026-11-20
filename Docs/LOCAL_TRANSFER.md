# 局域网首次加入保险库

## 用户流程

在发送设备解锁 Aegis，在「设置 → 同步与备份」选择连接新设备。接收设备在首次进入页选择「从局域网导入」，选中发送设备并连接。两台设备各自显示六位数字。核对全部数字后，两端分别点击「数字一致」。发送设备随后验证本机身份（必要时使用主密码），再导出并发送加密快照。接收设备验证快照后，可搜索、筛选和勾选条目，再单独确认导入。

导入保留原 `VaultHeader`、vault ID、保险库密钥、所选条目的不可变版本 ID、主密码和恢复密钥。生物识别凭据和设备草稿留在原设备。预览不写数据库，确认时 `restoreNewVault` 检查目标仍为空并事务提交。确认前若目标库已被初始化，导入会停止。

接收设备会先收到并验证整份加密快照。勾选范围只控制写入本机的条目。日后启用[持续同步](LAN_SYNC_DESIGN.md)时，其他条目也可能同步到本机。

## 发现与权限

- Bonjour 服务为 `_aegis-pair._tcp`，域为 `local.`。服务名称 `Aegis-<随机 8 字符>` 只供发现，设备身份由两端人工比对确认。
- 使用普通 TCP，禁止蜂窝接口，关闭 AWDL。两端均需在前台，发送端须保持解锁。关闭页面、进入后台或发送端锁定会取消配对。
- 主应用声明 `NSBonjourServices` 与 `NSLocalNetworkUsageDescription`。macOS 沙盒含网络 client/server 权限，覆盖 ad-hoc 安装包。自动填充扩展不开放监听。
- 访客网络、AP 隔离、防火墙或拒绝本地网络权限可能阻止发现和连接。

## 配对与线格式

局域网首次加入使用协议 v2，magic 为 8 字节 ASCII `AEGISLN2`。所有拼接均为原始字节，文本常量使用 UTF-8，TCP 读取处理任意分片。

1. 接收端先发 magic 和 32 字节承诺，发送端以相同格式回复。随后接收端、发送端按序公开 `X25519 公钥 || 32 字节随机量`。承诺为 SHA-256，输入依次是 `aegis.join.v2.commit`、magic、单字节角色（接收端 1，发送端 2）及公开内容。各端验证对方承诺后才接受握手。
2. 摘要取 `SHA256(magic || 接收端承诺 || 发送端承诺 || 接收端公开内容 || 发送端公开内容)`。以 X25519 共享秘密为输入、摘要为盐，使用 HKDF-SHA256 派生各 32 字节材料。info 前缀为 `aegis.join.v2.`，用途分别为 `receiver-to-sender`、`sender-to-receiver`、`abb-password` 和 `comparison`。
3. 使用 `comparison` 作为密钥，对单字节计数器 `0...7` 计算 HMAC-SHA256。依序读取输出中的 UInt32 大端候选值，取首个小于 4,294,000,000 的候选值对 1,000,000 取余，并补齐前导零。六位数字只在本机显示。核对全部数字时，单次错误匹配的概率约为百万分之一。
4. 加密帧依次为 UInt32 大端长度、ChaChaPoly 密文和 16 字节标签，长度包含密文和标签。每个方向的 nonce 为四个零字节和从零增长的 UInt64 大端计数。明文首字节为类型，依次为接收方同意 `1`、发送方同意 `2`、文件长度 `3`、文件块 `4`、文件摘要 `5` 和收据 `6`。
5. 双方确认后，发送端完成身份验证，再用 `abb-password` 派生结果的大写十六进制文本作为一次性口令导出 ABB。ABB 包含原保险库槽，格式见 [ABB 规范](BACKUP_FORMAT_DESIGN_V1.md)。文件长度为 UInt32 大端，范围为 `1...BackupLimits.maxFileLength`。每块最多 64 KiB，文件摘要与收据均为完整文件的 SHA-256。收据表示接收端已收齐文件并检查容器结构，完整解密和导入另行完成。
6. 邀请 5 分钟有效，同时只处理一条连接，单次连接最多 120 秒。成功发送一次或累计三次失败后关闭邀请。

## 验证

核心测试覆盖双方导出门槛、配对拒绝、重连、旧确认失效、失败次数上限、文件长度，以及加入后原保险库 ID、密钥、主密码和恢复密钥。以下命令会启用同机真实 Bonjour/TCP 测试。

```sh
AEGIS_TEST_LOCAL_NETWORK=1 uv run Scripts/build_isolation.py exec --root "$PWD" --lane core-test -- \
  swift test --build-system native --manifest-cache local --package-path Packages/AegisKit --filter 'LANPairingTests|LocalTransferTests'
```

iOS UI 测试检查首次进入可以打开导入页、未选设备时不能连接、没有长码输入、取消后仍未初始化，以及仅写入选中的条目。Mac 与签名 iPhone 的跨设备流程和本地网络权限需另行真机验证。
