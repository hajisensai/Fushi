## BUG-5539 · v182-collection-side-orphans-not-purged
- **报告**：2026-11-27（合并 PR #4516 时审查发现）
- **真实性**：✅ 真问题（范围缺口，未修）。v182 的 `purgeDanglingVideoBookRefs`（`packages/fushi_core/lib/src/database/database_video_domain.part.dart`）只清父表是 `video_books` 的孤儿行。`video_metadata_works` / `media_images` / `collection_relations` 里 `collection_id` 指向已删合集的孤儿（同一类页级撕裂留下的）没有清；`video_collection_relation_sync.dart` 的 `_kLiveOwner` 专门防着它，说明这种行确实可能存在。
- **[ ] ① 未修复** — 建议：下一次 schema 迁移补一组 `collection_id NOT IN (SELECT id FROM media_collections)` 的清理（CASCADE 的删、SET NULL 的置空，跟 v182 视频那一侧同一种写法），迁移测试照 `fushi/test/database/video_book_dangling_refs_test.dart` 从上一版真实升级。
- **[ ] ② 未加自动化测试** —
- **备注**：
