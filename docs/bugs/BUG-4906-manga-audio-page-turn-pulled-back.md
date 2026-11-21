## BUG-4906 · 漫画有声播放中翻页 / 滚动，画面先被拉回前一页再翻回来
- **报告**：2026-11-20（用户：「播放的时候翻页，会被音频拉回去一点点，然后继续翻页」「我滚动的时候他一会回到前面以后回到后面」，暂停时也会）
- **真实性**：✅ 真 bug。用户翻页 → `MangaAudioPlaybackDriver.onPageChanged` 发起「跳到该页页段起点」的 seek；成品音频每句一个文件，这类 seek 几乎都跨文件，播放器换源落地前仍按旧文件报位置并继续往下播。
  - 根因：`fushi/lib/src/media/manga/audio/manga_audio_playback_driver.dart:194`（旧 `_seek`）与 `:210`（`_sync`）不知道有跳转在途，照常按位置流处理：旧位置一跨进下一句就 `_show(旧页)`，`MangaSentenceFollower.show` 把阅读器翻回旧页，落地后再翻过来。滚轮连翻时，先发的 seek 后落地也会按它的页 `show` 一次，把用户拉回中间页。
- **[x] ① 已修复** — 驱动记录在途跳转的目标与代数（`_seekTarget` / `_seekGeneration`）：在途期间位置流只刷新播放条（进度显示目标），不显示、不翻页、不做纯听跳过；位置落到目标条目或这次 seek 完成才算落地，先发的 seek 完成时不清后发那次的标记。上一句 / 下一句改从在途目标算起，连按不会从旧位置重算。
- **[x] ② 已增加自动化测试** — `fushi/test/media/manga/audio/manga_audio_playback_test.dart`：假播放器加「跳转闸门」模拟跨文件 seek 未落地，翻页式 / 条漫各验「落地前旧位置跨句不拉回」「连续翻页先发的后落地不拉回中间页（暂停态）」。
- **验证**：`dart tool/heavy.dart -- flutter test`（playback / lookup pause / 播放卡三份）exit 0，29 项全部执行通过。
- **备注**：真机未复测新构建（需要发包后在 Windows 上播 MyGO 卷 1 连翻验证）。
