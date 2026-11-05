# 验证记录

本次使用 Xcode 27.2 / Swift 6.4.2 构建，部署目标仍是 iOS 17.0 / macOS 14.0。

- macOS 主应用与自动填充扩展：Debug 构建通过。
- iOS 主应用与自动填充扩展：iOS Simulator Debug 构建通过。
- 独立 iOS 27.1 模拟器：安装与启动成功（Aegis QA，使用内存预览数据）。
- Swift Testing：18 项测试通过，覆盖 Argon2 官方已知向量、错误密码、GCM 篡改、AAD 记录身份、防止父版本跨条目引用、随机 nonce、恢复密钥、并发冲突、删除恢复、备份、同步 JSON 规范化、密码策略、本地配置持久化、Markdown 解析和安全链接。
- 中文资源：184 个键校验通过，生产 Swift 源码没有内联中文文案。
- Mac 实际窗口：已观察解锁、分类列表、Markdown 原文编辑与详情渲染（标题、任务清单、引用、代码块、表格）。
- Mac 分栏的列表最小宽度已从系统实际分配的 200 修正为 280；银行卡分类新增默认选择银行卡。
- Mac 失焦遮罩移除，普通窗口切换不再立即锁定。保留 5 分钟无操作、休眠和系统用户切换锁定。

CloudKit 跨设备同步、生物识别和系统自动填充仍需要签名设备验证；没有把无签名构建通过视为系统服务已验证。当前没有安装 iOS 17 / macOS 14 专用运行环境，最低版本目前完成的是部署目标编译兼容检查。

本轮视觉调整：Markdown 正文基准 16pt、任务符号使用 20pt SF Symbols、标题分级和块间距优化；列表标题 15pt / 副标题 13pt，选中行图标与文字使用高对比度颜色。iOS / macOS 两端均再次构建通过。

备注 Markdown：登录信息与银行卡备注复用安全笔记的编辑／预览和详情渲染，支持复制 Markdown 原文；iOS / macOS 构建与 184 个本地化键校验通过。

## 整体 UI 重设计验证

- Mac / iOS 主应用与自动填充扩展均重新构建通过。
- 209 个本地化键校验通过，新增界面文案保持集中管理。
- Mac 实际检查了三栏、选中行、密码详情与 Markdown 编辑弹窗。
- 使用用户指定的 Duo 设备：系统名称 `iPhone Duo`，iOS 27.1，设备 ID `7F065405-FDDE-479A-886D-57B3F7F1664C`。当前环境没有名为 iPad Duo 的设备，也没有标准 Simulator 桌面程序；通过 simctl、XCUITest 与显示输出完成验证。
- `AegisUITests` 两项测试通过：打开记录、修改标题和 Markdown、切换预览、保存回详情；打开密码生成器、横竖屏切换、打开设置页。
- 成功结果包：`build/verification/ui-refresh/DuoUI-3.xcresult`。界面截图保存在 `Docs/Previews`。
- 已检查 Duo 主屏的浅色与深色显示，确认文字、图标和导航对比度；检查后恢复为原来的浅色设置。
- 测试使用 `--preview-vault` 的内存数据，未访问真实保险库或 CloudKit。

## Markdown 大编辑器

- macOS / iOS 17 部署目标构建通过；Mac 实际检查了紧凑面板、右下角展开按钮与 860pt 以上的双栏对照面板。
- Swift Testing 23 项通过，包括新增的 Unicode / Emoji 选区、标题光标、Todo 多行、链接选区和过期选区保护。
- Duo 上 2 项编辑流程测试通过：普通备注编辑与预览保存；全屏编辑、格式工具插入 Todo、预览、完成返回、保存后重新打开。
- 最终结果包：`build/verification/ExpandedEditor-final.xcresult`。此轮日志未再出现原生输入组件的 SwiftUI 更新期状态修改警告。
- 全屏书写、全屏预览及返回表单截图分别为 `Docs/Previews/iphone-expanded-editor.png`、`iphone-expanded-preview.png`、`iphone-compact-editor.png`。
- 本地化校验通过，共 232 个中文资源键。

## 构建隔离（参考 ProcScope 2e46736）

- 18 项 Python 测试通过：目录归属、旧 DerivedData 元数据识别、符号链接逃逸、Xcode / SwiftPM 参数边界、日志和失败退出码，以及宿主／扩展校验。
- `Scripts/test.sh` 在标准 SwiftPM 沙箱下通过，包含 23 项 Swift 测试和 232 个本地化键校验。
- `Scripts/build.sh ios-simulator Debug` 在 `.build/artifacts.noindex/xcode/ios-simulator-debug` 构建通过，验证了 iOS 17 最低系统和嵌入扩展信息一致性。
- 隔离目录内的 Mac Debug 构建及 macOS 14 最低系统验证通过；两端共享 Scheme 均生成 build/test/run/profile/archive 清理动作。
- `Scripts/preview.sh --build-only` 通过：依次签名 Debug dylib、Credential Provider 和宿主，并通过 `codesign --verify --deep --strict` 核验。
- 构建后的实际 LaunchServices 清理对本工程 11 个已注册开发应用副本发出注销请求，保留全部原文件。
- 当前调整没有改变产品功能，也没有发布安装包或部署 CloudKit schema。GitHub Actions 的远端运行结果需在推送后查看。
