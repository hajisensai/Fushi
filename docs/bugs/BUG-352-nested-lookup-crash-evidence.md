## BUG-352 · 嵌套查词闪退后错误日志一片空白（无可上传证据）

- **报告**：2026-06-20（用户：0.9.28 版，嵌套查词时闪退；「错误日志倒是写出来啊，用户怎么传」）
- **真实性**：✅ 真 bug（取证链路缺口，非崩溃本体）。根因不是单一 `file:line` 的逻辑错，而是**三处可观测性缺口**叠加，导致 native 进程级闪退（尤其嵌套查词最高频路径）后错误日志空白、用户无可上传证据：
  - `hibiki/lib/main.dart`（改前 :301 `FlutterError.onError` + :316 `runZonedGuarded` onError）**缺 `PlatformDispatcher.instance.onError`**——平台/引擎层未捕获的异步错误（platform message handler、原生回调、microtask）不经前两条钩子，对错误日志完全不可见。
  - `hibiki/lib/src/pages/implementations/dictionary_popup_controller.dart`（查词栈唯一真相源）的栈层进出（`beginTop`/`pushChild`/关栈）**没有任何崩溃面包屑**——纯 native 闪退绕过所有 Dart 错误捕获，异步日志来不及落盘，错误日志里看不到「上次嵌套查词把进程带崩 + 第几层」。
  - native minidump 机制（`hibiki/windows/runner/crash_dump.cpp` 经 `SetUnhandledExceptionFilter` 写 `%LOCALAPPDATA%\Hibiki\crashdumps\hibiki-<pid>-<tick>.dmp`）早已编译进 runner，但 **app 零暴露**——用户找不到、也无法分享这些唯一二进制证据。
  - 闪退本体（嵌套查词跨线程 teardown 竞态）**文档推断同 603-B / BUG-344**，本条仅做取证地基（P0），**待 dump 坐实**根因，不在此条断言已证实。
- **[x] ① 已修复** — 仅 P0 取证地基（TODO-607 P0-1/P0-2/P0-3）：
  - P0-1：`main.dart` 装 `PlatformDispatcher.instance.onError`（同步 flush 落盘 + 返回 true）；`FlutterError`/`UncaughtZone` 致命级改 `ErrorLogService.logFatal`（`writeAsStringSync(flush:true)` 同步落盘，崩溃前存活）。
  - P0-2：`error_log_service.dart` 新增**独立** `lookup_crash_breadcrumb.txt` 面包屑（不复用导入的 `import_crash_breadcrumb.txt`）+ 独立恢复分支，下次启动折成 `Lookup.crashRecovered`（记崩时查词栈深度）。面包屑落在 `dictionary_popup_controller.dart` 的**栈层进出**语义（同步代码，三查词表面共用），经注入回调 `onLookupStackDepthChanged` → 顶层函数 `recordLookupStackDepth` 接通；6 个查词宿主注入。
  - P0-3：诊断区（`settings_schema.dart`）新增 Windows-only「崩溃转储」项（`CrashDumpPage`）：`crash_dump_locator.dart` 纯函数列 `*.dmp` + 打开文件夹（`Process.run('explorer')` 净新增）+ 分享（`Share.shareXFiles` .dmp）+ 常驻 `.dmp` 含进程内存快照隐私提示。`isWindows` 门控仿 `wgc_capture_log.dart`。
  - 边界：全 app 层，不碰 native（texture_bridge 等是 P2）。P1（WGC 保活池无界泄漏改回有界）/P2（闪退根因 + dump 坐实）不在本条。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/startup/platform_dispatcher_error_guard_test.dart`：`PlatformDispatcher.onError` 装载 + `logFatal` 同步 flush 源码守卫。
  - `hibiki/test/utils/misc/lookup_crash_breadcrumb_test.dart`：查词面包屑**独立文件** + recovery 行为（写面包屑→模拟启动→错误日志现 `Lookup.crashRecovered`）。
  - `hibiki/test/settings/crash_dump_settings_windows_only_guard_test.dart`：诊断区 crashdumps 列表/打开文件夹/分享的 Windows 门控守卫。
  - `hibiki/test/utils/misc/crash_dump_locator_test.dart`：`CrashDumpLocator` 纯函数（列 dump/路径解析）单测。
  - `hibiki/test/pages/dictionary_popup_lookup_breadcrumb_depth_test.dart`：controller 注入回调栈深度（嵌套 pushChild → 深度 >=2，关栈回落）行为测试。
- **备注**：真机待验——①嵌套查词闪退后重启，错误日志应现 `Lookup.crashRecovered`（记栈深度）；②诊断区→崩溃转储应能列出 `.dmp` 并打开文件夹/分享。闪退根因（跨线程 teardown 竞态）待 dump 坐实，宜并入 BUG-344。
