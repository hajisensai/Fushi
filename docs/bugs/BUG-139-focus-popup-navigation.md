## BUG-139 · 查词弹窗焦点系统跳过 header 按钮且 reader caret 绕过总开关
- **报告**：2026-06-08（用户：完善当前的焦点系统，现在焦点系统有问题，特别是在查词弹窗里面）
- **真实性**：✅ 真 bug。根因在 `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` 的查词弹窗 header 控件和 reader/popup caret 输入路由，以及 `hibiki/lib/src/shortcuts/reader_caret_router.dart` 的进入 caret 判定。
- **[x] ① 已修复** — `767b62642`
- **[x] ② 已加自动化测试** — `hibiki/test/pages/reader_popup_focus_static_test.dart` + `hibiki/test/shortcuts/reader_caret_router_test.dart`
- **备注**：本轮用源码守卫和纯路由单测覆盖；查词弹窗包含真实 WebView，仍建议后续在设备/桌面上肉眼复测原始路径：打开查词弹窗后用方向键/手柄在 header 星标、重播、暂停、从 cue 播放之间移动并激活。

### 根因
查词弹窗顶部 header 音频/收藏工具栏仍使用 Flutter 裸 `IconButton`。当前实验焦点系统的方向导航由 `HibikiFocusRoot` 收集 `HibikiFocusTarget`，裸 `IconButton` 不会注册进这套目标表，所以在查词弹窗里手柄/键盘方向移动会跳过这些按钮或无法按预期落点。

同时 reader 内的 WebView 字级 caret 路由是页面私有路径，不经过 `main.dart` 里全局 `HibikiFocusRoot` 的启停包装。全局“实验焦点导航”开关关闭后，reader/popup 仍会消费 Enter / gameButtonA / D-pad Down 等输入来进入 caret 或跳到底栏，造成开关语义不一致。

### 修复
- 将查词弹窗 header 的收藏、重播、播放/暂停、从 cue 播放按钮改为 `HibikiIconButton`，让可操作按钮在 `HibikiFocusRoot` 下自动注册成 `HibikiFocusTarget`。
- 给 reader 页面增加 `_focusNavEnabled`，统一读取 `appModel.experimentalFocusNavigationEnabled`。
- 用 `_focusNavEnabled` 门控 reader/popup caret 的键盘路径、手柄路径、A 长按定时器回调、焦点环显示，以及 Down 跳到底栏的焦点层跳转。
- 给 `ReaderCaretRouter.isEnterTriggerKeyboard` / `isEnterTriggerGamepad` 增加 `focusNavEnabled` 参数，纯路由层也能直接测试总开关关闭时 Enter/A 不进入 caret。

### 验证
- `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test/pages/reader_popup_focus_static_test.dart test/shortcuts/reader_caret_router_test.dart`
