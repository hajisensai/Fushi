## BUG-3785 · remove-source-orphans-music-tracks
- **报告**：2026-10-26（AI 助手 P2 音乐域子代理补路由时发现）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/source_library/source_library_removal.dart` 的 `removeSourceLibrary` 只删来源行；`music_tracks.source_id` 不挂外键，删掉音乐扫描根后它下面的曲目留在曲库里成孤儿，之后重扫也清不掉（扫描只处理现存的根）。`DELETE /api/admin/library/sources/:id` 与来源页都走这个函数。
- **[x] ① 已修复** — `removeSourceLibrary` 删来源前先按扫描器「文件已不在」同一方法 `softDeleteMissingMusicTracks(sourceId, seenTrackUids: {})` 把该根下的曲目软删；非音乐来源下没有曲目，空操作。
- **[x] ② 已加自动化测试** — `fushi/test/media/source_library/source_library_removal_test.dart`「BUG-3785：删音乐扫描根把它下面的曲目一起软删…」。
- **备注**：
