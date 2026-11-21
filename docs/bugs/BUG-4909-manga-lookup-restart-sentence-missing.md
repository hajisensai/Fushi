## BUG-4909 · 小说「查词后从句首重播」在漫画阅读器不生效
- **报告**：2026-11-20（用户：要求根本性修复 PR #3751 里遗留的「查词后从句首重播没接到漫画」）
- **真实性**：✅ 真 bug。`ReaderFushiSource.restartSentenceAfterLookup` 是阅读器共用设置，小说按它从被查那句句首重播；漫画阅读器恢复时从不读它：成品音频原地续播，现场合成只会重读当前句。
  - 根因：漫画的查词恢复路径（BUG-4907 新接的 `MangaLookupPause`）只有「恢复 / 不恢复」，没有被查句子与重播语义；两种音源也没有「从指定句开始」的入口（`manga_audio_playback_driver.dart` 无按句续播，`manga_read_aloud_controller.dart` 的 `resume` 只回当前句）。
- **[x] ① 已修复** — 主屏点 OCR 字时阅读器把被查句（页 + OCR 块，即 `_miningSentenceBlocks`）交给 `MangaLookupPause.noteSentence`（`manga_fushi_page.dart:5405`），由接下来那次查词（页内或副屏）认领。恢复时开关开着就从句首重播：成品音频按页 + 块在清单里找台词（与制卡同一判据 `mangaMiningAudioLineIndex`），`MangaAudioPlaybackDriver.playFromLine`（`:186`）跳到句首再播；没有被查句（副屏面板自己发起的查词）退到当前页刚读过的那句，本页还没读到句子就原地播，不把读者拉回上一页。现场合成用新的 `MangaReadAloudController.resumeFromSentence`（`:299`）按块交集最大定位到那一句，对不上同 `resume`。
- **[x] ② 已增加自动化测试** — `manga_lookup_pause_test.dart`「查后从句首重播」组（被查句交给认领它的查词、副屏面板查词无句、句子不带到下一次、开关关着原地续）；`manga_audio_playback_test.dart`（指定句 / 当前句 / 无台词页原地播）；`manga_read_aloud_controller_test.dart`（从被查那句续读、对不上从当前句）。
- **验证**：同 BUG-4908 那次定向测试，全部执行通过。
- **备注**：真机未复测。
