# 软键盘粘贴键 + 移动端一键粘贴 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 app 内屏幕键盘(`HibikiGamepadKeyboard`,桌面/主机端无系统 IME 时唤出)加一个粘贴键;移动端(Android/iOS)可编辑文本框右侧加一个一键粘贴图标。两端共用一条剪贴板→插入路径,并让粘贴/屏幕键盘输入统一触发 `onChanged`(消除"粘贴不触发联想搜索"的特殊情况)。

**Architecture:** 新增纯函数 `gamepadKeyboardPaste(controller)`(读剪贴板纯文本→复用现有 `gamepadKeyboardInsert`,返回是否插入)。屏幕键盘加可选 `onPaste` 回调与一个图标键;`showGamepadKeyboard` 加可选 `onChanged`,在 char/backspace/paste 改完 controller 后回调。集中式 suffix helper(被 4 个文本组件复用)按平台分流:桌面→键盘按钮(不变),移动端→粘贴按钮;并把各组件的 `onChanged` 透传进来。

**Tech Stack:** Flutter 3.44 / Dart 3.12,Material 3,`flutter/services.dart` `Clipboard`,Slang i18n(复用既有 `t.paste`,17 语言已译,无需 i18n_sync),`flutter_test`(widget + mock `SystemChannels.platform`)。

---

## 背景与现状(实现前必读)

- 屏幕键盘:`hibiki/lib/src/utils/components/hibiki_gamepad_keyboard.dart`
  - `HibikiGamepadKeyboard`:底部控制行 `[⇧/abc] [␣] [⌫] [✓?]`(`_KbKey` 只渲染 `Text(label)`)。
  - 纯函数 `gamepadKeyboardInsert(controller, ch)`:在光标处插入(替换选区,按 `ch.length` 推进光标,**支持多字符**);`gamepadKeyboardBackspace(controller)`。
  - `showGamepadKeyboard(context, controller)`:底部 sheet,`onChar`/`onBackspace` 直接改 `controller.value`,`onSubmit` pop。
- suffix helper:`hibiki/lib/src/utils/components/hibiki_material_components.dart:447` `_hibikiTextFieldKeyboardSuffix({context, controller})`——`!isDesktop || controller==null` 返回 null;桌面返回键盘 `HibikiIconButton`。被 4 处复用:
  - `HibikiSearchField`(`:288`,有必填 `onChanged`)
  - `HibikiTextField`(`:390`,有可选 `onChanged`,`readOnly` 时传 null controller)
  - `HibikiEditorPanel`(`:1826`,**无 onChanged**)
  - `HibikiCompactSearchRow`(`:1911`,**无 onChanged**,submit 驱动;行序 `[关闭][TextField][suffix][搜索]`)
- 关键事实:
  - `t.paste` 已存在(17 语言:Paste/粘贴/貼り付け/...),直接复用作 tooltip,**不动 i18n_sync**。
  - `Icons.content_paste` 全仓未用(只有 `content_paste_outlined` 在 `custom_theme_page.dart`),`find.byIcon` 不歧义。为与同槽位 `keyboard_outlined` 及既有粘贴图标统一,**用 `Icons.content_paste_outlined`**。
  - `HibikiIconButton`(`hibiki_icon_button.dart:195`)在 `HibikiFocusRoot` 内且 `onTap!=null` 时**默认注册成手柄焦点目标**(fallback id)。→ 移动端粘贴键会进焦点序列(Android TV 手柄可达,符合预期),但会改变 android 默认平台下渲染这些字段的焦点测试顺序。
  - Flutter 程序化改 `controller.value` **不触发** `TextField.onChanged`(只有平台输入/`userUpdateTextEditingValue` 才触发)→ 这就是要修的根因,靠调用方在改完后回调 onChanged。
  - 测试默认平台是 android;`buildTestApp(child,{theme})` 不裹 `HibikiFocusRoot`。

## 文件清单

| 文件 | 责任 | 改动 |
|---|---|---|
| `hibiki/lib/src/utils/components/hibiki_gamepad_keyboard.dart` | 屏幕键盘 + 共用插入/粘贴原语 | 加 `gamepadKeyboardPaste`;`_KbKey` 图标支持;`onPaste` 字段 + 粘贴键;`showGamepadKeyboard` onChanged 透传 |
| `hibiki/lib/src/utils/components/hibiki_material_components.dart` | 4 个文本组件 + suffix helper | helper 重命名 `_hibikiTextFieldInputSuffix` + onChanged 参数 + 平台分流;`HibikiSearchField`/`HibikiTextField` 透传 onChanged |
| `hibiki/test/widgets/hibiki_gamepad_keyboard_test.dart` | 键盘单测 | 加粘贴键渲染/无渲染、粘贴插入、onChanged 透传 |
| `hibiki/test/widgets/hibiki_text_field_keyboard_test.dart` | suffix 单测 | 加移动端粘贴键、桌面无粘贴、移动端粘贴写入+onChanged、无 controller 无粘贴 |
| `hibiki/test/widgets/hibiki_material_components_test.dart` | CompactSearchRow 焦点 | 更新为 close→paste→search 三键遍历 |

---

## Task 1: `gamepadKeyboardPaste` 剪贴板插入原语

**Files:**
- Modify: `hibiki/lib/src/utils/components/hibiki_gamepad_keyboard.dart`
- Test: `hibiki/test/widgets/hibiki_gamepad_keyboard_test.dart`

- [ ] **Step 1: 写失败测试**（加进 `group('gamepad keyboard text wiring', ...)`,文件顶部加 `import 'package:flutter/services.dart';`）

```dart
group('gamepadKeyboardPaste', () {
  void mockClipboard(WidgetTester tester, String? text) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.getData') {
          return text == null ? null : <String, dynamic>{'text': text};
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
  }

  testWidgets('inserts clipboard text at the cursor and advances it',
      (WidgetTester tester) async {
    mockClipboard(tester, 'XY');
    final TextEditingController c = TextEditingController(text: 'ac');
    addTearDown(c.dispose);
    c.selection = const TextSelection.collapsed(offset: 1);
    final bool inserted = await gamepadKeyboardPaste(c);
    expect(inserted, isTrue);
    expect(c.text, 'aXYc');
    expect(c.selection.baseOffset, 3);
  });

  testWidgets('replaces the current selection', (WidgetTester tester) async {
    mockClipboard(tester, 'B');
    final TextEditingController c = TextEditingController(text: 'aXc');
    addTearDown(c.dispose);
    c.selection = const TextSelection(baseOffset: 1, extentOffset: 2);
    await gamepadKeyboardPaste(c);
    expect(c.text, 'aBc');
  });

  testWidgets('empty clipboard is a no-op returning false',
      (WidgetTester tester) async {
    mockClipboard(tester, '');
    final TextEditingController c = TextEditingController(text: 'ab');
    addTearDown(c.dispose);
    final bool inserted = await gamepadKeyboardPaste(c);
    expect(inserted, isFalse);
    expect(c.text, 'ab');
  });

  testWidgets('null clipboard is a no-op returning false',
      (WidgetTester tester) async {
    mockClipboard(tester, null);
    final TextEditingController c = TextEditingController(text: 'ab');
    addTearDown(c.dispose);
    expect(await gamepadKeyboardPaste(c), isFalse);
    expect(c.text, 'ab');
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/widgets/hibiki_gamepad_keyboard_test.dart --no-pub`
Expected: FAIL（`gamepadKeyboardPaste` 未定义）

- [ ] **Step 3: 最小实现**（加在 `gamepadKeyboardBackspace` 之后,文件顶部加 `import 'package:flutter/services.dart';`）

```dart
/// Reads the clipboard's plain text and inserts it at the controller's cursor
/// (replacing any selection) via [gamepadKeyboardInsert]. Returns true if text
/// was inserted; false when the clipboard holds no text (no-op). Shared by the
/// on-screen keyboard's paste key and the mobile text-field paste button.
Future<bool> gamepadKeyboardPaste(TextEditingController controller) async {
  final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
  final String? text = data?.text;
  if (text == null || text.isEmpty) return false;
  gamepadKeyboardInsert(controller, text);
  return true;
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/widgets/hibiki_gamepad_keyboard_test.dart --no-pub`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/utils/components/hibiki_gamepad_keyboard.dart hibiki/test/widgets/hibiki_gamepad_keyboard_test.dart
git commit -m "feat(keyboard): add gamepadKeyboardPaste clipboard insert primitive"
```

---

## Task 2: 屏幕键盘粘贴键 + `_KbKey` 图标 + onChanged 透传

**Files:**
- Modify: `hibiki/lib/src/utils/components/hibiki_gamepad_keyboard.dart`
- Test: `hibiki/test/widgets/hibiki_gamepad_keyboard_test.dart`

- [ ] **Step 1: 写失败测试**（加进 `group('HibikiGamepadKeyboard', ...)`,复用 Task 1 的 `mockClipboard`;若放不同 group,把 `mockClipboard` 提为顶层函数）

```dart
testWidgets('paste key renders only when onPaste is provided',
    (WidgetTester tester) async {
  await tester.pumpWidget(buildTestApp(
    HibikiFocusRoot(
      child: HibikiGamepadKeyboard(onChar: (_) {}, onBackspace: () {}),
    ),
  ));
  await tester.pump();
  expect(find.byIcon(Icons.content_paste_outlined), findsNothing);

  await tester.pumpWidget(buildTestApp(
    HibikiFocusRoot(
      child: HibikiGamepadKeyboard(
          onChar: (_) {}, onBackspace: () {}, onPaste: () {}),
    ),
  ));
  await tester.pump();
  expect(find.byIcon(Icons.content_paste_outlined), findsOneWidget);
});

testWidgets('tapping the paste key fires onPaste', (WidgetTester tester) async {
  int pastes = 0;
  await tester.pumpWidget(buildTestApp(
    HibikiFocusRoot(
      child: HibikiGamepadKeyboard(
          onChar: (_) {}, onBackspace: () {}, onPaste: () => pastes++),
    ),
  ));
  await tester.pump();
  await tester.tap(find.byIcon(Icons.content_paste_outlined));
  await tester.pump();
  expect(pastes, 1);
});
```

并在 `group('gamepad keyboard text wiring', ...)` 加 showGamepadKeyboard onChanged 透传测试（验证根因修复）：

```dart
testWidgets('showGamepadKeyboard fires onChanged on char and on paste',
    (WidgetTester tester) async {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (MethodCall call) async => call.method == 'Clipboard.getData'
        ? <String, dynamic>{'text': 'PV'}
        : null,
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));
  final TextEditingController c = TextEditingController();
  addTearDown(c.dispose);
  final List<String> changes = <String>[];

  await tester.pumpWidget(buildTestApp(Builder(
    builder: (BuildContext ctx) => ElevatedButton(
      onPressed: () => showGamepadKeyboard(ctx, c, onChanged: changes.add),
      child: const Text('open'),
    ),
  )));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();

  await tester.tap(find.text('q'));
  await tester.pump();
  expect(changes.last, 'q');

  await tester.tap(find.byIcon(Icons.content_paste_outlined));
  await tester.pumpAndSettle();
  expect(c.text, 'qPV');
  expect(changes.last, 'qPV');
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/widgets/hibiki_gamepad_keyboard_test.dart --no-pub`
Expected: FAIL（`onPaste` 参数不存在 / 无粘贴图标 / `onChanged` 参数不存在）

- [ ] **Step 3: 实现**

3a. `HibikiGamepadKeyboard` 加字段（在 `onSubmit` 之后）：

```dart
  /// Pressed the 📋 (paste) key, if provided.
  final VoidCallback? onPaste;
```

并在构造器参数列表加 `this.onPaste,`（放在 `this.onSubmit,` 之后)。

3b. 控制行加粘贴键(在 `_layerKeyLabel` 键之后、`␣` 之前)：

```dart
              _KbKey(label: _layerKeyLabel, onPress: _cycleLayer, flex: 2),
              if (widget.onPaste != null)
                _KbKey(
                  label: 'paste',
                  icon: Icons.content_paste_outlined,
                  tooltip: t.paste,
                  onPress: widget.onPaste!,
                  flex: 2,
                ),
              _KbKey(label: '␣', onPress: () => widget.onChar(' '), flex: 4),
```

3c. `_KbKey` 加可选 `icon` / `tooltip`,渲染分流：

```dart
class _KbKey extends StatefulWidget {
  const _KbKey({
    required this.label,
    required this.onPress,
    this.flex = 1,
    this.icon,
    this.tooltip,
  });

  final String label;
  final VoidCallback onPress;
  final int flex;
  final IconData? icon;
  final String? tooltip;
  ...
}
```

在 `_KbKeyState.build` 里把 `child: Text(...)` 那段换成：

```dart
            child: widget.icon != null
                ? Icon(widget.icon, size: 20, color: colors.onSurface)
                : Text(
                    widget.label,
                    style: tokens.type.controlLabel
                        .copyWith(color: colors.onSurface),
                  ),
```

并把整个 `key` widget 在有 tooltip 时套一层 `Tooltip`（在 `final Widget key = Padding(...)` 之后)：

```dart
    final Widget tipped =
        widget.tooltip == null ? key : Tooltip(message: widget.tooltip!, child: key);
```

随后 `_focusable` 分支里把原先用 `key` 的地方改用 `tipped`（`maybeControllerOf == null ? tipped : Actions(... child: HibikiFocusTarget(id: _focusId, child: tipped))`),`Expanded(flex: widget.flex, child: focusable)` 不变。

3d. 文件顶部加 i18n 导入：

```dart
import 'package:hibiki/i18n/strings.g.dart';
```

3e. `showGamepadKeyboard` 加 `onChanged` 并在每次改 controller 后回调：

```dart
Future<void> showGamepadKeyboard(
  BuildContext context,
  TextEditingController controller, {
  ValueChanged<String>? onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (BuildContext ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: HibikiGamepadKeyboard(
          onChar: (String ch) {
            gamepadKeyboardInsert(controller, ch);
            onChanged?.call(controller.text);
          },
          onBackspace: () {
            gamepadKeyboardBackspace(controller);
            onChanged?.call(controller.text);
          },
          onPaste: () async {
            if (await gamepadKeyboardPaste(controller)) {
              onChanged?.call(controller.text);
            }
          },
          onSubmit: () => Navigator.of(ctx).maybePop(),
        ),
      ),
    ),
  );
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/widgets/hibiki_gamepad_keyboard_test.dart --no-pub`
Expected: PASS（含原有 4 个 keyboard 测试 + 6 个 wiring 测试 + 新增)

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/utils/components/hibiki_gamepad_keyboard.dart hibiki/test/widgets/hibiki_gamepad_keyboard_test.dart
git commit -m "feat(keyboard): paste key in on-screen keyboard + onChanged propagation"
```

---

## Task 3: 移动端文本框粘贴按钮 + onChanged 透传

**Files:**
- Modify: `hibiki/lib/src/utils/components/hibiki_material_components.dart`
- Test: `hibiki/test/widgets/hibiki_text_field_keyboard_test.dart`
- Test(更新): `hibiki/test/widgets/hibiki_material_components_test.dart`

- [ ] **Step 1: 写失败测试**（`hibiki_text_field_keyboard_test.dart`,顶部加 `import 'package:flutter/services.dart';`）

```dart
testWidgets('mobile + controller shows a one-tap paste button',
    (WidgetTester tester) async {
  final TextEditingController c = TextEditingController();
  addTearDown(c.dispose);
  await tester.pumpWidget(buildTestApp(
    HibikiTextField(controller: c),
    theme: ThemeData(useMaterial3: true, platform: TargetPlatform.android),
  ));
  await tester.pump();
  expect(find.byIcon(Icons.content_paste_outlined), findsOneWidget);
  expect(find.byIcon(Icons.keyboard_outlined), findsNothing,
      reason: 'mobile uses the system IME, not the on-screen keyboard');
});

testWidgets('desktop shows the keyboard button, not paste',
    (WidgetTester tester) async {
  final TextEditingController c = TextEditingController();
  addTearDown(c.dispose);
  await tester.pumpWidget(buildTestApp(
    HibikiTextField(controller: c),
    theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
  ));
  await tester.pump();
  expect(find.byIcon(Icons.keyboard_outlined), findsOneWidget);
  expect(find.byIcon(Icons.content_paste_outlined), findsNothing);
});

testWidgets('mobile paste button inserts clipboard text and fires onChanged',
    (WidgetTester tester) async {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (MethodCall call) async => call.method == 'Clipboard.getData'
        ? <String, dynamic>{'text': 'hi'}
        : null,
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));
  final TextEditingController c = TextEditingController(text: 'a');
  addTearDown(c.dispose);
  c.selection = const TextSelection.collapsed(offset: 1);
  final List<String> changes = <String>[];
  await tester.pumpWidget(buildTestApp(
    HibikiTextField(controller: c, onChanged: changes.add),
    theme: ThemeData(useMaterial3: true, platform: TargetPlatform.android),
  ));
  await tester.pump();
  await tester.tap(find.byIcon(Icons.content_paste_outlined));
  await tester.pumpAndSettle();
  expect(c.text, 'ahi');
  expect(changes.last, 'ahi');
});

testWidgets('mobile no-controller shows no paste button',
    (WidgetTester tester) async {
  await tester.pumpWidget(buildTestApp(
    const HibikiTextField(initialValue: 'x'),
    theme: ThemeData(useMaterial3: true, platform: TargetPlatform.android),
  ));
  await tester.pump();
  expect(find.byIcon(Icons.content_paste_outlined), findsNothing);
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/widgets/hibiki_text_field_keyboard_test.dart --no-pub`
Expected: FAIL（移动端不显示 `content_paste_outlined`）

- [ ] **Step 3: 实现**（`hibiki_material_components.dart`)

3a. 重写 helper（重命名 `_hibikiTextFieldKeyboardSuffix` → `_hibikiTextFieldInputSuffix`,加 `onChanged`)：

```dart
/// The input-assist suffix icon for a text field. On desktop (no system IME)
/// it opens the on-screen [showGamepadKeyboard]; on mobile it offers one-tap
/// clipboard paste (the system IME handles typing, but paste otherwise needs a
/// long-press). [onChanged] is fired after a programmatic edit so reactive
/// fields (e.g. search-as-you-type) update — Flutter does not fire onChanged on
/// programmatic controller mutations.
Widget? _hibikiTextFieldInputSuffix({
  required BuildContext context,
  required TextEditingController? controller,
  ValueChanged<String>? onChanged,
}) {
  if (controller == null) return null;
  final TargetPlatform platform = Theme.of(context).platform;
  final bool isDesktop = platform == TargetPlatform.windows ||
      platform == TargetPlatform.linux ||
      platform == TargetPlatform.macOS;
  if (isDesktop) {
    return HibikiIconButton(
      icon: Icons.keyboard_outlined,
      tooltip: t.on_screen_keyboard,
      onTap: () => showGamepadKeyboard(context, controller, onChanged: onChanged),
    );
  }
  return HibikiIconButton(
    icon: Icons.content_paste_outlined,
    tooltip: t.paste,
    onTap: () async {
      if (await gamepadKeyboardPaste(controller)) {
        onChanged?.call(controller.text);
      }
    },
  );
}
```

3b. 4 处调用点改名 + 透传 onChanged：
- `HibikiSearchField`(`:288`)：`_hibikiTextFieldInputSuffix(context: context, controller: controller, onChanged: onChanged)`
- `HibikiTextField`(`:390`)：`_hibikiTextFieldInputSuffix(context: context, controller: widget.readOnly ? null : widget.controller, onChanged: widget.onChanged)`
- `HibikiEditorPanel`(`:1826`)：`_hibikiTextFieldInputSuffix(context: context, controller: controller)`（无 onChanged）
- `HibikiCompactSearchRow`(`:1911`)：`_hibikiTextFieldInputSuffix(context: context, controller: controller)`（无 onChanged，submit 驱动)

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/widgets/hibiki_text_field_keyboard_test.dart --no-pub`
Expected: PASS（原 4 个断言仍绿——它们查 `keyboard_outlined`,不受粘贴键影响)

- [ ] **Step 5: 更新 CompactSearchRow 焦点测试**（`hibiki_material_components_test.dart:577`,android 默认平台现多了粘贴键 → 行序变 `[关闭][TextField][粘贴][搜索]`)

把"`move(right)` 一次后激活=搜索"改为先到粘贴键、再右移到搜索键：

```dart
    // close → (right) paste → (right) search
    expect(controller.move(HibikiFocusDirection.right), isTrue);
    await tester.pump();
    // landed on the new paste affordance; advance to the search button.
    expect(controller.move(HibikiFocusDirection.right), isTrue);
    await tester.pump();
    Actions.maybeInvoke<ActivateIntent>(
      controller.activeContext!,
      const ActivateIntent(),
    );
    await tester.pump();
    expect(submitted, 'term');
```

- [ ] **Step 6: 跑两个文件确认通过**

Run: `flutter test test/widgets/hibiki_text_field_keyboard_test.dart test/widgets/hibiki_material_components_test.dart --no-pub`
Expected: PASS

- [ ] **Step 7: 提交**

```bash
git add hibiki/lib/src/utils/components/hibiki_material_components.dart hibiki/test/widgets/hibiki_text_field_keyboard_test.dart hibiki/test/widgets/hibiki_material_components_test.dart
git commit -m "feat(textfield): mobile one-tap paste button + onChanged threading"
```

---

## Task 4: 全量验证 + triage

**Files:** 视失败情况而定（仅限因新粘贴键真实改变焦点序/图标计数的 android 默认平台测试)

- [ ] **Step 1: 格式化**

Run: `dart format .`（在 `hibiki/` 下)

- [ ] **Step 2: 静态分析**

Run: `flutter analyze`
Expected: No issues（注意 `() => Future` fire-and-forget 与既有 `showGamepadKeyboard`/`onSubmit` 同模式,不应有新 lint)

- [ ] **Step 3: 全量测试**

Run: `flutter test --no-pub`
Expected: PASS。若有失败,**仅允许**修「因新增粘贴键真实改变了 android 默认平台下焦点遍历顺序/图标计数」的测试,改法是把期望更新为包含粘贴键(同 Task 3 Step 5)。每个被改测试在提交信息里写明原因。**禁止**为了过测试去掩盖真实行为(如给粘贴键禁用焦点注册来骗过计数)。

- [ ] **Step 4: 提交（如有 triage 改动)**

```bash
git add <仅本轮 triage 的测试文件>
git commit -m "test: account for new paste affordance in focus-order assertions"
```

---

## Task 5: 代码审查 + 收尾

- [ ] **Step 1: code review**：spawn code-reviewer subagent，**显式 `model: "opus"`**，审实现是否符合本计划、边界(空剪贴板/选区/多字符/平台分流)、向后兼容(桌面键盘行为不变、移动端原断言)、onChanged 根因修复是否到位无特殊情况。
- [ ] **Step 2:** 按审查结果修复并复测(`flutter test --no-pub`)。
- [ ] **Step 3:** `git status --short`,只 stage 本轮文件,`git diff --cached --check`,提交;回复给出提交哈希与仍存在的无关未提交改动。

---

## 验证策略与说明

- 纯 Flutter 组件,widget + mock clipboard 单测完整覆盖行为路径;无新 i18n key;无真机依赖。按 `hibiki/CLAUDE.md`「验证」节,Dart 改动跑 `dart format .` + `flutter test` 即可,无需 Android release 构建或真机复测。
- 根因修复说明:粘贴/屏幕键盘输入直接改 `controller.value` 本不触发 `onChanged`;本计划在调用层(showGamepadKeyboard 的 char/backspace/paste、移动端粘贴按钮)统一回调 onChanged,**让"打字/退格/粘贴"行为一致**,无特殊分支。无 onChanged 的组件(EditorPanel/CompactSearchRow)维持其既有 submit/外部读取语义。
- 向后兼容:桌面端 suffix 仍是键盘按钮(图标/tooltip 不变);移动端此前无 suffix,新增粘贴键属新增可达控件,焦点测试更新为如实反映。
```