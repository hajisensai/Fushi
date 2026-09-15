import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/lookup_ime_binding.dart';
import 'package:fushi/src/lookup/lookup_ime_channel.dart';

/// 输入法语言绑定的行为契约。最要紧的是**还原**：桌面端切的是系统全局输入法，
/// 漏掉一次还原，用户去别的应用打字就会发现自己在打日语。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('app.fushi.reader/lookup_ime');
  late List<Object?> sent;
  late List<Object?> persisted;

  setUp(() {
    sent = <Object?>[];
    persisted = <Object?>[];
    LookupImeChannel.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'setLanguage') {
        sent.add(call.arguments);
      }
      if (call.method == 'persistLanguage') {
        persisted.add(call.arguments);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('attach 立刻告知语言——iOS 要在任何聚焦之前就设好', () async {
    final LookupImeBinding binding = LookupImeBinding(languageOf: () => 'ja');
    binding.attach();
    await Future<void>.delayed(Duration.zero);
    expect(sent, <Object?>['ja']);
  });

  test('detach 必须还原，否则系统输入法留在我们切过去的语言上', () async {
    final LookupImeBinding binding = LookupImeBinding(languageOf: () => 'ja');
    binding.attach();
    await Future<void>.delayed(Duration.zero);
    binding.detach();
    await Future<void>.delayed(Duration.zero);
    expect(sent, <Object?>['ja', null]);
  });

  testWidgets('焦点离开查词框就还原，回来再设上', (WidgetTester tester) async {
    final FocusNode focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      Focus(focusNode: focusNode, child: const SizedBox.shrink()),
    );

    final LookupImeBinding binding = LookupImeBinding(languageOf: () => 'ja');
    binding.attach(focusNode: focusNode);
    await tester.pump();
    expect(sent, <Object?>['ja'], reason: 'attach 时先设上');

    focusNode.requestFocus();
    await tester.pump();
    expect(sent, <Object?>['ja'], reason: '已经是这个语言了，不该重复打扰系统');

    focusNode.unfocus();
    await tester.pump();
    expect(sent, <Object?>['ja', null], reason: '焦点离开查词框必须还原——桌面端切的是系统全局输入法');

    focusNode.requestFocus();
    await tester.pump();
    expect(sent, <Object?>['ja', null, 'ja'], reason: '回到查词框再设上');
  });

  test('未设置语言时发 null，不发空串', () async {
    final LookupImeBinding binding = LookupImeBinding(languageOf: () => null);
    binding.attach();
    await Future<void>.delayed(Duration.zero);
    // 去重：null 是初始状态，什么都不该发。
    expect(sent, isEmpty);
  });

  test('两个查词入口交叠时，关掉其中一个不该还原另一个还要着的语言', () async {
    // 桌面实景：词典主页搜索框聚焦着（已切日语），再打开弹窗词典、然后关掉它。
    // 弹窗那句「我不要了」只能撤回它自己的请求，不能把主页那份一起还原。
    final LookupImeBinding home = LookupImeBinding(languageOf: () => 'ja');
    final LookupImeBinding popup = LookupImeBinding(languageOf: () => 'ja');

    home.attach();
    await Future<void>.delayed(Duration.zero);
    popup.attach();
    await Future<void>.delayed(Duration.zero);
    popup.detach();
    await Future<void>.delayed(Duration.zero);
    expect(sent, <Object?>['ja'], reason: '主页那份还活着，关掉弹窗不该发出任何还原');

    home.detach();
    await Future<void>.delayed(Duration.zero);
    expect(sent, <Object?>['ja', null], reason: '最后一个请求者走了才还原');
  });

  test('后开的入口要别的语言：它走了要回落到先前那个', () async {
    final LookupImeBinding home = LookupImeBinding(languageOf: () => 'ja');
    final LookupImeBinding popup = LookupImeBinding(languageOf: () => 'ko');

    home.attach();
    await Future<void>.delayed(Duration.zero);
    popup.attach();
    await Future<void>.delayed(Duration.zero);
    expect(sent, <Object?>['ja', 'ko'], reason: '后登记的赢');

    popup.detach();
    await Future<void>.delayed(Duration.zero);
    expect(sent, <Object?>['ja', 'ko', 'ja'], reason: '回落到仍然活跃的那个请求者，而不是无条件还原');
  });

  group('persistForNativeSurfaces（给原生查词输入框的持久化值）', () {
    test('发的是 persistLanguage，不碰切换通道', () async {
      await LookupImeChannel.persistForNativeSurfaces('ja');
      expect(persisted, <Object?>['ja']);
      expect(sent, isEmpty, reason: '持久化不该顺带切换输入法——桌面上那会在启动时就把用户切走');
    });

    test('未设置时存空串而不是 null', () async {
      // Android 侧读的是 String，空串表示「用户没选」；null 过不去 codec 的类型约定。
      await LookupImeChannel.persistForNativeSurfaces(null);
      expect(persisted, <Object?>['']);
    });

    test('不参与 setLanguage 的去重状态', () async {
      await LookupImeChannel.persistForNativeSurfaces('ja');
      await LookupImeChannel.setLanguage('ja');
      expect(sent, <Object?>['ja'], reason: '持久化过不代表切换过，切换仍要发出去');
    });
  });

  test('每次同步都重新取值——用户可能在查词页面开着时改了设置', () async {
    String? current = 'ja';
    final LookupImeBinding binding = LookupImeBinding(
      languageOf: () => current,
    );
    binding.attach();
    await Future<void>.delayed(Duration.zero);
    current = 'ko';
    binding.detach();
    await Future<void>.delayed(Duration.zero);
    binding.attach();
    await Future<void>.delayed(Duration.zero);
    expect(sent, <Object?>['ja', null, 'ko']);
  });
}
