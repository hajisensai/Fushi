## BUG-5576 · flutter_logs 每 3 天冷启动整树删 Android 外部 files 根（外部书库、词典、有声书全没）
- **报告**：2026-11-27（GitHub #4521 / 反馈 1DaVBFXQEI，kanjieater，Samsung S25U，3.4.0 Debug 32769：书库受管目录 `Android/data/app.fushi.reader/files/data` 里 94 个解包书目录丢 82 个、有声书 74 个音频 / 字幕文件丢失，数据库行、进度、对齐记录都在。根因线索由用户转来的外部分析提供，本文已逐行核对源码。）同一根因的既往报告：BUG-5492（MXX0xhQDgt / yjj8-18vKt vivo、MOLf_50680 OnePlus「更新以后书籍、音频文件消失」，48 本词典文件全缺）——BUG-5492 当时判为「不是 Fushi 自己删的」，**判错了**。
- **真实性**：✅ 真 bug，Fushi 自己删的。链路：
  1. `fushi/lib/main.dart`（修前约 :793）启动时调 `FlutterLogs.initLogs(...)`，没传 `logsWriteDirectoryName` / `logsExportDirectoryName`（默认 `""`），`zipsRetentionPeriodInDays` 取 Dart 侧默认 3。
  2. flutter_logs 2.2.8 `android/.../LogsHelper.kt:114`：`exportPath = File(context.getExternalFilesDir(null), savePath + File.separator + exportPath).path` → 两个空串拼出来就是 `getExternalFilesDir(null)` 本身，即 `/storage/emulated/0/Android/data/app.fushi.reader/files`。
  3. RxLogs v1.0.27（flutter_logs 的原生依赖）`LogsConfig.doOnSetup()` → `Triggers.shouldClearExports()`：首次只记下日期；之后某次冷启动距上次 ≥ 3 天 → `PLog.clearExportedLogs()` = `File(outputPath).deleteRecursively()`（`PLog.kt:545-546`，`outputPath = getExportPath(config)`）。
  4. 结果：每满 3 天后的第一次冷启动，整个外部 `files/` 被递归删除。3.4.0 起外部书库就在 `files/data`（书、漫画、有声书、词典、封面全在里面），数据库在内部所以留着——正是「书全显示缺失、记录还在」。BUG-5492 里「丢失时间窗与应用内更新重合」只是巧合（更新后冷启动）。
  - iOS 侧 flutter_logs 只在显式调 `clearLogs` 时删自己的日志目录，Fushi 从没调过，不受影响。内部存储（`getFilesDir`）不受影响。
- **[x] ① 已修复** — 整个移除 flutter_logs：它写的日志文件没有任何代码读（反馈 / 错误上传全走 `ErrorLogService`），留着只有风险。
  - `fushi/pubspec.yaml` 删依赖，`pubspec.lock`、`fushi/ios/Podfile.lock` 同步；`main.dart` 删 `initLogs` 与 zone 顶层的 `FlutterLogs.logError`（`ErrorLogService.logFatal` 已同步落盘同一条）。
  - 删掉只为它存在的 iOS 补丁 `ci/patches/hosted/flutter_logs-2.2.8/`（BUG-5067）及其守卫、channel 守卫 `test/platform/flutter_logs_engine_scoped_channel_test.dart`（BUG-4271）；`headless_launch_entry_guard_test` 去掉 `FlutterLogs.initLogs(` 这一步。
  - 已出事的设备：升级到含本修复的版本后不再调 `initLogs`，删除不会再发生；RxLogs 留下的偏好与 `files/` 下旧日志目录无害，不清。已丢的内容由 `claude/fb-scan-repair`（扫描时用来源原件按现有条目重建）和 `claude/fb-sentinel-partial`（启动对账发现成片缺失并提示）两条分支兜底。
- **[x] ② 已加自动化测试** — `fushi/test/build/no_flutter_logs_guard_test.dart`：`pubspec.yaml` / 根 `pubspec.lock` 不得再出现 flutter_logs，`lib/` 不得 import 它或调 `FlutterLogs.`。
- **备注**：
  - 3.4.0 已发出的版本在用户升级前仍会每 3 天删一次外部书库——还在外部位置的用户（BUG-5492 之后新装已默认内部，但老安装沿用外部锚点）需要尽快发版。
  - #4521 里剩 12 个目录、1 个有声书目录，推测是删除后被同步 / 用户恢复回来的，不影响结论。
  - 以后引入任何第三方日志 / 缓存插件，凡是有「保留 N 天自动清理」的，都要核对它清理的根目录。
