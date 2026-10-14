## BUG-3332 · 在线视频制卡标签只有「Episode 2」，缺作品名
- **报告**：2026-10-14（反馈 #Q0gvMa_jyr，Android 扩展在线播放；卡片 Details 只有「Episode 2」，标签 `Episode_2`）
- **真实性**：✅ 真缺陷。作品名标签 `collectionTag` 与「系列名 - 剧集名」documentTitle 都读 `_playlistTitle`，但它只在本地播放列表路径赋值（`fushi/lib/src/pages/implementations/video_fushi_page.dart:3659`，修复前）；远端路径 `_initRemote`（:3685）从不赋值，于是扩展在线 / 互联 / 媒体服务器的卡只剩集名。作品名其实就在 `RemoteVideoInfo.collection.collectionName`（在线视频源每集都带作品名作合集归属，`fushi/lib/src/media/video/online/anime_source_video_client.dart:221`）。
- **[x] ① 已修复** — `_initRemote` 用纯函数 `remoteVideoWorkTitle(info)` 填 `_playlistTitle`（合集名去空白、空则 null）。设置项文案「自动添加书名到标签」顺手泛化为「自动添加作品名到标签」（en / zh-CN / zh-HK / ja 四个语言值；key 不变，其余语言保留原译）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_playlist_mining_title_test.dart`（group `remoteVideoWorkTitle`：纯函数 + `_initRemote` 接线守卫）。
- **备注**：未做「自动判断现有标签是否已含作品名」——作品名与集名是两个独立标签，重复无害（用户也表示可接受）。附带效果：远端 Jimaku 字幕检索种子的 `collectionTitle` 也拿到作品名。
