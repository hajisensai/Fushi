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

  // 未解锁卡片的视觉与「卡片能做什么」两条，是用户报回来的两个缺口（糊图被换成
  // 文案纸卡；网格里没有任何跳转入口 / 没法把揭开的图重新遮回去）。两者都属于
  // 「删一行就悄悄退回去、widget 测试改一句断言也就跟着绿」的形状，钉在源码层。
  test('未解锁卡片用共享遮罩视觉，且两个插图表面共用同一份', () {
    final String gallery =
        File('lib/src/reader/reader_gallery_page.dart').readAsStringSync();
    expect(gallery.contains('maskedIllustrationCover('), isTrue,
        reason: '锁着的卡是这张图自己的高斯模糊，不是写着「尚未读到」的占位卡');
    expect(gallery.contains('class _LockedCardBody'), isFalse,
        reason: '文案占位卡已退役，别再长回来');
    // 书架端插图库与阅读器插图册必须是同一份遮罩（含墨水屏的实心遮板分支）。
    final String shelf =
        File('lib/src/pages/implementations/illustrations_viewer_page.dart')
            .readAsStringSync();
    expect(
      shelf.contains(
          "import 'package:fushi/src/reader/masked_illustration_cover.dart';"),
      isTrue,
      reason: '遮罩视觉只许有一份，两端都从 masked_illustration_cover.dart 取',
    );
  });

  test('卡片长按 / 右键菜单提供跳转与恢复遮罩', () {
    final String gallery =
        File('lib/src/reader/reader_gallery_page.dart').readAsStringSync();
    expect(gallery.contains('onLongPress: () => unawaited(_showCardMenu(ref))'),
        isTrue,
        reason: '长按卡片必须唤出菜单（锁着的图此前没有任何跳转入口）');
    expect(gallery.contains('ContextMenuTrigger('), isTrue,
        reason: '桌面右键走统一的上下文菜单触发口，不得硬绑 onSecondaryTap');
    expect(gallery.contains("ValueKey<String>('fushi_gallery_menu_jump')"),
        isTrue);
    expect(gallery.contains("ValueKey<String>('fushi_gallery_menu_relock')"),
        isTrue);
    // 恢复遮罩必须真落到宿主（会话集 + Drift + 正文），不是只改本页外观。
    expect(gallery.contains('widget.onUnrevealImage?.call(key)'), isTrue);
    expect(src.contains('onUnrevealImage: (String key)'), isTrue,
        reason: 'chrome.part.dart 必须接住撤销揭开');
    expect(src.contains('unmarkImageRevealed(bookUid, key)'), isTrue,
        reason: '撤销要落 Drift，否则下次开书又是揭开态');
    expect(src.contains('__fushiUnmarkImageRevealed'), isTrue,
        reason: '正文 WebView 的会话活集也要跟着撤销');
  });
}
