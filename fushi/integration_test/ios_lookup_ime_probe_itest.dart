import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/lookup_ime_channel.dart';
import 'package:integration_test/integration_test.dart';

/// iOS spike：override `FlutterTextInputView.textInputMode` 到底生不生效。
///
/// 这条测试只回答**一个**问题，因为后续所有 iOS 工作都压在它上面：
///   A. `resolveCount` 涨了没有 → 系统有没有来读我们的实现；
///   B. `lastResolved` 是不是日语 → 我们有没有找到并返回日语输入法。
///
/// A 与 B 的失败修法完全不同：A=0 说明 runtime 注入没挂上（类名/时机不对）；
/// A>0 但 B 空说明模拟器里根本没装日语键盘（`activeInputModes` 里没有）；
/// A>0、B=ja 而键盘仍是英文，才是 flutter#53614 说的「返回值被系统忽略」——那条路
/// 就走不通，只能退回「iOS 上用原生 UITextField 平台视图」的重路子。
///
/// 键盘**看起来**是不是日语，这条测试自己证明不了（那是像素的事），而这恰恰是
/// flutter#53614 所说「读了但返回值被忽略」与「真的采纳了」的唯一分界。带
/// `--dart-define=FUSHI_IME_HOLD_SECONDS=25` 跑，测试会在聚焦后把键盘停在屏幕上，
/// 期间从外面 `xcrun simctl io <udid> screenshot x.png` 抓一张对照即可。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS 输入法语言提示：属性被读取且解析出日语', (WidgetTester tester) async {
    await LookupImeChannel.setLanguage('ja');

    final Map<String, Object?>? before = await LookupImeChannel.probe();
    expect(before, isNotNull, reason: '原生侧没有实现这个 channel——iOS 以外的平台不该跑这条测试');
    debugPrint('[lookup-ime] probe before focus: $before');
    expect(
      before!['installed'],
      isTrue,
      reason: 'runtime 注入失败：FlutterTextInputView 找不到，或它自己已实现 textInputMode',
    );
    expect(
      before['activeInputModes'],
      isA<List<Object?>>(),
      reason: '拿不到已启用输入法列表就没法判断下面的失败属于哪一类',
    );

    final int baseline = (before['resolveCount'] as int?) ?? 0;

    final FocusNode focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TextField(focusNode: focusNode)),
      ),
    );
    await tester.pumpAndSettle();

    focusNode.requestFocus();
    await tester.pumpAndSettle();
    // 键盘是异步起来的，`textInputMode` 在 becomeFirstResponder 之前被读。
    await Future<void>.delayed(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    final Map<String, Object?>? after = await LookupImeChannel.probe();
    debugPrint('[lookup-ime] probe after focus: $after');
    expect(after, isNotNull);

    final int resolved = (after!['resolveCount'] as int?) ?? 0;
    expect(
      resolved,
      greaterThan(baseline),
      reason: 'A 失败：输入框拿到焦点了，系统却没来读 textInputMode——注入没生效',
    );

    final List<Object?> modes =
        (after['activeInputModes'] as List<Object?>?) ?? const <Object?>[];
    final bool japaneseInstalled = modes.any(
      (Object? mode) =>
          mode is String && (mode == 'ja' || mode.startsWith('ja-')),
    );
    if (!japaneseInstalled) {
      fail(
        '模拟器里没装日语键盘（activeInputModes=$modes）——先加日语键盘再跑，'
        '否则这条测试只能证明 A、证明不了 B',
      );
    }

    expect(
      after['lastResolved'],
      startsWith('ja'),
      reason: 'B 失败：日语键盘装着，我们却没把它返回出去',
    );

    // 给外部抓图留窗口：键盘上写的是「あいう」还是「ABC」，只有像素能回答。
    const int holdSeconds = int.fromEnvironment('FUSHI_IME_HOLD_SECONDS');
    if (holdSeconds > 0) {
      debugPrint('[lookup-ime] holding keyboard on screen for ${holdSeconds}s');
      await tester.pumpAndSettle();
      await Future<void>.delayed(Duration(seconds: holdSeconds));
    }
  });
}
