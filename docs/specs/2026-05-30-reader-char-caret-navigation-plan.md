# 阅读器字级焦点导航 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development 或 executing-plans 逐任务实现。Steps 用 `- [ ]`。

**Goal:** 让手柄(X 进入)、键盘 Tab 进入 EPUB 书籍正文，并以「字」为粒度移动焦点，在某字上激活即查该字所在词。

**Architecture:** 字光标活在 JS（DOM 真相所有者）`window.hoshiCaret`；Flutter 侧一个 `_caretActive` 状态机把按键/手柄路由到光标操作；查词复用既有 `selectFromPosition→onTextSelected` 管线；写作模式(横/竖)与翻页/连续滚动的几何全在 JS。纯 Dart 路由(`ReaderCaretRouter`)可单测。

**Tech Stack:** Flutter/Dart, flutter_inappwebview, 既有 ReaderSelectionScripts/ReaderPaginationScripts/Shortcut registry。

---

## File Structure

- 新增 `hibiki/lib/src/reader/reader_caret_scripts.dart` — `ReaderCaretScripts`：`window.hoshiCaret` JS + invocation/parse helpers。
- 新增 `hibiki/lib/src/shortcuts/reader_caret_router.dart` — 纯 Dart 路由 `ReaderCaretRouter` + `CaretAction`。
- 改 `hibiki/lib/src/reader/reader_selection_scripts.dart` — 抽 `selectFromPosition(node,offset,maxLength)`。
- 改 `hibiki/lib/src/shortcuts/shortcut_action.dart` — `+readerCaretToggle`。
- 改 `hibiki/lib/src/shortcuts/shortcut_defaults.dart` — X→caret toggle，bookmark gamepad→R3。
- 改 `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` — 注入 JS、注册 handler、状态机、路由、翻页后 reanchor。
- 新增 `hibiki/test/shortcuts/reader_caret_router_test.dart`、`hibiki/test/shortcuts/caret_toggle_binding_test.dart`、`hibiki/test/reader/reader_caret_scripts_test.dart`。

---

### Task 1: shortcut action `readerCaretToggle`

**Files:** Modify `hibiki/lib/src/shortcuts/shortcut_action.dart`

- [ ] Step 1: 在 reader 区加入 `readerCaretToggle(ShortcutScope.reader, 'reader_caret_toggle')`（放在 readerToggleBookmark 之后）。
- [ ] Step 2: `flutter analyze lib/src/shortcuts/shortcut_action.dart` 应通过（enum 扩展）。
- [ ] Step 3: commit `feat(shortcuts): add readerCaretToggle action`。

### Task 2: 默认绑定 — X→caret，bookmark→R3 + 冲突测试

**Files:** Modify `hibiki/lib/src/shortcuts/shortcut_defaults.dart`；Test `hibiki/test/shortcuts/caret_toggle_binding_test.dart`

- [ ] Step 1: 写失败测试：desktop 默认下 `resolveGamepad(GamepadButton.x, scope: reader)==readerCaretToggle`，`resolveGamepad(GamepadButton.thumbRight, scope: reader)==readerToggleBookmark`，且 X 不再解析到 bookmark。
- [ ] Step 2: 跑测试，FAIL。
- [ ] Step 3: 实现：新增 `_gR3 = GamepadBinding(GamepadButton.thumbRight)`；`readerToggleBookmark` gamepad 由 `[_gX]`→`[_gR3]`；新增 `readerCaretToggle: _kb([], [_gX])`（键盘空，Tab 走页面专门处理）。
- [ ] Step 4: 跑测试，PASS；`flutter analyze`。
- [ ] Step 5: commit `feat(shortcuts): bind X to caret toggle, move bookmark to R3`。

注：`_mobile` 用 for-in 遍历 `ShortcutAction.values` 自动覆盖新 action（reader scope 取 desktop 的 keyboard+gamepad），无需额外改。

### Task 3: 纯 Dart 路由 `ReaderCaretRouter`

**Files:** Create `hibiki/lib/src/shortcuts/reader_caret_router.dart`；Test `hibiki/test/shortcuts/reader_caret_router_test.dart`

`CaretAction { stepForward, stepBackward, moveUp, moveDown, moveLeft, moveRight, lookup, dismissOrExit }`

- [ ] Step 1: 写失败测试（节选）：
  - `decideKeyboard(tab, shift:false)==stepForward`；`(tab, shift:true)==stepBackward`
  - `arrowUp→moveUp`、`arrowDown→moveDown`、`arrowLeft→moveLeft`、`arrowRight→moveRight`
  - `enter→lookup`、`gameButtonA→lookup`；`escape→dismissOrExit`、`gameButtonB→dismissOrExit`
  - `keyD→null`
  - `decideGamepad(dpadUp)==moveUp`…`a→lookup`、`b→dismissOrExit`、`x→null`、`lb→null`
- [ ] Step 2: 跑测试，FAIL（类不存在）。
- [ ] Step 3: 实现（physical 方向，写作模式留给 JS）：
```dart
import 'package:flutter/services.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';

/// 字级光标激活时，把一次输入翻译成光标动作。physical 方向(up/down/left/right)
/// 的「逻辑」含义（前进/换行）由 JS 端按 writing-mode 决定，这里只做纯映射，便于单测。
enum CaretAction { stepForward, stepBackward, moveUp, moveDown, moveLeft, moveRight, lookup, dismissOrExit }

class ReaderCaretRouter {
  ReaderCaretRouter._();

  /// 光标激活时键盘键的含义；null = 非光标键（交回既有处理）。
  static CaretAction? decideKeyboard(LogicalKeyboardKey key, {required bool shift}) {
    if (key == LogicalKeyboardKey.tab) {
      return shift ? CaretAction.stepBackward : CaretAction.stepForward;
    }
    if (key == LogicalKeyboardKey.arrowUp) return CaretAction.moveUp;
    if (key == LogicalKeyboardKey.arrowDown) return CaretAction.moveDown;
    if (key == LogicalKeyboardKey.arrowLeft) return CaretAction.moveLeft;
    if (key == LogicalKeyboardKey.arrowRight) return CaretAction.moveRight;
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.gameButtonA) {
      return CaretAction.lookup;
    }
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.gameButtonB) {
      return CaretAction.dismissOrExit;
    }
    return null;
  }

  /// 光标激活时手柄按钮的含义；null = 非光标键。X(toggle) 故意返回 null，交给
  /// registry 的 readerCaretToggle 处理退出。
  static CaretAction? decideGamepad(GamepadButton button) {
    switch (button) {
      case GamepadButton.dpadUp: return CaretAction.moveUp;
      case GamepadButton.dpadDown: return CaretAction.moveDown;
      case GamepadButton.dpadLeft: return CaretAction.moveLeft;
      case GamepadButton.dpadRight: return CaretAction.moveRight;
      case GamepadButton.a: return CaretAction.lookup;
      case GamepadButton.b: return CaretAction.dismissOrExit;
      default: return null;
    }
  }
}
```
- [ ] Step 4: 跑测试 PASS；analyze。
- [ ] Step 5: commit `feat(shortcuts): pure ReaderCaretRouter for caret-mode input`。

### Task 4: 选区脚本抽 `selectFromPosition`

**Files:** Modify `hibiki/lib/src/reader/reader_selection_scripts.dart`；Test `hibiki/test/reader/reader_selection_scripts_test.dart`(若存在则加断言，否则新建静态字符串断言)

- [ ] Step 1: 在 `source()` 的 `hoshiSelection` 对象里，把 `selectText` 中「命中后」的逻辑（从 `this.clearSelection();`(271 行后) 到 callHandler('onTextSelected',…) 与 `return text;`）整体移入新方法 `selectFromPosition: function(node, offset, maxLength)`，签名以 `{node, offset}` 替代 `hit`。`selectText` 命中后改为：
```js
return this.selectFromPosition(hit.node, hit.offset, maxLength, x, y);
```
其中 `x,y` 仅用于 `getSelectionRect(x,y)`；`selectFromPosition` 末参 `x,y` 可选，缺省时 rect 用首字 range 的 boundingRect。
- [ ] Step 2: 静态测试断言 `ReaderSelectionScripts.source()` 同时包含 `selectFromPosition:` 与 `selectText:`，且 `selectText` 调用 `selectFromPosition`。跑 FAIL→实现→PASS。
- [ ] Step 3: 新增 invocation：`static String selectFromPositionInvocation()` 不需要（光标侧由 hoshiCaret.lookup 内部直接调）。仅保留断言。
- [ ] Step 4: commit `refactor(reader): extract selectFromPosition for caret lookup reuse`。

### Task 5: `ReaderCaretScripts`（JS 字光标 + Dart helpers）

**Files:** Create `hibiki/lib/src/reader/reader_caret_scripts.dart`；Test `hibiki/test/reader/reader_caret_scripts_test.dart`

JS `window.hoshiCaret` 要点（完整实现见下）：状态 `active/node/offset`；`#hoshi-caret-ring` 固定定位环；`enter/exit/move/reanchor/lookup/refresh/isActive`；physical→logical 由 `_vertical()` 映射；可见性用 `getBoundingClientRect` 与视口(含 chrome inset)相交；分页越界返回 `pageForward/pageBackward`，连续模式自行 `scrollIntoView`。

Dart helpers：`source()`、`scriptInvocation` 各方法、`parseMoveResult(raw)→({String status, Rect? rect})`、`enterInvocation(bool atEnd)` 等。

- [ ] Step 1: 写失败测试：`ReaderCaretScripts.source()` 含 `window.hoshiCaret`、`enter:`、`move:`、`reanchor:`、`lookup:`、`_vertical`；`parseMoveResult('{"status":"pageForward"}').status=='pageForward'`。
- [ ] Step 2: FAIL。
- [ ] Step 3: 实现文件（JS 见「附：caret JS」整段；Dart helpers 如下）：
```dart
class ReaderCaretScripts {
  ReaderCaretScripts._();
  static String enterInvocation({bool atEnd = false}) =>
      'JSON.stringify(window.hoshiCaret.enter($atEnd))';
  static String exitInvocation() => 'window.hoshiCaret.exit()';
  static String moveInvocation(String dir) =>
      "JSON.stringify(window.hoshiCaret.move('$dir'))";
  static String reanchorInvocation(String edge) =>
      "JSON.stringify(window.hoshiCaret.reanchor('$edge'))";
  static String lookupInvocation() => 'window.hoshiCaret.lookup()';
  static String refreshInvocation() => 'window.hoshiCaret.refresh()';
  static ({String status}) parseMoveResult(Object? raw) { /* jsonDecode, default 'blocked' */ }
  static String source() => r"""...caret JS...""";
}
```
- [ ] Step 4: PASS；analyze。
- [ ] Step 5: commit `feat(reader): ReaderCaretScripts — JS char caret module`。

### Task 6: 页面集成（注入 + handler + 状态机 + 路由 + reanchor）

**Files:** Modify `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`

- [ ] Step 1: import `reader_caret_scripts.dart`、`reader_caret_router.dart`。
- [ ] Step 2: `_buildReaderSetupScript`：把 `ReaderCaretScripts.source()` 注入到 selection/pagination 之后（IIFE 内 `$caretJs`），并传入 accent 颜色与 chrome insets 给 ring 样式（用现有 `_readerTopOffset`、bottom inset）。
- [ ] Step 3: 状态 `bool _caretActive = false;`。方法：
```dart
Future<void> _enterCaret({bool atEnd = false}) async {
  if (_controller == null) return;
  final raw = await _controller!.evaluateJavascript(source: ReaderCaretScripts.enterInvocation(atEnd: atEnd));
  // enter 失败(无可见字)则不置位
  setState(() => _caretActive = true);
}
void _exitCaret() {
  if (!_caretActive) return;
  _controller?.evaluateJavascript(source: ReaderCaretScripts.exitInvocation());
  setState(() => _caretActive = false);
}
Future<void> _runCaretAction(CaretAction a) async {
  switch (a) {
    case CaretAction.stepForward:  await _caretTab(backward: false); return;
    case CaretAction.stepBackward: await _caretTab(backward: true);  return;
    case CaretAction.moveUp:    await _caretMove('up');    return;
    case CaretAction.moveDown:  await _caretMove('down');  return;
    case CaretAction.moveLeft:  await _caretMove('left');  return;
    case CaretAction.moveRight: await _caretMove('right'); return;
    case CaretAction.lookup:    await _caretLookup();      return;
    case CaretAction.dismissOrExit:
      if (isDictionaryShown) { clearDictionaryResult(); } else { _exitCaret(); }
      return;
  }
}
Future<void> _caretMove(String physicalDir) async {
  if (_controller == null) return;
  final raw = await _controller!.evaluateJavascript(source: ReaderCaretScripts.moveInvocation(physicalDir));
  final status = ReaderCaretScripts.parseMoveResult(raw).status;
  if (status == 'pageForward') { await _paginate(ReaderNavigationDirection.forward); await _caretReanchor('forward'); }
  else if (status == 'pageBackward') { await _paginate(ReaderNavigationDirection.backward); await _caretReanchor('backward'); }
}
Future<void> _caretTab({required bool backward}) async {
  if (_controller == null) return;
  final raw = await _controller!.evaluateJavascript(
    source: ReaderCaretScripts.moveInvocation(backward ? 'backward' : 'forward'));
  final status = ReaderCaretScripts.parseMoveResult(raw).status;
  if (status == 'pageForward') { await _paginate(ReaderNavigationDirection.forward); await _caretReanchor('forward'); }
  else if (status == 'pageBackward') { await _paginate(ReaderNavigationDirection.backward); await _caretReanchor('backward'); }
  else if (status == 'blocked') { // 书末/书首：退出书籍，焦点交还框架
    _exitCaret();
    if (mounted) {
      backward ? FocusScope.of(context).previousFocus() : FocusScope.of(context).nextFocus();
    }
  }
}
Future<void> _caretReanchor(String edge) async {
  await _controller?.evaluateJavascript(source: ReaderCaretScripts.reanchorInvocation(edge));
}
Future<void> _caretLookup() async {
  await _controller?.evaluateJavascript(source: ReaderCaretScripts.lookupInvocation());
  // onTextSelected 由 JS 触发，进入既有 _handleTextSelected
}
```
- [ ] Step 4: 路由接入 `_handleKeyEvent`（在 chrome 分支之后、registry 解析之前插入）：
```dart
if (_caretActive) {
  final shift = HardwareKeyboard.instance.isShiftPressed;
  final CaretAction? ca = ReaderCaretRouter.decideKeyboard(event.logicalKey, shift: shift);
  if (ca != null) { _runCaretAction(ca); return KeyEventResult.handled; }
} else if (event.logicalKey == LogicalKeyboardKey.tab &&
           !HardwareKeyboard.instance.isShiftPressed) {
  _enterCaret(); return KeyEventResult.handled;
}
```
  接入 `_handleGamepadButton`（chrome 分支之后、registry 之前）：
```dart
if (_caretActive) {
  final CaretAction? ca = ReaderCaretRouter.decideGamepad(button);
  if (ca != null) { _runCaretAction(ca); return true; }
}
```
- [ ] Step 5: `_executeShortcutAction` 增 `case ShortcutAction.readerCaretToggle:`：
```dart
case ShortcutAction.readerCaretToggle:
  if (_caretActive) { _exitCaret(); } else { _enterCaret(); }
  return KeyEventResult.handled;
```
- [ ] Step 6: 翻页后 reanchor：`_paginate` 完成处末尾加 `if (_caretActive) { await _caretReanchor(direction == ReaderNavigationDirection.forward ? 'forward' : 'backward'); }`（注意避免与边界自动翻页内已 reanchor 的重复——`_caretMove/_caretTab` 用的是直接 `_paginate`+`_caretReanchor`，因此把 reanchor 只放在 `_paginate` 内统一做，移除 `_caretMove/_caretTab` 里翻页后的显式 reanchor，避免双锚）。最终：reanchor 只在 `_paginate` 末尾按方向做一次。
- [ ] Step 7: re-anchor 串行链（既有重排）里调用 `_caretRefresh()`；新增 `Future<void> _caretRefresh() async { if (_caretActive) await _controller?.evaluateJavascript(source: ReaderCaretScripts.refreshInvocation()); }`。
- [ ] Step 8: `analyze`；`flutter test`（既有测试不应回归）。
- [ ] Step 9: commit `feat(reader): char-level caret navigation via gamepad X / Tab`。

### Task 7: 验证

- [ ] Step 1: `D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format .`
- [ ] Step 2: `flutter analyze`（lib 0 error）。
- [ ] Step 3: `flutter test`（全绿）。
- [ ] Step 4: 集成验证：`adb devices` 有设备则真机复测竖排/横排×分页/连续：X 进入→方向键/Tab 逐字与换行→边界翻页→A 查词出弹窗→B 退出。无设备则在 `docs/reviews/` 与 REGRESSION 记录「验证缺口」，不写成已通过。
- [ ] Step 5: commit 证据/报告（若有）。

### Task 8: Code review + 循环修复

- [ ] Step 1: superpowers:requesting-code-review，spawn code-reviewer subagent（**model: opus**）。
- [ ] Step 2: 按反馈修复，重跑 analyze/test，重新审查直到通过。

---

## 附：caret JS（实现参照，最终以源码为准）

要点：见 Task 5 描述。geometric 最近邻换行 + 视口相交判定 + physical/logical 映射 + 分页越界信号 / 连续滚动内处理 + fixed 焦点环。具体源码在实现 Task 5 时写入 `reader_caret_scripts.dart`。

## Self-Review

- 覆盖：spec §4 光标=Task5；§5 selectFromPosition=Task4；§6 状态机/路由=Task3+Task6；§3 决策(X/Tab/全模式)=Task2+Task6+JS；§8 测试=Task3/4/5/7/8。无遗漏。
- 占位符：caret JS 整段在 Task5 实现时落地（非占位，是「实现参照，源码为准」的有意安排，因 JS 体量大且需迭代）。
- 类型一致：`CaretAction` 枚举、`parseMoveResult` 返回 `({String status})`、`_caretMove/_caretTab/_caretReanchor` 命名贯穿一致。
