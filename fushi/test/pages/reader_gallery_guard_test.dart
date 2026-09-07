import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-723: source-scan guards that anchor the illustration gallery wiring so a
/// future refactor cannot silently drop the bottom-bar entry or introduce a
/// second image-zoom / chapter-navigation path. Behaviour (real thumbnail
/// rendering, auto-scroll, real chapter jump) is verified on device.
void main() {
  final File chrome = File(
    'lib/src/pages/implementations/reader_fushi/chrome.part.dart',
  );
  late String src;

  setUpAll(() {
    expect(chrome.existsSync(), isTrue,
        reason: 'chrome.part.dart must exist for the guard');
    src = chrome.readAsStringSync();
  });

  test('gallery button is wired into the bottom settings bar (barItems)', () {
    final int barItemsIdx = src.indexOf('final List<Widget> barItems');
    expect(barItemsIdx, greaterThan(-1));
    final int onPressedIdx =
        src.indexOf('onPressed: _openGallery,', barItemsIdx);
    expect(onPressedIdx, greaterThan(-1),
        reason: 'gallery IconButton must call _openGallery from barItems');
    expect(src.contains('tooltip: t.reader_gallery_tooltip'), isTrue);
  });

  test('_openGallery reuses _openImageViewer (no second zoom path)', () {
    final int idx = src.indexOf('void _openGallery()');
    expect(idx, greaterThan(-1));
    // _openGallery wires onOpenImage to _openImageViewer.
    expect(src.contains('onOpenImage: (EpubImageRef ref) =>'), isTrue);
    expect(
        src.contains('_openImageViewer(ReaderFushiSource.epubUrl(ref.src))'),
        isTrue,
        reason: 'gallery thumbnail tap must reuse _openImageViewer');
  });

  test('gallery jump reuses _navigateToChapter (no second nav path)', () {
    expect(src.contains('onJumpTo: (EpubImageRef ref)'), isTrue);
    expect(src.contains('_navigateToChapter(ref.chapterIndex, manual: true)'),
        isTrue,
        reason: 'gallery jump must reuse _navigateToChapter');
  });

  // BUG-2166 批做了两件事，两件都是有意的：① 画廊本体从 chrome.part.dart 抽成
  // lib/src/reader/reader_gallery_page.dart；② ッツ 形态把「缩略图网格」改成
  // 「中央大图 + 底部横向缩略图带」，GridView 因此变成 ListView.separated。
  // 行为由 test/reader/reader_gallery_page_test.dart 真 widget 测试覆盖，本条
  // 源码守卫的职责收敛成「实现只许有一份、且由 images 驱动」。
  test('gallery page renders a thumbnail strip (extracted component)', () {
    final File page = File('lib/src/reader/reader_gallery_page.dart');
    expect(page.existsSync(), isTrue,
        reason: 'ReaderGalleryPage 已从 chrome.part.dart 抽成独立组件');
    final String gallery = page.readAsStringSync().replaceAll('\r\n', '\n');
    expect(gallery.contains('class ReaderGalleryPage extends StatefulWidget'),
        isTrue);
    expect(gallery.contains('ListView.separated'), isTrue,
        reason: 'ッツ 形态：中央大图 + 底部横向缩略图带');
    expect(gallery.contains('itemCount: widget.images.length'), isTrue,
        reason: '缩略图带必须由 images 驱动，不得写死条目数');
    expect(gallery.contains('t.reader_gallery_empty'), isTrue);
    expect(gallery.contains('t.reader_gallery_current'), isTrue);
    expect(src.contains('class _ReaderGalleryPage'), isFalse,
        reason: 'chrome.part.dart 只保留路由，不得再夹带第二份画廊实现');
  });
}
