## BUG-878 · 游戏分支无法打开 schema v48 用户数据库
- **报告**：2026-07-19（用户：）
- **真实性**：✅ 真 bug。`packages/hibiki_core/lib/src/database/database.dart:400` 的游戏分支仍声明 schema v45；用户现有数据库已由新版 Hibiki 创建为 v48，降级保护因此按设计在任何查询前抛出 `HibikiDatabaseDowngradeException`。根因不是数据库损坏，而是该长期功能分支遗漏了上游 v46–v48 的正式表结构演进。
- **[x] ① 已修复** — 将 schema 提升到 v48，并原样补齐 v46 `epub_books.completed_at`、v47 `revealed_images` 与 v48 查询索引迁移；保留 `from > to` 的无损拒绝逻辑，未覆盖、降级或重建用户数据库。
- **[x] ② 已加自动化测试** — `packages/hibiki_core/test/migration_schema_v48_compat_test.dart` 覆盖现有 v48 数据库直接打开并保留哨兵数据、v45→v48 连续迁移、fresh v48 表结构与五个索引；同时复跑 `migration_downgrade_test.dart` 确认未来版本仍被拒绝。
- **备注**：`hibiki_core` 全量 29 项测试及 `flutter analyze` 通过，主应用 `flutter analyze lib` 通过；设备复测在合并并重新构建 Windows 应用后完成。
