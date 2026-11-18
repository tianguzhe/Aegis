# 局域网首次加入保险库（协议 v1）

## 用户流程与范围

新设备首次进入页提供“从局域网导入”“从备份文件恢复”和新建保险库三个入口，无须先创建主密码。旧设备解锁后在“设置 → 数据 → 通过局域网连接新设备”验证设备身份（不可用时验证主密码），生成临时配对码并等待连接。新设备选择发现的服务，输入完整配对码，验证快照后勾选要导入的条目，可搜索或按类型筛选，再显式确认导入。

导入保留原 `VaultHeader`、vault ID、保险库密钥、所选条目的不可变版本 ID、主密码和恢复密钥。不创建新的保险库身份，不迁移生物识别凭据或设备草稿。预览不写数据库；确认时 `restoreNewVault` 在一次 store actor 调用内检查目标仍为空并事务提交。期间出现其他初始化或云端保险库时拒绝，不自动跨库合并。

这是首次加入时的单次快照传输，不是持续双向局域网同步。传输期间新增的内容不包含在已准备的快照中。两端均需在前台运行，发送端保持解锁；用户离开页面、应用进入后台或锁定时停止服务与连接。配对码仅在当前发送会话内有效，5 分钟过期；成功发送一次后停止服务。

## 发现与权限

- 标准 mDNS / DNS-SD，服务类型 `_aegis-join._tcp`，域 `local.`。
- 服务名称 `Aegis-<随机 8 字符>`，不发布条目、主密码、配对码、密钥或 vault ID；服务名不是已验证的设备身份。
- 传输使用 TCP，无 Apple 专用多点连接协议；禁止蜂窝接口，不启用 AWDL。Android 可通过 NSD 发现服务、普通 TCP socket 实现协议。
- 主应用声明 `NSBonjourServices` 与 `NSLocalNetworkUsageDescription`；macOS 沙盒含网络 client/server 权限，包括 ad-hoc 安装包。自动填充扩展不开放监听。
- 同一 Wi-Fi 或有线路由可连通时可用；访客网络、AP 隔离、防火墙或拒绝本地网络权限可能阻止发现和连接。

## 配对与线格式

所有拼接均为原始字节；文本常量为 UTF-8；长度为 UInt32 大端。TCP 读取必须处理任意分片。v1 magic 为 8 字节 ASCII `AEGISLN1`。

发送端每次从系统 CSPRNG 生成 16 随机字节，编码为大写十六进制 32 字符 `C`。界面每 4 字符加连字符。接收时仅去空白和连字符、转大写，必须精确匹配 ASCII `[0-9A-F]{32}`。认证和备份密码使用归一化后的 32 字符；码通过用户输入等带外方式传递，不广播或发送到网络。

1. 发送端生成 32 随机字节 challenge `N`，发送 `magic || N`。
2. 接收端发送 `HMAC-SHA256(key=UTF8(C), data=UTF8("aegis.lan.v1.request") || magic || N)`，共 32 字节。
3. 发送端常量时间验证 proof，成功后才发送 `magic || UInt32BE(file.count) || file`。
4. `file` 为既有 ABB v1 加密备份。使用 `C` 作为备份密码，同时包含原保险库槽；用既定 Argon2id、HKDF、AES-256-GCM 和密钥承诺保护内容。格式与独立测试向量见 `BACKUP_FORMAT_DESIGN_V1.md`。不得发送解密后的 payload、保险库密钥或主密码。
5. 接收端完成有界读取及容器结构检查后，发送 `HMAC-SHA256(key=UTF8(C), data=UTF8("aegis.lan.v1.received") || magic || N || SHA256(file))`。此收据仅表示字节收齐；发送界面提示新设备仍需验证并确认导入。
6. 接收端使用 `C` 解开 ABB，验证全部记录和版本图，再显示确认页。失败不写数据库；成功确认后才提交原 header 和所选条目的全部原密文版本。接收端先收到并验证完整加密快照，选择控制数据库写入，不是发送端数据授权；后续全库同步也可能带入其他条目。

文件长度必须在 `1...BackupLimits.maxFileLength` 内，先检查再读取，单次读取不超过 64 KiB。每个连接最多 60 秒；发送端同时只处理一个连接，其他连接立即关闭。一个发送会话累积 3 次连接/认证失败后销毁配对码并停止。每次连接都有新 challenge，request 与 receipt 使用不同 domain，不接受截断或跨会话重放。

安全边界：局域网可观察服务名称、连接和数据长度；数据本身受 ABB AEAD 保护。协议依赖 128 位带外秘密，不可替换为 6 位数字 PIN。获得配对码和已传输文件等同持有可解密的备份；关闭服务不撤销已复制文件。当前会话码不持久化，也不构成长期设备授权。协议未使用临时 DH，不承诺前向保密。

## 验证

核心测试覆盖配对码格式、独立 HMAC 向量、challenge/方向/文件绑定、长度上限，以及首次加入后 ID、密钥、主密码和恢复密钥一致。真实发现和传输测试（含错误配对码后重试）：

```sh
AEGIS_TEST_LOCAL_NETWORK=1 python3 Scripts/build_isolation.py exec --root "$PWD" --lane core-test -- \
  swift test --build-system native --manifest-cache local --package-path Packages/AegisKit --filter LocalTransferTests
```

此测试在同一主机创建发送端与接收端，实际使用 Bonjour 和 TCP；不同物理设备、拒绝权限及路由隔离仍需设备验证。iOS UI 测试检查首次进入能打开局域网导入、未配对时不能提交、取消后仍未初始化。
