import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/shortcuts/global_navigation.dart'
    show readDesktopWindowFullscreen, setDesktopWindowFullscreen;
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';

import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, readyAppModel, seedReaderBook;
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// BUG-2948 macOS 真机取证：快捷键「无法识别」。
///
/// 输入经 macOS Runner 的 `app.fushi.test/input` 钩子（`FUSHI_TEST_INPUT` 门控）投
/// **真实 keyDown/keyUp NSEvent**（`NSApp.postEvent` → sendEvent → key equivalent /
/// 菜单 → first responder 的真实派发链），不走 `tester` 合成事件。
///
/// 2026-10-04 Mac（macOS 27.0）实测事实：Cmd / Option / Ctrl 组合都能到达 Flutter，
/// 菜单栏（Cmd+F/H/M/W/,）不抢键；但 Shift+符号键的逻辑键是**该修饰下产出的字符**
/// （Shift+/ → `question`、Shift+[ → `braceLeft`），与 Windows（`slash` /
/// `bracketLeft`）不同。
///
/// 证据：
///   ① 阅读器菜单改绑 Shift+/ → 真 NSEvent Shift+/ 打开外观面板（修复前不响应）；
///   ② macOS 新默认 Ctrl+Cmd+F → 窗口真进全屏、再按退出；
///   ③ macOS 新默认 Option+Space → 真事件解析到 audiobookPlayPause。
///
/// Run（在 Mac 上、可见窗口）：
///   FUSHI_TEST_INPUT=1 FUSHI_TEST_ROOT=$HOME/dev/fushi-test-root \
///     flutter test integration_test/macos_keyboard_shortcuts_itest.dart -d macos \
///     --no-pub --dart-define=FUSHI_TEST_ROOT=$HOME/dev/fushi-test-root

const MethodChannel _input = MethodChannel('app.fushi.test/input');
const Key _kWebViewKey = ValueKey<String>('fushi_webview');
const Key _kContentReadyKey = ValueKey<String>('fushi_content_ready');

// macOS 虚拟键码（Carbon kVK_*）。
const int _kVkSlash = 44;
const int _kVkF = 3;
const int _kVkSpace = 49;
const int _kVkEscape = 53;

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready,
  String label, {
  int maxPolls = 120,
}) async {
  for (int i = 0; i < maxPolls; i++) {
    if (ready()) return;
    await tester.pump(const Duration(milliseconds: 500));
  }
  fail('timed out waiting for $label');
}

Future<Map<Object?, Object?>> _call(
  String method, [
  Map<String, Object?> args = const <String, Object?>{},
]) async {
  final dynamic raw = await _input.invokeMethod<dynamic>(method, args);
  return (raw as Map).cast<Object?, Object?>();
}

Future<Map<Object?, Object?>> _key(
  int keyCode,
  String chars, {
  String? ignoring,
  bool cmd = false,
  bool shift = false,
  bool alt = false,
  bool ctrl = false,
}) =>
    _call('key', <String, Object?>{
      'keyCode': keyCode,
      'chars': chars,
      if (ignoring != null) 'ignoring': ignoring,
      'cmd': cmd,
      'shift': shift,
      'alt': alt,
      'ctrl': ctrl,
    });

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'BUG-2948: macOS shortcuts via real NSEvents',
    timeout: const Timeout(Duration(minutes: 12)),
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'mac-shortcuts',
        body: () async {
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue);
          await tester.pump(const Duration(seconds: 2));
          final String bookKey = await seedReaderBook(
            tester,
            fileName: 'bug2933_mac_shortcuts.epub',
          );
          await openBookViaProductionPath(tester, bookKey);
          await _waitFor(
            tester,
            () => find.byKey(_kWebViewKey).evaluate().isNotEmpty,
            'reader WebView',
          );
          await _waitFor(
            tester,
            () => find.byKey(_kContentReadyKey).evaluate().isNotEmpty,
            'reader content',
          );
          await tester.pump(const Duration(seconds: 2));
          await _drive(tester, await readyAppModel(tester));
        },
      );
    },
  );
}

Future<void> _drive(WidgetTester tester, AppModel appModel) async {
  // 记录 Flutter 侧真实收到的事件（不吞，事件照常进页面）。
  final List<KeyEvent> downs = <KeyEvent>[];
  final List<Set<ModifierKey>> downMods = <Set<ModifierKey>>[];
  bool record(KeyEvent e) {
    if (e is KeyDownEvent) {
      downs.add(e);
      // handler 在 HardwareKeyboard 更新完按下集之后才被调用，此刻即事件时刻的修饰键。
      downMods.add(activeModifierKeys());
    }
    return false;
  }

  HardwareKeyboard.instance.addHandler(record);
  addTearDown(() => HardwareKeyboard.instance.removeHandler(record));

  await _call('activate');
  await tester.pump(const Duration(milliseconds: 800));
  final Map<Object?, Object?> act = await _call('activate');
  debugPrint('[mac-shortcuts] activate=$act');
  expect(act['isKey'], isTrue, reason: '窗口必须是 key window，键盘事件才进得来');

  // ── ① Shift+/ 改绑阅读器菜单 ────────────────────────────────────
  const InputBinding shiftSlash = InputBinding(
    key: LogicalKeyboardKey.slash,
    modifiers: <ModifierKey>{ModifierKey.shift},
  );
  final ShortcutBindingSet menuBefore =
      appModel.shortcutRegistry.bindingsFor(ShortcutAction.readerOpenMenu);
  appModel.shortcutRegistry.updateBindingWithReassignments(
    ShortcutAction.readerOpenMenu,
    menuBefore.copyWith(
      keyboardBindings: <InputBinding>[shiftSlash],
    ),
    removeKeyboardConflicts: <InputBinding>[shiftSlash],
  );
  addTearDown(() => appModel.shortcutRegistry
      .updateBinding(ShortcutAction.readerOpenMenu, menuBefore));
  await tester.pump(const Duration(milliseconds: 300));

  final int barriersBefore = find.byType(ModalBarrier).evaluate().length;
  downs.clear();
  await _key(_kVkSlash, '?', ignoring: '?', shift: true);
  bool sheetOpened = false;
  for (int i = 0; i < 20 && !sheetOpened; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    sheetOpened = find.byType(ModalBarrier).evaluate().length > barriersBefore;
  }
  final KeyEvent slashEvent = downs.lastWhere(
    (KeyEvent e) => e.physicalKey == PhysicalKeyboardKey.slash,
  );
  debugPrint(
      '[mac-shortcuts] ① Shift+/ logical=${slashEvent.logicalKey.debugName} '
      'physical=${slashEvent.physicalKey.debugName} sheetOpened=$sheetOpened');
  expect(sheetOpened, isTrue,
      reason: '绑定 Shift+/ 的阅读器菜单必须被真实 Shift+/ 打开'
          '（macOS 逻辑键 ${slashEvent.logicalKey.debugName}）');
  await _key(_kVkEscape, '\u{1b}');
  for (int i = 0;
      i < 20 && find.byType(ModalBarrier).evaluate().length > barriersBefore;
      i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }

  // ── ③ Option+Space → audiobookPlayPause（macOS 新默认）──────────
  // 退出全屏的动画会让窗口暂时交出 key 状态，重新拿回来再投键。
  final Map<Object?, Object?> act3 = await _call('activate');
  await tester.pump(const Duration(milliseconds: 500));
  debugPrint('[mac-shortcuts] ③ activate=$act3');
  downs.clear();
  downMods.clear();
  final Map<Object?, Object?> spaceResult =
      await _key(_kVkSpace, ' ', ignoring: ' ', alt: true);
  await tester.pump(const Duration(milliseconds: 400));
  debugPrint('[mac-shortcuts] ③ post=$spaceResult flutterSaw='
      '${downs.map((KeyEvent e) => '${e.logicalKey.debugName}/${e.physicalKey.debugName}').toList()}');
  final int spaceAt = downs.lastIndexWhere(
    (KeyEvent e) => e.physicalKey == PhysicalKeyboardKey.space,
  );
  expect(spaceAt, isNonNegative, reason: 'Option+Space 必须到达 Flutter');
  final KeyEvent space = downs[spaceAt];
  final ShortcutAction? resolved = appModel.shortcutRegistry.resolveKeyboard(
    space.logicalKey,
    modifiers: downMods[spaceAt],
    scope: ShortcutScope.audiobook,
    physicalKey: space.physicalKey,
  );
  debugPrint(
      '[mac-shortcuts] ③ Option+Space logical=${space.logicalKey.debugName} '
      'mods=${downMods[spaceAt]} resolved=$resolved');
  expect(resolved, ShortcutAction.audiobookPlayPause);

  // ── ② Ctrl+Cmd+F 切窗口全屏（macOS 新默认）──────────────────────
  expect(await readDesktopWindowFullscreen(), isFalse, reason: '起点非全屏');
  try {
    await _key(_kVkF, 'f', ignoring: 'f', cmd: true, ctrl: true);
    bool? full = false;
    for (int i = 0; i < 24 && full != true; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      full = await readDesktopWindowFullscreen();
    }
    debugPrint('[mac-shortcuts] ② Ctrl+Cmd+F fullscreen=$full');
    expect(full, isTrue, reason: 'Ctrl+Cmd+F 必须让窗口进全屏');
    // macOS 全屏动画结束前再切会被系统忽略。
    await tester.pump(const Duration(seconds: 2));
    await _key(_kVkF, 'f', ignoring: 'f', cmd: true, ctrl: true);
    for (int i = 0; i < 24 && full != false; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      full = await readDesktopWindowFullscreen();
    }
    debugPrint('[mac-shortcuts] ② again fullscreen=$full');
    expect(full, isFalse, reason: '再按 Ctrl+Cmd+F 必须退出全屏');
  } finally {
    if (await readDesktopWindowFullscreen() == true) {
      await setDesktopWindowFullscreen(false);
      await tester.pump(const Duration(seconds: 2));
    }
  }
}
