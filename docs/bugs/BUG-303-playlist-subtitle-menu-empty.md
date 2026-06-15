## BUG-303 · m3u8 播放列表首集字幕菜单「一个字幕没有」
- **报告**：2026-06-16（用户：m3u8 播放列表 BanG Dream 打开首集，字幕菜单空，列不出那条内封 ass 字幕。Windows 桌面。PM 在本机对真文件直跑系统 ffmpeg 取得 ground truth：`D:\video\BanG Dream!\Season 01\BanG Dream! - S01E01.mkv` 真有 1 条 `Stream #0:2(eng): Subtitle: ass (ssa) (default)` + 15 个字体 attachment 流）
- **真实性**：✅ 真 bug（不在解析/路径/正则，而在枚举 `ffmpeg -i` 的**固定 30s 超时**对大体积交错容器在磁盘争用下会超时返回空 → 菜单静默 0 字幕），根因 `hibiki/lib/src/media/video/video_subtitle_source.dart:295 listEmbeddedSubtitleTracks`（超时 `const Duration(seconds: 30)`，未随容器体积放大）。

### 根因（真实代码路径取证）
先逐层证伪 PM 的「路径/ffmpeg 调用层」强假设：
1. **路径正确（非 .m3u8）**：m3u8 `Season 01\BanG Dream! - S01E01.mkv` 经 `parseM3u8`（`p.join(baseDir, rel)` + `p.normalize`，`\`→`/`）解析为绝对 `.mkv`。实查 DB `video_books`：playlist 行 `video_path` 与 `playlist_json` 各集 `path` 均是解析后的真实 `.mkv` 绝对路径（含 `!` 与空格），**不是 .m3u8**。`_applyLoad:1524` 把 `_currentVideoPath = episode.path`，菜单 `_showSubtitleSourceMenu:4914` 读它传给 `listAllSubtitleSources`，路径无误。
2. **解析/正则/codec 正确**：`_subtitleStreamPattern` 匹配真实 ass 行成功（lang=eng/codec=ass），`subtitleFormatForCodec('ass')=ass`，`isGraphicEmbedded=false`。
3. **ffmpeg 调用本身正确**：用 Hibiki 的确切调用（`Process.start(['-hide_banner','-i',absPath])` + drain stdout + 收集 stderr）对真文件复刻——系统 ffmpeg、两份 bundled `ffmpeg.exe`（n7.1）、PATH ffmpeg **全部枚举出 1 条** ass。`-i` 探测仅 0.044s。Hibiki 自身 `listAllSubtitleSources`（经 `CliFfmpegBackend`，flutter test 跑真文件）返回 1 条 `embedded:0 | 内封 0: eng / ass`。并发持有读句柄（模拟 libmpv 播放）下仍返回 1 条。该 ass 轨也能正常 `-map 0:s:0` 抽成 760KB 有效 cue。**离线无争用一切正常 → 复现不出。**

真根因落在**唯一与体积/争用相关的环节**：`listEmbeddedSubtitleTracks` 的 `-i` 探测超时**固定 30s，不随容器字节放大**。`-i` 为给交错容器里靠后的流定 codec 参数会读到远超 probesize（实测日志：`analyzeduration(0)/probesize(5000000)` + 对 15 个 attachment 流逐条 `Could not find codec parameters`）。真机首开 BanG Dream（1GB+、15 字体附件）时：冷缓存 + `_applyLoad:1546` 同时 fire `prewarmEmbeddedSubtitleCache`（整轨抽取，单趟读穿整个容器 ~20s）+ libmpv 正在播放，三方争用磁盘 IO，连「读到字幕流 codec 参数」都可能 > 30s。一旦超时，`FfmpegBackend` 返回 `returnCode:null + output:''`，且按设计**不回退 PATH**（超时=慢 IO 非坏二进制，见 `ffmpeg_backend.dart` BUG-283 注释 + `ffmpeg_executable_resolve_test.dart:280` 守卫），`parseSubtitleStreamsFromFfmpegLog('')` → **0 条字幕、菜单「一个字幕没有」**，无任何用户/日志反馈。

抽取路径早在 BUG-104 就学到「大交错容器超时必须 size-scaled」（`subtitleExtractTimeoutForBytes`：60s + 8s/GB，clamp [60s,1200s]），但**枚举路径当时漏改**，留下这处固定 30s 的同源 fragility。

### 修复
让枚举 `-i` 用与抽取路径同一条 size-scaled 超时：`listEmbeddedSubtitleTracks` 把 `const Duration(seconds: 30)` 改为 `subtitleExtractTimeoutForBytes(_fileSizeOrZero(videoPath))`（下限 60s，大文件随体积放大），消除「固定 30s 对大容器超时 → 静默 0 字幕」整类。并在超时（`returnCode==null && output.isEmpty`）时 `debugPrint` 留痕，让「0 字幕 vs 真无字幕」未来可区分（不抛、不改降级契约）。不动 ProcessException/坏二进制回退链（BUG-275/283 已覆盖）。

- **[x] ① 已修复** — `video_subtitle_source.dart listEmbeddedSubtitleTracks` 超时改 `subtitleExtractTimeoutForBytes(_fileSizeOrZero(videoPath))` + 超时诊断日志。提交：2e934008d（amend 前 498d0d8d2）
- **[x] ② 已加自动化测试** — `test/media/video/video_subtitle_source_test.dart` 新增组「listEmbeddedSubtitleTracks 超时 size-scaled（BUG-303）」：① 真实 BanG Dream `ffmpeg -i` 日志（含那条 ass + attachment 流 + `Could not find codec parameters` 警告）`parseSubtitleStreamsFromFfmpegLog` 返回 1 条；② 注入 `_TimeoutCapturingBackend` 捕获实际超时，断言 == `subtitleExtractTimeoutForBytes(realSize)` 且 > 30s（撤修复回 30s 变红）；③ 1GB/27GB 超时与抽取路径同公式（回归 BUG-104 同源）。
- **备注**：media_kit 无 headless，真机「首开大容器播放列表/单片 → 字幕菜单稳定列出内封轨（含 prewarm + 播放并发期）」待用户复验。本机离线无争用故原 30s 也能过，超时是真机冷缓存 + 三方 IO 争用下的窗口；修复消除该窗口而非掩盖。若真机仍空，下一步看新增的 `[VideoSubtitleSource] embedded enumeration timed out` 日志确认是否仍卡探测。
