import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show buildSpreadPageHtml;
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_core/fushi_core.dart';

Future<ReaderSettings> _settings({
  String writingMode = 'horizontal-tb',
  String viewMode = 'paginated',
  int pageColumns = 0,
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
  await settings.setPageColumns(pageColumns);
  await settings.setPageCrease(crease);
  return settings;
}

const String _creaseMarker = '中缝折痕（page crease）';

void main() {
  group('foldPageColumnsOverride（折叠屏书本姿态）', () {
    test('横排翻页 + 每页列数自动 → 2 栏', () async {
      final ReaderSettings s = await _settings();
      expect(
        ReaderContentStyles.foldPageColumnsOverride(
          bookPosture: true,
          settings: s,
        ),
        2,
      );
      expect(
        ReaderContentStyles.foldPageColumnsOverride(
          bookPosture: false,
          settings: s,
        ),
        isNull,
      );
    });

    test('用户显式列数 / 竖排 / 滚动 / VN 不覆盖', () async {
      for (final ReaderSettings s in <ReaderSettings>[
        await _settings(pageColumns: 1),
        await _settings(pageColumns: 3),
        await _settings(writingMode: 'vertical-rl'),
        await _settings(viewMode: 'continuous'),
        await _settings(viewMode: 'vn'),
      ]) {
        expect(
          ReaderContentStyles.foldPageColumnsOverride(
            bookPosture: true,
            settings: s,
          ),
          isNull,
        );
      }
    });

    test('覆盖值真的进了 multicol 列数', () async {
      final ReaderSettings s = await _settings();
      expect(
        ReaderContentStyles.css(settings: s),
        isNot(contains('column-count:')),
      );
      expect(
        ReaderContentStyles.css(settings: s, pageColumnsOverride: 2),
        contains('column-count: 2 !important;'),
      );
    });
  });

  group('foldColumnGapPx（铰链不压字）', () {
    test('两栏横排翻页：栏间隙 = 22 + 铰链缝；无铰链缝不覆盖', () async {
      final ReaderSettings s = await _settings();
      expect(
        ReaderContentStyles.foldColumnGapPx(
          hingeGutterPx: 24,
          effectivePageColumns: 2,
          settings: s,
        ),
        46,
      );
      expect(
        ReaderContentStyles.foldColumnGapPx(
          hingeGutterPx: 0,
          effectivePageColumns: 2,
          settings: s,
        ),
        isNull,
      );
      expect(
        ReaderContentStyles.foldColumnGapPx(
          hingeGutterPx: 24,
          effectivePageColumns: 1,
          settings: s,
        ),
        isNull,
        reason: '单栏没有「两页之间」，铰链缝不适用',
      );
    });

    test('column-gap 与子列宽推算用同一个间隙（JS 页步回读 column-gap，三者同源）', () async {
      final ReaderSettings s = await _settings();
      final String css = ReaderContentStyles.css(
        settings: s,
        pageColumnsOverride: 2,
        columnGapOverridePx: 46,
      );
      expect(css, contains('column-gap: 46px !important;'));
      expect(css, contains(' - 46px) / 2))'));
      expect(css, isNot(contains('column-gap: 22px')));
    });
  });

  test('EPUB 图片跨页：铰链缝进两半之间，无缝时不发', () {
    String html(double gutter) => buildSpreadPageHtml(
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
      final ReaderSettings s = await _settings(pageColumns: 2);
      expect(
        ReaderContentStyles.css(settings: s),
        isNot(contains(_creaseMarker)),
      );
    });

    test('开启 + 横排两栏 → html::after 竖向阴影，落在 content-box 中线', () async {
      final ReaderSettings s = await _settings(pageColumns: 2, crease: true);
      final String css = ReaderContentStyles.css(settings: s);
      expect(css, contains(_creaseMarker));
      final String rule = css.substring(css.indexOf(_creaseMarker));
      expect(rule, contains('html::after'));
      expect(rule, contains('pointer-events: none'));
      expect(rule, contains('linear-gradient(to right'));
      expect(rule, contains('width: 56px'));
      expect(rule, contains('var(--page-width, 100vw)'));
    });

    test('书本姿态的自动 2 栏同样出折痕', () async {
      final ReaderSettings s = await _settings(crease: true);
      expect(
        ReaderContentStyles.css(settings: s),
        isNot(contains(_creaseMarker)),
      );
      expect(
        ReaderContentStyles.css(settings: s, pageColumnsOverride: 2),
        contains(_creaseMarker),
      );
    });

    test('竖排上下两栏 → 横向阴影', () async {
      final ReaderSettings s = await _settings(
        writingMode: 'vertical-rl',
        pageColumns: 2,
        crease: true,
      );
      final String css = ReaderContentStyles.css(settings: s);
      final String rule = css.substring(css.indexOf(_creaseMarker));
      expect(rule, contains('linear-gradient(to bottom'));
      expect(rule, contains('height: 56px'));
    });

    test('单栏 / 三栏 / 滚动 / VN 不发（没有「两页之间」）', () async {
      for (final ReaderSettings s in <ReaderSettings>[
        await _settings(pageColumns: 1, crease: true),
        await _settings(pageColumns: 3, crease: true),
        await _settings(pageColumns: 2, viewMode: 'continuous', crease: true),
        await _settings(pageColumns: 2, viewMode: 'vn', crease: true),
      ]) {
        expect(
          ReaderContentStyles.css(settings: s),
          isNot(contains(_creaseMarker)),
        );
      }
    });
  });
}
