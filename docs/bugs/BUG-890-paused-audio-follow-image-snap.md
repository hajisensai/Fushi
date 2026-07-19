## BUG-890 · 暂停/图片等待时有声书跟随把阅读器拽回音频位置
- **报告**：2026-07-18（用户：）
- **真实性**：✅ 真 bug（沿真实代码路径定位）。根因链见下。
- **[x] ① 已修复** — 见下方修复
- **[x] ② 已加自动化测试** — `hibiki/test/media/audiobook/image_pause_resume_manual_nav_test.dart`
- **备注**：真机复测原始失败路径待做。

### 现象
开着「跟随音频」阅读带有声书的 EPUB，向前翻页想回看/预读时被拽回音频位置。用户观察：
- 平常暂停时随便翻没问题；
- 但**向前**跨过含插图的章（如 あとがき 前后必有一张图）时，被重置回“当前（音频）位置”；
- “不是我触发的”，试几次才复现。

### 根因
不是普通暂停态。触发者是**图片等待**（`imagePauseSec>0`）的自动暂停+自动恢复：

1. 播放中朗读跨过插图 → reader 的 `onImageDetected` → `AudiobookPlayerController.triggerImagePause()`
   （`packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart:331`）暂停播放并 arm 一个
   `imagePauseSec` 秒的定时器。用户此刻看到“音频停了”，以为可自由翻页。
2. 用户在这几秒窗口内手动向前翻页 → `noteManualReaderNavigation()`（`:1173`）把
   `_manualReaderOverrideCue = _currentCue`（图片那句），这枚一次性护栏本应让后续跟随保位不跳。
3. 定时器到点：`triggerImagePause` 回调（`:336`）`_player.play()` 恢复播放后**无条件**调
   `snapReaderToAudio()`（`:1208`）。`snapReaderToAudio` 会 `_manualReaderOverrideCue = null`（`:1212`）
   清掉护栏 + 置 `_forceNextReveal` + `_maybeEmitCrossChapter(cue, bypassPlayGuard: true)`——于是把
   reader 强行拽回音频所在章。用户手动翻到的位置被吃掉。

对比：章内滚动跟随（`shouldRevealCurrentCue` `:1053`）已用 `_player.playing` 把关，跨章跟随/强制
reveal 却只靠会被 `snapReaderToAudio` 清掉的一次性护栏——图片等待的自动恢复正好清掉它。

### 修复
图片等待的自动恢复**尊重手动导航**：若用户在暂停窗口内手动翻页离开，恢复播放时不再强制 snap，
让跟随只在播放真正推进到**下一句**时经既有护栏自然接管（正是用户诉求）。

- `triggerImagePause`：arm 定时器时清 `_readerMovedDuringImagePause=false`；回调里 `play()` 后仅当
  未手动移动才 `snapReaderToAudio()`。
- `noteManualReaderNavigation`：图片等待在途（`isImagePaused`）时置 `_readerMovedDuringImagePause=true`。
- 纯决策 `shouldSnapAfterImagePauseResume(readerMovedDuringPause)` 抽出便于单测。
- 生命周期各清点（`load`/`pause`/`play`/`dispose`）复位标志，杜绝泄漏。

未手动移动的老用户路径（看完图→自动继续）行为不变。
