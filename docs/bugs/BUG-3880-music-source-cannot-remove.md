## BUG-3880 · music-source-cannot-remove
- **报告**：2026-10-30（用户：群反馈，设置 › 音乐「曲库」点了直接跳音乐页，本地曲库来源找不到删除入口）
- **真实性**：✅ 真 bug。① `fushi/lib/src/settings/settings_schema_music.dart` 的 `music.library` 项 subtitle 写「曲库来源与播放」，onTap 却只是切到音乐 tab，文案误导；② 音乐页只有「添加文件夹」，没有任何入口打开 `MediaSourcesDialog(mediaKind: music)`，而 `MediaSourcesView` 对 music 也没有计数分支（`packages/fushi_core/lib/src/database/database_library.part.dart` `countMediaBySourceId` 对 music 恒返回 0）且会给出音乐不支持的网络 transport。
- **[x] ① 已修复** — 设置项 subtitle 改为「前往音乐页」，并新增「管理音乐文件夹」设置项；音乐页顶栏加「管理音乐文件夹」按钮，二者都打开 `showMusicSourcesDialog`（来源列表可移除，移除走既有 `removeSourceLibrary` 软删曲目）；`countMediaBySourceId` 新增 music 分支（排除软删曲目）；`media_sources_view.dart` 对 music 只给本地文件夹、计数显示「N 首曲目」。
- **[x] ② 已加自动化测试** — `fushi/test/database/media_sources_test.dart`（music 计数含软删排除与跨来源隔离）。
- **备注**：Windows 调试实例上人工确认过。
