## BUG-4776 · 覆盖前快照预览在 UI isolate 上同步检查书和视频文件
- **报告**：2026-11-17（用户：维护者，PR #3518 合入后只读核实的遗留缺陷）
- **真实性**：✅ 真 bug（卡顿幅度未实测）。origin/develop `fushi/lib/src/sync/backup_service/restore.part.dart:1667-1715` 的 `previewOverwriteSnapshot` 对每本缺失书做 `Directory(extractDir).existsSync()`（`_overwriteSnapshotBookFilesPresent`，1729-1730）、对每个缺失视频做 `videoMemberExistsSync`（`File.existsSync`，`packages/fushi_engine/lib/media/video/video_member_file.dart:54-56`），全在调用方 isolate 上同步执行；调用方 `takeOverwriteSnapshotNotice` 在首页首帧、恢复书库页也走它，视频在 SMB / UNC 共享上时单次就可能阻塞数秒。`mergeFromOverwriteSnapshot`（1744 起）同样逐条同步检查。
- **[x] ① 已修复** — 新增 `_overwriteSnapshotReachability`（`restore.part.dart:1836`），只传书目录 / 视频路径列表，用 `Isolate.run` 在后台 isolate 整批判定、回传按下标对齐的布尔数组；预览（`restore.part.dart:1753`）与快照合并（`restore.part.dart:1865`）都改走它，判据本身不变。提交 `9b2fdf543a`。
- **[x] ② 已加自动化测试** — `fushi/test/sync/overwrite_snapshot_recovery_test.dart`「snapshot preview and restore never probe book / video files on the calling (UI) isolate」：用 `IOOverrides`（不跨 isolate）在调用 isolate 上为书目录 / 视频路径构造 `File` / `Directory` 即抛错，预览与合并仍须给出正确结果；把 `Isolate.run` 换回同步执行时变红，已实测。
- **备注**：大书库 / 网络共享上的实际卡顿改善未做真机测量。
