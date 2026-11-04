import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/page_focus_ownership.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show readerCanOwnFocus;
import 'package:material_ui/material_ui.dart';

/// 反馈 IhPv0LqmYU / -RZluBdDUL：小说阅读器里打开高级制卡对话框，点句子输入框
/// 键盘弹出即收回。查词弹窗在对话框期间只是停靠屏外，键盘改视口 → 弹窗 JS 重报
/// 高度 → popupRendered；判据这一支不看「本页路由是不是当前路由」，于是把焦点
/// 从对话框输入框抢回正文。任何回收原因都不许夺走压在阅读器上面的路由的焦点。
void main() {
  bool can(
    FocusReclaimCause cause, {
    bool lyricsMode = false,
    bool dictionaryShown = false,
    bool chromeHasFocus = false,
    bool contentReady = true,
    bool caretBusy = false,
    required bool routeIsCurrent,
  }) => readerCanOwnFocus(
    cause,
    lyricsMode: lyricsMode,
    dictionaryShown: dictionaryShown,
    chromeHasFocus: chromeHasFocus,
    contentReady: contentReady,
    caretBusy: caretBusy,
    routeIsCurrent: routeIsCurrent,
  );

  test('no cause reclaims while another route sits above the reader', () {
    for (final FocusReclaimCause cause in FocusReclaimCause.values) {
      for (final bool lyricsMode in <bool>[false, true]) {
        for (final bool dictionaryShown in <bool>[false, true]) {
          expect(
            can(
              cause,
              lyricsMode: lyricsMode,
              dictionaryShown: dictionaryShown,
              routeIsCurrent: false,
            ),
            isFalse,
            reason: '$cause lyrics=$lyricsMode dict=$dictionaryShown',
          );
        }
      }
    }
  });

  test('current route keeps the existing answers', () {
    // 弹窗可见时 popupRendered 仍把焦点拉回正文（BUG-1071 ②）。
    expect(
      can(
        FocusReclaimCause.popupRendered,
        dictionaryShown: true,
        routeIsCurrent: true,
      ),
      isTrue,
    );
    expect(can(FocusReclaimCause.gesture, routeIsCurrent: true), isTrue);
    expect(can(FocusReclaimCause.popupDismissed, routeIsCurrent: true), isTrue);
    expect(can(FocusReclaimCause.chromeToggled, routeIsCurrent: true), isTrue);
  });

  testWidgets('popupRendered under a dialog leaves the dialog TextField '
      'focused', (WidgetTester tester) async {
    final FocusNode readerNode = FocusNode(debugLabel: 'reader');
    final FocusNode fieldNode = FocusNode(debugLabel: 'dialog-field');
    addTearDown(readerNode.dispose);
    addTearDown(fieldNode.dispose);
    late BuildContext pageContext;
    // 与阅读器 `_canOwnReaderFocus` 同一接法：路由是否当前取自本页 context。
    final PageFocusOwnership ownership = PageFocusOwnership(
      node: readerNode,
      canOwn: (FocusReclaimCause cause) {
        final ModalRoute<Object?>? owner = ModalRoute.of(pageContext);
        return readerCanOwnFocus(
          cause,
          lyricsMode: false,
          dictionaryShown: true,
          chromeHasFocus: false,
          contentReady: true,
          caretBusy: false,
          routeIsCurrent: owner == null || owner.isCurrent,
        );
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            pageContext = context;
            return Focus(
              focusNode: readerNode,
              autofocus: true,
              child: const SizedBox.expand(),
            );
          },
        ),
      ),
    );
    await tester.pump();
    expect(readerNode.hasFocus, isTrue);

    unawaited(
      showDialog<void>(
        context: pageContext,
        builder: (BuildContext context) =>
            Dialog(child: TextField(focusNode: fieldNode, autofocus: true)),
      ),
    );
    await tester.pumpAndSettle();
    expect(fieldNode.hasFocus, isTrue);

    // 键盘弹出 → 弹窗 resize 重报高度 → onDictionaryPopupRendered。
    expect(ownership.reclaim(FocusReclaimCause.popupRendered), isFalse);
    await tester.pump();
    expect(fieldNode.hasFocus, isTrue);
    expect(readerNode.hasFocus, isFalse);

    // 对话框关掉后本页又是当前路由，判据照常放行。
    Navigator.of(pageContext).pop();
    await tester.pumpAndSettle();
    expect(ownership.reclaim(FocusReclaimCause.popupRendered), isTrue);
    await tester.pump();
    expect(readerNode.hasFocus, isTrue);
  });
}
