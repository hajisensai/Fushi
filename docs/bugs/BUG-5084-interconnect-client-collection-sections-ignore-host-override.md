## BUG-5084 · 互联客户端看 host 合集时分栏不认 host 上的手动分栏
- **报告**：2026-11-21（拍板台 iR6ccUys9H 实现时自查发现）
- **真实性**：✅ 真缺口。v167 起合集分栏 = 手动分栏 → 手动季集指定 → 文件名（引擎
  `packages/fushi_engine/lib/media/collections/collection_section_loader.dart`），但这两张覆盖表只在
  本机。互联客户端打开 host 的合集时，纯远端集的分栏只能按 host 下发的文件名派生
  （`fushi/lib/src/pages/implementations/media_collection_detail_page.dart` `_reload` 里远端 slot 不进
  `loadCollectionSections`；`RemoteVideoInfo`（`packages/fushi_engine/lib/sync/fushi_library_host_service.dart`）
  没有分栏字段）。host 上钉到 PV·特典的短篇，在客户端仍显示在正片栏。
- **根因**：client 侧远端槽的分栏键只能由 host 下发的 basename 现场派生
  （`fushi/lib/src/pages/implementations/media_collection_detail_page.dart` `_reload` 的 `groupKeys`
  对远端槽取 `collectionGroupKeyForFilename(slot.filename)`；播放器远端合集
  `video_fushi_page.dart` `_PlaylistEpisodeRef` 不带 `sectionKey`，剧集面板按标题派生），而
  host 的分栏真相（手动分栏、手动季集指定、只写在父目录上的季号）都不在 wire 上
  （`RemoteVideoInfo` 无分栏字段，`LocalLibraryHostService.listVideos` 不算分栏）。
- **[x] ① 已修复** — host 在 `listVideos`（`packages/fushi_engine/lib/sync/local_library_host_service/videos.part.dart`）
  对整份清单走同一入口 `loadCollectionSections`（派生键用 host 完整路径，两次批量查询），
  经新 wire 字段 `RemoteVideoInfo.sectionKey`（`sectionKey`，只在非空时写；解析只认
  `isValidCollectionSectionKey` 形状，否则按缺省）下发；client 用
  `RemoteVideoInfo.collectionGroupKey`（有就用 host 的，没有按 `parseName` 派生）：
  合集详情页（`CollectionEpisodeSlot.baseSectionKey`）、播放器远端合集剧集面板
  （`_PlaylistEpisodeRef.sectionKey`）。旧 host 不发 = client 照旧派生；旧 client 忽略未知键。
  `getVideoEpisodeBindingOverrides` 顺带按 500 分块（host 按整库查）。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_client_video_parity_test.dart`
  「BUG-5084 分栏」组（真 host + 真 HTTP：手动分栏 / 第 0 季指定 / 父目录季号 → client 远端槽
  同一分栏，且与 host 本机 `loadCollectionGroupKeysForVideos` 逐条一致；旧 host / 非法键回落
  派生；往返与副本保留）；`fushi/test/pages/collection_detail_remote_members_test.dart`
  「远端集按 host 下发的生效分栏出季 tab」（详情页 widget：PV·特典 tab 与各栏成员）。
- **备注**：字幕分季（「为合集获取字幕」）与 tracking 多季判定只处理本机文件，不涉及远端集。
  host 改了分栏后 client 要在下次拉清单时才看到（与其它清单字段同一时机）。没做真机验证。
