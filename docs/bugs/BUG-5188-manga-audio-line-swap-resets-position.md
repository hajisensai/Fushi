## BUG-5188 · manga-audio-line-swap-resets-position
- **报告**：2026-11-22（用户：拍板 isATnQZ_eN 实现中发现，反馈要求「把续听位置换算到同一条台词」）
- **真实性**：✅ 真 bug。漫画有声单句换种子重生成 / 补回未配音句子后，只要换掉的那句在续听断点**之前**，续听进度就被清零。根因 `fushi/lib/src/media/manga/audio/manga_audio_library.dart` 的 `updateMangaAudioLine`（改前第 143–144 行）先 `saveCues` 再 `AudiobookRepository.replaceAudio`；后者的 BUG-1679 判据（`audiobookPositionSurvivesAudioChange`，`packages/fushi_audio/lib/src/audiobook/audiobook_position_rebase.dart`）针对「换了一套音频」，断点所在文件及之前任一路径变了就归零——而漫画按句换音频时文件数与顺序不变、每个下标仍是同一句，换的是那一句的新文件名，于是被误判成整套换掉。
- **[x] ① 已修复** — `AudiobookRepository.swapAudioFiles`（新）：文件结构不变、按下标换几个文件时，cue、音频列表与断点在一个事务里一起改，断点按 `audiobookPositionAfterFilesSwapped` 换算：仍在同一句，落在被换的那句里就从它开头接着听，不盖位置时间戳。`updateMangaAudioLines`（单句 / 批量补回、换本地音频、按角色重生成及其撤销共用）改走它。
- **[x] ② 已加自动化测试** — `packages/fushi_audio/test/audiobook/audiobook_reimport_keeps_position_test.dart`（`swapAudioFiles` 与纯函数）、`fushi/test/media/manga/audio/manga_audio_playback_test.dart`（`updateMangaAudioLine：只换补回的那一句` 断言断点仍在后一句的同一偏移）、`fushi/test/ops/ctl_tts_routes_test.dart`（换本地音频后断点在同一句）。
- **备注**：随拍板事项 isATnQZ_eN（漫画有声 CLI 按句替换本地音频 / 按角色重生成）一起修。
