## BUG-1470 · 选中台词线程后工作台正文为空：发布期过滤器丢掉同 hook 面兄弟行
- **报告**：2026-08-09（用户：某猿。）
  - 原话：「hook 后的进程/线程选择弹窗里预览**能看到文字**，选定进入后正文**不显示**。」
- **真实性**：✅ 真 bug。根因是同一件事被**两道判据不同的过滤器**各写了一遍：
  - 采集期 `fushi/lib/src/mining/gal_hook_session_controller.dart:1919`
    `_acceptsLineFromSelectedThread`，判据 `(threadId, faceId)`，**带 BUG-1159 的同 hook 面兜底**
    —— 同一 hook 面在不同剧情分支下调用点 ctx 会变、`thread_id` 随之变，只按 threadId
    精确匹配会把整段台词丢掉（native 侧 `face_id` 刻意不含 ctx，见
    `native/galgame_hook/include/luna_text_selector.h:163`）。
  - 发布期 `gal_hook_session_controller.dart:693` `_publishesUnderSelection`（修复前），判据是
    字符串 `textThreadKey` **全等**，没有 face 兜底。而 `textThreadKey` 由 threadId 派生
    （`fushi/lib/src/mining/galgame_audio_source.dart:1996`），ctx 一变 key 就变。
  - 于是剧情一分支，同一句台词**过了采集、被发布全丢**：`workbenchLines`（工作台正文唯一来源）
    与 `selectedSessionLines`（游戏窗浮窗唯一来源）同时空白；而线程预览区不受选择门控
    （`fushi/lib/src/sync/texthooker_service.dart:193`），照常有字 —— 正是「预览有字、选进去没文字」。
  - 既有守卫 `fushi/test/mining/gal_text_lane_consumer_filter_test.dart` 的立意本就是钉死
    「同 hook 面放行」，但它只断言 `service.entries`（**仅穿过采集期**）且 `selectTextThread`
    不传 `threadKey`，所以发布期过滤器从来没有被覆盖过。
- **[x] ① 已修复** — 让发布期成为采集期的**投影**而非平行实现：新增
  `_selectedThreadClaimedKeys`，采集期放行一行即认领它的 `textThreadKey`（`_claimThreadKey`），
  发布期只查该集合；`selectTextThread` 用选定 key 自身播种（保住绕过采集期直接塞行的
  无 helper 来源），三个复位点一并清空。顺带修两处同源缺陷：
  - `selectTextThread` 在「有 helper 却拿不到 native thread id」时显式 warning，
    消掉「弹窗关掉、状态条显示正在监听、一行文本都不来」的静默死态；
  - `_recoverSelectedThreadHistory` 改两趟（先学 hook 面再筛），消除
    `_acceptsLineFromSelectedThread` 带副作用 + native 按 seq 升序单遍求值导致的漏捞。
- **[x] ② 已加自动化测试** — `fushi/test/mining/gal_text_lane_consumer_filter_test.dart`
  新增「发布期过滤器」三条用例，断言面从 `service.entries` 换成
  `controller.workbenchLines` **与** `controller.selectedSessionLines` 并列（工作台与浮窗
  必须消费同一份集合）。已做变异实测：把 `_publishesUnderSelection` 改回 key 全等后，
  「同 hook 面的兄弟线程照样发布」用例即红。
- **备注**：与 A1（工作台查词失效）强耦合 —— 本 bug 发生时 `selectedSessionLines` 恒空，
  游戏窗浮窗根本不更新文本，点词自然无从谈起。见 [[BUG-1159]]。
