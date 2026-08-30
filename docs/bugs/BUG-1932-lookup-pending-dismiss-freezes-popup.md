## BUG-1932 · 挂起期关栈后查词界面卡死、播放控件再也唤不回

- **报告**：2026-08-29（用户：「在播放控件隐藏的前后几百毫秒内，点击查词界面，就可以让查词界面卡住」）
- **真实性**：✅ 真 bug。**不是焦点被抢，不是主 isolate 冻结，不是 WebView 被 dispose** —— 界面还在动
  （视频恢复播放、动画照跑），只是查词 UI 全部无响应。
- **根因**：`fushi/lib/src/pages/implementations/dictionary_popup_controller.dart:184`（修前）——
  `bool _searchingUi` 是一个**镜像变量（第二真相源）**，只有成功路径维护它。
  `endSearchUi()` 的全部 5 个调用点都在 `dictionary_page_mixin.dart`（:722/:755/:958/:975/:987），
  全是成功/超时路径；而 `dismissAt`(:427) / `truncateTo`(:293) / `pruneToWarmSlot`(:305) /
  `clear`(:323) 四条**关栈路径一条都不复位它**。

  以 `dismissAt(0)` 为例：热槽首条会走 `_cancelRevealTimers` + `_restoreWarmSeed`（把
  `revealOnRender` 置 false、掐掉 1800ms 兜底 Timer），全程没有一行碰 `_searchingUi`。之后 WebView
  真的渲染完 → `revealRendered(e)` 在 `:416 if (!e.revealOnRender) return false` 早退 → mixin 里
  包在 `if` 内的 `endSearchUi()` **永不执行**。镜像于是永久卡 true：
  - `shouldShowLookupDismissBarrier(... isSearching: true ...)` → 全屏 opaque barrier 永久挂着；
  - 再点 → `_onDismissBarrierTap` → `_popNestedPopupAt(0)` → `dismissAt(0)` 再走一遍 no-op，**点不动**；
  - Esc/返回 → `topVideoForegroundLayer(hasVisibleDictionaryPopup: false)` 选不到弹窗分支，去退全屏/
    退页了，**关不掉**；
  - `_lookupOverlayActive`（`video_fushi_page.dart:4408`）恒真 → `_pokeControlsVisible()` 永久早退，
    加上 barrier 挡住真实 hover，**播放控件从此再也唤不回来**。

  **为什么正好是「播放控件隐藏的前后几百毫秒」**：这不是巧合，两个窗口是同一个 —— 查词自己造成了
  控件隐藏。点字幕查词 → 下一帧 barrier 挂上根 Overlay → barrier 是全屏 opaque，真实鼠标此后命中
  不到 media_kit 自己的 `MouseRegion`（`controls_visibility.part.dart:37-46` 的注释就是这个事实）→
  MouseTracker 触发 `onExit()` → 控制条开始淡出（150ms）+ 字幕避让回落（200ms）。而这段时间正是
  `markPendingReveal` 等 `popupRendered` 的挂起窗口。此刻点下去，加载占位卡的空白区不吃命中
  （`buildPopupLoadingPlaceholder` 里只有进度条 + `Expanded(SizedBox.shrink())`），点击穿到 barrier
  → `dismissAt` → 卡死。

- **[x] ① 已修复** — 1d2053fdf4。**不是**在四条删除路径各补一句 `endSearchUi()`（那是打补丁，下次加第
  五条路径照样漏），而是**删掉镜像、改成派生值**：`isSearchingUi` 现在等价于「目标 entry 仍在栈内
  且仍 `isSearching || revealOnRender`」，`pendingRect` 随之派生。上述四条路径**本来就已经**清了
  entry 的这两个标志或把 entry 移出了栈 —— 它们早就表达了「这次搜索结束了」，只是从前没人把这个
  事实翻译给 UI。派生之后这条翻译没有失败的可能，将来新增任何关栈路径都自动正确。
  `beginSearchUi` 唯一调用点（`dictionary_page_mixin.dart:928`）多传一个已在手边的 `entry`；
  mixin 里 5 处 `endSearchUi()` 全部保留（仍是显式终点，负责清 rect 并 notify），只是不再是唯一出口。
- **[x] ② 已加自动化测试** — 新增 `fushi/test/pages/dictionary_popup_searching_ui_derived_test.dart`
  6 条：先钉前置（挂起态本身必须亮着盖板，否则后面什么都证明不了），再钉
  `dismissAt` / `truncateTo` / `pruneToWarmSlot` / `clear` 四条关栈路径走完盖板与 barrier 都必须落幕，
  最后钉正常路径不受影响（`revealRendered` 翻可见后盖板落幕、弹窗仍在）。
  变异实测：把派生判据改回恒真 → `dismissAt` / `pruneToWarmSlot` / `revealRendered` 三条变红
  （正是 entry 仍留在栈内的路径，即旧镜像失效的那些）；`truncateTo` / `clear` 保持绿，因为 entry
  直接离栈、由派生判据的另一半兜住 —— 两半都被覆盖到。
- **备注**：调查中发现一处同族口径不一致（本次未改，被 barrier 挡着不发作）：
  `_canOwnVideoFocus`（`video_fushi_page.dart:3855`）用 `_hasVisiblePopup`，而 `_lookupOverlayActive`
  （:4408）用 `_hasVisiblePopup || isSearchingUi`，挂起窗口内前者为假 → 该窗口内的焦点回收是放行的。
  另：`pushNestedPopup` 没有 search generation（对照 `home_dictionary_page.dart:648` 的
  `_searchGeneration` 是有的），在 `await searchDictionary` 期间被 dismiss 的那次查词仍会
  `fillResult + markPendingReveal` → 已关掉的弹窗可能几百毫秒后自己弹回来。两条都值得另开跟进。
