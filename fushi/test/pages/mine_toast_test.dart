// 制卡结果 toast 的 widget 守卫：FushiToast.showMine 走应用 navigator overlay，画
// M3E tonal 结果卡（FushiMineNoticeCard）——按状态取 container 底色、强调色图标块、
// 状态标题 + 具体消息。新制与覆盖分两种颜色（此前同绿，用户分不出）。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
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

  testWidgets('added：绿色结果卡 + 消息，与普通提示胶囊同高', (WidgetTester tester) async {
    await _pumpToastHost(tester);
    await _show(tester, '卡片已导出到『Fushi』。', MineToastStatus.added);

    // 状态标题不单占一行（卡片与普通提示胶囊同为单行 48 高），只进读屏 label。
    expect(find.text(t.card_notice_title_added), findsNothing);
    expect(
      find.bySemanticsLabel(RegExp(t.card_notice_title_added)),
      findsOneWidget,
    );
    expect(find.text('卡片已导出到『Fushi』。'), findsOneWidget);
    expect(tester.getSize(find.byType(FushiMineNoticeCard)).height, 48);
    expect(_cardBg(tester), mineNoticeTone(MineToastStatus.added).container);
    expect(find.byIcon(FushiIcons.filled(FushiIcons.success)), findsOneWidget);
    await tester.pump(const Duration(seconds: 3)); // 跑完自动消失计时器
  });

  testWidgets('overwritten：紫色结果卡，与新制区分', (WidgetTester tester) async {
    await _pumpToastHost(tester);
    await _show(tester, '卡片已覆盖到『Fushi』。', MineToastStatus.overwritten);

    expect(
      find.bySemanticsLabel(RegExp(t.card_notice_title_overwritten)),
      findsOneWidget,
    );
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

    expect(
      find.bySemanticsLabel(RegExp(t.card_notice_title_failed)),
      findsOneWidget,
    );
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

  testWidgets('角落锚点（歌词模式）：小号卡放在正文区域下沿之外、不压正文；撤销后复原', (
    WidgetTester tester,
  ) async {
    await _pumpToastHost(tester);
    const Rect region = Rect.fromLTRB(40, 60, 500, 520);
    final FushiToastCornerAnchor anchor = FushiToast.anchorMineToCorner(
      () => region,
    );
    try {
      await _show(tester, '卡片已导出到『日语单词』。', MineToastStatus.added);
      final FushiMineNoticeCard card = tester.widget(
        find.byType(FushiMineNoticeCard),
      );
      expect(card.compact, isTrue);
      expect(
        find.text(mineNoticeTitle(MineToastStatus.added)!),
        findsNothing,
        reason: '小号卡不画标题行',
      );
      final Rect box = tester.getRect(find.byType(FushiMineNoticeCard));
      expect(box.left, moreOrLessEquals(region.left + 12, epsilon: 2));
      // 反馈 OOZ-lrCsU0：放在正文区域外（紧贴下沿之下），不压正文。
      expect(box.top, moreOrLessEquals(region.bottom + 12, epsilon: 2));
      expect(box.overlaps(region), isFalse);
      expect(box.height, lessThanOrEqualTo(44));
      await tester.pump(const Duration(seconds: 3));
    } finally {
      anchor.release();
    }

    await _show(tester, '已添加', MineToastStatus.added);
    final FushiMineNoticeCard card = tester.widget(
      find.byType(FushiMineNoticeCard),
    );
    expect(card.compact, isFalse, reason: '撤销登记后回到默认大卡');
    await tester.pump(const Duration(seconds: 3));
  });
  testWidgets('角落锚点 + 「撤销」：小卡带按钮仍贴角、按钮可点、按带按钮时长停留', (
    WidgetTester tester,
  ) async {
    await _pumpToastHost(tester);
    const Rect region = Rect.fromLTRB(40, 60, 500, 520);
    final FushiToastCornerAnchor anchor = FushiToast.anchorMineToCorner(
      () => region,
    );
    int pressed = 0;
    try {
      FushiToast.showMine(
        msg: '卡片已导出到『日语单词』。',
        status: MineToastStatus.added,
        action: MineNoticeAction(label: '撤销', onPressed: () => pressed++),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      final FushiMineNoticeCard card = tester.widget(
        find.byType(FushiMineNoticeCard),
      );
      expect(card.compact, isTrue);
      expect(card.visibleFor, kMineNoticeActionVisibleFor);
      final Rect box = tester.getRect(find.byType(FushiMineNoticeCard));
      expect(box.left, moreOrLessEquals(region.left + 12, epsilon: 2));
      // 反馈 OOZ-lrCsU0：放在正文区域外（紧贴下沿之下），不压正文。
      expect(box.top, moreOrLessEquals(region.bottom + 12, epsilon: 2));
      expect(box.overlaps(region), isFalse);

      // 普通结果卡 2.4 秒就收；带按钮的小卡还在。
      await tester.pump(const Duration(seconds: 3));
      final Finder undo = find.byKey(
        const ValueKey<String>('mine-notice-action'),
      );
      expect(undo, findsOneWidget);
      // 命中测试必须真落到按钮上（角落路径不能整体 IgnorePointer）。
      await tester.tap(undo);
      await tester.pump();
      expect(pressed, 1);
      expect(find.byType(FushiMineNoticeCard), findsNothing, reason: '点下即收');
    } finally {
      anchor.release();
    }
  });

  testWidgets('显示期间撤销锚点（退出歌词模式）：同一张卡整张退回默认大卡与默认位置', (
    WidgetTester tester,
  ) async {
    await _pumpToastHost(tester);
    const Rect region = Rect.fromLTRB(40, 60, 500, 520);
    final FushiToastCornerAnchor anchor = FushiToast.anchorMineToCorner(
      () => region,
    );
    try {
      // 带「撤销」的卡停得久，撤销锚点时它一定还在显示期内。
      FushiToast.showMine(
        msg: '卡片已导出到『日语单词』。',
        status: MineToastStatus.added,
        action: MineNoticeAction(label: '撤销', onPressed: () {}),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        tester
            .widget<FushiMineNoticeCard>(find.byType(FushiMineNoticeCard))
            .compact,
        isTrue,
      );
    } finally {
      anchor.release();
    }
    // release 在帧后标脏 toast 条目，下一帧按剩下的锚点（无）重新定尺寸与位置。
    await tester.pump();
    await tester.pump();
    final FushiMineNoticeCard card = tester.widget(
      find.byType(FushiMineNoticeCard),
    );
    expect(card.compact, isFalse, reason: '尺寸与位置同一次解析：不能是贴默认位置的小卡');
    expect(card.maxWidth, 440);
    final Rect box = tester.getRect(find.byType(FushiMineNoticeCard));
    final Size screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(
      box.center.dx,
      moreOrLessEquals(screen.width / 2, epsilon: 2),
      reason: '回到屏幕底部正中，不留在已消失的歌词区域角上',
    );
    expect(box.bottom, greaterThan(region.bottom));
    FushiToast.dismissCurrent();
    await tester.pump();
  });

  testWidgets('正文区域下方放不下：小卡放到区域上沿之上，仍不压正文', (WidgetTester tester) async {
    await _pumpToastHost(tester);
    // 测试屏 800x600：区域下方只剩 20，上方有 100。
    const Rect region = Rect.fromLTRB(40, 100, 500, 580);
    final FushiToastCornerAnchor anchor = FushiToast.anchorMineToCorner(
      () => region,
    );
    try {
      await _show(tester, '卡片已导出到『日语单词』。', MineToastStatus.added);
      final Rect box = tester.getRect(find.byType(FushiMineNoticeCard));
      expect(box.bottom, moreOrLessEquals(region.top - 12, epsilon: 2));
      expect(box.left, moreOrLessEquals(region.left + 12, epsilon: 2));
      expect(box.overlaps(region), isFalse);
      await tester.pump(const Duration(seconds: 3));
    } finally {
      anchor.release();
    }
  });

  test('mineToastOffsetClearOf：下方优先、其次上方、RTL 贴右、都放不下才进区域内', () {
    const Size overlay = Size(1000, 700);
    const Size card = Size(300, 40);
    // 下方带子 700-560=140 ≥ 64：紧贴下沿。
    expect(
      mineToastOffsetClearOf(
        overlay: overlay,
        region: const Rect.fromLTRB(40, 28, 960, 560),
        card: card,
        rtl: false,
      ),
      const Offset(52, 572),
    );
    // RTL：贴区域右边。
    expect(
      mineToastOffsetClearOf(
        overlay: overlay,
        region: const Rect.fromLTRB(40, 28, 960, 560),
        card: card,
        rtl: true,
      ),
      const Offset(960 - 12 - 300, 572),
    );
    // 下方 30 放不下、上方 100 放得下：紧贴上沿之上。
    expect(
      mineToastOffsetClearOf(
        overlay: overlay,
        region: const Rect.fromLTRB(40, 100, 960, 670),
        card: card,
        rtl: false,
      ),
      const Offset(52, 100 - 12 - 40),
    );
    // 正文铺满整屏：只能落进区域内的底部起始角。
    expect(
      mineToastOffsetClearOf(
        overlay: overlay,
        region: const Rect.fromLTRB(0, 0, 1000, 700),
        card: card,
        rtl: false,
      ),
      const Offset(12, 700 - 12 - 40),
    );
  });

  testWidgets('角落锚点解析不出区域（页面被盖住 / 未布局）：退回默认大卡', (WidgetTester tester) async {
    await _pumpToastHost(tester);
    final FushiToastCornerAnchor anchor = FushiToast.anchorMineToCorner(
      () => null,
    );
    try {
      await _show(tester, '已添加', MineToastStatus.added);
      final FushiMineNoticeCard card = tester.widget(
        find.byType(FushiMineNoticeCard),
      );
      expect(card.compact, isFalse);
      await tester.pump(const Duration(seconds: 3));
    } finally {
      anchor.release();
    }
  });

  // 「撤销」按钮尺寸契约：视觉 32 高（不叠 VisualDensity.compact 压到 24），触控
  // 平台命中区 ≥48dp 且落在视觉按钮外、48 带内的触点也算点中；默认卡带按钮仍
  // 48 高。MD3 与 Apple 玻璃两套按钮都要满足（玻璃按钮不认 tapTargetSize）。
  for (final bool glass in <bool>[false, true]) {
    for (final bool compact in <bool>[false, true]) {
      final String label =
          '${glass ? 'Apple' : 'MD3'} ${compact ? '小号卡' : '默认卡'}';
      testWidgets('$label：触控平台撤销按钮视觉 32 高、命中区 48dp', (
        WidgetTester tester,
      ) async {
        int pressed = 0;
        await _pumpNoticeWithAction(
          tester,
          tapTargetSize: MaterialTapTargetSize.padded,
          glass: glass,
          compact: compact,
          onPressed: () => pressed++,
        );
        final Finder button = find.byKey(
          const ValueKey<String>('mine-notice-action'),
        );
        expect(button, findsOneWidget);
        expect(tester.getSize(button).height, 32, reason: '视觉 32 高');
        final Finder target = find.ancestor(
          of: button,
          matching: find.byType(FushiTouchTargetPadding),
        );
        expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
        expect(
          tester.getSize(find.byType(FushiMineNoticeCard)).height,
          48,
          reason: '命中区占满行高，卡片不因按钮长过 48',
        );

        // 视觉按钮上沿外 / 下沿外 6px（仍在 48 命中带内）都要点中；下沿外
        // 那一点落在倒计时条上，锁住装饰条不吞命中。
        final Rect visual = tester.getRect(button);
        await tester.tapAt(Offset(visual.center.dx, visual.top - 6));
        await tester.pump();
        expect(pressed, 1, reason: '48dp 命中带里视觉按钮上方的触点也算点中');
        await tester.tapAt(Offset(visual.center.dx, visual.bottom + 6));
        await tester.pump();
        expect(pressed, 2, reason: '倒计时条不能吞掉命中带底边的触点');
      });
    }
  }

  testWidgets('桌面精确指针（shrinkWrap）：撤销按钮保持视觉 32 高，卡片高度不变', (
    WidgetTester tester,
  ) async {
    await _pumpNoticeWithAction(
      tester,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      glass: false,
      compact: false,
      onPressed: () {},
    );
    final Finder button = find.byKey(
      const ValueKey<String>('mine-notice-action'),
    );
    expect(tester.getSize(button).height, 32);
    expect(tester.getSize(find.byType(FushiMineNoticeCard)).height, 48);
    // 按钮在卡片行内竖直居中（行高下限 = 卡片下限，不贴顶）。
    final Rect card = tester.getRect(find.byType(FushiMineNoticeCard));
    expect(
      tester.getRect(button).center.dy,
      moreOrLessEquals(card.center.dy, epsilon: 0.5),
    );
  });
}

Future<void> _pumpNoticeWithAction(
  WidgetTester tester, {
  required MaterialTapTargetSize tapTargetSize,
  required bool glass,
  required bool compact,
  required VoidCallback onPressed,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        materialTapTargetSize: tapTargetSize,
        extensions: <ThemeExtension<dynamic>>[
          FushiGlassTheme(FushiGlassMaterial.off, glassDesign: glass),
        ],
      ),
      home: Scaffold(
        body: Center(
          child: FushiMineNoticeCard(
            status: MineToastStatus.added,
            message: '卡片已导出到『日语单词』。',
            visibleFor: kMineNoticeActionVisibleFor,
            compact: compact,
            action: MineNoticeAction(label: '撤销', onPressed: onPressed),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 400));
}
