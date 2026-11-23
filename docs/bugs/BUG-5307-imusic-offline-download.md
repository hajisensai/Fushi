## BUG-5307 · 互联音乐库：把 host 曲目下载到本机离线听（design-imusic-q12）
- **报告**：2026-11-23（拍板台 design-imusic-q0..q12 实现分期，PR #4271 分支 `claude/imusic-impl`）
- **真实性**：✅ 真缺口（拍板「做」）。原先客户端只能串流 host 曲目。
- **[x] ① 已修复** — 新增 `fushi/lib/src/media/music/server/interconnect_music_download.dart`：复用插件下载的文件管线（落点、续传、嗅探、标签、目录封面、下载中心、导入曲库），取流改为向 host 签 `forDownload` 票（原样音质 + `segment`：CUE 曲目由 host 无损截段），封面经钉扎通道，host 生效歌词写成 sidecar；导入后 `adoptInterconnectMusicDownload` 用 `mergeMusicTrackInto` 把 host uid 记成本机曲目别名、引用改指，删掉 `fushi_host` 远程曲目行。入口：服务器曲目菜单「下载」（`music_local_playlist_actions.dart`）。MV 画面不随下载复制（MV 文件体积大，且 MV 由歌词页按需取，见 BUG-5302）。
- **[x] ② 已加自动化测试** — `fushi/test/media/music/server/interconnect_music_download_test.dart`（端到端下载：签票参数、sidecar、封面、导入、adopt；adopt 改指歌词偏移并删远程曲目行）；host 侧 `segment` 选项在 `music_library_host_module_test.dart`。
- **备注**：设计与拍板见 `docs/specs/2026-11-23-interconnect-music-library-design.md` §9。
