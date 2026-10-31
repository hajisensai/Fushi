// 制卡结果 toast 的 widget 守卫：FushiToast.showMine 走应用 navigator overlay，画
// M3E tonal 结果卡（FushiMineNoticeCard）——按状态取 container 底色、强调色图标块、
// 状态标题 + 具体消息。新制与覆盖分两种颜色（此前同绿，用户分不出）。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_mine_notice_card.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

Future<void> _pumpToastHost(WidgetTester tester) async {
  final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
  FushiToast.navigatorKey = navKey;
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: SizedBox.expand()),
    ),
  );
}

/// 结果卡的底色（卡片最外层带圆角的 BoxDecoration）。
Color _cardBg(WidgetTester tester) {
  final Finder card = find.byType(FushiMineNoticeCard);
  expect(card, findsOneWidget);
  for (final Container c in tester.widgetList<Container>(
    find.descendant(of: card, matching: find.byType(Container)),
  )) {
    final Decoration? d = c.decoration;
    if (d is BoxDecoration && d.color != null && d.borderRadius != null) {
      return d.color!;
    }
  }
  fail('未找到制卡结果卡的底');
}

Future<void> _show(
  WidgetTester tester,
  String msg,
  MineToastStatus status,
) async {
  FushiToast.showMine(msg: msg, status: status);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('原生降级色板：覆盖是独立的紫色，不再与新制同绿', () {
    expect(
      mineToastPalette(MineToastStatus.added).background,
      const Color(0xFF2E7D32),
    );
    expect(
      mineToastPalette(MineToastStatus.overwritten).background,
      const Color(0xFF6750A4),
    );
    expect(
      mineToastPalette(MineToastStatus.duplicate).foreground,
      Colors.black,
      reason: 'orange 800 配白字只有 3.08:1',
    );
  });

  test('结果卡色调：五种结果五种强调色，每态图标不同', () {
    final Map<MineToastStatus, Color> accents = <MineToastStatus, Color>{
      MineToastStatus.added: const Color(0xFF1E8E3E),
      MineToastStatus.overwritten: const Color(0xFF6750A4),
      MineToastStatus.duplicate: const Color(0xFFB26A00),
      MineToastStatus.queued: const Color(0xFF0B57D0),
      MineToastStatus.failed: const Color(0xFFC5221F),
    };
    accents.forEach((MineToastStatus s, Color accent) {
      expect(mineNoticeTone(s).accent, accent, reason: '$s');
    });
    final Set<IconData> icons = <IconData>{
      for (final MineToastStatus s in MineToastStatus.values)
        mineNoticeTone(s).icon,
    };
    // addedWithWarning 用警告图标、duplicate 用 libraryAdd：同琥珀色靠形状区分。
    expect(icons.length, MineToastStatus.values.length);
  });

  testWidgets('added：绿色结果卡 + 状态标题 + 消息', (WidgetTester tester) async {
    await _pumpToastHost(tester);
    await _show(tester, '卡片已导出到『Fushi』。', MineToastStatus.added);

    expect(find.text(t.card_notice_title_added), findsOneWidget);
    expect(find.text('卡片已导出到『Fushi』。'), findsOneWidget);
    expect(_cardBg(tester), mineNoticeTone(MineToastStatus.added).container);
    expect(find.byIcon(FushiIcons.filled(FushiIcons.success)), findsOneWidget);
    await tester.pump(const Duration(seconds: 3)); // 跑完自动消失计时器
  });

  testWidgets('overwritten：紫色结果卡，与新制区分', (WidgetTester tester) async {
    await _pumpToastHost(tester);
    await _show(tester, '卡片已覆盖到『Fushi』。', MineToastStatus.overwritten);

    expect(find.text(t.card_notice_title_overwritten), findsOneWidget);
    expect(
      _cardBg(tester),
      mineNoticeTone(MineToastStatus.overwritten).container,
    );
    expect(
      _cardBg(tester),
      isNot(mineNoticeTone(MineToastStatus.added).container),
    );
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('failed：红色结果卡', (WidgetTester tester) async {
    await _pumpToastHost(tester);
    await _show(tester, 'AnkiConnect 无响应', MineToastStatus.failed);

    expect(find.text(t.card_notice_title_failed), findsOneWidget);
    expect(_cardBg(tester), mineNoticeTone(MineToastStatus.failed).container);
    expect(find.byIcon(FushiIcons.filled(FushiIcons.error)), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('pending：无标题单行，随后被结果卡顶替', (WidgetTester tester) async {
    await _pumpToastHost(tester);
    await _show(tester, '制卡中…', MineToastStatus.pending);

    expect(find.byIcon(FushiIcons.sync), findsOneWidget);
    expect(find.text('制卡中…'), findsOneWidget);
    expect(mineNoticeTitle(MineToastStatus.pending), isNull);

    await _show(tester, '已添加', MineToastStatus.added);
    expect(
      find.byIcon(FushiIcons.sync),
      findsNothing,
      reason: 'pending 应被结果 toast 顶替',
    );
    expect(find.byType(FushiMineNoticeCard), findsOneWidget);
    expect(_cardBg(tester), mineNoticeTone(MineToastStatus.added).container);
    await tester.pump(const Duration(seconds: 3));
  });
}
