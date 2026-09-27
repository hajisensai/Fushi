import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_engine/epub/epub_book.dart' show EpubImageRef;
import 'package:fushi/src/reader/reader_gallery_page.dart';

/// BUG-2723：插图册顶栏把标题、计数、过滤分段按钮、定位、关闭五样塞在一行。
/// iPhone 竖屏（390pt）上计数被挤成 0 宽，英文等长文案整行 RenderFlex 溢出，
/// 看上去就是「顶部显示不全」。现在标题与计数上下叠放，窄窗过滤按钮另起一行。
const ValueKey<String> _count = ValueKey<String>('fushi_gallery_count');
const ValueKey<String> _filter = ValueKey<String>('fushi_gallery_filter');
const ValueKey<String> _close = ValueKey<String>('fushi_gallery_close');

Future<void> _pumpAt(
  WidgetTester tester, {
  required AppLocale locale,
  required double width,
}) async {
  LocaleSettings.setLocale(locale);
  addTearDown(() => LocaleSettings.setLocale(AppLocale.en));
  tester.view.physicalSize = Size(width * 3, 844 * 3);
  tester.view.devicePixelRatio = 3;
  // 灵动岛机型的顶部安全区。
  tester.view.padding = const FakeViewPadding(top: 59 * 3);
  tester.view.viewPadding = const FakeViewPadding(top: 59 * 3);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: ReaderGalleryPage(
        images: <EpubImageRef>[
          for (int i = 0; i < 20; i++)
            EpubImageRef(
              chapterIndex: i ~/ 3,
              orderInBook: i,
              src: 'img$i.png',
              revealKey: 'img$i.png',
            ),
        ],
        currentChapter: 3,
        fileForRef: (_) => null,
        onOpenImage: (_) {},
        onJumpTo: (_) {},
      ),
    ),
  );
  await tester.pump();
}

void main() {
  for (final AppLocale locale in <AppLocale>[AppLocale.en, AppLocale.zhCn]) {
    for (final double width in <double>[320, 375, 390, 430]) {
      testWidgets(
          '手机竖屏 ${locale.languageTag} ${width.toInt()}pt：顶栏不溢出、'
          '计数可见、过滤按钮在第二行', (WidgetTester tester) async {
        await _pumpAt(tester, locale: locale, width: width);

        expect(tester.takeException(), isNull);
        final Rect count = tester.getRect(find.byKey(_count));
        expect(count.width, greaterThan(0), reason: '计数被挤成 0 宽');
        // 整条顶栏在安全区之下、屏幕之内。
        final Rect close = tester.getRect(find.byKey(_close));
        expect(close.top, greaterThanOrEqualTo(59));
        expect(close.right, lessThanOrEqualTo(width));
        final Rect filter = tester.getRect(find.byKey(_filter));
        expect(filter.top, greaterThanOrEqualTo(close.bottom));
        expect(filter.right, lessThanOrEqualTo(width));
      });
    }
  }

  testWidgets('宽窗：过滤按钮与标题同一行', (WidgetTester tester) async {
    await _pumpAt(tester, locale: AppLocale.en, width: 800);

    expect(tester.takeException(), isNull);
    final Rect close = tester.getRect(find.byKey(_close));
    final Rect filter = tester.getRect(find.byKey(_filter));
    expect(filter.top, lessThan(close.bottom));
    expect(filter.right, lessThanOrEqualTo(close.left));
  });
}
