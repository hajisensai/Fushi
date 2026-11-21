## BUG-5140 · 收藏句改色：已收藏的书摘不能改颜色（同步缺颜色更新时间）
- **报告**：2026-11-21（用户：应用内反馈 fMicnouU6V ④「书摘颜色可自定义」，拍板台「做」）
- **真实性**：✅ 功能缺口。正文一直按 `FavoriteSentence.color` 画五色（`fushi/lib/src/media/audiobook/highlight_bridge.dart` `BASE_COLORS`），但此前没有任何入口写非默认色。分支 `claude/dec-fmicnouu6v` 已补「新收藏的颜色」偏好（`ReaderSettings.favoriteHighlightColor`，高亮样式页 → 收藏的色点），收藏时写入颜色；**已收藏的句子仍不能改色**。
- **[ ] ① 未修复** — 改色不能只改本机行：聚合同步 `AggregateMergeService.mergeFavoriteSentences`（`packages/fushi_engine/lib/sync/aggregate_merge_service.dart:202`）按内容键去重、同键保留 createdAt 更早的一条，两端同一条收藏 createdAt 相同 → 各自保留本机行，改色永远传不到别的设备；删了重收藏（新 createdAt）则旧行更早、旧色赢。根本做法：`favorite_sentences` 表加 `color_updated_at_us` 列（schema 迁移 + 备份合并 `backup_merge_engine.dart` 同步），合并时同键按它取较新的颜色；然后在收藏夹行（`reader_quick_settings_sheet.dart` `_buildFavoriteRow`）与正文收藏菜单加「改颜色」。
- **[ ] ② 未加自动化测试** — 修时补：合并两端改色取较新者、备份合并保留颜色、改色后正文重新上色。
- **备注**：一并考虑五色本身可自定义 RGB（现为固定五色，`kFavoriteHighlightColors` / `BASE_COLORS` / `reader_content_styles.dart` 兜底色三处）。
