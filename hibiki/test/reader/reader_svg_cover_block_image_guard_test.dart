import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import '../pages/reader_hibiki_page_source_corpus.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/reader/reader_content_styles.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';
import 'package:hibiki/src/reader/reader_settings.dart';

// BUG-025 · 固定布局 EPUB 封面（<svg><image>，非 <img>）在阅读器里被当作内联内容：
// 竖排 reflow 下漂到页面右缘（不居中）、且不像本文 <img> 插图那样能点击放大。
// 根因：_sharedInitImages 只把 <img> 升级为 block-img(+居中包裹+可点)，<svg><image>
// 被漏过；点击路径只认 tagName==='IMG'。修复后大尺寸 <svg><image> 与 <img> 同等
// 待遇。以下三层守卫：CSS 生成器 / JS 分类逻辑 / 点击 URL 解析源码扫描。

Future<ReaderSettings> _defaultSettings() async {
  final HibikiDatabase db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final ReaderSettings settings = ReaderSettings(db);
  await settings.refreshFromDb();
  return settings;
}

String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}

void main() {
  group('BUG-025 svg.block-img CSS', () {
    late String css;

    setUp(() async {
      final ReaderSettings settings = await _defaultSettings();
      css = ReaderContentStyles.css(settings: settings);
    });

    test('emits a dedicated svg.block-img rule', () {
      expect(css, contains('svg.block-img {'),
          reason: 'promoted SVG covers need a block-image sizing rule, '
              'otherwise the generic svg{width/height:100%} cannot resolve in '
              'an indefinite reflow column and the cover sticks to the edge');
    });

    test('svg.block-img gets a definite page-sized box and pointer cursor', () {
      final String rule = _functionSource(css, 'svg.block-img {', '}');
      // Definite box from the per-page image vars so the inner <image> meet-fits
      // and centres, rather than collapsing to the SVG default 300x150.
      expect(rule, contains('width: var(--hoshi-image-max-width'));
      expect(rule, contains('height: var(--hoshi-image-max-height'));
      expect(rule, contains('margin: auto'));
      // Tap-to-zoom affordance, matching img.block-img.
      expect(rule, contains('cursor: pointer'));
    });
  });

  group('BUG-025 _sharedInitImages SVG promotion', () {
    test('paginated shell promotes large <svg><image> to block-img', () {
      final String js = ReaderPaginationScripts.shellScript();
      _expectSvgPromotion(js);
    });

    test('continuous shell promotes large <svg><image> to block-img', () {
      final String js =
          ReaderPaginationScripts.shellScript(continuousMode: true);
      _expectSvgPromotion(js);
    });
  });

  test('BUG-025 tap handler resolves <svg><image> covers to a zoomable URL',
      () {
    // TODO-589 batch8: _hoshiBlockImageUrl/onImageTap 在 setup 脚本/handler，
    // 已搬到 reader_hibiki/webview.part.dart，改读「主壳 + 全部 part」合并语料。
    final String source = readReaderPageSource();

    expect(
      source,
      contains('function _hoshiBlockImageUrl(target)'),
      reason: 'tap resolution must be centralised so svg covers are handled '
          'alongside <img>',
    );

    final String helper = _functionSource(
      source,
      'function _hoshiBlockImageUrl(target)',
      'function _gestureEnd',
    );
    // Raster <img> path preserved.
    expect(helper, contains("target.tagName === 'IMG'"));
    // SVG cover path: find the wrapped block svg and resolve its <image> href
    // (xlink:href / href) against document.baseURI to an absolute hoshi.local
    // URL that _openImageViewer accepts.
    expect(helper, contains("querySelector('svg.block-img')"));
    expect(helper, contains("getAttribute('xlink:href')"));
    expect(helper, contains('document.baseURI'));

    // The tap branch must route through the helper, not the old IMG-only check.
    // TODO-861④ refactor: the resolved element is bound to `tapEl` (so the blur
    // reveal can run before zoom), then passed to the shared resolver — same
    // invariant, still elementFromPoint(x, y) -> _hoshiBlockImageUrl.
    expect(
      source,
      contains('var tapEl = document.elementFromPoint(x, y);'),
      reason: 'the single-tap branch must resolve via elementFromPoint(x, y)',
    );
    expect(
      source,
      contains('_hoshiBlockImageUrl(tapEl)'),
      reason: 'the single-tap branch must use the shared resolver',
    );
  });
}

void _expectSvgPromotion(String js) {
  // The SVG branch must classify large covers as block-img and wrap them in the
  // same centring wrapper used for <img>, gated to skip small gaiji glyphs.
  expect(js, contains("svg.classList.add('block-img')"),
      reason: 'large <svg><image> covers must become block illustrations');
  expect(js, contains("className = 'block-img-wrapper'"));
  // Size gate reuses the >256px threshold (image attrs or viewBox dims).
  expect(js, contains("getAttribute('viewBox')"));
  expect(js, contains('gaiji'),
      reason: 'gaiji svgs must be excluded like gaiji <img>');
}
