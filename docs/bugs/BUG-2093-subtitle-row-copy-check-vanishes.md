## BUG-2093 · 字幕列表行复制的 ✓ 反馈在播放头离开该行时提前消失
- **报告**：2026-09-03（用户：点「复制」没有任何互动 → PR#1190 加了就地 ✓ 反馈，审查时发现该反馈在最常用路径上根本不成立）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/video/video_subtitle_jump_panel.dart:1495-1500`（合入前）——
  行 key 按 `trackKey = selected || rawIndex == _scrollTargetRawIndex` 在 `GlobalKey` 与
  `ValueKey<int>` 之间翻转；播放头一离开该行 key 就翻，`KeyedSubtree` 的 Element 随之重建，
  挂在行内的 `CopyFeedback`（`fushi/lib/src/utils/components/copy_feedback.dart:44` 的
  局部 `_copied`）被无声清零。于是「复制**正在播的那句**」——最常用的那条路径——上，1.5s 的
  反馈窗口在播放头走出该 cue 的那一帧就结束（短台词常在几百毫秒内切走）。暂停浏览列表时复制才正常。
  实测 probe：点当前播放行的复制 → `Icons.check` findsOneWidget；`debugUpdateCueForPosition(2500)`
  + 一帧 → `Found 0 widgets with icon check`。
- **[x] ① 已修复** — 提交 `PENDING_FIX_SHA`。状态的真正拥有者是**面板**（它知道 rawIndex），
  不是身份被列表控制的行 Element：`int? _copiedRawIndex` + 一个 `Timer` 提到
  `_VideoSubtitleJumpPanelState`（`video_subtitle_jump_panel.dart` 的 `_copiedRawIndex` /
  `_markCueCopied` / `dispose`），行内按钮按 `rawIndex == _copiedRawIndex` 渲染。
  消除了 key 翻转这个特殊情况，并白送「同一时刻只有一行是 ✓」（点 B 时 A 立刻复位）。
  顺带把「这句复制成功了没有」的判据从三份（面板按钮里 `cue.text.trim().isNotEmpty`、
  原生页 `_copyCueText`、网页页 `_copyCue`）收敛成一份：`VideoSubtitleJumpPanel.onCopyCue`
  改返回 `bool`，面板只读返回值。`CopyFeedback` 组件保留给查词浮层顶栏那颗独苗按钮，
  并把与 `dispose` 里 `cancel()` 互为冗余的 `if (!mounted) return` 砍掉（两道都在时谁都钉不住）。
- **[x] ② 已加自动化测试** — 提交 `PENDING_FIX_SHA`。
  - `fushi/test/media/video/video_subtitle_jump_panel_test.dart`：
    `inline copy check survives the playhead leaving that row (BUG-2093)`（复现上面那条 probe：
    复制当前播放行 → `debugUpdateCueForPosition(2500)` → ✓ 仍在，窗口到点才回落）、
    `only one row can be checked at a time`、`unmounting inside the feedback window does not throw`。
  - `fushi/test/media/video/subtitle_copy_cue_contract_guard_test.dart`（新增）：`onCopyCue`
    契约守卫。**网页视频页 `_copyCue` 此前零覆盖**——实测把它整个变 no-op，8371 条测试全绿、
    无一察觉；widget 测试要立起 WebView + AppModel + Riverpod，代价远超收益，源码扫描是
    这条腿能落地的最强一层。
  - `fushi/test/utils/components/copy_feedback_test.dart`：卸载用例改名为如实的
    「dispose 取消定时器（删掉那句 cancel 即红）」，冗余门砍掉后它才真的钉住那句 cancel。
- **备注**：变异实测（详见 PR#1190 评论）——M2「删 `dispose` 里的 `_resetTimer?.cancel()`」、
  M3「删定时器回调里的 `if (!mounted) return`」、M6「把网页页 `_copyCue` 变 no-op」三条原存活
  变异现均被杀（M3 因冗余门被砍而不再适用，等价变异是删 `dispose` 的 cancel = M2）。
