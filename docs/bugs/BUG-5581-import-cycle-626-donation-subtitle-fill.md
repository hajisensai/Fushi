## BUG-5581 · import-cycle-626-donation-subtitle-fill
- **报告**：2026-11-27（2026-11-27 批量合并时 integration owner 发现：develop 既有红，本批未加剧）
- **真实性**：✅ 真红。`fushi/test/build/import_cycle_guard_test.dart`「最大 import 环不超过 620」在 develop `e9563b679e7` 与本批合并后都实测 626。按守卫同口径（import / export / part，`package:fushi/` 与相对路径）比对 `34778f9c3cc`（降到 620 那次）与 develop：新进环 6 个、出环 0 个，分两簇：
  - 整库补字幕（`1d104d25b29`）：`media/video/subtitle/library_subtitle_fill_{controller,host,sheet}.dart` 都 import `models/app_model.dart`（host 还 import `manga_ocr_wizard_engines` / `manga_reader_stream_ocr`），sheet 又被环内的 `pages/implementations/home_video_page.dart`、`media_collection_detail_page.dart` import。
  - 复习历史捐赠（`e79514cbce9`）：`srs/donation/srs_donation_{banner,page,providers}.dart` import `app_model` / `profile_view_model` / `srs_providers` / `srs_home_stats`，又被环内的 `pages/implementations/srs/srs_deck_list_page.dart` import。
- **[ ] ① 未修复** — 按守卫文档的口径拆边、不调上限：两簇各自改成由调用方页面注入（窄接口 / 回调，AppModel 实现），或把只用到的值类型 / 装配挪到不读 AppModel 的叶子，让 6 个文件出环后上限维持 620。
- **[ ] ② 未加自动化测试** — 守卫本身就是测试；修完把出环的文件补进 `kLeafEntries`。
- **备注**：不是本批 PR 引入：本批 7 条 PR 单独打在 develop 上都是 626（审查实测），合并后仍 626。
