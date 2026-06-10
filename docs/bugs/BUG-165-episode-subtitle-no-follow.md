## BUG-165 · 播放列表换集字幕不自动跟随对应集
- **报告**：2026-06-11（用户：导入一整季+配套同名字幕，切下一集时字幕不自动切到该集对应字幕，还得手动点。Windows 桌面）
- **真实性**：✅ 真 bug（BUG-132 捷径判定过宽，把剧集同目录 sidecar 误当导入字幕跨集沿用），根因 `hibiki/lib/src/pages/implementations/video_hibiki_page.dart:601 _restorePersistedSubtitle`（捷径条件）+ `hibiki/lib/src/media/video/video_subtitle_source.dart:112 isImportedExternalSubtitlePath`（判定只看扩展名）。

### 根因（真实代码路径取证）
1. 整季导入走 `_importGroup`/`_importPlaylistFromPath`：`PlaylistEntry(title, path)` 只存视频绝对路径，字幕留在视频同目录（`EP01.ja.srt`、`EP02.ja.srt`…），playlist `VideoBooks.subtitleSource` = null。
2. 打开第一集：`_init` → `_currentSubtitleSource = null` → `_loadEpisode(0, subtitleSource: null)` → ② `_detectSidecar(EP01.path)` 命中 `<剧集目录>/EP01.ja.srt`；`_applyLoad:846` 把 `_currentSubtitleSource = "<剧集目录>/EP01.ja.srt"`。
3. 切第二集：`_switchEpisode(1)` → `_loadEpisode(1, subtitleSource: "<剧集目录>/EP01.ja.srt")` → ① `_restorePersistedSubtitle(videoPath=EP02.path, persisted=".../EP01.ja.srt", crossEpisode: true)`。
4. **命中点**：`isImportedExternalSubtitlePath(".../EP01.ja.srt")` 只看「非 `embedded:` 前缀 + 字幕扩展名」→ 对剧集同目录 sidecar 也返回 true；`File(...).existsSync()` 为 true → 进入 BUG-132 捷径，**原样加载上一集的 `EP01.ja.srt`**（cues 非空就返回），**绕过 `pickEpisodeSubtitleSource` 的按新集 basename 匹配** → 第二集仍显示第一集字幕，要手动重选。

真正的导入字幕落点是 `<appDocs>/video_subtitles/<basename>`（`_importExternalSubtitleInner:2748`），与剧集目录无关；剧集自带 sidecar 在视频同目录。两者唯一区分是**目录归属**，BUG-132 捷径用「扩展名」判定过宽，把同目录 sidecar 一并截下来跨集沿用。BUG-132 文档备注声称「各集自带 sidecar 时仍由 pickEpisodeSubtitleSource 按集匹配」——代码实际从未实现这个区分。

### 修复
新增纯函数 `shouldReusePersistedSubtitleAcrossEpisode(persisted, episodeVideoPath)`（`video_subtitle_source.dart`）：仅当持久化外挂字幕路径的**目录 ≠ 新集视频目录**（即真正的导入/下载字幕，住在 video_subtitles 等独立目录）才沿用；同目录 sidecar（上一集旁的字幕）返回 false，让 `_restorePersistedSubtitle` 落回同目录枚举 + `pickEpisodeSubtitleSource` 按新集 basename 重新选。`_restorePersistedSubtitle` 的 BUG-132 捷径仅在 `crossEpisode: true` 时叠加这个目录判定；`crossEpisode: false`（单视频重启恢复，同一视频本就该恢复同一字幕）保持沿用不变。

- **[x] ① 已修复** — `video_subtitle_source.dart` 新增 `shouldReusePersistedSubtitleAcrossEpisode`；`video_hibiki_page.dart _restorePersistedSubtitle` 的导入字幕捷径在 `crossEpisode` 时加目录归属判定。提交：375f21856
- **[x] ② 已加自动化测试** — `test/media/video/video_subtitle_preference_test.dart` 新增 `shouldReusePersistedSubtitleAcrossEpisode`（同目录 sidecar=false / 异目录导入字幕=true / embedded=false / 空=false 等纯函数用例，撤修复变红）；`test/pages/video_subtitle_fixes_guard_test.dart` 源码守卫（捷径在 crossEpisode 分支调用新判定）。
- **备注**：media_kit 无 headless，真机「整季 sidecar→换集字幕自动跟随、且显式导入字幕仍跨集沿用」待用户复验。
