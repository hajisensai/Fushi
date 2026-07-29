## BUG-1246 · 有声书跨章等待后触发已销毁 State 重绘

- **报告**：2026-07-29（用户：Android 错误日志显示有声书 cue 跨章节时，
  `_handleCueCrossChapter → _navigateToChapter → _beginNavigation → _rebuild`
  最终触发 `State.setState` 的空值断言）
- **真实性**：✅ 真 bug。根因位于
  `hibiki/lib/src/pages/implementations/reader_hibiki/audiobook.part.dart:648-701`：
  `_handleCueCrossChapter` 会先 `await _pauseThroughImageOnlyChapters` 展示中间纯图片章，
  旧 continuation 会在用户退出 reader 后继续运行。仅复检 `mounted` 仍不完整：进程级
  `AudiobookPlayerController` 会被立即重进的另一个 reader `State` 复用，旧 `finally`
  若只凭 controller identity 清 `imageChapterPauseActive` / chapter transition，仍会改坏
  新 owner 的状态；同一 reader 中被更晚导航顶替的序列也必须按 navigation generation
  失效。
- **[x] ① 已修复** — `AudiobookSession` 在每次 reader attach/detach 时递增 owner
  epoch，并把 captured controller identity + epoch 作为 attachment 凭证；图片章序列在
  每个 await 边界同时复检 attachment 与 navigation generation。attach/detach 原子复位
  图片序列 active 位和 chapter transition；旧 continuation 的 reveal、pause、最终导航、
  cancel/finally 均不能触碰新 owner。控制器内部的 await-based 图片暂停另持
  reader-transition epoch + cancel Completer：owner 切换会完成旧等待但不恢复播放或通知，
  连底层 `pause()` 尚未返回的路径也可立即失效。`_navigateToChapter` 和 `_rebuild` 的
  同步入口通过可直接测试的生产门控，在任何副作用前拒绝已销毁 reader。原业务修复基线：
  `dcfcda708bbff15720a01c65ec711eb779e52495`；本条随后由 corrective 分支补强。
- **[x] ② 已加自动化测试** —
  `hibiki/test/pages/reader_navigation_dispose_guard_test.dart` 不再读取源码或用
  `indexOf` 匹配字符串，而是用可控 Completer 运行真实生产协调器，覆盖 dispose 发生于
  图片导航 await、dispose 后立即 reattach、同 owner 新 generation 顶替、连续图片章与
  宿主去重、正常无 dispose 路径，以及 late rebuild / 导航入口零副作用。
  `audiobook_session_test.dart` 另锁定 owner epoch 与 attach/detach 原子复位。
  定向及相邻回归覆盖 owner 在计时等待中、底层 `pause()` await 中切换的反例；故障注入
  确认无效/后移 guard、漏释放、漏 await 后复检、旧 owner 仅凭 controller identity
  穿透，以及移除内部 cancel token/epoch 复检均会使测试失败。
- **备注**：同一日志中的互联同步 Socket/HTTP 超时是独立网络错误，不是本崩溃的调用链
  根因，未在本条中混修。当前仍缺 Android 真机“播放跟随跨过纯图片章时立刻退出并立即
  重进 reader”的端到端验收；PR CI / APK 状态以集成线程的最新硬证据为准。
