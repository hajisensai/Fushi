## BUG-3520 · 复习中改牌组设置返回后不立即生效（间隔预览/计数/下一张仍按旧设置）
- **报告**：2026-10-18（用户：背卡的时候修改卡组设置不会立马生效）
- **真实性**：✅ 真 bug。排程层本身没有配置快照：`packages/fushi_engine/lib/srs/srs_db_store.dart` 的 `nextCard`（:1804）/ `answer`（:1491）/ `preview`（:1479）每次都经 `deckTree()` / `schedulingConfigFor()` 现读，**不存在预排好的队列**。过期的是复习页自己缓存的状态：
  - `fushi/lib/src/pages/implementations/srs/srs_review_page.dart:675`（修前 `_reloadCurrent`）从设置页回来只刷卡面与音频归属，不重算 `_preview`（评分按钮上的间隔，学习步长 / 记忆率 / 最大间隔算出来的）、不刷 `_newCount/_learnCount/_reviewCount`（每日上限）、标题一直是 `widget.deckName`（改名不变）。用户看到按钮间隔、计数都还是旧设置。
  - `:226`（`_startPrefetch`）预取的下一张连同当时的音频归属快照（`_PrefetchedCard.audioOwner`）一起缓存，`:289` 预取命中时直接用它；设置页一关就评分时，`_reloadCurrent` 还没来得及重启预取，下一张按旧自动播放开关显示 / 播放。
  - 附带竞态：`_reloadCurrent` 跨多个 await 后无条件 `setState` 回写旧卡，期间已评分换卡时会把旧卡盖回去。
- **[x] ① 已修复** — 提交 f00044c71a：新增 `_applyDeckSettingsChange`（设置页回来时**同步**作废预取快照，再 `_reloadCurrent`，自动播放开关变化时按新值播 / 停）；`_reloadCurrent` 额外现读计数、标题（`SrsDeckSummary.fullName`）、`dayContext` 与间隔预览，并以 `_shownGeneration` 守住「刷新途中已换卡就不回写」。当前这张卡不换（用户正在看它，可能已在答案面；与 Anki 一样答完再按新上限选下一张），注释写明排程层无队列需重建。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_review_live_settings_test.dart`：走真实路径（复习页工具栏「牌组设置」→ 改学习步长 25 60、每日新卡 1、改名 → 保存返回），断言仍是同一张卡且在答案面、「重来」间隔等于按新设置现算的值（旧值 1m → 25m）、计数变为新卡 1、标题换成新名。变异实测：换回旧复习页该用例红（Expected '25m' Actual '1m'）。
- **备注**：纯状态刷新，无 WebView 几何改动；真机复测待补。
