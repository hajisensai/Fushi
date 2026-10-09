## BUG-3093 · 词典样式开圆角后释义塌成一字一行
- **报告**：2026-10-09（用户：词典样式可视化面板开「圆角」后样式改炸，视频查词弹窗里释义竖成一字一列）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/reader/dictionary_style_css.dart` `_declarations`：圆角除了 `border-radius` 还附带 `display: inline-block !important`（注释前提「inline 元素圆角无效」不成立），把 `.entry` / `.glossary-content` / `summary.dict-label` 等块级部位压成收缩包裹的行内块，多列卡片里释义宽度塌成一两个字。Android 独立弹窗读的编译产物缓存（`dict_style_rules_css`）里也存着这条旧 CSS。
- **[x] ① 已修复** — 圆角只产 `border-radius`（`dictionary_style_css.dart:133`）；`AppModel.refreshCompiledDictStyleCssCache` 启动时按当前编译器重算缓存，存量用户不必重存规则。提交 `b18d1207ab`（PR `pr/dict-popup-style`）。
- **[x] ② 已加自动化测试** — `fushi/test/dictionary/dict_style_rules_css_test.dart`「圆角只产 border-radius，任何部位都不改 display」逐部位断言。
- **备注**：headless Chrome 前后对比截图见 PR 描述（before-radius / after-radius）。
