## BUG-5335 · 游戏速览「继续」不认正在运行的游戏
- **报告**：2026-11-22（用户：侧栏速览卡要与点进去的页面一致；只读审查发现）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/home_nav_peek.dart:491-500,519-520`（develop 06c73737a2）`_loadGames` 只按 `lastPlayedMs` 排、取第一条当「继续」；游戏首页首块是 `running ?? played.first`（`galgame_home_page.dart:922-925`，`_runningGame` :379-390）。正在运行的游戏不在第一位，从没玩过的运行中游戏干脆不出现。（首页经典版式 :767 用的也是只看 `lastPlayedMs` 的 `_recentGame`，与拼贴版不一致。）
- **[x] ① 已修复** — 「继续」选取只写一次：`mining/galgame_home_selection.dart` 的 `galgameHomeContinue`（运行中优先，否则最近玩过；其余按最近游玩）与 `galgameRunningEntry` / `galHookRunningExe` / `galgamePlayedByRecency`。游戏首页两套版式（拼贴 / 经典）与速览 `navPeekGamesFeed` 都用它；运行中那条在速览里按此刻计时（首页速览混排时它就是最近的）。（提交 1c515c6992 + 速览接线提交）
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_nav_peek_mirrors_page_test.dart`「正在运行的游戏是首块，从没玩过也算；按此刻计时」+ 接线守卫。
- **备注**：经典版式首块现在也会是运行中的游戏（之前只有拼贴版这样）。未在应用里肉眼复测。
