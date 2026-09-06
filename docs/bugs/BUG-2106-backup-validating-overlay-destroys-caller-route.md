## BUG-2106 · 备份 validating 遮罩换根摧毁调用方路由：引导选包后引导蒸发且无提示
- **报告**：2026-09-04（用户：「选择本地包文件以后，会强制退出引导，并且没有提醒」）
- **真实性**：✅ 真 bug（静态可证的整树 unmount）。根因 `fushi/lib/main.dart:1713`（原 `if (appModel.backupImportActive)` 分支返回 `TranslationProvider(MaterialApp(...))`，与正常分支 `fushi/lib/main.dart:1802` 的 `KeyedSubtree(TranslationProvider(MaterialApp(navigatorKey: ...)))` **根 widget 类型不同**）+ `fushi/lib/src/models/app_model.dart:1271` `beginBackupValidating()`
- **[x] ① 已修复** — 本分支 `worktree-worktree-user-batch-0904`（提交见 git log）
- **[x] ② 已加自动化测试** — 行为测试 `fushi/test/sync/backup_validating_overlay_route_test.dart`（真 Navigator：遮罩在栈上时调用方页面 State **未被 dispose**、其字段原样保留；系统返回被遮罩吃掉、绝不 pop 底下的向导页；取消接线）+ 源码守卫 `fushi/test/sync/backup_import_overlay_test.dart` 五条（根分支必须用 `backupImportOwnsAppRoot` 且不得回退 `backupImportActive`；`backupImportOwnsAppRoot` 必须排除 validating；遮罩必须 push 路由并在 `finally` 摘除；摘除必须 `removeRoute` 不得 `pop`；取消接线搬到路由调用方）。变异实测：根分支判据换回 `backupImportActive` → 判红
- **备注**：与 BUG-2107（同一次报告的第二个根因：引导那条选文件是裸 `pickFiles`）配套。设置页那条导入路径不受影响（它本来就丢得起一条路由）。

### 根因

`main.dart` 的根 `build` 里，备份导入遮罩分支返回的根 widget 是 `TranslationProvider(MaterialApp(home: BackupImportOverlayView))`，而正常分支返回 `KeyedSubtree(TranslationProvider(MaterialApp(navigatorKey: appModel.navigatorKey, ...)))`。**根 runtimeType 不同 ⇒ Flutter 不复用 element ⇒ 整棵子树连 `MaterialApp` / `Navigator` 一起 unmount。**

而 `runBackupImportFlowForFile`（`backup.part.dart`）选完文件后**第一句**就是 `appModel.beginBackupValidating()` → 相位置 `validating` → `notifyListeners()` → 根重建 → 换根。于是：

1. 引导向导（`OnboardingWizardPage`，由 `home_page.dart:449` 以 `fullscreenDialog` push）连同它的 `_stepIndex` / `_selected` 当场销毁 —— 用户观感就是「选完本地包，引导被强制退出」；
2. `home_page.dart:450` 那句 `await Navigator.push(...OnboardingWizardPage...)` 的 future 在 Navigator 被 dispose 后**永不完成**，其后的 `setOnboardingCompleted(true)` 永不执行，「引导未完成」标记一直留着；
3. 校验阶段的提示（`backup_import_invalid` / `backup_schema_newer` / `backup_import_failed`）必须等「切回正常树 + navigator 重新挂载」才能弹，`_rootContextAfterOverlay` 只等 2 帧，拿不到就**静默 return** —— 这就是「并且没有提醒」。

关键在于**相位边界被一刀切了**：`validating` 只是读 zip + 生成合并预览，**DB 仍打开、可取消**，没有任何理由卸载整棵树；只有 `running` / `done` / `failed` 之前调了 `closeDatabase()`，页面再挂着就会查已关闭的库，那才**必须**换根独占并随后重启进程。

### 修复

- `AppModel` 新增派生判据 `backupImportOwnsAppRoot`（相位非空 **且** 不是 `validating`），`main.dart` 的根分支改判它 —— 换根只留给关库后的三个相位。
- `validating` 相位的遮罩改由**压在调用方页面之上的模态路由**承载：新增 `fushi/lib/src/sync/backup_validating_overlay_route.dart`（`opaque: true` 挡住底下的绘制与命中测试，`PopScope(canPop: false)` 让系统返回不再穿透到底下的向导页）。调用方页面全程留在栈里。
- 摘除**必须** `Navigator.removeRoute`：路由带 `PopScope(canPop: false)`，`pop` 会被它拦下（与 BUG-2043 的接管同一手法）。句柄 `_BackupValidatingOverlay` 幂等，且每条退出路径 + `finally` 兜底都摘一次（漏一次 app 就被永久挡在遮罩后面）。
- 失败提示改为**先摘遮罩再弹**（原先遮罩还在栈顶时 snackbar 会被压在底下），且两处「拿不到 root context 就 return」补上 `ErrorLogService` 诊断 —— 提示是这条路径唯一的用户可见产物，丢了就等于「点了没反应」。

### 验证

- `flutter analyze`（lib + test）clean
- `flutter test test/sync/backup_import_overlay_test.dart test/sync/backup_validating_overlay_route_test.dart test/tools/file_picker_discipline_guard_test.dart test/i18n/ --no-pub`：`PASSED - 51 tests ran`
- 变异实测：根分支判据换回 `backupImportActive` → `FAILED`；还原后复绿
- ⚠ **真机复测缺口**：真机上「首次启动引导 → 选本地包 → 校验遮罩 → 确认对话框」整条路径尚未实测（本轮为静态 + widget 层）。
