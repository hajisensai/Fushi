## BUG-1979 · 存储页备份被隐藏且无法清理
- **报告**：2026-08-31（用户：）
- **真实性**：✅ 真 bug。移动端备份导出物落在缓存根；`storage_usage_view.dart:90,480-516` 只给每类前 20 个明细提供操作，第 21 个以后压成无操作的汇总行，因此备份可能计入总量却没有清理入口。
- **[x] ① 已修复** — `storage_usage_service.dart:772` 将备份归档从缓存中剥离、独立聚合为“本地备份”，避免重复计数并稳定提供删除入口（提交哈希在本 PR 首个提交）。
- **[x] ② 已加自动化测试** — `test/storage/storage_usage_service_test.dart` 断言两份备份聚合、缓存排除备份且总字节不重复；与存储页既有 `deleteFiles` widget 测试共同覆盖清理原语。
- **备注**：只识别 `fushi-backup-*.fushi.zip` 与兼容旧名 `hibiki-backup-*.hibiki.zip`，不会误删推荐包等其他 zip。
