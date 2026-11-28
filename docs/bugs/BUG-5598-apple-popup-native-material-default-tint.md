## BUG-5598 · apple-popup-native-material-default-tint
- **报告**：2026-11-27（审查 PR #4573 时发现，非用户报告）
- **真实性**：✅ 代码与注释矛盾（未真机核对观感）。`fushi/lib/src/utils/components/fushi_material_components.dart` 的 `_applePanelColor`（约 7719 行）在浅色下把默认面板色改成 `apple.groupedBackground`（#F2F2F7），但 `_buildNativeMaterial`（约 7917 行）判断「是不是默认色、要不要淡染」时仍拿 `secondaryGroupedBackground`（白）比较。结果是 iOS / macOS 浅色、原生材质路径下，默认面板也会叠一层 #F2F2F7 的 40% 淡染，与该方法注释「Apple：纯系统材质，只有用户手动指定的词典底色才淡染」不符。
- **[ ] ① 未修复** — 方向：两处共用同一个「Apple 默认面板色」判据（抽成一个函数，按明暗取值），不再各写一份。动手前先跟 PR #4573 作者（W1ght）确认：PR 描述称 macOS 真机外观是带着这层淡染确认的，要分清是想要淡染（那就改注释与判据语义）还是判据漏改。
- **[ ] ② 未加自动化测试** — 方向：在 `fushi/test/widgets/glass/fushi_popup_surface_nested_fill_test.dart` 断言浅色默认色下原生材质路径 tint 为 null。
- **备注**：
