# 构建隔离与开发清理

本次参考 `tianguzhe/ProcScope` 默认分支最新提交 [2e4673654533756748e30a985d6e9e7cd0291f73](https://github.com/tianguzhe/ProcScope/commit/2e4673654533756748e30a985d6e9e7cd0291f73)，主题为 “Isolate development artifacts and streamline build cleanup”。其隔离脚本、日志处理与测试按 Aegis 的 iOS / macOS 多 Target 工程适配。

## 路径

所有新入口把产物放到项目内的 `.build/artifacts.noindex/`：

| 子路径 | 用途 |
| --- | --- |
| `xcode/macos-debug/` | Mac 调试构建和唯一预览应用 |
| `xcode/macos-release/` | Mac Release 构建 |
| `xcode/ios-simulator-debug/` | iOS Simulator 调试构建 |
| `xcode/ios-release/` | iOS 设备 Release 编译产物 |
| `xcode/ios-ui-test/` | iOS UI 测试及 `.xcresult` |
| `xcode/ide/` | Xcode 图形界面使用的 DerivedData |
| `swift/` | Swift Package 编译、依赖 checkout 与测试产物 |
| `cache/` | SwiftPM 与编译器缓存 |
| `logs/` | 按执行批次命名的完整日志 |
| `legacy-build-*/build/` | 显式迁入的旧构建目录，保留原文件 |

`.noindex` 后缀用于排除 Spotlight 索引；`.metadata_never_index` 是辅助标记。项目源码、签名配置、保险库数据库和备份不在清理范围内。

`prepare` 将 DerivedData 的绝对路径写入当前用户的 `WorkspaceSettings.xcsettings`，保留其他偏好；绝对路径仅存在被忽略的 `xcuserdata/` 中。项目移动后再运行一次 prepare 即可。共享 Scheme 使用 `$SRCROOT`，不会把本机路径写入仓库。

## 入口

`bash Scripts/build.sh [macos|ios-simulator|ios] [Debug|Release]` 先构建，再核验主应用与嵌入 Credential Provider 的版本号、最低系统、平台和 Bundle ID 关系。命令行入口为无签名编译验证，不生成 IPA 或可发布的 CloudKit 安装包；真机与正式发布仍使用已配置团队的 Xcode 流程。macOS Release 编译 Apple Silicon 与 Intel 两个架构。

`bash Scripts/test.sh` 运行 Python 边界测试、本地化检查和 Swift Testing；`--ui <UDID>` 追加对应模拟器的 XCUITest。测试失败的退出码会传回调用方。

`bash Scripts/preview.sh` 只使用 `macos-debug` 下同一个应用，不再为每次预览复制新的 App；对自动填充扩展和宿主依次做 ad-hoc 签名并核验，带 `--preview-vault` 启动内存示例。脚本等待窗口进程退出后清理注册。`--build-only` 只准备预览产物。

自定义构建可使用：

```sh
python3 Scripts/build_isolation.py exec --lane macos-custom -- \
  xcodebuild -project Aegis.xcodeproj -scheme Aegis-macOS \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

包装器为 xcodebuild 注入 DerivedData，拒绝越界、重复或符号链接逃逸的输出路径；为 SwiftPM 注入 scratch/cache 和本地 manifest 缓存。标准系统服务仍由 Xcode 管理，隔离目录不是权限沙箱。

## 清理边界

清理通过 `lsregister -dump` 读取路径，仅对确认属于工程的 `.app` 发出 `-u` 注销请求。范围包括当前隔离目录、项目旧 `build/` / `DerivedData/` / `TestResults/` 和 workspace 元数据匹配的旧全局 DerivedData。额外指定目录需通过安全检查。旧 `release/Aegis.app` 只有在已存在且 Bundle ID 匹配时才处理；路径已失效的旧注册也可清理。

不会根据名字或 Bundle ID 扫除系统所有同名应用。不会越过指向外部路径的符号链接，也不会处理 `/Applications`、用户 Applications 或其他工程的 DerivedData。不会删除任何 App、卸载设备应用或清理保险库。

构建失败、运行异常和 SIGINT/SIGTERM 时仍执行清理，并保留原始退出码。清理失败不会伪装成成功。LaunchServices 可能保留 launch-disabled 记录，其他启动器也有自己的缓存；注销成功不等于所有搜索结果立即消失。

## 旧开发图标仍出现在搜索中

Spotlight 会重新发现仍位于普通 `build/` 路径下的预览应用，因此仅执行 LaunchServices 注销不能解决物理文件持续被索引的问题。退出从旧目录运行的开发应用后，执行：

```sh
python3 Scripts/build_isolation.py archive-legacy
```

该操作先检查旧路径下的运行进程、注销已知开发应用，再将整个 `build/` 原子迁入唯一的 `.build/artifacts.noindex/legacy-build-*/build/`。不删除文件、不覆盖已有归档、不结束应用进程；运行中的旧应用和符号链接会阻止迁移。普通 `cleanup` 仍只注销注册，不自动移动目录。

供日常使用的应用保留一份到 `/Applications/Aegis.app` 或 `~/Applications/Aegis.app`，开发预览继续由 `Scripts/preview.sh` 从隔离目录启动。安装副本不在清理范围内。迁移后用系统搜索验证结果；不重置全局 Spotlight 或 LaunchServices 数据库。

## CI

`.github/workflows/ci.yml` 在 main 的 push / PR 以及手动触发时运行：脚本与 Swift 测试、Mac Debug 构建、iOS Simulator Debug 构建。诊断包含 `.build/artifacts.noindex/logs/` 与测试结果，使用 `include-hidden-files: true` 上传，保留 7 天。

本次没有添加自动发布流程或推送版本标签。签名、CloudKit schema 部署与实际发行仍需单独完成。
