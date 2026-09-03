## BUG-1930 · 折叠「本地备份」分区会取消进行中的备份

- **报告**：2026-08-29（用户截图圈出「本地备份」标题行右侧的折叠箭头：「甚至点击这里会直接取消备份」）
- **真实性**：✅ 真 bug。因果链完整，且比「取消」更糟 —— 备份其实**没有**被取消。
- **根因**：备份任务的所有权错放在会被折叠销毁的 State 上。
  1. `fushi/lib/src/utils/components/settings_shared.dart:350` —— 收起时
     `child: _expanded ? rowsColumn : const SizedBox(...)`，整棵 rows 子树**直接从 widget tree
     移除**（不是 Offstage、不是 maintainState；`:341` 的注释说明这是有意设计：收起时行不入树、
     不参与焦点驱动）。折叠开关就是标题行那个箭头（`:327`）。
  2. 「本地备份」正是可折叠且默认收起的 section（`sync_settings_schema.dart:360`，
     `collapsedByDefault: true`）。
  3. 备份任务的所有者就是被销毁的那个 State：`backup.part.dart:129` `_BackupExportWidgetState`
     的 `_export()` 里直接 `await service.createBackup(...)`。
  4. **致命行**：`backup.part.dart:192`（修前）`if (!mounted) return;` —— 折叠 → State dispose →
     `mounted == false` → `createBackup` 返回后直接 return，后面的 `FushiShare.shareFiles`（移动端）
     / `FilePicker.saveFile`（桌面）**永远不执行**。
  5. 放大症状：成功/失败 snackbar 同样被 mounted 门挡掉（既没拿到文件也没看到任何错误）；
     `_isExporting = false` 不执行，再展开时是全新 State（标志位归零）→ 转圈消失、按钮回来，
     进一步坐实「被取消了」；重入守卫随旧 State 一起没了，可以立刻再点一次，两个 `createBackup`
     并发写同一个 tmpPath（文件名只带日期，同一天必撞）。

  **精确事实**：`Isolate.run` 里的 zip 还在继续写，写完后静静躺在缓存目录里没人管（见 BUG-1931）。
  所以这是「结果被丢弃 + 临时文件泄漏」，不是资源被释放 —— 全文没有任何 `CancelableOperation`，
  `backup.part.dart` 里也没有 `dispose()` 覆写。

- **[x] ① 已修复** — 1d2053fdf4。照**导入侧已经踩过同一个坑并修好**的做法（`runBackupImportFlowForFile`
  的头部注释：「appModel 驱动全程遮罩……此后不依赖任何页面 mounted/context」）对称重做：
  - 流程提成**库级函数** `runBackupExportFlow({required AppModel appModel, ...})`；顶层函数根本
    看不到 State 的 `mounted`，这类丢结果的写法结构上无从产生；
  - 导出态与进度搬到 `AppModel`（`backupExportActive` / `beginBackupExport` / `endBackupExport`），
    重入守卫也随之搬家（旧的 State 字段守不住 —— 折叠再展开就是新 State）；
  - 结果提示走 `AppModel.navigatorKey` 的全局 context（`_rootContextAfterOverlay`），不再用调用方
    的 context；
  - 设置行只订阅、不持有。**导出不 `closeDatabase`，app 全程可用，所以刻意不走导入那样的全屏遮罩。**
- **[x] ② 已加自动化测试** — `fushi/test/sync/backup_export_file_picker_guard_test.dart` 新增
  「备份打包的所有权不在设置行的 State 上」：`runBackupExportFlow` 必须是**顶层**函数（行首无缩进）、
  `service.createBackup(` 全文只此一处且在它的函数体里、`_BackupExportWidgetState` 的类体里
  **不得**再出现 `createBackup(`。同文件既有的「取消另存不得报成功」一条按新形状改写
  （`cancelled = true` + `if (cancelled) return;`），意图不变。
- **备注**：判据前先剥整行注释 —— 本次修复的注释大段引用了「旧实现在 createBackup 之后的
  `if (!mounted) return`」，不剥的话 `indexOf` 会先命中注释里那份，守卫恒绿。
