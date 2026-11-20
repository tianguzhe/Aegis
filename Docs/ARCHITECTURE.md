# 架构与数据约定

## 模块

- `AegisCore`：纯数据结构、Argon2id / CryptoKit、密钥 Actor、密码生成、资源本地化。
- `AegisStorage`：SwiftData `@ModelActor`，只存储密文版本与公开密钥包裹元数据；显式关闭 SwiftData 自动 CloudKit 同步。不使用 iCloud。
- `AegisSync`：通过 Bonjour 发现设备，支持加密快照传输和同库增量对账。协议见 [局域网首次加入](LOCAL_TRANSFER.md) 和 [持续同步](LAN_SYNC_DESIGN.md)。
- `AegisMarkdown`：官方 Swift Markdown 解析器，SwiftUI 原生渲染。
- `App`：`@MainActor @Observable` 会话、平台 Keychain、SwiftUI 功能视图。
- `AutoFill`：独立扩展，读取 App Group 的原子写入密文快照，不与主应用并发打开同一 SwiftData 数据库。

## 密钥

主密码（UTF-8 原样编码，不自动去空格或归一化）+ 16 字节随机盐，经 Argon2id 派生 32 字节 KEK。KEK 以 AES-GCM 包裹 32 字节随机保险库密钥。独立的 32 字节随机恢复密钥另行包裹同一保险库密钥。密钥包裹 AAD 包含格式版本、保险库 ID 与用途。

生物识别使用 `biometryCurrentSet` 与 `WhenPasscodeSetThisDeviceOnly` 的 Keychain 条目，仅限本设备；不参与 iCloud Keychain 同步。主密码不持久化。恢复密钥在用户确认前以保险库密钥加密保存在本机，确认后从本地状态移除。Swift 字符串和 SwiftUI 控件无法保证所有内存副本立即清零；锁定清理可控密钥引用、可见条目和表单。iOS 后台锁定保留系统设置的 local-only 剪贴板过期时间，以支持切到其他 App 粘贴；手动锁定立即清理本应用持有的剪贴板内容。

## 可恢复的本机状态

`LocalVaultStateStore` 使用独立用途 AAD（`aegis|local-state|1|<vaultID>`）和随机 nonce，将草稿及待确认恢复密钥以 AES-256-GCM 保存到数据库目录下的 `local-state-<vaultID>.aegis`。它不离开本机，也不包含在用户导出的保险库备份中。

恢复配置先落盘，再提交保险库 header；创建中断后，主密码解锁会解密本机状态并继续确认。

编辑器保留原始内容及其父 revision，持续同步加密草稿。锁定前还会同步读取已注册编辑器的最新绑定值，避免 SwiftUI 的 onChange 尚未送达导致最后输入丢失。锁定后本地状态对象移除明文与密钥，解锁再恢复。显式保存或放弃会移除对应草稿。详情身份使用稳定 item ID，远端 revision 更新不会销毁当前编辑器；保存仍使用草稿原父版本，保留真实同步冲突。

## 不可变版本

每次编辑产生新的 UUID 版本，AES-GCM 自动生成随机 96-bit nonce。标题、用户名、密码、网址、备注、卡信息、收藏和删除时间均在密文内。版本 envelope 暴露不含内容的保险库 ID、条目 ID、版本 ID 和父版本 ID，全部绑定到 AAD。

每个条目的未被后续版本引用的版本是当前 head。多 head 表示并发编辑冲突。保留一个版本会产生引用所有 head 的新版本；历史保留，避免静默丢失密码。删除后进入回收站。永久删除用加密标记阻止旧离线分支重新出现，轮换密钥时可压缩历史。

所有版本先通过 AEAD 验证，父关系才参与 head 计算，避免未认证父指针隐藏有效记录。跨条目父指针被拒绝。相同 Record ID 的不同内容被拒绝；JSON 使用规范化键排序以支持跨设备导入。

局域网持续同步仅在设备前台且解锁时运行。两端校验同库身份，核对不可变版本清单并交换缺失的记录。

## 边界

- 局域网可观察服务广播、连接时序和数据大小。
- AEAD 验证记录真实性。缺失的父版本通过本地与对端清单对账。
- 同一保险库身份下的 header 不可变。修改主密码时创建新身份、轮换密钥并重新加密记录。
- 恢复密钥可以直接解锁和导出；不依赖服务器重置密码。
- 同步不是备份。需保留独立加密导出，首次导入会验证全部 AEAD 标签。
- Markdown 原文作为笔记内容一起加密。预览不加载远程图片，不执行 HTML / JavaScript，只允许用户主动打开 http / https / mailto 链接。

## 固定依赖

Argon2 官方发布包：`https://github.com/P-H-C/phc-winner-argon2/releases/tag/20190702`。
下载归档 SHA-256：`daf972a89577f8772602bf2eb38b6a3dd3d922bf5724d45e7f9589b5e830442c`。
官方许可证随 C 源码保存在 `Sources/CArgon2/LICENSE`。使用 portable reference 内核，禁用内部线程。

Swift Markdown 0.9.0：`https://github.com/swiftlang/swift-markdown`，Apache 2.0 with Runtime Library Exception；由 SPM 锁定并带入 swift-cmark 解析器依赖。
