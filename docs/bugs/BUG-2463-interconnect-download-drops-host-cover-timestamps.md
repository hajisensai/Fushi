## BUG-2463 · 互联下载登记丢失 host 封面 / importedAt / completedAt
- **报告**：2026-09-12（用户：host 上刮好的元数据有的没同步到客户端——交接 #7c；本条是其中「wire 已输出但客户端未写」的三个字段，刮削元数据整块通路缺失另立 spec）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/home_video_page.dart` `_registerDownloadedVideo`：① 封面无条件走本机 ffmpeg 抽帧 `extractVideoCover`，注释称「host 无封面文件下载原语」——但 host 早有 `GET /api/library/videos/<id>/cover`（`fushi_sync_server/video.part.dart`）且 client 已实现 `RemoteCoverFetcher.fetchRemoteCover(coverUrl)`（远端占位卡就是靠它画封面），下载后刮削封面被一帧截图顶掉；② `importedAt` 写 `DateTime.now()`，而 `RemoteVideoInfo.importedAt` 是 host 值、远端占位卡按它排序，下载后同一条目在「按导入时间」里跳位；③ `completedAt` 根本不写，远端槽按 `remote.completedAt` 画的已看完角标下载后消失。
- **[x] ① 已修复** — 先 `_fetchHostCoverToDisk`（coverUrl + RemoteCoverFetcher → `remote_videos/<uid>.cover.jpg`），失败/无再退抽帧；`importedAt: video.importedAt ?? now`；`completedAt` 镜像 host 毫秒值。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_video_remote_download_register_test.dart`「下载登记镜像 host 封面（coverUrl）、importedAt 与 completedAt」（变异实测：还原修复红在 importedAt）。
- **备注**：刮削元数据（简介/评分/分集名/external id/海报语言/lockedFields 等）在互联 wire 上整块不存在，见 `docs/specs/2026-09-12-interconnect-scrape-metadata.md`。
