# Apple 服务配置与验证

本机构建时没有发现可用的开发签名证书，因此没有创建、部署或访问任何 CloudKit 容器。代码和扩展 Target 已就绪，下面的账号配置必须由拥有该 Apple Developer 团队权限的人完成。

## 配置

1. 将 `Config/Local.xcconfig.example` 复制为 `Config/Local.xcconfig`，填入你的 `DEVELOPMENT_TEAM`、唯一 Bundle 前缀、CloudKit 容器和 App Group。该本地文件已被 Git 忽略。
2. 在 Xcode 为四个 Target 选择同一团队，启用自动签名。
3. 为 iOS / macOS 主应用启用 iCloud → CloudKit，关联同一个私有容器。启用 Push Notifications；iOS 主应用还需 Background Modes → Remote notifications。
4. 为主应用和对应自动填充扩展启用 App Groups，选择同一个组。确认组的标识符合所用团队和平台的要求。
5. 为扩展启用 AutoFill Credential Provider capability。确认生成的描述文件包含这项 entitlement。
6. 将 `AEGIS_CLOUD_ENABLED` 设置为 `YES` 后重新构建。启用 App Group 会改变存储目录；若之前已创建本地保险库，先导出加密备份，在新目录导入。

主应用 Bundle ID 为 `$(AEGIS_BUNDLE_PREFIX).ios` / `.mac`；扩展为主应用 ID 加 `.autofill`。默认命名只是开发占位，需替换成团队拥有的标识。

## CloudKit 数据模型

- 私有数据库自定义 Zone：`AegisVault`。
- Record Type：`VaultObject`。
- `kind`：String，值为 `header` 或 `revision`。
- `payload`：Bytes，JSON 编码的密钥包裹信息或密文记录版本。
- Header Record ID 固定为 `header`；版本 Record ID 为 UUID。
- CKSyncEngine 管理订阅与令牌；无服务器业务代码。

首次在 Development 环境运行时创建 schema。发布 TestFlight / App Store 前，在 CloudKit Console 将 schema 部署至 Production。不要将用户密码或明文字段添加到 CloudKit schema。

## 必须在签名设备上验证

- iPhone 创建保险库，Mac 在相同 Apple ID 下下载并用主密码解锁。
- 反向新增 / 修改 / 收藏 / 删除 / 恢复；断网修改后再连网。
- 两台设备同时编辑同一记录，验证两个冲突版本均可查看并合并。
- 应用锁定时下载密文，解锁后显示完整记录。
- 注销或切换 Apple ID，验证立即锁定并停止同步；返回原账号并重启后恢复。
- Touch ID / Face ID 启用、取消、失败、变更生物识别集合后的回退。
- 系统自动填充启用后，打开 Safari 登录页，输入主密码，核对域名，确认填充。
- iOS 17 真机上的 Argon2 64 MiB 内存与解锁耗时，以及自动填充扩展内存预算。

模拟器构建通过只证明 SDK 编译兼容，不代表上述系统服务已完成端到端验证。
