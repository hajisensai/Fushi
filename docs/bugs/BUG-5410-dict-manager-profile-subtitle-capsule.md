## BUG-5410 · dict-manager-profile-subtitle-capsule
- **报告**：2026-11-24（用户：应用内反馈 NresBjfKM-「词典管理页读到配置名后顶栏变成胶囊样式，和其他工具页不一致」）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/dictionary_dialog_page.dart` `_buildTitle` 在异步读到激活配置名后把标题换成 `FittedBox(Column(Text, 配置名按钮))`；通用顶栏只在标题是纯文字时走页头大字——宽屏分栏路径 `FushiToolScaffold._mastheadTitle`（`fushi_material_components.dart` `custom is Text`）、窄屏 `AdaptiveSettingsScaffold`（`settings_shared.dart` `titleWidget is Text`）——拿不到纯文字页名就退回旧胶囊顶栏。于是进页先出页头大字，配置名一到整页切成胶囊。
- **[x] ① 已修复** — 根因是「副标题只能塞进标题组件」：给 `FushiToolScaffold`、`AdaptiveSettingsScaffold`、`SettingsKitScaffold` 加独立的 `subtitle` 组件通道（`SettingsFloatingHeader.pinnedSubtitle`，页头大字形态画在页名下、旧形态画在标题块 / 顶栏行下，Cupertino 大标题下另起一行）；词典管理页标题恢复纯文字 `t.dictionaries`，「配置 · 名字」按钮走 subtitle 通道，title 类型不再随异步数据变化。
- **[x] ② 已加自动化测试** — `fushi/test/pages/dictionary_manager_server_rows_test.dart`「split / narrow: profile subtitle keeps the masthead header」：宽屏分栏与窄屏设置壳两条路径，配置名读到后仍是 `FushiMastheadHeader`，页名与配置名按钮都在页头里。
- **备注**：其它页如再需要页名下的可交互副标题，走同一 subtitle 通道，不要拼进 title。
