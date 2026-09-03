## BUG-1979 · 存储页备份被隐藏且无法清理
- **报告**：2026-08-31（用户：）
- **真实性**：✅ 真 bug。移动端备份导出物落在缓存根；`storage_usage_view.dart:90,480-516` 只给每类前 20 个明细提供操作，第 21 个以后压成无操作的汇总行，因此备份可能计入总量却没有清理入口。
- **[x] ① 已修复** — `storage_usage_service.dart:772` 将备份归档从缓存中剥离、独立聚合为“本地备份”，避免重复计数并稳定提供删除入口（`116dc112f2`）。
- **[x] ② 已加自动化测试** — `test/storage/storage_usage_service_test.dart` 断言两份备份聚合、缓存排除备份且总字节不重复；与存储页既有 `deleteFiles` widget 测试共同覆盖清理原语。
- **备注**：只识别 `fushi-backup-*.fushi.zip` 与兼容旧名 `hibiki-backup-*.hibiki.zip`，不会误删推荐包等其他 zip。
- **审查补修**（在 ① 的基础上，同一 PR 内）：
  - **缓存根被完整扫两遍**。`storage_usage_service.dart` 的 `_scanCache` 与 `_scanBackups`
    各起一个 isolate、各把整棵树递归 stat 一遍。iOS 上 `Library/Caches` + 沙盒 `tmp` 是
    GB 级大头，那是实打实的双倍耗时。改成 `_cacheRootEntries()` 只列举一次、两个类目按
    谓词分流；守卫用注入的根解析器调用次数（== 扫描遍数的忠实代理）钉住只问一次。
  - **`kDeletableEntryCategories` 契约漂移**。集合文档说「只有该集合里的类目会产出可直接
    删的明细」，而 `backups` 明明也接通用文件删除原语却不在集合里。把 `backups` 补进集合
    并新增 `kDirectlyDeletableEntryKinds`，用一条「产出可删明细的类目必须登记在案」的行为
    守卫钉住两者一致。
  - **备份包的生命周期与展示口径对不上**。`runBackupExportFlow` 开头无条件清扫临时目录里
    的旧备份包，这一步**是必要的**（移动端分享面板拿走文件后当场删会把文件从接收方手里
    抽走，桌面分支的 `finally` 删除移动端一次都没执行过，包会一份份堆），但存储页把它
    展示成「本地备份」，用户会以为那是自己的存档、点一次导出却发现没了。改的是展示口径：
    类目名与明细名都改成「上次导出遗留的备份包」，清扫函数与正则真相源都补上「为什么这
    是中间物、为什么必须在下一次导出前清」的理由。
  - **`label: 'backup archives'` 硬编码英文**。与快照聚合项统一口径：`label` 是**路径形状
    的身份串**，用户可见名一律由 UI 按 `paths.length` 翻译，服务层不再产出未翻译英文。
