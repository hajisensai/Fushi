## BUG-2490 · 歌词模式显示转录文本而非已匹配的原文
- **报告**：2026-09-13（用户截图：正常阅读显示「牛／痴れ者／馬鹿」，歌词显示「うし／知れもの／バカ」）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/audiobook/lyrics_mode_html.dart:33` 原来直接渲染 `AudioCue.text`，即语音转录结果；`reader_fushi/lyrics.part.dart:178` 未传 EPUB。匹配器仅将原文位置写入 `textFragmentId`，不会改写字幕文本。普通阅读展示 EPUB，因此没有同样的文字差异。`reader_fushi/audiobook.part.dart:1065` 的制卡 cue 句子同样直接读取转录文本。
- **[x] ① 已修复** — `LyricsCueTextResolver` 复用 `EpubBook.chapterPlainText` 与 `AudioTextNormalizer.normalizeWithOffsets`，按已匹配的 UTF-16 范围提取原文字形（排除 ruby 注音），歌词 HTML 和歌词模式制卡 cue 句子共用。保留原 `AudioCue`、时间、索引、tokenTiming；没有匹配或非法范围时回退原字幕。支持合法跨章匹配、拒绝半代理对/整书越界；按需缓存最多三章。提交见本文件所属修复提交。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/lyrics_cue_text_test.dart`：10 项，涵盖截图差异、ruby、内部标点、全角、跨章/空章、无匹配/越界、非 BMP、HTML 转义、cue 不变和生产接线。定向测试退出码 0；`flutter analyze --no-pub` 通过。
- **备注**：范围边界沿用归一化匹配坐标，不扩大到范围外的开引号或句末标点。历史范围没有正文版本指纹，合法但陈旧的匹配仍需重新匹配。用户只提供截图，尚未拿到原 EPUB/字幕做真实设备上的原始失败路径复测；自动化文本/HTML 验证不等于设备验收。正常阅读、悬浮歌词和 ASR 算法不在本轮修改范围。
- **扩展验证**：`tests_for_changes.dart --include-dart` 推导守卫加相邻歌词/坐标测试共 566 个文件，分 15 批执行（避免 Windows 命令行长度上限）：4,160 项通过、4 项失败，整批退出码 1。失败为 `video_double_tap_seek_guard_test.dart`、`video_popup_cue_actions_guard_test.dart`、`video_remote_resume_guard_test.dart`、`video_render_fixes_guard_test.dart` 各一项源码断言；已用 `git diff HEAD --` 核对测试及其读取的视频源文件与基线 `e61c243117` 相同，本轮未改，未计为通过。日志在 worktree 的 `fushi/.lyrics-tests-*.log`。BUG 号/索引检查通过。
