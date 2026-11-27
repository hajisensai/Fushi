## BUG-5601 · Windows 集成测试：Apple 设计冷启动等不到首页，测试失败后进程不退出、吃满内存
- **报告**：2026-11-27（用户：做 BUG-5549 截图时，同一 RunId 的第二轮离屏集成测试卡了 2 小时被杀，要求修）
- **真实性**：✅ 真 bug，三层叠在一起：
  1. `fushi/integration_test/test_helpers.dart:140` `_primaryNavigationRoot()` 只认 `fushiMaterialNavKey` / `NavigationRail` / `BottomNavigationBar` / `NavigationBar` / `CupertinoTabBar`。Apple 设计 + 宽窗口时首页外壳是 `AppleSidebarTabsShell`（侧栏 ↔ 顶部标签栏，`home_page.dart` 的 Apple 分支），没有 `fushiMaterialNavKey`；运行中切换设计时旧 Material 侧栏还在，所以只有「测试根里已存了 Apple 设计、冷启动」才出事：`isHomeReady()` 恒假，`waitForHome()` 90 秒后返回 false。探针实测：冷启动时 `nav-rail-0…9` 十个目的地都在，祖先链是 `Positioned('apple-tab-bar-items')`，`fushiMaterialNavKey` 0 个。
  2. `fushi/lib/main.dart:1119` 直接替换 `FlutterError.onError`。集成测试在测试里跑真实 `main()`，flutter_test 的 binding 靠这个钩子判红：被替换后测试期间的框架错误只进错误日志、不判红；测试真失败时 binding 自己的失败报告也进了 app 的处理器，触发 `_pendingExceptionDetails != null` 断言并在同一处理器里循环，进程涨到 heavy 的 16 GB 上限，最后 `Could not start thread DartWorker` 崩掉——红测试变成「挂死」。
  3. `fushi/tool/run_windows_itest.ps1` 把子进程 stdout / stderr 整个读进内存、退出后才落盘：上面那种情况下 runner 自己先 `OutOfMemoryException` / `StackOverflowException`，磁盘上一行输出都没留下，无从诊断。
- **[x] ① 已修复** —
  1. `_primaryNavigationRoot()` 认 `AppleSidebarTabsShell`，`_navigationIconsInside()` 对它同样只取 `nav-(bar|rail)-<序号>` 目的地（不含品牌位、收起钮、库页子项 `nav-rail-library-*`）；`findNavTargetForTab()` 同时认 `FushiIcon.icon`（Apple 下内层 `Icon` 字形已换成 SF 替身）。
  2. 新增 `flutterErrorPresenterFor(host)`（`lib/src/utils/misc/flutter_error_log.dart`）：宿主是默认 `presentError` 时原样返回（正式运行行为不变）；宿主是别的处理器（测试 binding）时，非 silent 错误交给它，silent 错误（图片解码失败等）仍只 present。`main.dart` 装钩子前取当前处理器，用它代替直接 `presentError`，日志落盘不变。
  3. runner 用 `Start-PipeCapture`（内嵌 C#，按块写文件并 flush，超过 256 MB 后继续读但丢弃并写标记行，子进程不会因管道满而阻塞）把两路输出流式写到证据目录的 `stdout.log` / `stderr.log`，退出后 `Add-CapturedOutput` 以流拷贝追加进 `command.log`（`[stdout]` / `[stderr]` 段格式不变，下游 grep 照旧）再删临时文件；被杀的运行会把文件留在磁盘上。
- **[x] ② 已加自动化测试** —
  - `test/integration/navigation_helpers_test.dart`「Apple shell (sidebar / top tab bar)」：真实 `AppleSidebarTabsShell` 两种模式下 `isHomeReady()` 为真、目的地数量与顺序正确、`findNavTargetForTab` 能焦点驱动切到指定 tab（旧 helper 下两条都红）。
  - `test/utils/misc/flutter_error_log_test.dart`「flutterErrorPresenterFor」：默认宿主原样返回 `presentError`；自定义宿主只收非 silent 错误；在真实测试 binding 下经它报的错能被 `tester.takeException()` 取到。
  - `test/tools/windows_itest_isolation_guard_test.dart`「child output streams to capped files」：从脚本 AST 加载两个函数，真 `cmd` 子进程刷约 1.5 MB、上限 64 KB：子进程正常退出、捕获文件停在上限并带标记、`command.log` 有 `[stdout]` 段、空 stderr 不加段、临时文件已删；并钉住脚本里不再出现整读 API。
- **备注**：真实 app 复测（同一测试根先切 Apple 设计、再冷启动）：修复前 `waitForHome` 90 秒超时；修复后 5.1 秒就绪，10 个目的地、设置 tab 可定位。强制失败的探针：修复前跑到 16 GB 内存上限后崩溃（约 5.5 分钟），修复后见 PR。
