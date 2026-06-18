# Computer Use 测试流程

> [CLAUDE.md](../../CLAUDE.md) 的子文档。自动验收仍以 Flutter 集成测试为准；Computer Use 只做可见应用巡检、截图和人工证据补充。

## 定位

Computer Use 流程验证的是「用户真的看见并操作到的 app 状态」。它不替代 `ci/integration-test.sh`，也不把坐标点击写进自动化测试。自动验收必须落到 `integration_test/`，并且操作真 app 时只走 `FocusDriver` / `tester.sendKeyEvent`。

首批固定路径是 `reader_computer_use_flow`：

- 打开本轮 seed 的合成 EPUB，不打开用户已有书。
- 用 PageDown/PageUp 走 reader shortcut，连续前翻 20 次、后翻 5 次。
- 进入 reader char caret，用 Tab/Enter/Escape 连续查词 5 轮。
- 弹窗断言覆盖 popup 存在、WebView 已加载、结果词面或结果正文与预期一致、关闭后回到 reader caret、下一轮不是上一轮旧结果。

## 自动化入口

```bash
bash ci/integration-test.sh --only=reader_computer_use_flow
bash ci/integration-test.sh --only=reader_computer_use_flow,reader_pagination,reader_caret,reader_popup_caret,popup_dictionary
```

Windows 离屏补充：

```powershell
.\hibiki\tool\run_windows_itest.ps1 integration_test/reader_computer_use_flow_test.dart
```

日志固定落在 `.codex-test/itest-logs/reader_computer_use_flow.log`。可见巡检截图、录屏、UI hierarchy、logcat 和临时说明统一放 `.codex-test/computer-use/<task>/`，例如 `.codex-test/computer-use/todo-519/reader-popup-after-lookup.png`。

## 何时用人工截图

需要证明「用户看到的状态」时再用 Computer Use 截图：弹窗位置、翻页后正文是否空白、连续查词是否闪旧结果、WebView 是否白屏、焦点环是否回到 reader。截图只作为证据，不作为自动化判定；能编码的判定要写进集成测试。

人工巡检记录至少包含：

- app 目标：Android 模拟器 / Windows 离屏 / Mac 远程。
- 命令和日志路径。
- 测试素材来源：合成 EPUB / 生成词典 / 外部文件。
- 截图或录屏路径。
- 如果阻塞，写明是设备、WebView、构建、权限还是 fixture 问题。

## 禁止事项

- 不在自动测试里使用 `tester.tap`、坐标点击或 adb `input tap`。
- 不用 JS 调 `window.hoshiReader.paginate(...)` 代替用户翻页。
- 不直接调用 `onTextSelected` 代替 reader caret 查词。
- 不打开用户已有书作为验收对象。
