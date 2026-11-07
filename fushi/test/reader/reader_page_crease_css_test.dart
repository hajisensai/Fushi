import 'dart:ui' show Size;

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show buildSpreadPageHtml;
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_page_spread.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_core/fushi_core.dart';

Future<ReaderSettings> _settings({
  String writingMode = 'horizontal-tb',
  String viewMode = 'paginated',
  ReaderPageSpread spread = ReaderPageSpread.auto,
  bool crease = false,
}) async {
  final FushiDatabase db = FushiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
  addTearDown(db.close);
  final ReaderSettings settings = ReaderSettings(db);
  await settings.refreshFromDb();
  await settings.setWritingMode(writingMode);
  await settings.setViewMode(viewMode);
  await settings.setPageSpread(spread);
  await settings.setPageCrease(crease);
  return settings;
}

/// 阅读器页面同一条路径：偏好 + 窗口 + 折痕 → 本次排版（[resolveReaderSpreadLayout]）。
ReaderSpreadLayout _layoutFor(
  ReaderSettings s, {
  bool fold = false,
  Size window = const Size(400, 800),
}) => resolveReaderSpreadLayout(
  preference: s.pageSpread,
  viewMode: s.viewMode,
  writingMode: s.writingMode,
  hasFoldSpine: fold,
  window: window,
);

const String _creaseMarker = '中缝折痕（page crease）';
const String _spreadMarker = '竖排对开（竖排双页）';

void main() {
  group('横排双页进 multicol', () {
    test('「自动」在折叠屏上解析成 2 栏，真的进了 column-count', () async {
      final ReaderSettings s = await _settings();
      expect(
        ReaderContentStyles.css(settings: s, spreadLayout: _layoutFor(s)),
        isNot(contains('column-count:')),
      );
      expect(
        ReaderContentStyles.css(
          settings: s,
          spreadLayout: _layoutFor(s, fold: true),
        ),
        contains('column-count: 2 !important;'),
      );
    });
  });

  group('foldColumnGapPx（铰链不压字）', () {
    test('双页：间隙 = 22 + 铰链缝；无铰链缝 / 单页不覆盖', () {
      expect(
        ReaderContentStyles.foldColumnGapPx(
          hingeGutterPx: 24,
          layout: ReaderSpreadLayout.horizontalDouble,
        ),
        46,
      );
      expect(
        ReaderContentStyles.foldColumnGapPx(
          hingeGutterPx: 24,
          layout: ReaderSpreadLayout.verticalDouble,
        ),
        46,
      );
      expect(
        ReaderContentStyles.foldColumnGapPx(
          hingeGutterPx: 0,
          layout: ReaderSpreadLayout.horizontalDouble,
        ),
        isNull,
      );
      expect(
        ReaderContentStyles.foldColumnGapPx(
          hingeGutterPx: 24,
          layout: ReaderSpreadLayout.single,
        ),
        isNull,
        reason: '单页没有「两页之间」，铰链缝不适用',
      );
    });

    test('column-gap 与子列宽推算用同一个间隙（JS 页步回读 column-gap，三者同源）', () async {
      final ReaderSettings s = await _settings();
      final String css = ReaderContentStyles.css(
        settings: s,
        spreadLayout: ReaderSpreadLayout.horizontalDouble,
        columnGapOverridePx: 46,
      );
      expect(css, contains('column-gap: 46px !important;'));
      expect(css, contains(' - 46px) / 2))'));
      expect(css, isNot(contains('column-gap: 22px')));
    });
  });

  group('竖排双页 = 对开', () {
    test('对开几何：column-wrap 行换行，整段在 @supports 里，补一页空白页', () async {
      final ReaderSettings s = await _settings(writingMode: 'vertical-rl');
      expect(
        ReaderContentStyles.css(settings: s),
        isNot(contains(_spreadMarker)),
      );
      final String css = ReaderContentStyles.css(
        settings: s,
        spreadLayout: ReaderSpreadLayout.verticalDouble,
      );
      final int block = css.indexOf(_spreadMarker);
      expect(block, isNonNegative);
      final String rule = css.substring(block);
      expect(rule, contains('@supports (column-wrap: wrap) {'));
      expect(rule, contains('column-count: 1 !important;'));
      expect(rule, contains('column-wrap: wrap !important;'));
      expect(rule, contains('row-gap: 22px !important;'));
      expect(
        rule,
        contains(' - 22px) / 2)) !important;'),
        reason: '一页宽 = (content-box 宽 − 页间隙) / 2，一屏右页 + 左页',
      );
      expect(rule, contains('break-before: column !important;'));
      // 对开声明必须排在分页布局之后，才能压过布局里的 column-count。
      expect(block, greaterThan(css.indexOf('column-fill: auto !important;')));
    });

    test('偏好「双页」不看窗口也排对开（css 不带 spreadLayout 时按偏好解析）', () async {
      final ReaderSettings s = await _settings(
        writingMode: 'vertical-rl',
        spread: ReaderPageSpread.double,
      );
      final String css = ReaderContentStyles.css(settings: s);
      expect(css, contains(_spreadMarker));
      expect(css, isNot(contains('column-count: 2 !important;')));
    });

    test('横排 / 滚动 / VN 不发对开', () async {
      for (final ReaderSettings s in <ReaderSettings>[
        await _settings(spread: ReaderPageSpread.double),
        await _settings(
          writingMode: 'vertical-rl',
          viewMode: 'continuous',
          spread: ReaderPageSpread.double,
        ),
        await _settings(
          writingMode: 'vertical-rl',
          viewMode: 'vn',
          spread: ReaderPageSpread.double,
        ),
      ]) {
        expect(
          ReaderContentStyles.css(settings: s, spreadLayout: _layoutFor(s)),
          isNot(contains(_spreadMarker)),
        );
      }
    });

    test('铰链缝加宽的是两页之间的 row-gap', () async {
      final ReaderSettings s = await _settings(writingMode: 'vertical-rl');
      final String css = ReaderContentStyles.css(
        settings: s,
        spreadLayout: ReaderSpreadLayout.verticalDouble,
        columnGapOverridePx: 46,
      );
      final String rule = css.substring(css.indexOf(_spreadMarker));
      expect(rule, contains('row-gap: 46px !important;'));
      expect(rule, contains(' - 46px) / 2)) !important;'));
    });

    test('中缝折痕：对开时画竖线，且与对开几何同在 @supports 里', () async {
      final ReaderSettings s = await _settings(
        writingMode: 'vertical-rl',
        crease: true,
      );
      expect(
        ReaderContentStyles.css(settings: s),
        isNot(contains(_creaseMarker)),
      );
      final String css = ReaderContentStyles.css(
        settings: s,
        spreadLayout: ReaderSpreadLayout.verticalDouble,
      );
      final int crease = css.indexOf(_creaseMarker);
      expect(crease, isNonNegative);
      final String rule = css.substring(crease);
      expect(rule, contains('linear-gradient(to right'));
      expect(rule, contains('width: 22px'));
      expect(
        css.substring(0, css.indexOf('/* $_creaseMarker')).trimRight(),
        endsWith('@supports (column-wrap: wrap) {'),
        reason: '不支持 column-wrap 的 WebView 退回竖排单条，不能在正文中间画一道阴影',
      );
    });
  });

  test('EPUB 图片跨页：铰链缝进两半之间，无缝时不发', () {
    String html(double gutter) => buildSpreadPageHtml(
      navigationGeneration: 1,
      leftUrl: 'l.jpg',
      rightUrl: 'r.jpg',
      swipeDistThreshold: 44,
      swipeFastDistThreshold: 22,
      swipeFastVelocity: 300,
      gutterPx: gutter,
    );
    expect(html(24.4), contains('.spread{column-gap:25px}'));
    expect(html(0), isNot(contains('column-gap')));
  });

  group('中缝折痕 CSS', () {
    test('关闭时不发', () async {
      final ReaderSettings s = await _settings(spread: ReaderPageSpread.double);
      expect(
        ReaderContentStyles.css(settings: s),
        isNot(contains(_creaseMarker)),
      );
    });

    test('开启 + 横排双页 → html::after 竖向阴影，落在 content-box 中线', () async {
      final ReaderSettings s = await _settings(
        spread: ReaderPageSpread.double,
        crease: true,
      );
      final String css = ReaderContentStyles.css(settings: s);
      expect(css, contains(_creaseMarker));
      final String rule = css.substring(css.indexOf(_creaseMarker));
      expect(rule, contains('html::after'));
      expect(rule, contains('pointer-events: none'));
      expect(rule, contains('linear-gradient(to right'));
      // 阴影宽 = 栏间隙（默认 22px），只落在两页之间的空白里、不压正文。
      expect(rule, contains('width: 22px'));
      expect(rule, contains(' - 11.0px)'));
      expect(rule, contains('var(--page-width, 100vw)'));
    });

    test('折痕加宽栏间隙时阴影跟着加宽', () async {
      final ReaderSettings s = await _settings(
        spread: ReaderPageSpread.double,
        crease: true,
      );
      final String css = ReaderContentStyles.css(
        settings: s,
        columnGapOverridePx: 47,
      );
      final String rule = css.substring(css.indexOf(_creaseMarker));
      expect(rule, contains('width: 47px'));
      expect(rule, contains(' - 23.5px)'));
    });

    test('「自动」解析成双页（宽屏 / 折叠屏）同样出折痕', () async {
      final ReaderSettings s = await _settings(crease: true);
      expect(
        ReaderContentStyles.css(settings: s, spreadLayout: _layoutFor(s)),
        isNot(contains(_creaseMarker)),
      );
      expect(
        ReaderContentStyles.css(
          settings: s,
          spreadLayout: _layoutFor(s, window: const Size(1280, 800)),
        ),
        contains(_creaseMarker),
      );
      expect(
        ReaderContentStyles.css(
          settings: s,
          spreadLayout: _layoutFor(s, fold: true),
        ),
        contains(_creaseMarker),
      );
    });

    test('单页 / 滚动 / VN 不发（没有「两页之间」）', () async {
      for (final ReaderSettings s in <ReaderSettings>[
        await _settings(spread: ReaderPageSpread.single, crease: true),
        await _settings(
          spread: ReaderPageSpread.double,
          viewMode: 'continuous',
          crease: true,
        ),
        await _settings(
          spread: ReaderPageSpread.double,
          viewMode: 'vn',
          crease: true,
        ),
      ]) {
        expect(
          ReaderContentStyles.css(settings: s, spreadLayout: _layoutFor(s)),
          isNot(contains(_creaseMarker)),
        );
      }
    });
  });
}
