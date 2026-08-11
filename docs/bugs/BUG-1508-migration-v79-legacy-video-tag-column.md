## BUG-1508 · v79 标签迁移不兼容旧 video_book_uid 列导致启动失败
- **报告**：2026-08-11（用户：Wight）
- **真实性**：✅ 真 bug。用户真实库的 `video_book_tag_mappings` 仍为旧列 `video_book_uid`，但 `packages/fushi_core/lib/src/database/database.dart` 的 v79 迁移硬编码读取 `book_uid`，启动时报 `SqliteException: no such column: book_uid` 并中断初始化。
- **[x] ① 已修复** — `77a0d11f6d`：迁移改为探测物理表，兼容 `book_uid` / `video_book_uid` 两代键列，并为缺失 `added_at` 的更老形态使用可解释的 0 时钟。
- **[x] ② 已加自动化测试** — `fushi/test/database/migration_v79_tag_assignments_test.dart` 新增 v78 版本号但遗留 `video_book_uid` 列的真实分支血统夹具，守卫视频标签值与时间戳保留且旧表最终删除。按用户先前要求未运行自动化测试。
- **备注**：修复后使用用户同一份 Fushi 数据库重新构建并启动实测，已越过初始化错误并进入视频设置页面；未运行自动化测试。
