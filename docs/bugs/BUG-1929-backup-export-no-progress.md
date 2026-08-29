## BUG-1929 · 导出备份没有进度，只有一个转圈

- **报告**：2026-08-29（用户：「导出备份的过程中没有显示备份进度，只显示"正在创建备份"」，Android 调试版）
- **真实性**：✅ 真 bug。不是「有回调但 UI 没订阅」，而是**从服务层到 UI 层根本不存在导出进度这条通路**。
- **根因**：
  - `fushi/lib/src/sync/backup_service.dart:1040`（修前）`createBackup` 签名里没有任何 `onProgress`，
    方法体从头到尾没有一次回调；
  - 打包 `_writeBackupZipInIsolate`（同文件 :3477）用 `Isolate.run` 一次性 fire-and-forget，
    **没有 `ReceivePort` / `SendPort`**，逐文件进度全烧在 isolate 里；
  - UI `sync_settings_schema/backup.part.dart:656`（修前）只有 `Row(转圈 + Text(t.backup_exporting))`，
    背后是一个 `bool`，没有可订阅的东西。

  对照：**导入侧早在 TODO-1183 就把这条通路做完了** —— `_archiveByteProgress`（已处理字节/总字节）
  + `_extractEntriesStreaming` 经 `SendPort` 回传每个 chunk，`AppModel.backupImportProgress`
  （`ValueNotifier<double>`）持状态，根层 `BackupImportOverlayView` 渲染。导出侧一处都没有
  （`grep backupExport app_model.dart` 零命中）。

- **[x] ① 已修复** — 1d2053fdf4。三层补齐：
  1. `createBackup` 收 `void Function(double)? onProgress`；打包前用 `_totalSourceBytes(files)`
     求分母（`files` 本就是一张平铺的 archivePath→磁盘路径表），worker 每写完一个文件经 SendPort
     回传该文件大小。保留 `Isolate.run`（错误传播与半成品 zip 清理的 crash-safety 一字不改），
     只让闭包捕获一个 `SendPort`。
  2. `AppModel` 加 `backupExportProgress`（`ValueNotifier<double?>`，与导入侧同理只让进度条重建）。
  3. 设置行用 `ValueListenableBuilder` 渲染确定进度圈 + 百分比；`adaptiveIndicator` 加 `value` 参数
     （Cupertino 走 `partiallyRevealed`，避免「Material 显进度、Cupertino 一直转」的静默分歧）。
- **[x] ② 已加自动化测试** — 进度本身未加独立用例；打包链路的既有套件
  （`test/sync/backup_service_test.dart` / `backup_full_export_test.dart`）覆盖改后的
  `_writeBackupZipInIsolate` 仍产出可导入的包。
- **备注**：**粒度只能到「每个文件写完」** —— archive 3.6.1 的 `ZipFileEncoder.addFile` 没有
  chunk 级回调。所以打包单个几 GB 的视频时进度条仍会停一段时间。准备阶段（`VACUUM INTO`、
  按分类裁剪行、枚举待打包文件）没有可分的量，此时 `progress == null`，UI 走不确定动画。
