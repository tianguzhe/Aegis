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

## 按钮状态与首次进入流程

- macOS 主应用／扩展构建及临时签名检查通过，iOS 主应用／扩展随模拟器测试构建通过。
- Duo 上 2 项针对性 UI 测试通过：短密码／确认不匹配时禁止创建；恢复密钥未确认、确认、取消确认时进入按钮正确切换；空名称／纯空格禁止保存；密码生成器最小长度处禁用减号。
- 已查看恢复密钥确认按钮的实际截图：禁用态为浅灰底灰字，启用态为深色底白字。对照截图保存于 `Docs/Previews/recovery-button-disabled.png` 和 `recovery-button-enabled.png`。
- 结果包：`.build/artifacts.noindex/results/ButtonStates.xcresult`。新增中文提示集中在 String Catalog，244 个本地化键校验通过。

## 审查问题修复与 Actions

- 修复草稿关闭保护、锁定前快照、加密持久化与解锁恢复；未确认恢复密钥同样加密保留，确认后移除。
- iOS 后台锁定保留系统 30 秒剪贴板过期时间；手动／系统／空闲锁定按策略清理。
- Markdown 书写／预览切换保留输入组件，避免重复执行命令和丢失撤销栈。
- Mac 设置弹窗已实际验证错误提示可见；内嵌设置、导入、编辑与大编辑器由当前呈现层处理错误。
- 统一可缩放字体、辅助功能字号纵向布局、浅色对比度与 44pt 小图标命中范围。
- 20 项 Python 测试、26 项 Swift 核心测试通过；新增测试验证加密本机状态跨锁定／存储对象重建的恢复、AAD 绑定和篡改拒绝。
- Duo 完整 8 项 UI 回归通过（`.build/artifacts.noindex/results/UIFixes.xcresult`）；最后的草稿快照与展开生命周期修改后，3 项关键流程再次通过（`UIFixes-final.xcresult`）。
- macOS 主应用／扩展构建、临时签名与 `codesign --verify --deep --strict` 通过。
- GitHub Actions 失败运行 `42138301319` 的根因为原生 SwiftPM 未编译 `.xcstrings`，3 个本地化断言返回键名，后续两端构建被跳过。已从 Catalog 生成 `.strings`，添加生成一致性校验，并强制本地测试使用 native build system 对齐 CI。
- 本地重复清理时发现 LaunchServices `-10814`（应用已不可用）被误判为失败，已作为幂等清理处理，其他清理错误仍返回失败。

## 待办对齐与重复开发图标

- 待办图标按当前平台字体的 cap height 对齐首行文字中心，移除固定行高造成的下移；有序和无序列表统一使用首行基线。Mac 实际检查了中文已完成／未完成项目；Duo 回归截图检查了英文待办。
- Mac 主应用及扩展构建、临时签名验证通过；Duo 的大编辑器编辑、预览、返回与保存回归通过，结果为 `.build/artifacts.noindex/results/TodoAlignment-final.xcresult`。
- 22 项 Python 测试通过，新增旧目录完整迁移、幂等性、运行进程保护和符号链接保护验证；251 个中文资源键及生成资源一致性检查通过。
- 重复图标来自仍被 Spotlight 索引的旧 `build/preview`、Mac 和 iOS 模拟器产物。已增加显式 `archive-legacy` 命令，完整保留旧构建文件并移入 `.noindex`；普通构建清理不执行迁移。
- 本机保留更新版本 `~/Applications/Aegis.app`，签名验证通过，已正常启动并识别现有保险库。Spotlight 查询 `app.aegis.*` 只返回该应用；没有删除保险库或重置全局系统索引。


## 八种银行卡卡面与卡号输入

- 银联、Visa、Mastercard、百夫长分别提供借记／信用两种卡面，编辑实时预览、列表缩略图和详情共用组件；选择由用户手动设置，不使用卡号前缀识别。
- 卡面采用 85.60 × 53.98 比例；实际 SwiftUI 总览图首卡为 880 × 555 像素，比例 1.58559，与目标 1.58577 的差异来自像素取整。总览保存为 Docs/Previews/card-designs.png。
- 5 项 PaymentCardTests 通过，覆盖旧记录、新字段加密往返、遮罩、Luhn、混合数字输入和长度边界。中文资源及生成一致性检查通过。
- Mac / iOS 主应用与扩展构建通过。Mac 签名验证通过，已更新 ~/Applications/Aegis.app，正常识别已有保险库。
- Duo 卡面选择、保存、重开与遮罩回归通过，记录位于 CardDesigns-isolated.xcresult 的 testAppearancePersistsAndCardFaceStaysMasked；最终原生输入回归通过结果为 .build/artifacts.noindex/results/CardDesigns-input-verified.xcresult。两项用例分别验证通过，未将包含早期失败的整套结果标为成功。
- 最终输入回归使用独立 Duo，避免与备份测试竞争；确认连续混合字符输入不丢数字、16 / 19 位计数、Luhn 错误禁止保存、修正后允许保存，以及卡号不改变手选卡组织。
- 卡号使用 NSTextField / UITextField 原生编辑回调过滤，避免 SwiftUI 异步清洗回写覆盖后续输入；iOS 编辑器提供收起键盘入口。
