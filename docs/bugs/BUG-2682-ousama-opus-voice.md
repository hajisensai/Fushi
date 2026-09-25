## BUG-2682 · 王様恋愛导出的 Opus 语音未进入资源索引

- **报告**：2026-09-25（用户：《王様恋愛》Ver1.00 的台词 Hook 和内嵌查词正常，游戏内有配音，但 Fushi 没有语音）
- **真实性**：✅ 真 bug。该游戏是 Windows x86 KiriKiri Z，原生 Hook 已导出 Ogg/Opus 容器的 `.opus` 语音；`fushi/lib/src/mining/gal_voice_dump_index.dart:853` 的文件分类未接纳 `.opus`，`fushi/lib/src/mining/galgame_audio_source.dart:2589` 的资源 ID 回查也拒绝 `.opus`，导致已导出的原声无法进入配对、试听和制卡路径。
- **[x] ① 已修复** — `8f43235fd4`：将 `.opus` 纳入 Ogg 类资源索引与资源 ID 回查；不改原生 Hook、IPC 或现有文本配对判据。
- **[x] ② 已加自动化测试** — `fushi/test/mining/galgame_multi_voice_resources_test.dart` 覆盖带事件 ID 和无标记的 Opus 资源、BGM/其他事件隔离、资源文件回查及制卡转码调用；在上游基线的投稿分支上，连同 `gal_voice_dump_index_test.dart` 共 38 个定向测试通过，改动文件的 `flutter analyze --no-pub` 通过。
- **备注**：用户已在原始 Windows 游戏实机确认语音正常、可以制卡。该反馈不等同于逐句资源字节哈希验证，因此本修复不升级引擎支持矩阵。游戏 EXE SHA-256：`E8491038F517D84709DFC59D4A65FC5CF0FA922F701E0D5688A314EC0D6BEAE5`；未提交游戏资源。
