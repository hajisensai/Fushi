import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';
import 'package:hibiki/src/utils/misc/swipe_dismiss_wrapper.dart';

import '../widgets/widget_test_helpers.dart';

void main() {
  test('calcPopupPosition stays inside a constrained popup surface', () {
    final Rect popupRect = calcPopupPosition(
      selectionRect: const Rect.fromLTWH(2, 2, 1, 1),
      screen: const Size(8, 8),
    );

    expect(popupRect.left, greaterThanOrEqualTo(0));
    expect(popupRect.top, greaterThanOrEqualTo(0));
    expect(popupRect.right, lessThanOrEqualTo(8));
    expect(popupRect.bottom, lessThanOrEqualTo(8));
  });

  test('calcPopupPosition keeps desktop popup capped and in bounds', () {
    final Rect popupRect = calcPopupPosition(
      selectionRect: const Rect.fromLTWH(730, 520, 20, 20),
      screen: const Size(800, 600),
      maxWidth: 360,
      maxHeight: 480,
    );

    expect(popupRect.width, 360);
    // 高度现在 = availableHeight（受 maxHeight 与屏幕可用空间双重 clamp），不再被
    // 旧的 *0.5 顶死在半屏：480 < (600-余白) 所以取 maxHeight=480。
    expect(popupRect.height, 480);
    expect(popupRect.left, greaterThanOrEqualTo(6));
    expect(popupRect.top, greaterThanOrEqualTo(6));
    expect(popupRect.right, lessThanOrEqualTo(794));
    expect(popupRect.bottom, lessThanOrEqualTo(594));
  });

  test('calcPopupPosition respects bottomReserve', () {
    final Rect popupRect = calcPopupPosition(
      selectionRect: const Rect.fromLTWH(100, 500, 20, 20),
      screen: const Size(400, 800),
      bottomReserve: 80,
    );

    expect(popupRect.bottom, lessThanOrEqualTo(800 - 80));
  });

  test('calcPopupPosition survives bottomReserve larger than the surface', () {
    final Rect popupRect = calcPopupPosition(
      selectionRect: const Rect.fromLTWH(10, 10, 10, 10),
      screen: const Size(80, 48),
      bottomReserve: 80,
    );

    expect(popupRect.left, greaterThanOrEqualTo(0));
    expect(popupRect.top, greaterThanOrEqualTo(0));
    expect(popupRect.right, lessThanOrEqualTo(80));
    expect(popupRect.bottom, lessThanOrEqualTo(48));
  });

  test('dual reserves exceeding screen height do not throw (both modes)', () {
    const Size screen = Size(400, 300);
    const Rect sel = Rect.fromLTWH(180, 140, 30, 30);
    for (final bool vertical in <bool>[false, true]) {
      final Rect popup = calcPopupPosition(
        selectionRect: sel,
        screen: screen,
        maxWidth: 360,
        maxHeight: 360,
        topReserve: 250,
        bottomReserve: 250, // 250+250 > 300
        verticalWriting: vertical,
      );
      expect(popup.width, greaterThanOrEqualTo(0));
      expect(popup.height, greaterThanOrEqualTo(0));
      expect(popup.left.isFinite && popup.top.isFinite, isTrue);
    }
  });

  group('calcPopupPosition maxWidth constraint', () {
    const Rect selectionRect = Rect.fromLTWH(400, 300, 40, 24);
    const Size screen = Size(1920, 1080);

    test('small maxWidth caps the popup width to <= maxWidth', () {
      final Rect popupRect = calcPopupPosition(
        selectionRect: selectionRect,
        screen: screen,
        maxWidth: 250,
      );

      expect(popupRect.width, lessThanOrEqualTo(250));
      expect(popupRect.width, 250);
      expect(popupRect.left, greaterThanOrEqualTo(0));
      expect(popupRect.right, lessThanOrEqualTo(1920));
    });

    test(
        'larger maxWidth yields a wider popup, still bounded by available width',
        () {
      final Rect narrow = calcPopupPosition(
        selectionRect: selectionRect,
        screen: screen,
        maxWidth: 250,
      );
      final Rect wide = calcPopupPosition(
        selectionRect: selectionRect,
        screen: screen,
        maxWidth: 1000,
      );

      expect(wide.width, greaterThan(narrow.width));
      expect(wide.width, 1000);
      expect(wide.width, lessThanOrEqualTo(screen.width));
      expect(wide.right, lessThanOrEqualTo(screen.width));
    });

    test(
        'TODO-846: new 1400 max is reachable on a wide screen, still in bounds',
        () {
      // 大屏（1920 宽）足以容纳新的 1400 上限：弹窗宽应到达 1400 且不越界。
      final Rect popupRect = calcPopupPosition(
        selectionRect: selectionRect,
        screen: screen,
        maxWidth: 1400,
      );

      expect(popupRect.width, 1400);
      expect(popupRect.left, greaterThanOrEqualTo(0));
      expect(popupRect.right, lessThanOrEqualTo(screen.width));
    });

    test('TODO-846: 1400 max still clamped down by a small screen', () {
      // 小屏：即使设置 maxWidth=1400，弹窗也被屏幕可用宽度夹住，不得越界。
      const Size smallScreen = Size(360, 720);
      final Rect popupRect = calcPopupPosition(
        selectionRect: const Rect.fromLTWH(180, 120, 40, 24),
        screen: smallScreen,
        maxWidth: 1400,
      );

      expect(popupRect.width, lessThan(1400),
          reason: '小屏可用宽度远小于 1400，弹窗须被屏幕夹住');
      expect(popupRect.left, greaterThanOrEqualTo(0));
      expect(popupRect.right, lessThanOrEqualTo(smallScreen.width));
    });
  });

  group('calcPopupPosition maxHeight constraint (half-screen cap removed)', () {
    // selection 放在靠顶部，留足下方空间，让 height 完全由 maxHeight 决定。
    const Rect selectionRect = Rect.fromLTWH(400, 100, 40, 24);
    const Size screen = Size(1920, 1080);

    test('small maxHeight caps the popup height to <= maxHeight', () {
      final Rect popupRect = calcPopupPosition(
        selectionRect: selectionRect,
        screen: screen,
        maxHeight: 300,
      );

      expect(popupRect.height, 300);
      expect(popupRect.top, greaterThanOrEqualTo(0));
      expect(popupRect.bottom, lessThanOrEqualTo(screen.height));
    });

    test('large maxHeight grows past half-screen (no *0.5 cap)', () {
      final Rect popupRect = calcPopupPosition(
        selectionRect: selectionRect,
        screen: screen,
        maxHeight: 900,
      );

      // 旧实现这里会被 0.5*1080=540 顶死；去掉 *0.5 后真正取到 maxHeight=900。
      expect(popupRect.height, 900);
      expect(popupRect.height, greaterThan(screen.height / 2));
      expect(popupRect.top, greaterThanOrEqualTo(0));
      expect(popupRect.bottom, lessThanOrEqualTo(screen.height));
    });

    test('larger maxHeight yields a taller popup', () {
      final Rect short = calcPopupPosition(
        selectionRect: selectionRect,
        screen: screen,
        maxHeight: 300,
      );
      final Rect tall = calcPopupPosition(
        selectionRect: selectionRect,
        screen: screen,
        maxHeight: 700,
      );

      expect(tall.height, greaterThan(short.height));
      expect(tall.height, 700);
    });
  });

  group('calcPopupPosition never covers the selection (BUG-098)', () {
    // selection 在垂直中线偏上：下方空间略大于上方但都装不下整高弹窗。旧实现
    // 走「below」分支后用 top.clamp(maxTop) 把弹窗顶边拉到选区之上 → 盖住选中词。
    test('tight-fit below: popup top stays at/below the selection bottom', () {
      const Rect selectionRect = Rect.fromLTWH(100, 250, 40, 20);
      const Size screen = Size(800, 600);
      final Rect popupRect = calcPopupPosition(
        selectionRect: selectionRect,
        screen: screen,
        maxHeight: 360,
      );

      // 弹窗顶边不得越过选区底边（否则覆盖被查的词）。
      expect(popupRect.top, greaterThanOrEqualTo(selectionRect.bottom));
      // 仍在屏内。
      expect(popupRect.bottom, lessThanOrEqualTo(600));
    });

    test('placed above keeps its bottom at/above the selection top', () {
      // 选区靠近底部：弹窗放上方，底边不得越过选区顶边。
      const Rect selectionRect = Rect.fromLTWH(100, 560, 40, 30);
      const Size screen = Size(800, 600);
      final Rect popupRect = calcPopupPosition(
        selectionRect: selectionRect,
        screen: screen,
        maxHeight: 360,
      );

      expect(popupRect.bottom, lessThanOrEqualTo(selectionRect.top));
      expect(popupRect.top, greaterThanOrEqualTo(0));
    });
  });

  testWidgets('empty popup layer fits a compact surface without overflow', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      buildTestApp(
        SizedBox(
          width: 80,
          height: 48,
          child: DictionaryPopupLayer(
            result: null,
            isSearching: false,
            webViewKey: GlobalKey<DictionaryPopupWebViewState>(),
            onDismiss: () {},
            onTextSelected: (text, rect) {},
            onLinkClick: (query, rect) {},
            onMineEntry: (fields) async => const MinePopupResult(),
            onDuplicateCheck: (expression, reading) async => false,
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(HibikiPopupSurface), findsOneWidget);
  });

  testWidgets('borderless popup layer still uses shared popup surface', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      buildTestApp(
        SizedBox(
          width: 240,
          height: 160,
          child: DictionaryPopupLayer(
            result: null,
            isSearching: false,
            webViewKey: GlobalKey<DictionaryPopupWebViewState>(),
            showBorder: false,
            swipeDismissible: false,
            onDismiss: () {},
            onTextSelected: (text, rect) {},
            onLinkClick: (query, rect) {},
            onMineEntry: (fields) async => const MinePopupResult(),
            onDuplicateCheck: (expression, reading) async => false,
          ),
        ),
      ),
    );

    expect(find.byType(DictionaryPopupLayer), findsOneWidget);
    expect(find.byType(SwipeDismissWrapper), findsNothing);
    expect(find.byType(HibikiPopupSurface), findsOneWidget);
  });

  group('calcPopupPosition vertical writing avoids the current column', () {
    const Size screen = Size(1000, 800);

    test('vertical-rl prefers the already-read (right) side of the column', () {
      const Rect sel = Rect.fromLTWH(480, 300, 30, 30);
      final Rect popup = calcPopupPosition(
        selectionRect: sel,
        screen: screen,
        maxWidth: 360,
        maxHeight: 360,
        verticalWriting: true,
      );
      expect(popup.left, greaterThanOrEqualTo(sel.right),
          reason: '竖排弹窗须在当前列右侧，不压列');
      expect(popup.right, lessThanOrEqualTo(screen.width));
    });

    test('falls to the left side when the right has no room', () {
      const Rect sel = Rect.fromLTWH(960, 300, 30, 30);
      final Rect popup = calcPopupPosition(
        selectionRect: sel,
        screen: screen,
        maxWidth: 360,
        maxHeight: 360,
        verticalWriting: true,
      );
      expect(popup.right, lessThanOrEqualTo(sel.left),
          reason: '右侧无空间时弹窗须落在当前列左侧');
      expect(popup.left, greaterThanOrEqualTo(0));
    });

    test('never horizontally overlaps the selection column', () {
      const Rect sel = Rect.fromLTWH(500, 200, 28, 120);
      final Rect popup = calcPopupPosition(
        selectionRect: sel,
        screen: screen,
        maxWidth: 360,
        maxHeight: 360,
        verticalWriting: true,
      );
      final bool onRight = popup.left >= sel.right;
      final bool onLeft = popup.right <= sel.left;
      expect(onRight || onLeft, isTrue, reason: '弹窗与当前列不得水平重叠');
    });

    test('stays within vertical reserves in vertical mode', () {
      const Rect sel = Rect.fromLTWH(480, 10, 30, 30);
      final Rect popup = calcPopupPosition(
        selectionRect: sel,
        screen: screen,
        maxWidth: 360,
        maxHeight: 360,
        topReserve: 100,
        bottomReserve: 120,
        verticalWriting: true,
      );
      expect(popup.top, greaterThanOrEqualTo(100), reason: '竖直方向仍须避让顶部预留');
      expect(popup.bottom, lessThanOrEqualTo(screen.height - 120),
          reason: '竖直方向仍须避让底部预留');
    });

    test('horizontal mode unchanged: still placed above/below selection', () {
      const Rect sel = Rect.fromLTWH(400, 380, 60, 24);
      final Rect popup = calcPopupPosition(
        selectionRect: sel,
        screen: screen,
        maxWidth: 360,
        maxHeight: 360,
        verticalWriting: false,
      );
      final bool below = popup.top >= sel.bottom;
      final bool above = popup.bottom <= sel.top;
      expect(below || above, isTrue, reason: '横排须维持上/下放置，避开当前行');
    });
  });

  group(
      'TODO-107: vertical writing falls back to above/below when neither '
      'side fits', () {
    // 窄屏 + 选区横向居中：左右两侧可用宽都 < minPopupWidth(200)，整宽弹窗两侧都放不下。
    // 左右避让只会把弹窗压成一根挡视线的窄竖条 → 应回退横排上/下避让，把整宽留给弹窗。
    test('narrow screen, centered selection: falls back to placeAboveBelow',
        () {
      // 屏宽 300、选区 x∈[140,160]：roomRight=roomLeft=130(<200)，竖向有充足空间。
      const Size screen = Size(300, 600);
      const Rect sel = Rect.fromLTWH(140, 50, 20, 20);
      final Rect popup = calcPopupPosition(
        selectionRect: sel,
        screen: screen,
        maxWidth: 360,
        maxHeight: 360,
        verticalWriting: true,
      );

      // 回退后走横排：弹窗放在选区下方（顶边不越选区底边），不被压成窄条。
      final bool below = popup.top >= sel.bottom;
      final bool above = popup.bottom <= sel.top;
      expect(below || above, isTrue, reason: '两侧都放不下时应回退上/下避让');
      // 横排回退把整宽给弹窗——比任一侧的窄竖条(<=130)宽得多，故水平上与当前列重叠。
      final bool overlapsColumn =
          popup.left < sel.right && popup.right > sel.left;
      expect(overlapsColumn, isTrue, reason: '回退后弹窗占整宽（不再贴列侧），证明确实回退而非竖排窄条');
      expect(popup.width, greaterThan(130), reason: '回退后宽度远超任一侧可用窄宽(130)');
    });

    test('min-height protection: no fallback when vertical room is too small',
        () {
      // 同样两侧都放不下，但选区几乎占满竖向高度 → 上下都没有 >=minPopupHeight 的空间，
      // 不应回退（回退后弹窗反而被压成更矮的横带），保留原竖排逻辑落在某一侧。
      const Size screen = Size(300, 200);
      // 选区高 180：roomBelow=200-6-(186+4)<0、roomAbove=(6-4)-6<0，均 < minPopupHeight。
      const Rect sel = Rect.fromLTWH(140, 6, 20, 180);
      final Rect popup = calcPopupPosition(
        selectionRect: sel,
        screen: screen,
        maxWidth: 360,
        maxHeight: 360,
        verticalWriting: true,
      );

      // 未回退：仍走竖排侧放——弹窗与当前列不水平重叠（在列左/右侧）。
      final bool onRight = popup.left >= sel.right;
      final bool onLeft = popup.right <= sel.left;
      expect(onRight || onLeft, isTrue, reason: '竖向空间不足时不回退，保留竖排侧放（与列不水平重叠）');
    });

    test('reverting the fallback turns the narrow-screen case red', () {
      // 守卫：撤掉 TODO-107 回退增强（即把判据当作恒不触发），narrow-screen 用例会落到
      // 竖排侧放——此时弹窗与当前列不水平重叠。本断言要求“水平重叠”，故撤增强即转红。
      const Size screen = Size(300, 600);
      const Rect sel = Rect.fromLTWH(140, 50, 20, 20);
      final Rect popup = calcPopupPosition(
        selectionRect: sel,
        screen: screen,
        maxWidth: 360,
        maxHeight: 360,
        verticalWriting: true,
      );
      final bool overlapsColumn =
          popup.left < sel.right && popup.right > sel.left;
      expect(overlapsColumn, isTrue);
    });
  });

  group('TODO-108: dockedPopupRect pins a full-width bottom panel', () {
    const Size screen = Size(800, 600);

    test('ignores selection: full-width panel pinned to the bottom', () {
      final Rect docked = dockedPopupRect(
        screen: screen,
        dockedHeight: 360,
      );

      // 全宽（减左右内边距），贴屏底（减底内边距），与选区无关。
      expect(docked.left, 6, reason: '左边距=inset');
      expect(docked.width, 800 - 6 * 2, reason: '占满屏宽减左右内边距');
      expect(docked.right, lessThanOrEqualTo(800));
      expect(docked.bottom, lessThanOrEqualTo(600 - 6), reason: '底边贴屏底减底内边距');
      expect(docked.height, 360);
    });

    test('docked rect is identical regardless of where the word sits', () {
      // 同一屏、相同参数 → 结果只取决于屏与高度，不含选区。
      final Rect a = dockedPopupRect(screen: screen, dockedHeight: 300);
      final Rect b = dockedPopupRect(screen: screen, dockedHeight: 300);
      expect(a, b, reason: 'dock 矩形是选区无关的纯函数');
    });

    test('clamps docked height to the available space and respects reserves',
        () {
      final Rect docked = dockedPopupRect(
        screen: screen,
        dockedHeight: 5000, // 远超屏高
        bottomReserve: 80,
        topReserve: 40,
      );

      expect(docked.top, greaterThanOrEqualTo(40), reason: '不越过顶部预留');
      expect(docked.bottom, lessThanOrEqualTo(600 - 80), reason: '不越过底部预留');
      expect(docked.left, greaterThanOrEqualTo(0));
      expect(docked.right, lessThanOrEqualTo(800));
    });

    test('survives a reserve larger than the surface without throwing', () {
      final Rect docked = dockedPopupRect(
        screen: const Size(80, 48),
        dockedHeight: 360,
        bottomReserve: 80, // > 屏高
      );
      expect(docked.left, greaterThanOrEqualTo(0));
      expect(docked.top, greaterThanOrEqualTo(0));
      expect(docked.right, lessThanOrEqualTo(80));
      expect(docked.bottom, lessThanOrEqualTo(48));
      expect(docked.width.isFinite && docked.height.isFinite, isTrue);
    });
  });
}
