## BUG-3077 · Android 阅读器顶部留白变大：Flutter 3.47 的 edgeToEdge 清掉沉浸标志，状态栏回来并计入正文顶部 inset
- **报告**：2026-10-07（用户：marv，Discord「the new update broke the top margin in novel reader — now the margin is bigger than before」；平台 / 书 / 视图模式未说明）
- **真实性**：✅ 真回归（Android）。引入提交 `4cadca674a build: bump Flutter to 3.47.6`（2026-10-05，随 PR #1984「M3 Expressive wave 1 and Flutter 3.47.6 migration」于 2026-10-06 合入 develop，10-07 的调试版 APK 起带它；10-03 的正式版 v2.9.1 用的是 3.44，不受影响）。
  - 触发点：`fushi/lib/src/pages/implementations/reader_fushi/navigation.part.dart:138`（修前）——正文首次恢复完成时裸调 `SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)`。打开书时 `AppModel.openMedia`（`fushi/lib/src/models/app_model.dart:7111`）先设了 `immersiveSticky`。
  - 引擎差异：Flutter 3.47.6 的 `engine/src/flutter/shell/platform/android/io/flutter/plugin/platform/PlatformPlugin.java` `enableEdgeToEdge()` 新增了一行 `activity.getWindow().getDecorView().setSystemUiVisibility(0)`（3.44 引擎没有，两版 `diff` 只差这一处）。3.44 下 edgeToEdge 只改 decor fitting，`openMedia` 设下的 FULLSCREEN / HIDE_NAVIGATION / IMMERSIVE_STICKY 原样保留，阅读器里状态栏与导航栏一直是隐藏的（BUG-2925 记录过这个 3.44 行为）；3.47 下这一行把隐藏标志清零，书一打开完成，状态栏和导航栏就回来了。
  - 留白怎么变大：`FlutterView.onApplyWindowInsets`（两版一致）取 `viewPaddingTop = max(getInsets(systemBars()).top, cutout.safeInsetTop)`，系统栏隐藏时为挖孔安全区（无挖孔为 0），显示时为状态栏高度。阅读器 `didChangeDependencies` 把它存进 `_stableTopInset`（`reader_fushi_page.dart:3643`）并回喂 WebView；`_readerTopOffset = _stableTopInset + _topProgressReserve + _desktopHeaderReserve`（`reader_fushi_page.dart:2546`）→ `chromeTopInset` → CSS `--chrome-top-inset` → body `padding-top: calc(<上边距> + var(--chrome-top-inset))`（`fushi/lib/src/reader/reader_content_styles.dart:1197`，连续 / VN 同构）。正文顶部留白因此**多出一条「状态栏高度 − 挖孔安全区」**（无挖孔设备上就是整条状态栏高），底部同理多出导航栏高。翻页 / 滚动 / VN、横排 / 竖排都经同一个 inset，全部受影响。
  - iOS / 桌面不是回归：iOS 引擎的 edgeToEdge 一直表示「显示状态栏」，3.44 → 3.47 行为没变；桌面没有系统栏。
  - 排除过的嫌疑（10-05~06 的 M3E 改造与近期排版提交）：CSS 生成器（`reader_content_styles.dart`）在 v2.9.1..develop 间没有改顶部 padding；页顶注音预留（BUG-2761）/ BUG-2810 注音度量不在这一区间；上边距默认值仍是 0。M3E 悬浮工具栏把**挤压态**（关掉「点空白隐藏控制栏」）的顶栏预留从贴边 48 改成胶囊外框 72（`kReaderFloatingHeaderExtent`），但默认 `tap_empty_hide_chrome=true` 是悬浮态、预留恒 0，不是这条报告的主因；只有关掉该开关的用户会额外多 24px（顶栏在场时），属于有意的设计变化，不在本条修。
- **[x] ① 已修复** — 新增 `setReaderSystemUiMode()` / `readerSystemUiMode()`（`fushi/lib/src/utils/misc/platform_utils.dart:85`、`:92`，与 `setHomeShellSystemUiMode` 并列）：阅读器正文就绪时**直接声明它要的模式**——Android `immersiveSticky`（保持 `openMedia` 进入的系统栏隐藏，正文 inset 回到挖孔安全区），iOS / 桌面仍 `edgeToEdge`（行为不变）。调用点 `navigation.part.dart:140` 改走 helper，不再依赖「edgeToEdge 不清沉浸标志」这个引擎细节。没有用减像素抵消：留白回到原值是因为系统栏回到隐藏、`viewPadding.top` 回到原值。
- **[x] ② 已加自动化测试** — `fushi/test/utils/reader_system_ui_mode_test.dart`：拦截真实 `SystemChannels.platform`，断言 Android 恰发一次 `immersiveSticky`、非 Android 恰发一次 `edgeToEdge`；源码守卫扫描 `reader_fushi_page.dart` 与 `reader_fushi/` 全部 part，禁止任何裸 `setEnabledSystemUIMode`（修前代码在此红），并要求内容就绪路径调用 `setReaderSystemUiMode()`。（host runner 上 `Platform.isAndroid` 恒 false，Android 引擎行为本身只能靠真机，见备注。）
- **备注**：
  - 真机验证：见下方「真机数值」。
  - 同一个引擎变化也影响漫画阅读器 `manga_fushi_page.dart` 的 `_chromeVisible ? edgeToEdge : immersiveSticky`：3.44 下显示 chrome 时系统栏其实没回来，3.47 下会回来——那正是 BUG-1888 写的设计意图（「显示 → 还原 edgeToEdge」），不在本条改动范围，留意即可。

### 交接后复核（2026-10-07）
- 修复提交：`0fe9c4b09f`。追加退出生命周期保护：`navigation.part.dart` 内容就绪回调仅在 `!_popInProgress` 时声明 reader 模式；路由退出动画期间仍 mounted，晚到回调不得盖掉 `closeMedia()` 已恢复的首页系统栏。`reader_system_ui_mode_test.dart` 对此添加源码守卫。
- Mac / Flutter 3.47.6 定向验证：`reader_system_ui_mode_test.dart`、`home_shell_system_ui_mode_test.dart`、`reader_exit_bounded_probe_test.dart`，**19 tests / exit 0**。
- `FUSHI_BUG_BASE=upstream/develop dart run tool/bug.dart check --strict`：**exit 0**，本分支新增 BUG-3077 无撞号。

### 真机数值与验收边界
- Android 14 / API 34 真机，824×1648、300dpi；Flutter 3.47.6 debug APK，独立包 `app.fushi.reader.topmargintest`。APK build **exit 0**；`flutter drive` 连接已运行的测试包，**exit 0**，1 个 probe 场景（runner 计数 +2 含 tearDownAll），6 个组合 × 3 个阶段 = **18 组独立采样**。逐组数值校验 **18/18、exit 0**。
- 三阶段为 A：生产开书后的修复状态；B：显式发送修前的 `edgeToEdge`；C：再次发送 `setReaderSystemUiMode()`。各组合测得：

| view mode | writing mode | viewPadding.top A/B/C | chrome-top-inset A/B/C | 正文有效顶部 padding A/B/C |
|---|---|---|---|---|
| paginated | vertical-rl | 0 / 24 / 0 | 0 / 24 / 0 | body：0 / 24 / 0 |
| paginated | horizontal-tb | 0 / 24 / 0 | 0 / 24 / 0 | body：0 / 24 / 0 |
| continuous | horizontal-tb | 0 / 24 / 0 | 0 / 24 / 0 | body：0 / 24 / 0 |
| continuous | vertical-rl | 0 / 24 / 0 | 0 / 24 / 0 | body：0 / 24 / 0 |
| vn | horizontal-tb | 0 / 24 / 0 | 0 / 24 / 0 | stage：0 / 24 / 0 |
| vn | vertical-rl | 0 / 24 / 0 | 0 / 24 / 0 | stage：0 / 24 / 0 |

- 单位为逻辑像素 / CSS px。该设备的底部 viewPadding 三阶段均为 0，未声称此设备复现了底部差异。
- 本地证据：worktree 下 `.codex-test/reader-top-margin/` 的 `device-first-run.log`、`measurements.json`、`measurement-check.txt`。无遮挡截图为 `vn-vertical-rl-{A-fixed,B-legacy-edgeToEdge,C-setReaderSystemUiMode}.png` 与 `vn-horizontal-tb-{B-legacy-edgeToEdge,C-setReaderSystemUiMode}.png`，可见旧模式状态栏出现、修复模式隐藏。VN 横排 A 与滚动竖排截图含新装包 Anki 权限对话框，不能当作无遮挡验收；翻页没有可靠截图。**三模式数值回归已验证，翻页/滚动无遮挡截图仍未完成。**
- 为补截图进行了重跑，但 Android 拒绝创建该临时包 Chromium 子进程（`ActivityManager: ... SandboxedProcessService... process is bad` / `cr_ChildProcessConn: Failed to establish the service connection`），即使重装临时包仍如此，WebView 白屏/初始化超时；这些中断轮次不算通过，证据 `webview-restart-blocker.txt`。没有为此重启用户设备或操作正式包。
- 新装包的 Anki 权限仅拒绝，没有授权访问用户卡片；临时包已卸载、Gradle suffix 已还原、探针移出源码树且不入库。正式包 `app.fushi.reader` 的版本与安装时间前后相同。设备尺寸/密度/旋转未修改。
- API 35/36 与有挖孔设备未真机验证；退出保护是源码守卫 + 调用链复核，探针返回走生产 Escape 路径，但未单独断言首页系统栏恢复。
- 合入上游后的全量 `flutter analyze --no-pub`：**No issues found / exit 0**（102.8s）。
- 20:14 再查 adb 已无真机，尝试 API 35 x64 模拟器补拍。模拟器冷启动成功，但新 APK 构建在 Gradle 启动阶段持续阻塞于 JAR 文件读取（线程栈 `FileDispatcherImpl.read0 → ZipFile$Source.initCEN`，未进入编译）；本轮构建已中止，**exit 137、0 tests**，不算通过。模拟器已关闭、临时 suffix/probe 再次还原/移出；保留 `api35-build-unverified.log` 与 `x64-gradle-threads.txt`。API 35 仍为未验证。
