// BUG-4244：查词弹窗进程从没给 FushiToast 装 navigator key，弹窗里的提示全落到系统原生 toast，
// Android 12+ 把文字 toast 截成两行——「保存到」退回主机默认那句只剩「Cards now go to …」。
// 钉两件事：自绘通知胶囊把长句完整画出来（不限行、不省略）；弹窗入口真的把 key 装上并挂到词卡页。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/rendering.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:material_ui/material_ui.dart';

const String _longNotice =
    'The paired device no longer offers your chosen save location. Cards now '
    'go to its default. This sentence is deliberately long so it needs well '
    'over two lines on a phone-width screen.';

void main() {
  testWidgets('the overlay toast renders a long notice in full on a phone '
      'width', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final GlobalKey<NavigatorState> key = GlobalKey<NavigatorState>();
    FushiToast.navigatorKey = key;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );

    FushiToast.show(msg: _longNotice);
    await tester.pump(const Duration(milliseconds: 500));

    final Finder text = find.text(_longNotice);
    expect(text, findsOneWidget);
    final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
      text,
    );
    expect(paragraph.didExceedMaxLines, isFalse);
    final double lineHeight = paragraph.getFullHeightForCaret(
      const TextPosition(offset: 0),
    );
    expect(
      paragraph.size.height,
      greaterThan(lineHeight * 2.5),
      reason: 'needs at least three lines and gets them',
    );

    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  test('the dictionary popup entry point gives FushiToast its navigator', () {
    final String src = File('lib/popup_main.dart').readAsStringSync();
    expect(src, contains('FushiToast.navigatorKey = _toastNavigatorKey;'));
    expect(src, contains('navigatorKey: _toastNavigatorKey,'));
  });
}
