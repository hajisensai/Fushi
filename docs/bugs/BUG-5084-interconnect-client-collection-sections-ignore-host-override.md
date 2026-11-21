## BUG-5084 · 互联客户端看 host 合集时分栏不认 host 上的手动分栏
- **报告**：2026-11-21（拍板台 iR6ccUys9H 实现时自查发现）
- **真实性**：✅ 真缺口。v167 起合集分栏 = 手动分栏 → 手动季集指定 → 文件名（引擎
  `packages/fushi_engine/lib/media/collections/collection_section_loader.dart`），但这两张覆盖表只在
  本机。互联客户端打开 host 的合集时，纯远端集的分栏只能按 host 下发的文件名派生
  （`fushi/lib/src/pages/implementations/media_collection_detail_page.dart` `_reload` 里远端 slot 不进
  `loadCollectionSections`；`RemoteVideoInfo`（`packages/fushi_engine/lib/sync/fushi_library_host_service.dart`）
  没有分栏字段）。host 上钉到 PV·特典的短篇，在客户端仍显示在正片栏。
- **[ ] ① 未修复** — 方向：`RemoteVideoInfo` 加可选 wire 字段（如 `sectionKey`，host 侧按
  `loadCollectionSections` 填，旧 host 不发 = 客户端照旧派生，旧客户端忽略未知字段），客户端详情页 /
  剧集面板 / 字幕分季优先用它。
- **[ ] ② 未加自动化测试** — 修时在 `fushi/test/sync/interconnect_client_video_parity_test.dart` 加
  「host 手动分栏 → 客户端同一分栏」用例。
- **备注**：本机合集、播放器剧集面板、字幕分季、tracking、控制通道都已走同一入口，只差互联这一段。
