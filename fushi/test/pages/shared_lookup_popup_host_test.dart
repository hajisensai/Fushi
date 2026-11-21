import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi/src/pages/implementations/shared_lookup_popup_host.dart';

/// 拍板台 design-shared-lookup-webview：游戏 tab（texthooker）与查词 tab 共用一个查词
/// 弹窗栈与一个常驻热槽 WebView。这里用假宿主页钉住所有权模型：
/// - 两页都 seed 也只有一个热槽；
/// - 另一页切到前台不夺走会话（浮层只是随渲染方不可见而 inert，BUG-953），切回原页
///   会话还在；
/// - 另一页真正查词时才收回热槽、接管渲染，热槽层的 State 不重建（BUG-4896 同理：
///   热槽 WebView 不随切换拆建）；
/// - 非渲染方不能收别人的会话；渲染方销毁后交接给另一页。
class _FakeOwner implements SharedLookupPopupOwner {
  _FakeOwner(this.name);

  final String name;
  int claims = 0;
  bool alive = true;
  final List<String> builtBy = <String>[];

  @override
  List<Widget> buildSharedLookupPopupLayers(BuildContext context, Size screen) {
    builtBy.add(name);
    final DictionaryPopupController controller = _hostOf[this]!.controller;
    return <Widget>[
      for (final DictionaryPopupEntry entry in controller.entries)
        _LayerProbe(key: ObjectKey(entry), owner: name),
    ];
  }

  @override
  ThemeData? get sharedLookupPopupTheme => null;

  @override
  bool get sharedLookupPopupOwnerAlive => alive;

  @override
  void onSharedLookupPopupClaimed(DictionaryPopupController controller) {
    claims++;
  }
}

final Map<_FakeOwner, SharedLookupPopupHost> _hostOf =
    <_FakeOwner, SharedLookupPopupHost>{};

/// 替身「热槽 WebView」：State 身份即 WebView 身份。
class _LayerProbe extends StatefulWidget {
  const _LayerProbe({super.key, required this.owner});

  final String owner;

  @override
  State<_LayerProbe> createState() => _LayerProbeState();
}

class _LayerProbeState extends State<_LayerProbe> {
  @override
  Widget build(BuildContext context) =>
      SizedBox(width: 10, height: 10, child: Text(widget.owner));
}

DictionaryPopupEntry _openSession(DictionaryPopupController controller) =>
    controller.beginTop(
      term: '食べる',
      rect: const Rect.fromLTWH(10, 10, 20, 20),
      reuseWarmSlot: true,
      replaceStack: false,
      visible: true,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedLookupPopupHost host;
  late _FakeOwner games;
  late _FakeOwner dict;

  setUp(() {
    host = SharedLookupPopupHost();
    games = _FakeOwner('games');
    dict = _FakeOwner('dict');
    _hostOf[games] = host;
    _hostOf[dict] = host;
  });

  tearDown(() {
    host.dispose();
    _hostOf.clear();
  });

  test('第一个登记的成为渲染方；两页都 seed 也只有一个热槽', () {
    host.attach(games);
    host.attach(dict);
    expect(host.isRenderOwner(games), isTrue);
    expect(host.isRenderOwner(dict), isFalse);
    expect(games.claims, 1);
    expect(dict.claims, 0);

    host.controller.seedWarmSlot();
    host.controller.seedWarmSlot();
    expect(host.controller.entries, hasLength(1));
    expect(host.controller.entries.single.isWarmSlot, isTrue);
  });

  test('另一页可见不夺走会话：浮层随渲染方不可见而 inert，切回会话还在', () {
    host.attach(games);
    host.attach(dict);
    host.controller.seedWarmSlot();
    host.setOwnerVisible(games, true);
    _openSession(host.controller);
    expect(host.overlayInert, isFalse);

    // 切到查词 tab。
    host.setOwnerVisible(games, false);
    host.setOwnerVisible(dict, true);
    expect(host.isRenderOwner(games), isTrue);
    expect(host.overlayInert, isTrue, reason: '游戏的弹窗不能跨 tab 压在查词页上');

    // 查词页在自己的结果里换词：不能收游戏的会话。
    host.pruneToWarmSlotFor(dict);
    expect(host.controller.hasVisiblePopup, isTrue);

    // 切回游戏 tab：会话原样还在、浮层恢复。
    host.setOwnerVisible(dict, false);
    host.setOwnerVisible(games, true);
    expect(host.overlayInert, isFalse);
    expect(host.controller.hasVisiblePopup, isTrue);
    expect(host.controller.entries.first.searchTerm, '食べる');
  });

  test('另一页真正查词时收回热槽并接管', () {
    host.attach(games);
    host.attach(dict);
    host.controller.seedWarmSlot();
    final DictionaryPopupEntry warm = host.controller.entries.single;
    _openSession(host.controller);
    host.setOwnerVisible(dict, true);

    host.claimForLookup(dict);
    expect(host.isRenderOwner(dict), isTrue);
    expect(dict.claims, 1, reason: '查词计数等 controller 级回调改接到查词页');
    expect(host.controller.hasVisiblePopup, isFalse);
    expect(host.controller.entries, <DictionaryPopupEntry>[warm]);
    expect(warm.searchTerm, isEmpty);
    expect(host.overlayInert, isFalse);

    // 自己的嵌套查词再 claim 是 no-op。
    _openSession(host.controller);
    host.claimForLookup(dict);
    expect(dict.claims, 1);
    expect(host.controller.hasVisiblePopup, isTrue);
  });

  testWidgets('换渲染方只换回调：热槽层 State 不重建；inert 时只 Offstage 不拆', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox.expand())),
    );
    host.attach(games);
    host.attach(dict);
    host.controller.seedWarmSlot();
    host.setOwnerVisible(games, true);
    host.sync(tester.element(find.byType(Scaffold)));
    await tester.pump();
    expect(host.debugHasOverlayEntry, isTrue);

    final State<_LayerProbe> before = tester.state(find.byType(_LayerProbe));
    expect(find.text('games'), findsOneWidget);

    // 切到查词 tab：浮层 inert（Offstage），热槽层仍挂着、同一个 State。
    host.setOwnerVisible(games, false);
    host.setOwnerVisible(dict, true);
    await tester.pump();
    await tester.pump();
    expect(find.byType(_LayerProbe), findsNothing);
    expect(
      tester.state(find.byType(_LayerProbe, skipOffstage: false)),
      same(before),
    );

    // 查词页查词：接管渲染，层由查词页出，State 仍是同一个（热 WebView 复用）。
    host.claimForLookup(dict);
    await tester.pump();
    expect(find.text('dict'), findsOneWidget);
    expect(tester.state(find.byType(_LayerProbe)), same(before));
    expect(dict.builtBy, isNotEmpty);
  });

  testWidgets('渲染方销毁交接给另一页并收栈；一页不剩就清栈摘浮层', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox.expand())),
    );
    host.attach(games);
    host.attach(dict);
    host.controller.seedWarmSlot();
    _openSession(host.controller);
    host.setOwnerVisible(games, true);
    host.sync(tester.element(find.byType(Scaffold)));
    await tester.pump();

    host.detach(games);
    expect(host.isRenderOwner(dict), isTrue);
    expect(dict.claims, 1);
    await tester.pump();
    expect(host.controller.hasVisiblePopup, isFalse, reason: '游戏的会话随它走');
    expect(
      host.controller.entries.single.isWarmSlot,
      isTrue,
      reason: '热槽留给查词页',
    );
    expect(host.debugHasOverlayEntry, isTrue);

    host.detach(dict);
    expect(host.renderOwner, isNull);
    await tester.pump();
    expect(host.controller.entries, isEmpty);
    expect(host.debugHasOverlayEntry, isFalse);
    expect(host.debugOwnerCount, 0);
  });

  testWidgets('渲染方 State 失效当帧浮层空渲染（BUG-121）', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox.expand())),
    );
    host.attach(games);
    host.controller.seedWarmSlot();
    host.setOwnerVisible(games, true);
    host.sync(tester.element(find.byType(Scaffold)));
    await tester.pump();
    expect(find.byType(_LayerProbe), findsOneWidget);

    games.alive = false;
    host.sync(tester.element(find.byType(Scaffold)));
    await tester.pump();
    expect(find.byType(_LayerProbe, skipOffstage: false), findsNothing);
  });
}
