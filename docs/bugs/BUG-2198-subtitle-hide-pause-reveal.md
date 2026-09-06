## BUG-2198 · 隐藏字幕在暂停/查词时不恢复显示
- **报告**：2026-09-06（用户：「查词的时候隐藏字幕也会隐藏，而且暂停的时候隐藏字幕不会恢复」）
- **真实性**：✅ 真 bug — 根因 `fushi/lib/src/media/video/video_subtitle_overlay.dart:1247`（修前）：
  遮蔽模式两种视觉走了**不对称的门**。模糊是 `blurEnabled && !revealed && controller.isPlaying`
  （BUG-199「暂停时清晰」），隐藏却是 `subtitleHidden && !revealed`——刻意绕过 `isPlaying`，
  当时的理由写在注释里：「隐藏的语义是我不想看见它，暂停时自己冒出来才是惊吓」。
  这条特例同时造出用户报的两个症状：
  - **查词时也隐藏**：视频查词第一步就是 `controller.pause()`
    （`fushi/lib/src/pages/implementations/video_fushi/lookup_favorite.part.dart:52`）。暂停不解遮蔽，
    查词期间字幕就仍然看不见；更糟的是同一个 `hidden` 还门控着 `registerHits`
    （`video_subtitle_overlay.dart:1687`），未显形时字符不进命中登记表——**看不见，也点不到**，
    查词浮层里无从对照原句。模糊没这个问题纯粹是因为它吃 `isPlaying`，查词一暂停就自动清晰。
  - **暂停不恢复**：用户主动暂停想读一眼当前句，隐藏照旧不让位。
- **[x] ① 已修复** — 删掉不对称：抽出共同门 `obscureActive = !revealed && isPlaying`，模糊与隐藏
  只在「用哪种视觉」上分叉，判据不再有第二份（`video_subtitle_overlay.dart` 的 `_buildSubtitleLayer`）。
  暂停（含查词自动暂停）时两种遮蔽一起让位、字符同时恢复可查词；恢复播放下一帧自动遮回去，
  不需要复位显形态。副字幕（`secondaryHidden`）同一条门。提交见本文件所在分支。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_hide_hover_reveal_test.dart`
  （① 组翻转旧断言 + 新增「恢复播放重新隐藏」「暂停时模糊也让位」对称基准；⑧ 组新增
  「暂停让位 → 字符同时恢复可查词」直接钉住用户诉求 ①）与
  `fushi/test/media/video/video_secondary_subtitle_obscure_test.dart`（副字幕暂停让位 + 播放遮回）。
  变异实测：把 `hidden` 改回旧的 `!revealed`，这 4 条新守卫全红（不是空壳断言）。
- **备注**：旧行为有一条测试专门钉着（「暂停时隐藏依然生效（不吃 isPlaying 门，与模糊不同）」），
  本次按用户诉求翻转。原文件里大量隐藏用例的 controller **未起播**，靠的正是这条特例；
  改门后它们等于在测暂停态，故 helper 统一 `debugSetIsPlayingForTesting(true)`，
  ⑨ 组两条自建 controller 的用例单独补起播——否则断言恒假、变成空壳绿。
