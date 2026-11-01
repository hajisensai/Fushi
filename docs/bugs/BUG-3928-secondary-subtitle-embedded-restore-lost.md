## BUG-3928 · 退出视频再进，内封副字幕不显示（菜单仍高亮该轨，得重选一遍）
- **报告**：2026-11-01（用户：应用内反馈 XcV2TsgvMz（Windows，附录屏）；同问题反馈 666SKnuUTb）
- **真实性**：✅ 真 bug。录屏：主字幕为外挂 .ass、副字幕选内封 0（简中）；退出后从首页「继续观看」重进，顶部中文副字幕消失，字幕面板「副字幕」里内封 0 仍高亮；点内封 1 再点内封 0 才恢复。
  根因 `fushi/lib/src/pages/implementations/video_fushi/subtitle.part.dart` `_restoreSecondarySubtitle`（原 1155–1163 行）：内嵌副字幕恢复凭持久化串 `embedded:<n>` 自拼 `SubtitleSource.embedded(streamIndex:, label:)`，**没有 codec**；`packages/fushi_engine/lib/media/video/video_subtitle_source.dart` `_loadEmbeddedCues` 第一步 `subtitleFormatForCodec(source.codec ?? '')` 对空 codec 恒返 null → `unsupportedFormat` → 空 cue，恢复「空 cue 静默跳过」，副字幕层就一直空着。手动选择走的是菜单枚举出的源（带 codec），所以重选就好。主字幕恢复 `_restorePersistedSubtitle` 走 `listAllSubtitleSources` + `_firstMatching`，不受影响。
- **[x] ① 已修复** — 副字幕内嵌轨恢复改为与主字幕同一条路：`listAllSubtitleSources` 枚举 + `_firstMatching` 精确匹配取真实源（带 codec）；轨已不在或是图形位图轨则保持无副字幕。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_secondary_subtitle_same_list_guard_test.dart`「副字幕内嵌轨恢复从真实枚举取源（带 codec），不凭持久化串自拼」（源码扫描守卫：私有 State 方法需整页真播放器才能 widget 测）。
- **备注**：未在真机复测原始路径（本轮反馈批处理不做设备验证）。
