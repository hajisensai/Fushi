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
    // jumpChapterIndex, not chapterIndex: an OPF cover no chapter references
    // sits at kEpubCoverChapterIndex (-1), which is not a navigable spine slot.
    expect(
        src.contains('_navigateToChapter(ref.jumpChapterIndex, manual: true)'),
        isTrue,
        reason: 'gallery jump must reuse _navigateToChapter');
  });

  // BUG-2559 / BUG-2589：插图册与书架端「查看插图」必须是同一份实现——同一组图、
  // 同一把尺判「读到没读到」、同一套网格。书架端曾是另一套网格 + 翻页查看器 +
  // 自己的进度索引（各扫一遍 = 同一张图在两处被判出不同的「读到没读到」，横版图
  // 也各裁各的），现在只剩装载与接线。「删一行就悄悄长回第二份」的形状钉在源码层。
  test('两个插图表面共用 EpubBook.images 这一份枚举与同一份 ReaderGalleryPage', () {
    expect(
        src.contains('final List<EpubImageRef> images = book.images;'), isTrue);
    final String shelf =
        File('lib/src/pages/implementations/illustrations_viewer_page.dart')
            .readAsStringSync();
    expect(
        shelf.contains(
            "import 'package:fushi/src/reader/reader_gallery_page.dart';"),
        isTrue,
        reason: '书架端「查看插图」必须直接用阅读器内的 ReaderGalleryPage');
    expect(shelf.contains('images: input.book.images,'), isTrue,
        reason: '书架端的清单也只许来自 EpubBook.images');
    expect(shelf.contains('currentChapter: position?.sectionIndex,'), isTrue,
        reason: '没有位置行的书传 null，不得退化成 (0, 0) 把整本糊掉');
    for (final String forbidden in <String>[
      'GridView',
      'PageView',
      'maskedIllustrationCover(',
      'IllustrationProgressIndex',
      'querySelectorAll',
      'InteractiveViewer(',
    ]) {
      expect(shelf.contains(forbidden), isFalse,
          reason: '书架端不得再长出第二份网格 / 查看器 / 进度索引：$forbidden');
    }
    expect(File('lib/src/reader/illustration_progress_index.dart').existsSync(),
        isFalse,
        reason: '书架端专用的进度索引已退役（判据由 EpubImageRef 自带）');
  });

  test('画廊的「还没读到」带章内偏移，且宿主真把偏移传进来', () {
    final String gallery =
        File('lib/src/reader/reader_gallery_page.dart').readAsStringSync();
    expect(
        gallery.contains('ref.normCharOffset > widget.currentNormCharOffset'),
        isTrue,
        reason: '只比章号 = 当前章里靠后的插图在画廊不遮、在书架遮，两处不一致');
    expect(src.contains('currentNormCharOffset: currentNormCharOffset'), isTrue,
        reason: '宿主必须把当前章内位置传给画廊，否则判据恒退化成章首');
    // reveal key 走 ref 自带的（已 decode），与 WebView / 书架 / Drift 同源；
    // 画廊自己再 normalize 一次会对 %xx 文件名得出另一个 key。
    expect(gallery.contains('revealKey: ref.revealKey'), isTrue);
    expect(gallery.contains('ImageRevealKey.normalize('), isFalse,
        reason: 'reveal key 的第四套归一已退役');
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
  });

  // BUG-2589：横版图占两列。滚动定位模型与真实网格必须读同一份槽位表，且宽高比
  // 要在布局前由 isolate 探好——等缩略图解码再改行数会让「定位到当前章」漂走。
  test('横版插图占两列：槽位表驱动网格与滚动定位，宽高比开页时在 isolate 探好', () {
    final String gallery =
        File('lib/src/reader/reader_gallery_page.dart').readAsStringSync();
    expect(
        gallery.contains('class _SlotGridDelegate extends SliverGridDelegate'),
        isTrue,
        reason: '网格必须按预算好的槽位画，不得退回固定列数的 childAspectRatio');
    expect(
        gallery.contains('SliverGridDelegateWithFixedCrossAxisCount'), isFalse);
    expect(
        gallery.contains('compute(') &&
            gallery.contains('probeIllustrationAspectRatios'),
        isTrue,
        reason: '宽高比在 isolate 里批量读文件头，不在 UI 线程解码');
    expect(gallery.contains('(_aspects[ref.src] ?? 0) > 1 ? 2 : 1'), isTrue,
        reason: '横版（宽 > 高）占两列，没探到的按竖版');
    final String probe = File('lib/src/reader/illustration_aspect_probe.dart')
        .readAsStringSync();
    expect(probe.contains('kIllustrationProbeHeadBytes'), isTrue,
        reason: '只读头部，走不到尺寸再整文件重读');
    expect(probe.contains('decodeImage'), isFalse, reason: '探针不得整图解码');
  });

  test('卡片长按 / 右键菜单提供跳转与恢复遮罩', () {
    final String gallery =
        File('lib/src/reader/reader_gallery_page.dart').readAsStringSync();
    expect(gallery.contains('onLongPress: () => unawaited(_showCardMenu(ref))'),
        isTrue,
        reason: '长按卡片必须唤出菜单（锁着的图此前没有任何跳转入口）');
    expect(gallery.contains('ContextMenuTrigger('), isTrue,
        reason: '桌面右键走统一的上下文菜单触发口，不得硬绑 onSecondaryTap');
    // 长按 / 右键都是指针动作。插图册整页本来就是方向键 + Enter 驱动的，菜单
    // 没有键位就等于对键盘 / 手柄用户不存在。
    expect(gallery.contains('_isContextMenuKey(event)'), isTrue,
        reason: '卡片菜单必须有键盘入口（菜单键 / Shift+F10）');
    expect(gallery.contains('_restoreGridFocus()'), isTrue,
        reason: '菜单关闭后要把焦点还给网格，否则键盘导航一次性废掉');
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
