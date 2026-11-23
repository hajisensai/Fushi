## BUG-5111 · 书的简介没有手填入口（BUG-5082 书侧剩余项）
- **报告**：2026-11-22（拆自 BUG-5082：应用内反馈 fMicnouU6V ②「其它方式都失败时可以手动填元数据」，拍板台「做」）
- **真实性**：✅ 缺口。书 / 漫画 / PDF「编辑信息」（`media_item_edit_dialog_page.dart`）只有标题、作者、封面；简介 / 日期 / 标签存在 `item_scrape_meta`（`BookMetadataField.details`，`book_metadata_scrape_facade.dart`），只能由条目刮削写入，刮不到的书没有任何办法补简介。
- **[x] ① 已修复**（分支 `claude/dec-fmicnouu6v-manual-meta`）— schema v172 给 `item_scrape_meta` 加 `locked_fields`（与视频 v99 字段锁同形，值域 `ItemScrapeLockableField`，现有 `summary`）。`ItemScrapeStore` 是唯一写入口：`writeMeta`（条目刮削 / 游戏刮削口径）对锁住的字段保留旧值、锁随行保留；新增 `setManualFields`（非空 = 写值上锁，清空 = 清值解锁交还下一次刮削；只剩手动空壳时删行）；脚本 `mergeMeta` / `replace` 照写值但不清锁；撤销走 `restoreMeta` 原样写回（快照 JSON 带 `lockedFields`）。「编辑信息」弹窗（`media_item_edit_dialog_page.dart`）对书族条目加简介框，改过才写。清空后不会立刻回到旧刮削值（锁住期间不保存刮削值的影子），要等下一次条目刮削回填。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/media/item_scrape/item_scrape_store_test.dart`（手填落库 / 重刮不覆盖 / 清空后重刮回填 / 空壳删行 / 脚本替换与撤销）、`fushi/test/database/migration_v172_item_scrape_locked_fields_test.dart`、`fushi/test/ops/ctl_library_scrape_routes_test.dart`（锁经 replace 与 undo 往返）。
- **备注**：
