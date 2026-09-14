import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/lookup_ime_channel.dart';
import 'package:integration_test/integration_test.dart';

/// 桌面端（Windows / macOS）：查词输入法语言**真的**切了系统输入法，并且能还原。
///
/// 读的是系统自己的返回值（Windows `GetKeyboardLayout` / macOS
/// `TISCopyCurrentKeyboardInputSource`）——不是「我们调用了 API」而是「系统状态
/// 确实变了」。还原那一半同样重要：两端切的都是**系统全局**状态，漏掉还原，用户
/// 切到别的应用打字就会发现自己在打日语。
///
/// 两端的 probe 形状是统一的（语言标签而非平台原生标识），所以这一份测试两端都能跑：
///   Windows: fushi/tool/run_windows_itest.ps1 integration_test/lookup_ime_switch_itest.dart
///   macOS:   tool/run_mac_itest.ps1 integration_test/lookup_ime_switch_itest.dart
///
/// 前提：机器上启用了日语输入法。没启用的话第一个断言会明确说清楚，而不是静悄悄
/// 跳过——「跳过」和「通过」在这种测试里差别太大。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  List<String> stringsOf(Object? value) =>
      (value as List<Object?>? ?? const <Object?>[]).whereType<String>().toList(
            growable: false,
          );

  bool isJapanese(String tag) => tag == 'ja' || tag.startsWith('ja-');

  testWidgets('切到日语再还原，系统输入源跟着变', (WidgetTester tester) async {
    final Map<String, Object?>? before = await LookupImeChannel.probe();
    expect(
      before,
      isNotNull,
      reason: '原生侧没有实现这个 channel——这条测试只能在 Windows / macOS 真 app 上跑',
    );

    final List<String> enabled = stringsOf(before!['enabledLanguages']);
    if (!enabled.any(isJapanese)) {
      fail(
        '本机没启用日语输入法（enabledLanguages=$enabled）——'
        '先在系统里加日语输入法再跑，否则这条测试证明不了任何事',
      );
    }

    final List<String> original = stringsOf(before['currentLanguages']);
    addTearDown(() async {
      // 测试中途失败也要把用户的输入源放回去。
      await LookupImeChannel.setLanguage(null);
      await tester.pump(const Duration(milliseconds: 400));
    });

    await LookupImeChannel.setLanguage('ja');
    await tester.pump(const Duration(milliseconds: 600));

    final Map<String, Object?>? switched = await LookupImeChannel.probe();
    expect(
      stringsOf(switched!['currentLanguages']).any(isJapanese),
      isTrue,
      reason: '设了日语，但当前输入源没变——切换没真正落地'
          '（沙盒下 TISSelectInputSource 有「图标变了实际没切」的已知问题）',
    );
    expect(switched['active'], isTrue);

    await LookupImeChannel.setLanguage(null);
    await tester.pump(const Duration(milliseconds: 600));

    final Map<String, Object?>? restored = await LookupImeChannel.probe();
    expect(
      stringsOf(restored!['currentLanguages']),
      original,
      reason: '没还原到用户原来的输入源——这会漏到用户的其它 app 里',
    );
    expect(restored['active'], isFalse);
  });

  testWidgets('没装/没启用的语言：什么都不做，不替用户装', (WidgetTester tester) async {
    final Map<String, Object?>? before = await LookupImeChannel.probe();
    expect(before, isNotNull);
    final List<String> original = stringsOf(before!['currentLanguages']);
    final List<String> enabled = stringsOf(before['enabledLanguages']);

    // 泰语——本机几乎不会启用，正好当「没启用」的样本；万一启用了就跳过。
    if (enabled.any((String tag) => tag == 'th' || tag.startsWith('th-'))) {
      return;
    }

    await LookupImeChannel.setLanguage('th');
    await tester.pump(const Duration(milliseconds: 600));

    final Map<String, Object?>? after = await LookupImeChannel.probe();
    expect(
      stringsOf(after!['currentLanguages']),
      original,
      reason: '没启用泰语输入法时不该动用户的输入源',
    );
    expect(after['active'], isFalse, reason: '没切成功就不该进入 active 状态');
  });
}
