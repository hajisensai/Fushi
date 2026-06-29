# Computer Use 测试流程

> [CLAUDE.md](../../CLAUDE.md) 的子文档。自动验收仍以 Flutter 集成测试为准；Computer Use 只做可见应用巡检、截图和人工证据补充。

## 定位

Computer Use 流程验证的是「用户真的看见并操作到的 app 状态」。它不替代 `ci/integration-test.sh`，也不把坐标点击写进自动化测试。自动验收必须落到 `integration_test/`，并且操作真 app 时只走 `FocusDriver` / `tester.sendKeyEvent`。

首批固定路径是 `reader_computer_use_flow`：

- 打开本轮 seed 的合成 EPUB，不打开用户已有书。
- 用 PageDown/PageUp 走 reader shortcut，连续前翻 20 次、后翻 5 次。
- 进入 reader char caret，用 Tab/Enter/Escape 连续查词 5 轮。
- 弹窗断言覆盖 popup 存在、WebView 已加载、结果词面或结果正文与预期一致、关闭后回到 reader caret、下一轮不是上一轮旧结果。

## 离屏观察（非焦点 / 不阻碍用户）—— 抓真实像素的权威路径

需要「看到」功能是否真的渲染出来、又不能占用用户屏幕 / 焦点时，用离屏 Dart 抓图，
而不是 OS 级 PrintWindow（对 Flutter 的 ANGLE/GPU 合成面只能抓回白屏）。

- 入口：`.\tool\run_windows_itest.ps1 integration_test\<t>_test.dart`
  全程窗口非激活（`WS_EX_NOACTIVATE`，不抢前台 / 键盘）+ 离屏（窗口停 -32000）+ 隔离
  app data / WebView2 profile + 非阻塞 —— 你可以继续用电脑。
- 在测试里用 `integration_test/helpers/observe_capture.dart`：
  - `captureFlutterFrame(tester, name)`：抓 Flutter UI（设置 / 弹窗 / 主页 / 词典结果 /
    对话框）。根 RenderView.toImage，与窗口可见性无关。
  - `captureReaderWebView(name)`：抓阅读器 EPUB 正文（WebView2 CDP，离屏可用）。
  两者落 `<evidenceDir>/screenshots/<name>.png` 并自检「非空白」（`rgbaLooksNonBlank`）。
- 样板：`integration_test/observe_offscreen_test.dart`（抓主页 + 阅读器正文并断言非空白）。
- 判读：`observe-*.png` 是权威真实像素；`shot-NN.png`（PrintWindow）对 Flutter/WebView
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
