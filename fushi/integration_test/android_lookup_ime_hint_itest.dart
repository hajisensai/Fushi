import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/lookup_ime_language.dart';
import 'package:fushi/src/pages/implementations/popup_dictionary_page.dart';
import 'package:integration_test/integration_test.dart';

/// Android：查词输入框真的把输入法语言提示交给了输入法系统。
///
/// Android 不让应用切换系统输入法，应用侧的上限就是 `EditorInfo.hintLocales`
/// 这个**提示**（API 24+）。所以这条测试验的是「契约到达」而不是「键盘变了」：
///
///   1. 组件层——生产组件 [PopupDictionarySearchBar] 收下的值一路到 [EditableText]；
///   2. 系统层——聚焦后 `adb shell dumpsys input_method` 里当前 EditorInfo 的
///      hintLocales 必须是 `[ja]`。这一步这条测试自己看不到（它在 app 进程里），
///      带 `--dart-define=FUSHI_IME_HOLD_SECONDS=N` 跑，测试会把键盘停在屏幕上，
///      外面 dumpsys + screencap 取证。
///
/// 键盘**切不切**是 Gboard 的自由（它可能切、可能只把该语言排前、也可能忽略），
/// 那一层只能看截图，不该写成断言——写了就是拿别人的实现细节当自己的契约。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('查词框聚焦后把 ja 交给输入法系统', (WidgetTester tester) async {
    final TextEditingController controller = TextEditingController();
    final FocusNode focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PopupDictionarySearchBar(
            controller: controller,
            focusNode: focusNode,
            onSubmit: (_) {},
            // 走生产路径算出来的值，而不是测试里手写一个 Locale。
            hintLocales: lookupImeHintLocalesOf('ja'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final EditableText editable = tester.widget<EditableText>(
      find.byType(EditableText),
    );
    expect(
        editable.hintLocales,
        <Locale>[
          const Locale('ja'),
        ],
        reason: '组件层就没传下去，后面 dumpsys 也不可能看到');

    focusNode.requestFocus();
    await tester.pumpAndSettle();
    // 软键盘是异步起来的，EditorInfo 要等 InputConnection 建立后才在 dumpsys 里。
    await Future<void>.delayed(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    const int holdSeconds = int.fromEnvironment('FUSHI_IME_HOLD_SECONDS');
    if (holdSeconds > 0) {
      debugPrint('[lookup-ime] holding keyboard on screen for ${holdSeconds}s');
      await Future<void>.delayed(Duration(seconds: holdSeconds));
    }
  });
}
