import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/collections/collection_shelf_row.dart';
import 'package:hibiki/src/utils/misc/platform_utils.dart';

void main() {
  group('windowSizeClassOf', () {
    test('uses compact/medium/expanded Material breakpoints', () {
      expect(
        windowSizeClassOf(const BoxConstraints(maxWidth: 599)),
        WindowSizeClass.compact,
      );
      expect(
        windowSizeClassOf(const BoxConstraints(maxWidth: 600)),
        WindowSizeClass.medium,
      );
      expect(
        windowSizeClassOf(const BoxConstraints(maxWidth: 839)),
        WindowSizeClass.medium,
      );
      expect(
        windowSizeClassOf(const BoxConstraints(maxWidth: 840)),
        WindowSizeClass.expanded,
      );
    });
  });

  group('windowSizeClassReal (BUG-401)', () {
    // Breakpoints must classify on the REAL physical viewport width, not the
    // virtually-inflated logical width handed down inside HibikiAppUiScale.
    // realW = logicalWidth * appUiScale.
    test('scale=1 is identity across all bands (regression guard)', () {
      expect(windowSizeClassReal(599, 1.0), WindowSizeClass.compact);
      expect(windowSizeClassReal(600, 1.0), WindowSizeClass.medium);
      expect(windowSizeClassReal(839, 1.0), WindowSizeClass.medium);
      expect(windowSizeClassReal(840, 1.0), WindowSizeClass.expanded);
    });

    test(
        'a logical 960 canvas at scale 0.88 is no longer expanded once it '
        'shrinks (real width drives the class)', () {
      // The desktop auto-scale floor is 0.88. With the window minimum width
      // relaxed, dragging the real window narrow lowers the LOGICAL canvas
      // width (canvas = realViewport / scale). A 600-logical canvas at 0.88
      // is really ~528px -> compact. The old code read the logical 600 and
      // mislabeled it medium, keeping the phone layout unreachable.
      expect(windowSizeClassReal(600, 0.88), WindowSizeClass.compact);
      // 960 logical at 0.88 = 844.8 real -> expanded (a genuinely wide one).
      expect(windowSizeClassReal(960, 0.88), WindowSizeClass.expanded);
    });

    test('logical 480 at scale 1.0 is compact', () {
      expect(windowSizeClassReal(480, 1.0), WindowSizeClass.compact);
    });

    test('desktop >=1280 real width stays expanded at scale ~1.0', () {
      expect(windowSizeClassReal(1280, 1.0), WindowSizeClass.expanded);
    });

    test('tablet ~800 real width stays medium at scale 1.05', () {
      // logical 762 * 1.05 = 800.1 -> medium (>=600, <840)
      expect(windowSizeClassReal(762, 1.05), WindowSizeClass.medium);
      expect(windowSizeClassReal(800, 1.0), WindowSizeClass.medium);
    });

    test('windowSizeClassForWidth holds the single threshold definition', () {
      expect(windowSizeClassForWidth(599), WindowSizeClass.compact);
      expect(windowSizeClassForWidth(600), WindowSizeClass.medium);
      expect(windowSizeClassForWidth(839), WindowSizeClass.medium);
      expect(windowSizeClassForWidth(840), WindowSizeClass.expanded);
    });

    test('non-finite / non-positive scale degrades to identity', () {
      expect(windowSizeClassReal(700, double.nan), WindowSizeClass.medium);
      expect(windowSizeClassReal(700, 0), WindowSizeClass.medium);
      expect(windowSizeClassReal(700, -1), WindowSizeClass.medium);
    });
  });

  group('desktop layout metrics', () {
    const ValueKey<String> childKey = ValueKey<String>('content-child');
    const ValueKey<String> primaryKey = ValueKey<String>('primary-pane');
    const ValueKey<String> supportingKey = ValueKey<String>('supporting-pane');

    test('keeps mobile layouts unconstrained', () {
      expect(
        desktopContentMaxWidth(
          WindowSizeClass.compact,
          DesktopContentKind.readerShelf,
        ),
        isNull,
      );
    });

    test('uses wider settings content on Windows-sized expanded layouts', () {
      expect(
        desktopContentMaxWidth(
          WindowSizeClass.expanded,
          DesktopContentKind.settings,
        ),
        // MD3 list-detail: widened 760 -> 960 so the detail pane breathes after
        // the 280px nav pane (Phase 1 ④).
        960,
      );
    });

    test('dictionary content is full-bleed on wide desktop (TODO-1352)', () {
      // TODO-1352 取消了查词页在宽屏上的 1040px 强制内容宽度上限，改为 null
      // （占满，仅由 DesktopContentLayout 保留侧向留白）。权威契约见
      // test/pages/popup_layout_width_columns_test.dart。
      expect(
        desktopContentMaxWidth(
          WindowSizeClass.expanded,
          DesktopContentKind.dictionary,
        ),
        isNull,
      );
    });

    test('sizes reader shelf cards from available content width', () {
      expect(readerShelfGridExtentForWidth(520), 150);
      expect(readerShelfGridExtentForWidth(760), 180);
      expect(readerShelfGridExtentForWidth(1100), 190);
      expect(readerShelfGridExtentForWidth(1450), 210);
    });

    test('sizes reader shelf cards from constrained content width', () {
      expect(
        readerShelfGridExtentForLayout(
          mediaWidth: 1600,
          contentWidth: 760,
        ),
        180,
      );
      expect(
        readerShelfGridExtentForLayout(
          mediaWidth: 1600,
          contentWidth: 1100,
        ),
        190,
      );
    });

    test('adds desktop breathing room without changing compact padding', () {
      expect(
        desktopContentPadding(
          WindowSizeClass.compact,
          DesktopContentKind.dictionary,
        ),
        EdgeInsets.zero,
      );
      expect(
        desktopContentPadding(
          WindowSizeClass.medium,
          DesktopContentKind.dictionary,
        ),
        const EdgeInsets.symmetric(horizontal: 16),
      );
      expect(
        desktopContentPadding(
          WindowSizeClass.expanded,
          DesktopContentKind.settings,
        ),
        const EdgeInsets.symmetric(horizontal: 24),
      );
    });

    test('reader shelf (media wall) is full-bleed at every size class', () {
      // 用户实报「首页左右强制的间距」：媒体墙类页面（书架/视频/游戏/漫画目录/
      // 来源页）卡片自带内边距，宽屏不再叠 16/24px 强制侧向留白。
      for (final WindowSizeClass sizeClass in WindowSizeClass.values) {
        expect(
          desktopContentPadding(sizeClass, DesktopContentKind.readerShelf),
          EdgeInsets.zero,
        );
      }
    });

    test('keeps compact dialog fields usable', () {
      expect(desktopDialogContentWidth(320), 256);
      expect(desktopDialogContentWidth(1200), 420);
    });

    testWidgets('keeps compact AlertDialog content inside screen insets', (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 240);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: AlertDialog(
            content: SizedBox(
              key: childKey,
              width: desktopDialogContentWidth(320),
              height: 40,
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);

      final Rect contentRect = tester.getRect(find.byKey(childKey));
      expect(contentRect.left, greaterThanOrEqualTo(0));
      expect(contentRect.right, lessThanOrEqualTo(320));
    });

    testWidgets(
        'full-bleed dictionary keeps side padding on wide desktop (TODO-1352)',
        (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1600, 200);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: double.infinity,
            height: double.infinity,
            child: DesktopContentLayout(
              kind: DesktopContentKind.dictionary,
              child: SizedBox.expand(key: childKey),
            ),
          ),
        ),
      );

      // TODO-1352：dictionary 宽屏改为 full-bleed（null 上限），子内容宽度
      // = 屏幕 1600 - 2×24 侧向留白 = 1552（不再锁 1040→992）。
      expect(tester.getSize(find.byKey(childKey)).width, 1552);
    });

    testWidgets('reader shelf spans edge-to-edge on wide desktop', (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1600, 200);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: double.infinity,
            height: double.infinity,
            child: DesktopContentLayout(
              kind: DesktopContentKind.readerShelf,
              child: SizedBox.expand(key: childKey),
            ),
          ),
        ),
      );

      // 媒体墙类页面零侧向留白（用户实报「首页左右强制的间距」）：宽屏子内容
      // 宽度 = 整屏 1600，不再扣 2×24。
      expect(tester.getSize(find.byKey(childKey)).width, 1600);
    });

    testWidgets('keeps compact content full width without desktop padding', (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(500, 200);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: double.infinity,
            height: double.infinity,
            child: DesktopContentLayout(
              kind: DesktopContentKind.dictionary,
              child: SizedBox.expand(key: childKey),
            ),
          ),
        ),
      );

      expect(tester.getSize(find.byKey(childKey)).width, 500);
    });

    testWidgets('collapses supporting pane layouts below expanded width', (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(500, 300);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox.expand(
            child: MaterialSupportingPaneLayout(
              primary: SizedBox.expand(key: primaryKey),
              supporting: SizedBox.expand(key: supportingKey),
            ),
          ),
        ),
      );

      expect(find.byKey(primaryKey), findsOneWidget);
      expect(find.byKey(supportingKey), findsNothing);
      expect(tester.getSize(find.byKey(primaryKey)).width, 500);
    });

    testWidgets('uses 70/30 split for expanded supporting pane layouts', (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 300);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox.expand(
            child: MaterialSupportingPaneLayout(
              primary: SizedBox.expand(key: primaryKey),
              supporting: SizedBox.expand(key: supportingKey),
            ),
          ),
        ),
      );

      expect(tester.getSize(find.byKey(primaryKey)).width, 699);
      expect(tester.getSize(find.byKey(supportingKey)).width, 300);
    });

    testWidgets('caps supporting pane width on very wide layouts', (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 300);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox.expand(
            child: MaterialSupportingPaneLayout(
              primary: SizedBox.expand(key: primaryKey),
              supporting: SizedBox.expand(key: supportingKey),
            ),
          ),
        ),
      );

      expect(tester.getSize(find.byKey(supportingKey)).width, 360);
      expect(tester.getSize(find.byKey(primaryKey)).width, 919);
    });

    testWidgets('uses an explicit supporting pane width when provided', (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 300);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox.expand(
            child: MaterialSupportingPaneLayout(
              minSplitWidth: 640,
              supportingWidth: 248,
              primary: SizedBox.expand(key: primaryKey),
              supporting: SizedBox.expand(key: supportingKey),
            ),
          ),
        ),
      );

      expect(tester.getSize(find.byKey(supportingKey)).width, 248);
      expect(tester.getSize(find.byKey(primaryKey)).width, 651);
    });

    testWidgets(
      'top-aligns short primary pane content instead of centering it',
      (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1000, 600);
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox.expand(
              child: MaterialSupportingPaneLayout(
                supportingSide: SupportingPaneSide.start,
                minSplitWidth: 720,
                // Mirrors the production detail pane: an own-scrolling
                // SingleChildScrollView whose content is shorter than the pane
                // (e.g. the audiobook settings destination with only a couple of
                // visible toggles on desktop).
                primary: SingleChildScrollView(
                  child: SizedBox(height: 80, key: childKey),
                ),
                supporting: const SizedBox.expand(),
              ),
            ),
          ),
        );

        // Short content must hug the top of the pane (y == 0), not float to the
        // vertical center the default Row CrossAxisAlignment.center produced.
        expect(tester.getTopLeft(find.byKey(childKey)).dy, 0);
      },
    );
  });

  group('video shelf card layout (BUG-895)', () {
    // 手机窄屏视频卡不得再退化成「1 列铺满整屏」。视频页 targetWidth 从硬编码 240
    // 改成书架同款响应式 readerShelfGridExtentForWidth，必须让手机（宽<600）出 ≥2 列。
    // 卡宽内边距按视频页构建：availableWidth = maxWidth - tokens.spacing.card*2。
    // 这里用保守的 12*2 内边距（tokens.spacing.card 实际 16，减得更多列数只会更多，
    // 用 12 是列数下界的安全估计）。
    double phoneAvailable(double maxWidth) => maxWidth - 12 * 2;

    test('regression: hardcoded targetWidth 240 yielded 1 column on phone', () {
      // 复现旧行为：手机可用宽下 240 目标宽只算出 1 列（铺满整屏 = 卡片过大）。
      final layout = unifiedShelfCardLayout(
        availableWidth: phoneAvailable(384),
        targetWidth: 240,
      );
      expect(layout.columns, 1, reason: '旧硬编码 240 在手机窄屏退化为 1 列');
    });

    test('responsive target gives >=2 columns across phone widths', () {
      for (final double w in <double>[360, 384, 393, 412, 480, 599]) {
        final layout = unifiedShelfCardLayout(
          availableWidth: phoneAvailable(w),
          targetWidth: readerShelfGridExtentForWidth(w),
        );
        expect(
          layout.columns,
          greaterThanOrEqualTo(2),
          reason: '手机宽 $w 应出至少 2 列（targetWidth='
              '${readerShelfGridExtentForWidth(w)}）',
        );
      }
    });

    test('wide screens still collapse to comfortable multi-column', () {
      // 宽屏不受影响：仍按断点收敛列数（不会因目标宽变小而爆出过多超小卡）。
      final tablet = unifiedShelfCardLayout(
        availableWidth: phoneAvailable(840),
        targetWidth: readerShelfGridExtentForWidth(840),
      );
      expect(tablet.columns, greaterThanOrEqualTo(3));
      final desktop = unifiedShelfCardLayout(
        availableWidth: phoneAvailable(1440),
        targetWidth: readerShelfGridExtentForWidth(1440),
      );
      expect(desktop.columns, greaterThanOrEqualTo(5));
    });
  });
}
