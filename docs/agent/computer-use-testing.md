# Computer Use 测试流程

> [CLAUDE.md](../../CLAUDE.md) 的子文档。自动验收仍以 Flutter 集成测试为准；Computer Use 只做可见应用巡检、截图和人工证据补充。

## 定位

Computer Use 流程验证的是「用户真的看见并操作到的 app 状态」。它不替代 `ci/integration-test.sh`，也不把坐标点击写进自动化测试。自动验收必须落到 `integration_test/`，并且操作真 app 时只走 `FocusDriver` / `tester.sendKeyEvent`。

首批固定路径是 `reader_computer_use_flow`：

- 打开本轮 seed 的合成 EPUB，不打开用户已有书。
- 用 PageDown/PageUp 走 reader shortcut，连续前翻 20 次、后翻 5 次。
- 进入 reader char caret，用 Tab/Enter/Escape 连续查词 5 轮。
- 弹窗断言覆盖 popup 存在、WebView 已加载、结果词面或结果正文与预期一致、关闭后回到 reader caret、下一轮不是上一轮旧结果。

## 离屏 / 非焦点观察（不阻碍用户）—— 抓真实像素的权威路径

需要「看到」功能是否真的渲染出来、又不能占用用户屏幕 / 焦点时，用 Dart 抓图，
而不是 OS 级 PrintWindow（对 Flutter 的 ANGLE/GPU 合成面只能抓回白屏）。

**两种窗口模式（都不抢焦点，自己选）：**
- **默认（纯离屏）** `.\tool\run_windows_itest.ps1 integration_test\<t>_test.dart`：
  窗口非激活（`WS_EX_NOACTIVATE`）+ 停 -32000 屏外 + 隔离 + 非阻塞。**仅适合纯 Flutter
  UI 表面**（设置 / 弹窗 / 主页 / 词典结果 / 对话框）——`captureFlutterFrame` 走根
  RenderView.toImage，与窗口可见性无关。
- **`-Visible`（屏内非焦点）** `.\tool\run_windows_itest.ps1 -Visible integration_test\<t>_test.dart`：
  同样非激活、不抢前台 / 键盘（只在屏幕角落显示、不置顶），但 DWM 会合成该窗。
  **凡用例经 `appModel.openMedia` 打开媒体（阅读器 / 有声书 / 视频）必须用 `-Visible`**：
  media_kit（音频 / 视频）初始化需要 DWM 合成的实窗，纯离屏 parked 窗口下
  `initialiseAudioHandler()` 会**永久挂起**（曾实测挂 1 小时）。

**测试与用户的 Hibiki 并存**：测试 exe 在 `HIBIKI_TEST_HIDDEN` 下跳过全局单实例互斥量
（用隔离 WebView2 profile，无锁冲突），故你开着 Hibiki 也能跑、互不干扰
（见 `windows/runner/main.cpp`）。

**抓图 / 开页助手** `integration_test/helpers/observe_capture.dart`：
- `captureFlutterFrame(tester, name)`：抓 Flutter 图层树（不含 WebView/视频平台纹理）。
- `captureReaderWebView(name)`：抓阅读器 / 有声书正文（WebView2 CDP，跨章节 / 歌词模式）。
- `readerWebViewReady()`：阅读器 WebView 是否已创建（跨模式可靠的就绪信号）。
- 两路抓图落 `<evidenceDir>/screenshots/<name>.png` 并自检「非空白」（`rgbaLooksNonBlank`）。

**确定性开页钩子**（离屏 / 非焦点下焦点驱动激活偶发不触发，故用这些直达；均 debug/profile
only，`@visibleForTesting`）：`HomePage.debugSelectTab(tab)` 切顶层 tab、
`ReaderHibikiHistoryPage.debugOpenBook(mediaIdentifier)` 走书卡同路径 openMedia 开书、
`HomeVideoPage.debugRefreshVideos()` 重查视频列表、`ReaderHibikiPage.debugCaptureWebView`
抓 WebView。

**素材生成器** `integration_test/helpers/media_fixtures.dart` + `library_fixture.dart`：
程序化造字幕(SRT/VTT/LRC/ASS) / cue / 有声书 EPUB / ffmpeg 音视频，`seedReaderBook` /
`seedAudiobook` / `seedVideo` 播种，**不依赖用户私人文件**。

**样板**：`integration_test/observe_offscreen_test.dart`（阅读器正文）、
`observe_media_offscreen_test.dart`（有声书 + 视频）——都用 `-Visible` 跑。

**判读**：`observe-*.png` 是权威真实像素；`shot-NN.png`（PrintWindow）对 Flutter/WebView
多为白屏，只证明「窗口存在」，不证明「渲染正确」。

## 自动化入口

```bash
bash ci/integration-test.sh --only=reader_computer_use_flow
bash ci/integration-test.sh --only=reader_computer_use_flow,reader_pagination,reader_caret,reader_popup_caret,popup_dictionary
```

Windows 离屏补充：

```powershell
.\hibiki\tool\run_windows_itest.ps1 integration_test/reader_computer_use_flow_test.dart
```

Android 编排日志固定落在 `.codex-test/itest-logs/reader_computer_use_flow.log`。Windows runner 会为每次运行创建 `.codex-test/windows-itest/<run-id>/`，其中固定包含：

- `command.log` / `exit-code.txt` / `paths.json` / `process-before.json` / `process-after.json`
- `computer-use/reader_computer_use_flow/function-matrix.json`
- `computer-use/reader_computer_use_flow/function-matrix.md`
- `computer-use/reader_computer_use_flow/flutter-ui-tree-*.txt`

这些产物记录 reader ready 后正文非空、连续翻页后的页面状态、连续查词每轮 popup 可见内容、Escape 关闭后焦点回到 reader caret，以及截图是否由当前平台实际保存。额外的可见巡检截图、录屏、UI hierarchy、logcat 和临时说明统一放 `.codex-test/computer-use/<task>/`，例如 `.codex-test/computer-use/todo-528/reader-popup-after-lookup.png`。

## 何时用人工截图

需要证明「用户看到的状态」时再用 Computer Use 截图：弹窗位置、翻页后正文是否空白、连续查词是否闪旧结果、WebView 是否白屏、焦点环是否回到 reader。截图只作为证据，不作为自动化判定；能编码的判定要写进集成测试。

人工巡检记录至少包含：

- app 目标：Android 模拟器 / Windows 离屏 / Mac 远程。
- 命令和日志路径。
- 测试素材来源：合成 EPUB / 生成词典 / 外部文件。
- 截图、录屏或 `computer-use/.../flutter-ui-tree-*.txt` 路径。
- 功能矩阵路径；Windows runner 优先引用 `computer-use/reader_computer_use_flow/function-matrix.md`。
- 如果阻塞，写明是设备、WebView、构建、权限还是 fixture 问题。

## 禁止事项

- 不在自动测试里使用 `tester.tap`、坐标点击或 adb `input tap`。
- 不用 JS 调 `window.hoshiReader.paginate(...)` 代替用户翻页。
- 不直接调用 `onTextSelected` 代替 reader caret 查词。
- 不打开用户已有书作为验收对象。
