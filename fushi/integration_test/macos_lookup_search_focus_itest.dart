import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/home_page.dart'
    show HomePage, HomeTab;
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/library_fixture.dart' show readyAppModel, seedDictionary;
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// BUG-3131 macOS 真机取证：查词页手动输入框「查到词就退出输入框、打不了字，
/// 清空后再触发一次」。
///
/// 输入不走 tester 合成事件，全部经 macOS Runner 的 `app.fushi.test/input` 钩子
/// （`FUSHI_TEST_INPUT` 门控）：
///   - 真 keyDown/keyUp NSEvent（`NSApp.postEvent` → sendEvent → first responder
///     → FlutterKeyboardManager → FlutterTextInputPlugin）；
///   - 组字走 `imeMarked` / `imeCommit`：对**第一响应者的 inputContext.client**
///     调 `setMarkedText` / `insertText`，与 IMK 输入法回调 client 的入口一致
///     （ssh 会话里投递的合成键事件 IMK 输入法不接，见 BUG-3131 记录）。
/// 每一步记下窗口 first responder、Flutter primaryFocus、结果区证据与 WKWebView
/// 数，并以「下一次输入真的进了输入框」为判据。
///
/// 覆盖两种窗口宽度（`WIN_W`，0 = 默认宽屏主从；560 = 窄屏单栏）与带查词历史的
/// 真实用户形态（先回车提交两次）。
///
/// Run（在 Mac 上、可见窗口、显示器唤醒）：
///   FUSHI_TEST_INPUT=1 FUSHI_TEST_ROOT=$HOME/dev/fushi-test-root-mlif \
///     flutter test integration_test/macos_lookup_search_focus_itest.dart -d macos \
///     --no-pub --dart-define=FUSHI_TEST_ROOT=$HOME/dev/fushi-test-root-mlif \
///     [--dart-define=WIN_W=560]

const MethodChannel _input = MethodChannel('app.fushi.test/input');
const Key _kField = ValueKey<String>('home_dictionary_search_field');
const Key _kEvidence = ValueKey<String>('home_dictionary_result_evidence');
const int _kWindowWidth = int.fromEnvironment('WIN_W');

// macOS 虚拟键码（Carbon kVK_*）。
const Map<String, int> _kVk = <String, int>{
  'd': 2,
  'e': 14,
  'o': 31,
  'r': 15,
  's': 1,
  't': 17,
  'w': 13,
};
const int _kVkReturn = 36;
const int _kVkDelete = 51;

Future<Map<Object?, Object?>> _call(
  String method, [
  Map<String, Object?> args = const <String, Object?>{},
]) async {
  final dynamic raw = await _input.invokeMethod<dynamic>(method, args);
  return (raw as Map<Object?, Object?>).cast<Object?, Object?>();
}

Future<Map<Object?, Object?>> _key(int keyCode, String chars) =>
    _call('key', <String, Object?>{'keyCode': keyCode, 'chars': chars});

Future<void> _settle(WidgetTester tester, [int quarters = 8]) async {
  for (int i = 0; i < quarters; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

String _fieldText(WidgetTester tester) {
  final Finder editable = find.descendant(
    of: find.byKey(_kField),
    matching: find.byType(EditableText),
  );
  return tester.widget<EditableText>(editable.first).controller.text;
}

/// 当前窗口 first responder 的类名（`FlutterTextInputPlugin` = 输入框在收字）。
Future<String> _snapshot(WidgetTester tester, String label) async {
  final Map<Object?, Object?> act = await _call('activate');
  final String views = ((await _call('dumpViews'))['views'] ?? '').toString();
  final int webViews = RegExp(
    'InAppWebView|WKWebView',
  ).allMatches(views).length;
  debugPrint(
    '[mac-lookup-focus] $label text="${_fieldText(tester)}" '
    'firstResponder=${act['firstResponder']} '
    'primaryFocus=${FocusManager.instance.primaryFocus} '
    'evidence=${find.byKey(_kEvidence).evaluate().length} '
    'webviews=$webViews',
  );
  return act['firstResponder']! as String;
}

Future<void> _typeWord(WidgetTester tester, String word) async {
  for (final String ch in word.split('')) {
    await _key(_kVk[ch]!, ch);
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _deleteAll(WidgetTester tester, int count) async {
  for (int i = 0; i < count; i++) {
    await _key(_kVkDelete, '\u{7f}');
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<Map<Object?, Object?>> _ime(
  WidgetTester tester,
  String method,
  String text,
) async {
  final Map<Object?, Object?> r = await _call(method, <String, Object?>{
    'text': text,
  });
  await tester.pump(const Duration(milliseconds: 120));
  debugPrint(
    '[mac-lookup-focus] $method("$text") -> $r '
    'field="${_fieldText(tester)}"',
  );
  return r;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'BUG-3131: macOS lookup search field keeps keyboard input when results '
    'arrive and after clearing',
    timeout: const Timeout(Duration(minutes: 12)),
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'mac-lookup-focus',
        body: () async {
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue);
          await readyAppModel(tester);
          expect(await seedDictionary(tester), isTrue);
          HomePage.debugSelectTab!(HomeTab.dictionaries);
          await _settle(tester, 4);
          expect(find.byKey(_kField), findsWidgets);
          await _drive(tester);
        },
      );
    },
  );
}

Future<void> _drive(WidgetTester tester) async {
  void logFocus() => debugPrint(
    '[mac-lookup-focus] focus -> ${FocusManager.instance.primaryFocus}',
  );
  FocusManager.instance.addListener(logFocus);
  addTearDown(() => FocusManager.instance.removeListener(logFocus));

  await _call('activate');
  await tester.pump(const Duration(milliseconds: 800));
  if (_kWindowWidth > 0) {
    await _call('resize', <String, Object?>{
      'w': _kWindowWidth.toDouble(),
      'h': 820.0,
    });
    await _settle(tester, 6);
  }

  // 进入输入框：与「点一下输入框」同义的 requestKeyboard（合成点击会被
  // desktop_drop 的整窗 DropTarget 截走，见记忆 mac-test-input-hook）。
  final EditableTextState editable = tester.state<EditableTextState>(
    find
        .descendant(
          of: find.byKey(_kField),
          matching: find.byType(EditableText),
        )
        .first,
  );
  editable.requestKeyboard();
  await tester.pump(const Duration(milliseconds: 800));
  final String fr0 = await _snapshot(tester, 'focused');
  expect(fr0, 'FlutterTextInputPlugin', reason: '前置：输入框必须真的在收字');

  // 真实用户形态：先回车提交两次写出查词历史（历史列表 / 最近搜索不为空）。
  for (int i = 0; i < 2; i++) {
    await _typeWord(tester, 'testword');
    await tester.pump(const Duration(milliseconds: 400));
    await _key(_kVkReturn, '\r');
    await _settle(tester);
    await _deleteAll(tester, 10);
    await _settle(tester);
  }
  expect(_fieldText(tester), isEmpty);

  // ① 真键：查到词 → 下一个键仍进输入框。
  await _typeWord(tester, 'testword');
  await _settle(tester, 12);
  expect(find.byKey(_kEvidence), findsOneWidget, reason: '必须真的查到词');
  expect(await _snapshot(tester, 'results-shown'), 'FlutterTextInputPlugin');
  await _key(_kVk['s']!, 's');
  await tester.pump(const Duration(milliseconds: 600));
  expect(_fieldText(tester), 'testwords', reason: '结果出现后下一个键必须进输入框');

  // ② 真键：删光 → 再打仍进输入框。
  await _deleteAll(tester, 12);
  await _settle(tester);
  expect(await _snapshot(tester, 'cleared'), 'FlutterTextInputPlugin');
  await _typeWord(tester, 'testword');
  await _settle(tester, 12);
  expect(_fieldText(tester), 'testword', reason: '清空后重打必须进输入框');
  await _deleteAll(tester, 12);
  await _settle(tester);

  // ③ 组字：结果在组字中途出现，后续组字 / 上屏仍落在输入框；清空后再来一轮。
  for (int round = 0; round < 2; round++) {
    for (final String step in <String>['n', 'ね', 'ねk', 'ねこ']) {
      final Map<Object?, Object?> r = await _ime(tester, 'imeMarked', step);
      expect(r['ok'], isTrue, reason: '组字时第一响应者必须是文本 client');
    }
    await _settle(tester);
    expect(find.byKey(_kEvidence), findsOneWidget, reason: '组字中途就要查到词');
    expect(
      await _snapshot(tester, 'ime-results-$round'),
      'FlutterTextInputPlugin',
    );
    expect((await _ime(tester, 'imeMarked', 'ねこが'))['ok'], isTrue);
    expect((await _ime(tester, 'imeCommit', '猫が'))['ok'], isTrue);
    await _settle(tester);
    expect(_fieldText(tester), '猫が', reason: '结果出现后的组字与上屏必须进输入框');
    await _deleteAll(tester, 4);
    await _settle(tester);
    expect(
      await _snapshot(tester, 'ime-cleared-$round'),
      'FlutterTextInputPlugin',
    );
    expect(_fieldText(tester), isEmpty);
  }
}
