# CLI 补齐第三批：剩余界面流程（BUG-5123 / 拍板台 PGpPujl99g）

维护者拍板：「全部都补齐 cli，cli 不是要支持所有功能吗，应该支持就得支持」。第一、二批已接漫画有声导入、音乐导入 / 碟片 / 插件 / 歌词导出 / 音频 CD、Hook Code、制卡历史导入 SRS、排行榜恢复码、动画立即导入、页面背景图。本文件是剩下几项的落地方案，每项都按惯例做「ctl 路由 + `op_descriptions_<域>.dart` + `fushi_cli` 命令 + 删守卫登记」，调用界面按钮背后的同一个方法，不另写业务逻辑。

## 待接项

| 流程 | 现入口 | 路由草案 | CLI 草案 | 风险 / 撤销 |
|---|---|---|---|---|
| `importIptvChannels` | 视频 · IPTV 播放列表导入 | `POST /api/admin/video/iptv/import`（`path` 或 `url`） | `video iptv-import <路径\|URL>` | write；撤销 = 删本次新增频道 |
| `pickAndApplyVideoFrameCover` | 视频详情 · 取当前帧当封面 | `POST /api/admin/video/:uid/cover/frame`（`atMs`） | `video cover-frame <uid> --at <时间>` | write；撤销 = 恢复原封面引用。取帧逻辑从 pick 流程里抽成无 UI 函数共用 |
| `exportTranscribedSrt` | 有声书 · 转录结果导出 SRT | `POST /api/admin/audiobook/:key/export-srt`（`path`、`overwrite`） | `audiobook export-srt <key> <路径> [--overwrite]` | irreversible（写盘），已存在要 overwrite |
| `exportTtsAudiobookM4b` | TTS 有声书 · 导出 M4B | `POST /api/admin/tts/audiobook/:key/export-m4b`，长任务 | `tts export-m4b <key> <路径> [--overwrite]` + `task get --wait` | irreversible + longRunning |
| `importSyncedBookFile`（互联远端） | 阅读历史 · 互联远端书库下载单本 | `POST /api/admin/peer/:peer/books/:id/download`，走 `InterconnectDownloadManager` | `peer book-download <peer> <id>` | write；撤销 = 删下载得到的本地书 |
| 音乐歌单增删改 / 加歌 | 音乐 · 歌单页 | `GET/POST/PATCH/DELETE /api/admin/music/playlists[/:id[/tracks]]` | `music playlist …` | write，全部可撤销 |
| 音乐歌词搜索 | 音乐 · 正在播放 · 搜歌词 | `GET /api/admin/music/tracks/:uid/lyrics/search` + 选用 `POST …/lyrics/apply` | `music lyrics-search` / `lyrics-apply` | apply 为 write，可撤销 |

## 不做

- 歌词单独编辑界面：在功能黑名单（`docs/agent/feature-blacklist.md`），不加路由。

## 完成判据

- `fushi/test/ops/ctl_ui_flow_cli_coverage_guard_test.dart` 里不再有 `pending cli-ui-only-ops-gaps:` 条目；歌单 / 歌词搜索两项（守卫扫不到）以路由测试为证。
- 每项有路由测试（失败码 + 撤销）与 CLI 解析测试；BUG-5123 状态改 ✅。
