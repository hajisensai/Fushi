## BUG-126 · 退出后导入的字幕未绑定视频丢失
- **报告**：2026-06-08（用户：退出后字幕又要重新自己导入，能不能绑定一下视频 / Windows 桌面）
- **真实性**：✅ 真 bug（播放列表恢复路径扫不到 app 文档目录里的导入文件），根因 `video_hibiki_page.dart:393 _restorePersistedSubtitle` + `:454 _loadEpisode`。

### 根因（真实代码路径取证）
导入/下载的外挂字幕被 `_importExternalSubtitle` 拷到 `<appDocs>/video_subtitles/<名>`（持久化值=该绝对路径）。恢复时：
- **单视频**（`_episodes.isEmpty`）：`_selectSubtitleSource` 走 `saveSubtitleSelection` 把 cue+源指针原子落库（BUG-081），重进 `_loadSingle` 的 `loadCues` 直接命中 → **能恢复**。
- **播放列表**（多集自动分组）：`_selectSubtitleSource` 只 `updateSubtitleSource` 存源指针、**不存 cue**（各集按磁盘动态解析，避免跨集 bookUid 错配）。重进/换集走 `_restorePersistedSubtitle(crossEpisode)` → `pickEpisodeSubtitleSource(persisted, listAllSubtitleSources(episode.path))`。但 `listAllSubtitleSources` 只扫**视频同目录 + 内封轨**，扫不到 app 文档目录里的导入文件 → 匹配失败 → 退默认 sidecar → **字幕丢失，要重新导入**。

### 修复
`_restorePersistedSubtitle` 在同目录枚举**之前**加捷径：若 `persisted` 是「显式导入的外挂字幕」（纯函数 `isImportedExternalSubtitlePath`：非 `embedded:` 前缀 + 受支持扩展名）且文件仍在磁盘上（`File(persisted).existsSync()`），直接按路径 `loadCuesForSource(SubtitleSource.external(...))` 加载返回。这类源与剧集目录无关、持久化值就是文件路径，按路径恢复最直接；单视频已被 `loadCues` 提前命中、走不到这里，故主要救播放列表。文件在但解析空（坏字幕）时落回同目录枚举。

- **[x] ① 已修复** — `video_subtitle_source.dart` 新增纯函数 `isImportedExternalSubtitlePath`；`video_hibiki_page.dart _restorePersistedSubtitle` 在 `listAllSubtitleSources` 前按路径直接加载导入的外挂字幕。
- **[x] ② 已加自动化测试** — `test/media/video/video_subtitle_source_test.dart`（`isImportedExternalSubtitlePath`：导入路径=true / `embedded:<n>`=false / 空 / 非字幕扩展名=false / srt·ass·ssa·vtt 大小写不敏感）；`test/pages/video_subtitle_fixes_guard_test.dart`（恢复路径用 `isImportedExternalSubtitlePath` + `File.existsSync` 且排在同目录枚举之前）。
- **备注**：media_kit 无 headless，真机「播放列表导入字幕→退出→重进仍在」待用户复验。多集播放列表里导入的同一字幕会跨集沿用（用户显式导入，可接受；各集自带 sidecar 时仍由 pickEpisodeSubtitleSource 按集匹配）。
