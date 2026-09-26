import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/pages/implementations/popup_dictionary_loading_view.dart';

/// 系统全局查词冷启动占位：旧实现在别的 app 画面正中裸画大转圈、且加载期间关不掉。
void main() {
  final ColorScheme cs =
      ColorScheme.fromSeed(seedColor: const Color(0xFF1F4959));

  Widget wrap(Widget child) => MaterialApp(
        home: Scaffold(backgroundColor: Colors.transparent, body: child),
      );

  Finder pill() => find.byType(LinearProgressIndicator);

  testWidgets('快速冷启动不闪任何加载态；慢了才在顶部居中淡入小胶囊', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(PopupDictionaryLoadingView(
      colorScheme: cs,
      onDismiss: () {},
    )));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(pill(), findsNothing);

    await tester.pump(kPopupLoadingRevealDelay);
    await tester.pump(const Duration(milliseconds: 300));
    expect(pill(), findsOneWidget);

    final Rect card = tester.getRect(find.byType(Material).last);
    expect(card.size, kPopupLoadingPillSize);
    expect(card.center.dx, 200, reason: '无锚点与词卡同样贴顶居中');
    expect(card.top, 8, reason: '与词卡同一外边距起点');
  });

  testWidgets('加载期间点外面即关窗（onDismiss）', (WidgetTester tester) async {
    int dismissed = 0;
    await tester.pumpWidget(wrap(PopupDictionaryLoadingView(
      colorScheme: cs,
      onDismiss: () => dismissed++,
      revealDelay: Duration.zero,
    )));
    await tester.tapAt(const Offset(20, 500));
    expect(dismissed, 1);
  });

  testWidgets('有锚点时贴被查字旁，而不是屏幕正中', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const Rect glyph = Rect.fromLTWH(40, 600, 24, 24);
    await tester.pumpWidget(wrap(PopupDictionaryLoadingView(
      colorScheme: cs,
      onDismiss: () {},
      anchorRect: glyph,
      revealDelay: Duration.zero,
    )));
    await tester.pump(const Duration(milliseconds: 300));

    final Rect card = tester.getRect(find.byType(Material).last);
    expect(card.size, kPopupLoadingPillSize);
    expect(card.overlaps(glyph), isFalse, reason: '不得遮住被查字');
    expect((card.center.dy - glyph.center.dy).abs(), lessThan(120),
        reason: '应贴在被查字附近，而不是屏幕正中');
  });

  test('popup_main 的未初始化分支接的是 PopupDictionaryLoadingView，不再裸转圈', () {
    final String src = File('lib/popup_main.dart').readAsStringSync();
    expect(src.contains('PopupDictionaryLoadingView('), isTrue);
    expect(src.contains('CircularProgressIndicator'), isFalse);
  });
}
