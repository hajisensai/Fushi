import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-723: source-scan guards that anchor the illustration gallery wiring so a
/// future refactor cannot silently drop the bottom-bar entry or introduce a
/// second image-zoom / chapter-navigation path. Behaviour (real thumbnail
/// rendering, auto-scroll, real chapter jump) is verified on device.
void main() {
  final File chrome = File(
    'lib/src/pages/implementations/reader_hibiki/chrome.part.dart',
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
    final int onPressedIdx = src.indexOf('onPressed: _openGallery,', barItemsIdx);
    expect(onPressedIdx, greaterThan(-1),
        reason: 'gallery IconButton must call _openGallery from barItems');
    expect(src.contains('tooltip: t.reader_gallery_tooltip'), isTrue);
  });

  test('_openGallery reuses _openImageViewer (no second zoom path)', () {
    final int idx = src.indexOf('void _openGallery()');
    expect(idx, greaterThan(-1));
    // _openGallery wires onOpenImage to _openImageViewer.
    expect(src.contains('onOpenImage: (EpubImageRef ref) =>'), isTrue);
    expect(src.contains('_openImageViewer(ReaderHibikiSource.epubUrl(ref.src))'),
        isTrue,
        reason: 'gallery thumbnail tap must reuse _openImageViewer');
  });

  test('gallery jump reuses _navigateToChapter (no second nav path)', () {
    expect(src.contains('onJumpTo: (EpubImageRef ref)'), isTrue);
    expect(src.contains('_navigateToChapter(ref.chapterIndex, manual: true)'),
        isTrue,
        reason: 'gallery jump must reuse _navigateToChapter');
  });

  test('gallery page renders a thumbnail GridView', () {
    expect(src.contains('class _ReaderGalleryPage'), isTrue);
    expect(src.contains('GridView.builder'), isTrue);
    expect(src.contains('t.reader_gallery_empty'), isTrue);
    expect(src.contains('t.reader_gallery_current'), isTrue);
  });
}
