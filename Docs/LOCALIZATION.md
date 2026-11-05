# 本地化

源语言为 `zh-Hans`（简体中文）。目前只提供中文，使用 Xcode String Catalog，暂不添加空的其他语言。

## 文案位置

- `Packages/AegisKit/Sources/AegisCore/Resources/Localizable.xcstrings`：主应用、扩展、错误消息、Markdown 编辑器共用。
- `App/InfoPlist.xcstrings`：系统权限说明，例如 Face ID。
- 产品品牌 `Aegis / AEGIS`、用户输入、URL、协议标识、文件格式标识不作为可翻译的 UI 文案。

代码通过 `L10n.text("稳定的键")` 获取字符串，通过 `L10n.format` 插入数字；不在 Swift 视图中写中文，也不使用中文本身作为翻译键。日期由 Foundation 的本地化 Date.FormatStyle 处理。记录数量等有复数变化的语言应在 String Catalog 中添加 plural variations。

## 添加语言

1. 在 Xcode 为项目和两个 Catalog 添加目标语言（例如 `en`）。
2. 为现有稳定键添加翻译，不改键名。
3. 更新 `project.yml` 中的 `CFBundleLocalizations`，运行 `xcodegen generate`。
4. 翻译权限说明，检查长文案、动态字体和 VoiceOver 标签。
5. 用 Scheme → Options → App Language 切换语言验证。首版不包含应用内语言切换器。

运行 `python3 Scripts/check_localizations.py` 可检查缺失键及生产 Swift 源码中的内联中文。新增文案应直接编辑 Catalog，它是唯一文案来源。
