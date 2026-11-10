## BUG-4336 · MD3 悬浮底栏在查词页收起后回不来，用户离不开查词页
- **报告**：2026-11-08（应用内反馈 TyMqz158nj，moto g55 / Android 16：「点放大镜进了查词页，就再也去不了主页 / 阅读或任何别的地方」）
- **真实性**：✅ 真 bug（代码路径已验证，触发序列按反馈与 AI 总结推定，未上真机复现）。收起状态与「还有没有能滚回去的内容」脱钩：
  1. BUG-3064 让查词（MD3 悬浮底栏胶囊外的 FAB）当前时也随下滑收起：`fushi/lib/src/utils/adaptive/adaptive_navigation.dart:722-740`（旧）`fabCurrent` 时 `currentItem: null`，整条胶囊让位、只剩 FAB。
  2. 恢复路径只有两条：回滚（`GlassTabBarMinimizeController.handleSample`，只在 `ScrollUpdateNotification` 上判）和切 tab（`fushi/lib/src/utils/components/glass/fushi_apple_scroll_chrome.dart:166` `syncScope`）。
  3. 在查词 tab 上点 FAB 走 `onTap(searchIndex)` → `home_page.dart` `_selectTabFromNav` → tab 不变（`syncScope` 不展开），同时发 `clearQuery`，`home_dictionary_page.dart` `_clearSearch` / `_resetQuery` 清掉结果、换成历史页。内容被换掉 / 缩短时 Flutter 只发 `ScrollMetricsNotification`，而 `FushiAppleScrollChrome.handleNotification`（`fushi_apple_scroll_chrome.dart:181`，旧）对尺寸通知只更新 scroll edge、不喂状态机，库里「内容滚不动 / 停在起始边就展开」两条规则都看不到；历史页又常常滚不动，回滚也无从谈起——底栏永远收着。
- **[x] ① 已修复** —
  - `FushiAppleScrollChrome._expandIfStranded`：`ScrollMetricsNotification`（内容替换 / 缩短 / 新列表首次布局）也按库的同两条规则判——可滚范围不足 `GlassTabBarMinimizeController.kMinScrollableExtent` 或停在起始边时展开。只展开、不收起，「只有用户滚动才收起」不变。只认收起底栏那条主滚动视图所在深度及更浅的尺寸通知（复核补）：内容里嵌套的竖向子 Scrollable（shrinkWrap 嵌套列表、多行输入框）被外层下滑建出时首次布局就发尺寸通知、恒在顶部且滚不动，不过滤会让底栏边下滑边被弹开。Apple 胶囊与 MD3 悬浮胶囊共用这台状态机，两边一起修。
  - MD3 悬浮底栏 FAB：FAB 是当前项且胶囊已让位时，点 FAB 只调 `onGlassExpand` 展开底栏、不再触发目的地（与胶囊目的地当前时「点小胶囊只展开、不切 tab」同一语义）。这保证即使当前页根本没有滚动视图（空历史占位），收起态也有一条不依赖内容的恢复路径。展开态下点 FAB 行为不变（清空查询 / 聚焦搜索框）。
  - BUG-3064 的设计（FAB 当前时整条胶囊让位、FAB 留下）保留：FAB 即收起态里的「当前项」小钮，不另画最小化胶囊。
  - Apple 风格核查：Apple 玻璃胶囊在搜索项选中时不收起（`_buildGlassTabBar` `selectedInCapsule`），胶囊目的地当前时留可点的小胶囊，不会出现同样的「无可点恢复入口」；尺寸通知的展开规则对 Apple 同样生效。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/md3_floating_bar_stranded_recovery_test.dart`：外壳同款接线（NotificationListener → `FushiAppleScrollChrome` → `adaptiveBottomBar`）下查词 FAB 当前、真实拖动收起后：内容缩短到滚不动 → 展开；整块换成新列表 → 展开；点当前 FAB → 只展开、不触发 onTap，展开后再点照旧触发；列表变长仍停在中间 → 不误展开；收起后可见区新建嵌套竖向子列表 → 不误展开。（本分支未运行，统一在合并后验证。）
- **备注**：真机未复测（本批次不做真机验证）。
