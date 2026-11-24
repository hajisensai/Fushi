// 制卡结果 toast 的 widget 守卫：FushiToast.showMine 走应用 navigator overlay，画
// M3E tonal 结果卡（FushiMineNoticeCard）——按状态取 container 底色、强调色图标块、
// 第一行词（没词时状态标题）、第二行「状态标题 · 说明」。新制与覆盖分两种颜色；
// 重复是青色、与琥珀色的「有缺失」分开（用户 2026-11-22 重设计）。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_mine_notice_card.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

Future<void> _pumpToastHost(
  WidgetTester tester, {
  TextDirection direction = TextDirection.ltr,
}) async {
  final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
  FushiToast.navigatorKey = navKey;
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navKey,
      builder: (BuildContext context, Widget? child) =>
          Directionality(textDirection: direction, child: child!),
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

/// 等结果卡的底色 / 强调色补间走完（处理中 → 结果原地变色）。
Future<void> _settleColors(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 600));

Finder _rich(String text) => find.text(text, findRichText: true);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 制卡队列是进程级的：每个用例收尾清空，免得上一个用例没到期的卡串进下一个。
  tearDown(FushiToast.debugReset);

  test('原生降级色板：覆盖是独立的紫色，不再与新制同绿', () {
    expect(
      mineToastPalette(MineToastStatus.added).background,
      const Color(0xFF2E7D32),
    );
    expect(
      mineToastPalette(MineToastStatus.overwritten).background,
      const Color(0xFF6750A4),
    );
    // 重复是青色（不再与「有缺失」同琥珀色），白字对比度 > 4.5:1。
    expect(
      mineToastPalette(MineToastStatus.duplicate).background,
      const Color(0xFF006874),
    );
    expect(
      mineToastPalette(MineToastStatus.duplicate).foreground,
      Colors.white,
    );
  });

  test('结果卡色调：五种结果五种强调色，每态图标不同', () {
    final Map<MineToastStatus, Color> accents = <MineToastStatus, Color>{
      MineToastStatus.added: const Color(0xFF1E8E3E),
      MineToastStatus.overwritten: const Color(0xFF6750A4),
      MineToastStatus.duplicate: const Color(0xFF006874),
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
    expect(icons.length, MineToastStatus.values.length);
    // 有缺失（琥珀）与重复（青）不再同色。
    expect(
      mineNoticeTone(MineToastStatus.addedWithWarning).accent,
      isNot(mineNoticeTone(MineToastStatus.duplicate).accent),
    );
    // 深色主题有自己的一套色调，不是浅色那套照搬。
    for (final MineToastStatus s in MineToastStatus.values) {
      expect(
        mineNoticeTone(s, dark: true).container,
        isNot(mineNoticeTone(s).container),
        reason: '$s',
      );
    }
  });

  testWidgets('added：没有词时第一行是可见的状态标题，第二行是消息', (WidgetTester tester) async {
    await _pumpToastHost(tester);
    await _show(tester, '卡片已导出到『Fushi』。', MineToastStatus.added);

    expect(_rich(t.card_notice_title_added), findsOneWidget);
    expect(_rich('卡片已导出到『Fushi』。'), findsOneWidget);
    expect(
      tester.getSize(find.byType(FushiMineNoticeCard)).height,
      greaterThanOrEqualTo(64),
    );
    expect(_cardBg(tester), mineNoticeTone(MineToastStatus.added).container);
    expect(find.byIcon(FushiIcons.filled(FushiIcons.success)), findsOneWidget);
    await tester.pump(const Duration(seconds: 3)); // 跑完自动消失计时器
  });

  testWidgets('有词时：第一行「词 读音」，第二行「状态标题 · 说明」', (WidgetTester tester) async {
    await _pumpToastHost(tester);
    FushiToast.showMine(
      msg: '卡片已导出到『日语::挖矿』。',
      status: MineToastStatus.added,
      term: '雪',
      reading: 'ゆき',
      detail: '日语::挖矿',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(_rich('雪  ゆき'), findsOneWidget);
    expect(_rich('${t.card_notice_title_added} · 日语::挖矿'), findsOneWidget);
    expect(_rich('卡片已导出到『日语::挖矿』。'), findsNothing, reason: '有短说明就不重复长消息');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('overwritten：紫色结果卡，与新制区分', (WidgetTester tester) async {
    await _pumpToastHost(tester);
    await _show(tester, '卡片已覆盖到『Fushi』。', MineToastStatus.overwritten);

    expect(_rich(t.card_notice_title_overwritten), findsOneWidget);
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

    expect(_rich(t.card_notice_title_failed), findsOneWidget);
    expect(_cardBg(tester), mineNoticeTone(MineToastStatus.failed).container);
    expect(find.byIcon(FushiIcons.filled(FushiIcons.error)), findsOneWidget);
    // 失败停得比成功久（8 秒档）：3 秒后还在，8 秒档到期才收。
    await tester.pump(const Duration(seconds: 3));
    expect(find.byType(FushiMineNoticeCard), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(FushiMineNoticeCard), findsNothing);
  });

  testWidgets('pending：标题「制卡中」，结果到了在同一张卡上原地变成结果', (WidgetTester tester) async {
    await _pumpToastHost(tester);
    FushiToast.showMine(
      msg: '制卡中…',
      status: MineToastStatus.pending,
      term: '雪',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byIcon(FushiIcons.sync), findsOneWidget);
    expect(_rich('雪'), findsOneWidget);
    expect(_rich(t.card_notice_title_pending), findsOneWidget);
    final int pendingId = FushiToast.debugMineNotices.entries.single.id;

    FushiToast.showMine(msg: '已添加', status: MineToastStatus.added);
    await tester.pump();
    await _settleColors(tester);
    expect(find.byIcon(FushiIcons.sync), findsNothing);
    expect(find.byType(FushiMineNoticeCard), findsOneWidget);
    expect(
      FushiToast.debugMineNotices.entries.single.id,
      pendingId,
      reason: '同一条目原地换成结果，不是另插一张',
    );
    expect(_rich('雪'), findsOneWidget, reason: '结果没带词时沿用处理中那张的词');
    expect(_cardBg(tester), mineNoticeTone(MineToastStatus.added).container);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('角落锚点（歌词模式）：小号卡贴正文区域左下角；撤销后复原', (WidgetTester tester) async {
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
      final Rect box = tester.getRect(find.byType(FushiMineNoticeCard));
      // 反馈 RZpvO4Dl3y：贴正文区域起始侧下角（LTR 左下），不出区域（OOZ-lrCsU0）。
      expect(box.left, moreOrLessEquals(region.left + 12, epsilon: 2));
      expect(box.bottom, moreOrLessEquals(region.bottom - 12, epsilon: 2));
      expect(box.height, lessThan(64), reason: '小号卡比默认卡矮');
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
      // 反馈 RZpvO4Dl3y：贴正文区域起始侧下角（LTR 左下），不出区域（OOZ-lrCsU0）。
      expect(box.left, moreOrLessEquals(region.left + 12, epsilon: 2));
      expect(box.bottom, moreOrLessEquals(region.bottom - 12, epsilon: 2));

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
      expect(FushiToast.debugMineNotices.isEmpty, isTrue, reason: '点下即收');
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(FushiMineNoticeCard), findsNothing);
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
      box.left,
      moreOrLessEquals(16, epsilon: 2),
      reason: '回到屏幕左下的默认位置，不留在已消失的歌词区域角上',
    );
    expect(box.width, lessThan(screen.width / 2 + 220));
    expect(box.bottom, greaterThan(region.bottom));
    FushiToast.dismissCurrent();
    await tester.pump();
  });

  testWidgets('RTL 界面：小卡落正文区域右下角', (WidgetTester tester) async {
    await _pumpToastHost(tester, direction: TextDirection.rtl);
    const Rect region = Rect.fromLTRB(40, 60, 500, 520);
    final FushiToastCornerAnchor anchor = FushiToast.anchorMineToCorner(
      () => region,
    );
    try {
      await _show(tester, '卡片已导出到『日语单词』。', MineToastStatus.added);
      final Rect box = tester.getRect(find.byType(FushiMineNoticeCard));
      expect(box.right, moreOrLessEquals(region.right - 12, epsilon: 2));
      expect(box.bottom, moreOrLessEquals(region.bottom - 12, epsilon: 2));
      await tester.pump(const Duration(seconds: 3));
    } finally {
      anchor.release();
    }
  });

  // 反馈 RZpvO4Dl3y（维护者 2026-11-24）：制卡提示放左下角；普通提示仍底部正中。
  for (final TextDirection direction in TextDirection.values) {
    testWidgets('默认位置 $direction：制卡结果卡落起始侧下角，普通提示仍居中', (
      WidgetTester tester,
    ) async {
      await _pumpToastHost(tester, direction: direction);
      final Size screen =
          tester.view.physicalSize / tester.view.devicePixelRatio;
      await _show(tester, '已添加', MineToastStatus.added);
      final FushiMineNoticeCard card = tester.widget(
        find.byType(FushiMineNoticeCard),
      );
      expect(card.compact, isFalse);
      final Rect box = tester.getRect(find.byType(FushiMineNoticeCard));
      if (direction == TextDirection.ltr) {
        expect(box.left, moreOrLessEquals(16, epsilon: 2), reason: '贴左');
      } else {
        expect(
          box.right,
          moreOrLessEquals(screen.width - 16, epsilon: 2),
          reason: 'RTL 镜像贴右',
        );
      }
      expect(box.width, lessThan(screen.width - 32), reason: '不是整条横铺');
      expect(box.bottom, greaterThan(screen.height / 2), reason: '在下半屏');
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 300));

      FushiToast.show(msg: '普通提示');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final Rect generic = tester.getRect(find.text('普通提示'));
      expect(
        generic.center.dx,
        moreOrLessEquals(screen.width / 2, epsilon: 2),
        reason: '普通提示不受制卡提示挪位影响',
      );
      FushiToast.dismissCurrent();
      await tester.pump(const Duration(seconds: 1));
    });
  }

  test('mineToastOffsetInRegion：起始侧下角，夹在屏幕内', () {
    const Size overlay = Size(1000, 700);
    const Size card = Size(300, 40);
    const Rect region = Rect.fromLTRB(40, 28, 960, 560);
    // LTR：左下。
    expect(
      mineToastOffsetInRegion(
        overlay: overlay,
        region: region,
        card: card,
        direction: TextDirection.ltr,
      ),
      const Offset(52, 560 - 12 - 40),
    );
    // RTL：右下。
    expect(
      mineToastOffsetInRegion(
        overlay: overlay,
        region: region,
        card: card,
        direction: TextDirection.rtl,
      ),
      const Offset(960 - 12 - 300, 560 - 12 - 40),
    );
    // 区域伸出屏幕：夹回屏内。
    expect(
      mineToastOffsetInRegion(
        overlay: overlay,
        region: const Rect.fromLTRB(-100, 0, 1200, 900),
        card: card,
        direction: TextDirection.ltr,
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
  // 平台命中区 ≥48dp 且落在视觉按钮外、48 带内的触点也算点中；卡片不因命中区
  // 长过自己的最小高（默认 64 / 小号 44）。MD3 与 Apple 玻璃两套按钮都要满足
  // （玻璃按钮不认 tapTargetSize）。
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
          greaterThanOrEqualTo(tester.getSize(target).height),
          reason: '48dp 命中区整个落在卡片里',
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
    expect(tester.getSize(find.byType(FushiMineNoticeCard)).height, 64);
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
