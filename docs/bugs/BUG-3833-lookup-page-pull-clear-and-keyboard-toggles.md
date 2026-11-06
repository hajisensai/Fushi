## BUG-3833 · 查词页：结果顶部下拉回到历史、进入自动弹键盘不可关，键盘无收起手段
- **报告**：2026-10-24（用户反馈 3D-JH966Kr、cczhbM7ZOI，Android moto g 5G 2023：往上翻查词结果顶到头会被甩回搜索历史；一进查词页键盘就弹起占半屏，只能点很少的空白处收起，返回键又会清空查询或退出 app）。分诊 `docs/reviews/2026-10-27-feedback-triage.md` 第五节第 9 项，所有者 2026-10-27 批准推荐方案：两项都做成查词设置里的开关，默认保持现状。
- **真实性**：✅ 行为真实存在，但两条都是**有意设计**而非缺陷（行号按基线 `cd7c9a975f`）：
  1. 结果 WebView 的顶部下拉（`kPopupTopPullReleaseJs` → `topPullReleased` 桥）无条件接到 `fushi/lib/src/pages/implementations/home_dictionary_page.dart:1904` `onTopPullReleased: _clearSearchFromResultPull` → `:579` `_clearSearchFromResultPull` → `_clearSearch`，清空查询回到历史，没有任何偏好可关。
  2. 底栏 / rail 点「查词」= `home_page.dart:1231` `_selectTabFromNav` 发 `DictionaryFocusIntent.clearQuery` → `home_dictionary_page.dart:332` → `:554` `_clearSearch` → `_focusSearchField`（BUG-2687：`requestKeyboard`，键盘必弹）。结果下拉清空、返回键清空也走同一个 `_clearSearch`，都会把键盘再弹一次。键盘弹起后页面没有任何可见的收起入口（提交后的收键盘 BUG-2686 只在提交时触发）。
- **[x] ① 已修复** — 本条提交（message 尾行 `Feedback: 3D-JH966Kr` / `Feedback: cczhbM7ZOI`）：
  - 新偏好 `lookup_page_pull_to_clear` / `lookup_page_auto_show_keyboard`（均默认 true = 原行为，登记进 `preference_keys.dart`，随 Profile 快照 / 备份走），`PreferencesRepository` + `AppModel` getter（未初始化按默认值，同 `librarySentencesEnabled` 纪律）。
  - 设置 › 查词 › 查词触发 新增两个开关 `lookup.page_pull_to_clear`、`lookup.page_auto_show_keyboard`（后者桌面也显示：同一判据管「自动聚焦」）。
  - `_clearSearchFromResultPull` 开头按 `lookupPagePullToClear` 早退；`_clearSearch` 只在 `lookupPageAutoShowKeyboard` 开时 `_focusSearchField()`——导航点进、结果下拉、返回键清空都经过它，一个判据管住全部「替用户弹键盘」的路径；显式热键「聚焦搜索框」（keepQuery / selectQuery）不经过 `_clearSearch`，照常聚焦。
  - 收起键盘：搜索栏尾部新增「收起键盘」按钮（`home_dictionary_hide_keyboard_button`），只在 Android / iOS、搜索框持焦且软键盘真的弹着时出现（`WidgetsBindingObserver.didChangeMetrics` 读 `View.viewInsets`——Scaffold 把 body 的 viewInsets 抹成 0，读 MediaQuery 拿不到），点了只 `TextInput.hide`、不交焦点（与 BUG-2686 同理：unfocus 会被 FushiFocusRoot 被动修复还回焦点、键盘再弹）。出现时走 `FushiStaggeredEntrance` 单项进场。MD3 与 Apple 两套设计系统都挂（`FushiSearchField.trailing` 两条分支共用）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_dictionary_lookup_page_toggles_test.dart`（真 widget 行为，7 例）：下拉开 / 关两态、导航 clearQuery 开 / 关两态、开关关时显式 keepQuery 仍聚焦、移动端键盘弹着出按钮并发 `TextInput.hide` 且焦点留框、桌面不出按钮。
- **备注**：未真机复测（Android 键盘收起 / 按钮显隐需要真机或模拟器看一眼）。图标用现有语义名 `FushiIcons.keyboard`（Material Symbols 没有切进子集的 `keyboard_hide`，新增要重跑 `tool/icons/gen_fushi_symbols.py` 重切字体子集，本条没做）。
