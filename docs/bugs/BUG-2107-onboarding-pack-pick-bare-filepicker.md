## BUG-2107 · 引导选本地包走裸 pickFiles：安卓整份复制进 cache，失败静默无提示
- **报告**：2026-09-04（用户：「再次导入的时候点击导入文件没有任何提醒」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/onboarding_wizard_page.dart:341`（`_pickPackFileAndImport` 裸调 `FilePicker.platform.pickFiles`，`path == null` 与「用户取消」同形静默 return，函数无 try/catch 而调用点是 `unawaited(...)`）
- **[x] ① 已修复** — 本分支 `worktree-worktree-user-batch-0904`（提交见 git log）
- **[x] ② 已加自动化测试** — `fushi/test/tools/file_picker_discipline_guard_test.dart`：按「豁免清单只减不增」删掉本文件的豁免条目，该守卫的两条断言从此把回退钉死——① 未登记文件裸调 `pickFiles` 即红；② 清单条目虚挂（文件已不再裸调）也红。i18n 完整性由 `test/i18n/` 覆盖（新增 2 个 key × 17 语言）
- **备注**：与 BUG-2106（同一次报告的第一个根因：validating 遮罩换根摧毁引导路由）配套。BUG-1667 已把本仓其余大文件入口统一到 `pickRealFilePathDetailed`，引导这条是最后的漏网。

### 根因

`_pickPackFileAndImport` 是全 app 仅剩的几处裸 `FilePicker.platform.pickFiles()` 之一，偏偏承载**体积最大**的文件：推荐包 `kRecommendedPackFileName = fushi-recommended.fushi.zip`，`kRecommendedPackSizeLabel = 9.5 GB`（`fushi/lib/src/onboarding/recommended_pack.dart:43,70`）。

三条失败面：

1. **安卓整份复制**：file_picker 在安卓会先把选中文件同步复制进 app cache 再返回缓存路径（BUG-1667 已取证）。9.5 GB 的包需要约 2 倍内部存储、几分钟全程无进度无取消；多数手机直接失败或看起来永久卡死。
2. **失败与取消同形**：`final String? path = result?.files.single.path; if (path == null || !mounted) return;` —— 平台只回 bytes 不回 path（BUG-446 已立过「必须可见失败」的规矩）与用户主动取消压成同一条静默 return。
3. **异常被吞**：函数无 try/catch，调用点是 `onPressed: () => unawaited(_pickPackFileAndImport())`，`PlatformException`（`already_active`、cache 复制失败/空间不足）直接漂到 zone handler，UI 上毫无反应 = 用户报的「点击导入文件没有任何提醒」。

另外这条路径**没有**设置页那条导入的重入守卫（`_BackupImportWidget._isImporting`），连点两次会撞 `already_active`。

### 修复

改走仓内既有的 `pickRealFilePathDetailed`（`fushi/lib/src/media/import/real_path_directory_picker.dart`：安卓先要 `MANAGE_EXTERNAL_STORAGE` 再解析真实路径、零复制；桌面/iOS 本就直接给真实路径），并把三种结果分开：

- 返回 `null` = 用户取消 → 静默（取消不是失败）；
- `PickedFileWithoutPathException` = 平台交回条目却没给路径 → **可见失败**（新 i18n `onboarding_pack_pick_no_path`，告诉用户把包放进设备存储或授予全文件访问）+ `ErrorLogService` 诊断；
- 其它异常 → 可见失败（新 i18n `onboarding_pack_pick_failed`）+ 诊断。

同时补 `_packPicking` 重入守卫（与 `_packDownloading` 互斥），并把 `_packError` 的语义从「裸异常串」改成「已组好的用户可见文案」——原先渲染处无条件套「下载失败：{}」，选文件失败也会显示成「下载失败」。

### 验证

- `flutter analyze`（lib + test）clean
- `flutter test test/sync/backup_import_overlay_test.dart test/sync/backup_validating_overlay_route_test.dart test/tools/file_picker_discipline_guard_test.dart test/i18n/ --no-pub`：`PASSED - 51 tests ran`
- ⚠ **真机复测缺口**：安卓真机上「选本地包 → 授权 → 零复制拿到路径 → 导入」尚未实测；新增两条失败文案也未在真机触发过。
