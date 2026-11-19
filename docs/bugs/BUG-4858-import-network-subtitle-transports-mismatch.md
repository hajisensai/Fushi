## BUG-4858 · 「添加来源 › 网络」副标题与本域真实可选传输不符（视频写只有 WebDAV，书/漫画/音乐漏 AList、音乐还写了 FTP，IM10）
- **报告**：2026-11-16（用户：导入界面设计稿 v2 IM10，所有者确认按稿实现）
- **真实性**：✅ 真 bug（代码验真）。网络表单可选传输来自 `_networkTransports`（`fushi/lib/src/pages/implementations/media_sources_view.dart:241`，视频 / 音乐 SFTP · WebDAV · AList，书 / 漫画 SFTP · FTP · WebDAV · AList），但「添加来源」对话框的网络副标题是写死的两条 key（改前 `media_sources_view.dart:1170-1173`，注释「视频域只开 WebDAV」已过时）：视频 `media_source_network_subtitle_video`「WebDAV 远程库」，其余共用 `media_source_network_subtitle`「SFTP / FTP / WebDAV」——漏 AList，音乐还承诺了不支持的 FTP。同样的写死副标题还在导入页网络卡（`media_sources_page.dart:208-211`、`media/manga/manga_sources_page.dart:118`）。
- **[x] ① 已修复** — 「添加来源」/「导入文件夹」换成 `showImportChoiceDialog`，网络选项说明为 `importNetworkTransportsSummary(widget.mediaKind)`（与表单协议分段同一真相源 `importNetworkTransports`），删过时注释；视频导入页「网络共享」块说明同样派生（`video_import_page.dart`）。书 / 漫画导入页的写死副标题随各自导入页换新组件一起消失。
- **[x] ② 已加自动化测试** — `fushi/test/pages/import_network_transports_summary_test.dart`（各域摘要 + 源码守卫）、`fushi/test/pages/video_import_page_test.dart`。
- **备注**：`media_source_network_subtitle` / `_video` 两个 key 已随旧导入页（`media_sources_page.dart`）删除后 `i18n_sync --remove`。
