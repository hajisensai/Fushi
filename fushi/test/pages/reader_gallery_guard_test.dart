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

  test('gallery button is a layout item wired to _openGallery', () {
    // 顶栏 / 底栏按钮全部来自 ReaderControlLayout；动作真相源 _readerControlAction。
    final int caseIdx = src.indexOf('case ReaderControlItem.gallery:');
    expect(caseIdx, greaterThan(-1));
    final int onPressedIdx = src.indexOf('onPressed: _openGallery,', caseIdx);
    expect(onPressedIdx, greaterThan(-1),
        reason: 'gallery action must call _openGallery');
    expect(src.contains('t.reader_gallery_tooltip'), isTrue);
  });

  test('_openGallery reuses _openImageViewer (no second zoom path)', () {
    final int idx = src.indexOf('void _openGallery()');
    expect(idx, greaterThan(-1));
    // _openGallery wires onOpenImage to _openImageViewer.
    expect(src.contains('onOpenImage: (EpubImageRef ref) =>'), isTrue);
    expect(src.contains('_openImageViewer(ReaderFushiSource.epubUrl(ref.src))'),
        isTrue,
        reason: 'gallery thumbnail tap must reuse _openImageViewer');
  });

  test('gallery jump reuses _navigateToChapter (no second nav path)', () {
    expect(src.contains('onJumpTo: (EpubImageRef ref)'), isTrue);
    expect(src.contains('_navigateToChapter(ref.chapterIndex, manual: true)'),
        isTrue,
        reason: 'gallery jump must reuse _navigateToChapter');
  });

  // BUG-2166 批把画廊本体从 chrome.part.dart 抽成
  // lib/src/reader/reader_gallery_page.dart；2026-09-13 阅读器 chrome 重做又把
  // ッツ 形态的「中央大图 + 缩略图带」换成「按章分组的网格 + 占位卡」。行为由
  // test/reader/reader_gallery_page_test.dart 真 widget 测试覆盖，本条源码守卫的
  // 职责收敛成「实现只许有一份、由 images 驱动、解锁判据与正文 / 书架端同源」。
  test('gallery page is a chapter-grouped grid (extracted component)', () {
    final File page = File('lib/src/reader/reader_gallery_page.dart');
    expect(page.existsSync(), isTrue,
        reason: 'ReaderGalleryPage 已从 chrome.part.dart 抽成独立组件');
    final String gallery = page.readAsStringSync().replaceAll('\r\n', '\n');
    expect(gallery.contains('class ReaderGalleryPage extends StatefulWidget'),
        isTrue);
    expect(gallery.contains('SliverGrid('), isTrue,
        reason: '插图册是按章分组的 sliver 网格，不是缩略图带');
    expect(gallery.contains('childCount: section.images.length'), isTrue,
        reason: '每节网格必须由该章 images 驱动，不得写死条目数');
    // 解锁判据只有一处、且带 unreadAhead：与阅读器正文（blurEnabled）和书架端
    // 插图库（unreadAhead）同一个 ImageRevealKey.shouldBlur，不得另造第二套。
    expect(gallery.contains('ImageRevealKey.shouldBlur('), isTrue);
    expect(gallery.contains('unreadAhead: _unreadAhead(ref)'), isTrue);
    expect(gallery.contains('t.reader_gallery_empty'), isTrue);
    expect(gallery.contains('t.reader_gallery_position_current'), isTrue);
    expect(src.contains('class _ReaderGalleryPage'), isFalse,
        reason: 'chrome.part.dart 只保留路由，不得再夹带第二份画廊实现');
  });
}
