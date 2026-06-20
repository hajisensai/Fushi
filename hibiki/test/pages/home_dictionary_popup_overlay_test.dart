import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/focus_geometry.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';
import 'package:hibiki/src/utils/components/clipboard_lookup_text_panel.dart';

/// TODO-617 M0 guard: HomeDictionaryPage popup stack lifted to the root Overlay
/// (full window), no longer clamped by the result sub-area. Guards screen=window,
/// popup layer Clip.none, and unified screen-space coordinates.
void main() {
  const Size physical = Size(1000, 800);

  Widget harness({required double scale, required Widget home}) =>
      HibikiAppUiScale(scale: scale, child: MaterialApp(home: home));

  Future<(Rect, OverlayEntry)> insertPopup(
    WidgetTester tester,
    BuildContext pageContext, {
    required Rect selectionRect,
    required bool neutralize,
  }) async {
    final GlobalKey popupKey = GlobalKey();
    Widget overlayChild = LayoutBuilder(
      builder: (BuildContext _, BoxConstraints cons) {
        final Rect pos = calcPopupPosition(
          selectionRect: selectionRect,
          screen: Size(cons.maxWidth, cons.maxHeight),
          maxWidth: 360,
          maxHeight: 360,
        );
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned(
              left: pos.left,
              top: pos.top,
              width: pos.width,
              height: pos.height,
              child: SizedBox(key: popupKey),
            ),
          ],
        );
      },
    );
    if (neutralize) {
      overlayChild = HibikiAppUiScaleNeutralizer(child: overlayChild);
    }
    final OverlayEntry entry = OverlayEntry(builder: (BuildContext _) {
      return overlayChild;
    });
    Overlay.of(pageContext, rootOverlay: true).insert(entry);
    await tester.pumpAndSettle();
    final Rect rect = globalRectOfBox(
        popupKey.currentContext!.findRenderObject()! as RenderBox);
    return (rect, entry);
  }

  testWidgets(
      'home popup in root Overlay (neutralized) hugs the selected word ON '
      'SCREEN across scales (clamp-free, full window)',
      (WidgetTester tester) async {
    tester.view.physicalSize = physical;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    for (final double scale in <double>[1.0, 1.5, 0.8]) {
      final GlobalKey charKey = GlobalKey();
      final GlobalKey pageKey = GlobalKey();
      await tester.pumpWidget(harness(
        scale: scale,
        home: Stack(
          key: pageKey,
          children: <Widget>[
            Positioned(
              left: 300,
              top: 40,
              width: 40,
              height: 50,
              child: SizedBox(key: charKey),
            ),
          ],
        ),
      ));

      final BuildContext pageContext = pageKey.currentContext!;
      final Rect charScreen = globalRectOfBox(
          charKey.currentContext!.findRenderObject()! as RenderBox);

      final (Rect popupScreen, OverlayEntry entry) = await insertPopup(
        tester,
        pageContext,
        selectionRect: charScreen,
        neutralize: true,
      );

      expect(popupScreen.left, closeTo(charScreen.left, 2.0),
          reason: 'popup x aligns with the char on screen across scales');
      expect(popupScreen.top, closeTo(charScreen.bottom + 4, 2.0),
          reason: 'popup sits just below the char on screen');

      entry.remove();
      entry.dispose();
      await tester.pump();
    }
  });

  testWidgets(
      'WITHOUT the neutralizer the same raw screen rect lands the popup off by '
      'the scale factor (proves the neutralizer is required)',
      (WidgetTester tester) async {
    tester.view.physicalSize = physical;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const double scale = 1.5;
    final GlobalKey charKey = GlobalKey();
    final GlobalKey pageKey = GlobalKey();
    await tester.pumpWidget(harness(
      scale: scale,
      home: Stack(
        key: pageKey,
        children: <Widget>[
          Positioned(
            left: 300,
            top: 200,
            width: 40,
            height: 50,
            child: SizedBox(key: charKey),
          ),
        ],
      ),
    ));
    final BuildContext pageContext = pageKey.currentContext!;
    final Rect charScreen = globalRectOfBox(
        charKey.currentContext!.findRenderObject()! as RenderBox);

    final (Rect popupScreen, OverlayEntry entry) = await insertPopup(
      tester,
      pageContext,
      selectionRect: charScreen,
      neutralize: false,
    );

    expect((popupScreen.top - (charScreen.bottom + 4)).abs(), greaterThan(50),
        reason: 'without neutralizer the popup is misplaced by the scale');

    entry.remove();
    entry.dispose();
    await tester.pump();
  });

  testWidgets(
      'SourceLookupTextPanel(globalCoordinates: true) reports the tapped char '
      'in screen coordinates (so the home popup in the root Overlay lands at '
      'the word, not offset by the result sub-area origin)',
      (WidgetTester tester) async {
    tester.view.physicalSize = physical;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Rect? reported;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.only(left: 120, top: 200),
            child: Align(
              alignment: Alignment.topLeft,
              child: SourceLookupTextPanel(
                text: 'XY',
                globalCoordinates: true,
                onLookup: (String query, Rect rect) => reported = rect,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('X'));
    await tester.pump();

    expect(reported, isNotNull);
    final Rect charScreen = tester.getRect(find.text('X'));
    expect(reported!.left, closeTo(charScreen.left, 1.0),
        reason: 'global rect left equals the on-screen char left');
    expect(reported!.top, closeTo(charScreen.top, 1.0),
        reason: 'global rect top equals the on-screen char top');
    expect(reported!.top, greaterThan(100),
        reason: 'screen-space top carries the sub-area offset, not start at 0');
  });

  test(
      'home_dictionary_page mounts the popup stack in the root Overlay '
      '(full-window, Clip.none, neutralized), not a clamped sub-area Stack',
      () {
    final String page = File(
      'lib/src/pages/implementations/home_dictionary_page.dart',
    ).readAsStringSync();

    expect(page.contains('rootOverlay: true'), isTrue,
        reason: 'home popup stack must mount in the root Overlay');
    expect(page.contains('OverlayEntry'), isTrue,
        reason: 'home popup overlay uses an OverlayEntry like video');
    expect(page.contains('HibikiAppUiScaleNeutralizer('), isTrue,
        reason: 'overlay popup subtree must be neutralized for native density');
    expect(page.contains('clipBehavior: Clip.none'), isTrue,
        reason: 'overlay popup Stack must be Clip.none');
    // screen 来自整窗：弹窗栈在根 Overlay 的中和后 LayoutBuilder（rootOverlay: true 的
    // entry）取约束，而不再是结果子区域 LayoutBuilder。`rootOverlay: true` 是「screen=整窗」
    // 的唯一信号（screen 从 _buildPopupOverlay 内层 LayoutBuilder 来，等于整窗视口）。
    expect(page.contains('rootOverlay: true'), isTrue,
        reason: 'popup screen must be the whole window (root Overlay), not the '
            'result sub-area');

    expect(
        page.contains('_overlayInert') || page.contains('overlayInert'), isTrue,
        reason: 'must guard the root-Overlay rebuild during deactivate');
    expect(page.contains('void deactivate()'), isTrue,
        reason: 'deactivate must mark the overlay inert');

    expect(page.contains('popupWordScreenRect('), isTrue,
        reason:
            'top-level result-WebView lookup maps localRect to screen coords');
    expect(page.contains('globalCoordinates: true'), isTrue,
        reason: 'source-text panel reports screen coords for the overlay');
  });

  test(
      'dictionary_page_mixin still positions nested popups via '
      'popupWordScreenRect (screen-space) keeps its contract', () {
    final String mixin = File(
      'lib/src/pages/implementations/dictionary_page_mixin.dart',
    ).readAsStringSync();
    expect(mixin.contains('popupWordScreenRect('), isTrue,
        reason: 'nested layers keep mapping rects through the WebView box');
  });
}
