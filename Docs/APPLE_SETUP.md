# Apple 服务配置与验证

Aegis 不使用 iCloud。签名设备上需要配置的系统服务只有生物识别和自动填充。自动填充扩展需要 App Group 与 AutoFill Credential Provider 权限；免费 Apple ID 个人团队无法开启自动填充（2026-11-19 实机确认），需要付费开发者团队。

## 配置

1. 将 `Config/Local.xcconfig.example` 复制为 `Config/Local.xcconfig`，填入你的 `DEVELOPMENT_TEAM`、唯一 Bundle 前缀和 App Group。该本地文件已被 Git 忽略。
2. 在 Xcode 为四个 Target 选择同一团队，启用自动签名。
3. 为主应用和对应自动填充扩展启用 App Groups，选择同一个组。确认组的标识符合所用团队和平台的要求。
4. 为扩展启用 AutoFill Credential Provider capability。确认生成的描述文件包含这项 entitlement。
5. 启用 App Group 会改变存储目录；若之前已创建本地保险库，先导出加密备份，在新目录导入。

主应用 Bundle ID 为 `$(AEGIS_BUNDLE_PREFIX).ios` / `.mac`；扩展为主应用 ID 加 `.autofill`。默认命名只是开发占位，需替换成团队拥有的标识。

## 必须在签名设备上验证

- Touch ID / Face ID 启用、取消、失败、变更生物识别集合后的回退。
- 系统自动填充启用后，打开 Safari 登录页，输入主密码，核对域名，确认填充。
- iOS 17 真机上的 Argon2 64 MiB 内存与解锁耗时，以及自动填充扩展内存预算。

模拟器构建通过只证明 SDK 编译兼容，不代表上述系统服务已完成端到端验证。
