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

  group('foldVerticalSpread（竖排对开）', () {
    const String spreadMarker = '竖排对开（折叠屏书本姿态）';

    test('竖排翻页 + 每页列数自动 + 书本姿态 → 对开；其余不对开', () async {
      final ReaderSettings vertical = await _settings(
        writingMode: 'vertical-rl',
      );
      expect(
        ReaderContentStyles.foldVerticalSpread(
          bookPosture: true,
          settings: vertical,
        ),
        isTrue,
      );
      expect(
        ReaderContentStyles.foldVerticalSpread(
          bookPosture: false,
          settings: vertical,
        ),
        isFalse,
      );
      for (final ReaderSettings s in <ReaderSettings>[
        await _settings(),
        await _settings(writingMode: 'vertical-rl', pageColumns: 1),
        await _settings(writingMode: 'vertical-rl', pageColumns: 2),
        await _settings(writingMode: 'vertical-rl', viewMode: 'continuous'),
        await _settings(writingMode: 'vertical-rl', viewMode: 'vn'),
      ]) {
        expect(
          ReaderContentStyles.foldVerticalSpread(
            bookPosture: true,
            settings: s,
          ),
          isFalse,
          reason: '横排走两栏；用户显式列数 / 滚动 / VN 不对开',
        );
      }
      // 竖排不走「每页列数」覆盖：竖排的 2 栏是上下两条，挡不住竖向折痕。
      expect(
        ReaderContentStyles.foldPageColumnsOverride(
          bookPosture: true,
          settings: vertical,
        ),
        isNull,
      );
    });

    test('对开几何：column-wrap 行换行，整段在 @supports 里，补一页空白页', () async {
      final ReaderSettings s = await _settings(writingMode: 'vertical-rl');
      expect(
        ReaderContentStyles.css(settings: s),
        isNot(contains(spreadMarker)),
      );
      final String css = ReaderContentStyles.css(
        settings: s,
        verticalSpread: true,
      );
      final int block = css.indexOf(spreadMarker);
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

    test('横排 / 滚动 / VN 下即使传了 verticalSpread 也不发', () async {
      for (final ReaderSettings s in <ReaderSettings>[
        await _settings(),
        await _settings(writingMode: 'vertical-rl', viewMode: 'continuous'),
        await _settings(writingMode: 'vertical-rl', viewMode: 'vn'),
      ]) {
        expect(
          ReaderContentStyles.css(settings: s, verticalSpread: true),
          isNot(contains(spreadMarker)),
        );
      }
    });

    test('铰链缝加宽的是两页之间的 row-gap', () async {
      final ReaderSettings s = await _settings(writingMode: 'vertical-rl');
      expect(
        ReaderContentStyles.foldColumnGapPx(
          hingeGutterPx: 24,
          effectivePageColumns: 0,
          settings: s,
          verticalSpread: true,
        ),
        46,
      );
      expect(
        ReaderContentStyles.foldColumnGapPx(
          hingeGutterPx: 24,
          effectivePageColumns: 0,
          settings: s,
        ),
        isNull,
        reason: '竖排单条没有「两页之间」',
      );
      final String css = ReaderContentStyles.css(
        settings: s,
        verticalSpread: true,
        columnGapOverridePx: 46,
      );
      final String rule = css.substring(css.indexOf(spreadMarker));
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
        verticalSpread: true,
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
      expect(
        ReaderContentStyles.pageCreaseApplies(
          viewMode: 'paginated',
          effectivePageColumns: 0,
          verticalSpread: true,
        ),
        isTrue,
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
      // 阴影宽 = 栏间隙（默认 22px），只落在两页之间的空白里、不压正文。
      expect(rule, contains('width: 22px'));
      expect(rule, contains(' - 11.0px)'));
      expect(rule, contains('var(--page-width, 100vw)'));
    });

    test('书本姿态加宽栏间隙时阴影跟着加宽', () async {
      final ReaderSettings s = await _settings(pageColumns: 2, crease: true);
      final String css = ReaderContentStyles.css(
        settings: s,
        columnGapOverridePx: 47,
      );
      final String rule = css.substring(css.indexOf(_creaseMarker));
      expect(rule, contains('width: 47px'));
      expect(rule, contains(' - 23.5px)'));
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
      expect(rule, contains('height: 22px'));
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
