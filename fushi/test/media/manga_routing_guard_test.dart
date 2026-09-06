import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi_core/fushi_core.dart';

/// 漫画 OCR P1 的接线守卫（源码扫描 + 键不变量），与 PDF 的
/// `reader_pdf_routing_guard_test.dart` 同纪律。
///
/// 漫画作为「第三种书」复用 EpubBooks/书架/进度/删除管线，正确性依赖数处接线不能被
/// 后续重构悄悄改断——一旦断掉，漫画行会带 EPUB 源标识被打开、进 EPUB 阅读器的解压/
/// 解析路径 → 崩溃或白屏。MangaFushiPage 过重无法在纯 widget test 拉起完整链路
/// （WebView + 词典引擎），故守卫落在最强可落地的源码语料层。
void main() {
  String read(String relativePath) {
    final File file = File(relativePath);
    expect(file.existsSync(), isTrue, reason: '守卫目标文件应存在：$relativePath');
    return file.readAsStringSync();
  }

  test('MangaFushiSource.kUniqueKey 是独立键 reader_manga，与 EPUB/PDF 源互异', () {
    expect(MangaFushiSource.kUniqueKey, 'reader_manga');
    expect(MangaFushiSource.instance.uniqueKey, 'reader_manga');
    expect(
      MangaFushiSource.instance.uniqueKey,
      isNot(ReaderFushiSource.instance.uniqueKey),
    );
    expect(
      MangaFushiSource.instance.uniqueKey,
      isNot(ReaderPdfSource.instance.uniqueKey),
    );
  });

  test('书架列书按 format 路由：format==manga 的行带 MangaFushiSource 源标识', () {
    // BUG-1316：路由派生已收敛成公开的具名函数，故判据从「源码里有那串三元」升级
    // 成**直接调它**——行为断言比语料锚点强，也不会被等价改写绕过。
    expect(
      ReaderFushiSource.mediaSourceKeyFor(BookFormat.manga),
      MangaFushiSource.kUniqueKey,
      reason: '漫画行 mediaSourceIdentifier 应取 MangaFushiSource.kUniqueKey',
    );
    // PDF 分流不能被漫画分流破坏（向后兼容守卫）。
    expect(
      ReaderFushiSource.mediaSourceKeyFor(BookFormat.pdf),
      ReaderPdfSource.kUniqueKey,
    );
    expect(
      ReaderFushiSource.mediaSourceKeyFor(BookFormat.epub),
      ReaderFushiSource.instance.uniqueKey,
    );
  });

  test('_bookToMediaItem 走共享派生点，不得再内联自己的一套三元', () {
    final String src = read('lib/src/media/sources/reader_fushi_source.dart');
    expect(
      src.contains('mediaSourceIdentifier: mediaSourceKeyFor(format)'),
      isTrue,
      reason:
          '书架列书必须与「跳回原文」入口共用 mediaSourceKeyFor：'
          '两条各写各的，漫画/PDF 就会在其中一条上永远用错阅读器',
    );
  });

  test('AppModel 注册 MangaFushiSource.instance（否则打开漫画崩于 map 空断言）', () {
    final String src = read('lib/src/models/app_model.dart');
    expect(
      src.contains('MangaFushiSource.instance'),
      isTrue,
      reason:
          'populateMediaSources 必须注册 MangaFushiSource，'
          'item.getMediaSource 才能解析到它',
    );
  });

  test('media.dart 导出 manga_fushi_source（书架/路由处可见）', () {
    final String src = read('lib/media.dart');
    expect(src.contains('manga_fushi_source.dart'), isTrue);
  });

  // ── 身份：fushi://book/<bookKey>，无 manga:// 特例 ──────────────────

  test('漫画身份统一 fushi://book/<bookKey>，源与页面都不引入 manga:// 标识', () {
    final String source = read('lib/src/media/sources/manga_fushi_source.dart');
    final String page = read(
      'lib/src/media/manga/reader/manga_fushi_page.dart',
    );
    // 打开时从 fushi://book/ 标识解析 bookKey（与 PDF 完全同构），关书自动同步
    // （triggerAutoSyncAfterClose 的 fushi://book/ 前缀识别）天然工作。
    expect(
      source.contains('ReaderFushiSource.parseBookKey'),
      isTrue,
      reason: 'buildLaunchPage 必须用共享的 fushi://book/ 解析器',
    );
    expect(source.contains('manga://'), isFalse, reason: '不再有 manga:// 身份特例');
    expect(page.contains('manga://'), isFalse, reason: '页面也不得引入 manga:// 身份');
  });

  // ── 进度：ReaderPositions 页码口径 ──────────────────────────────────

  test('页码进度落 ReaderPositions.sectionIndex，且显式传 charOffset', () {
    final String src = read('lib/src/media/manga/reader/manga_fushi_page.dart');
    expect(src.contains('ReaderPositionRepository('), isTrue);
    expect(
      src.contains('sectionIndex: page'),
      isTrue,
      reason: '漫画用 sectionIndex 存 0-based 页码',
    );
    // charOffset 传 null 会掉进 EPUB 专用的「跨 section 精确锚失效」启发式；
    // spread 传 0，webtoon 存页内滚动千分比。
    expect(
      src.contains('charOffset: isWebtoon'),
      isTrue,
      reason: '必须显式传 charOffset（spread 0 / webtoon 千分比），不能传 null',
    );
    expect(src.contains('webtoonFractionToCharOffset'), isTrue);
    expect(
      src.contains('markEpubBookCompletedIfUnset'),
      isTrue,
      reason: '翻到末页写已读完',
    );
  });

  test('书架漫画进度按页计（与 PDF 共用 1-based 页序分支）', () {
    final String src = read('lib/src/media/sources/reader_fushi_source.dart');
    expect(
      src.contains('(pos?.sectionIndex ?? 0) + 1'),
      isTrue,
      reason: '页码型书进度用 1-based 页序，停在第 1 页也要计入在读',
    );
    expect(src.contains('pageBased'), isTrue, reason: 'PDF/漫画共用页码型进度分支');
  });

  test('漫画阅读统计：字数走 OCR 记账、页数走独立列，两个量纲不交叉', () {
    final String src = read('lib/src/media/manga/reader/manga_fushi_page.dart');
    // 旧守卫钉的是字面量 `charsRead: 0`，理由写「漫画无字数」+「页数塞进 charsRead
    // 会污染字数口径」。前半句在 schema v60 起**不再成立**：统计口径已按产品决策纳入
    // 漫画，漫画的字来自 mokuro / 内置 OCR 的实义字符（口径与 EPUB 同源的
    // japaneseCharCount），恒 0 反而是错的——统计页会永远显示漫画 0 字。
    //
    // 后半句仍然是真不变量，且是这条守卫真正要防的东西，所以原样保留并加强：页数有
    // 自己的 `pagesRead` 列（v60 新增），绝不能冒充字数，否则「字数」和「阅读速度」
    // 两个口径同时被污染。下面从「钉一个字面量」改成「钉两个量纲的接线不交叉」。
    expect(
      src.contains('mangaStatsForPages('),
      isTrue,
      reason: '字数必须来自 OCR 文本换算，不能凭页数现编',
    );
    // v92：字数 / 页数直接记进 StudyClock 的当前段（`study_segments.chars` /
    // `.pages` 两列），页面不再持有会话累计器。
    expect(
      src.contains('_studyClock?.addChars(added.chars)'),
      isTrue,
      reason: 'OCR 字符数经 addChars 落段的 chars 列',
    );
    expect(
      src.contains('_studyClock?.addPages(added.pages)'),
      isTrue,
      reason: '页数经 addPages 落段的 pages 独立列，不与字数混流',
    );
    // 交叉接线守卫：任何把页数喂给字数、或把字数喂给页数的写法都算口径污染。
    expect(
      src.contains('addChars(added.pages)'),
      isFalse,
      reason: '页数绝不能塞进 chars（会污染字数口径与阅读速度）',
    );
    expect(
      src.contains('addPages(added.chars)'),
      isFalse,
      reason: '字数绝不能塞进 pages',
    );
    expect(src.contains('StudyClock'), isTrue, reason: '复用时长统计');
  });

  // ── 阅读模式覆盖 ────────────────────────────────────────────────────

  test('阅读模式读写 EpubBooks.mangaReadingMode（null=自动判定）', () {
    final String src = read('lib/src/media/manga/reader/manga_fushi_page.dart');
    expect(src.contains('mangaReadingMode'), isTrue, reason: '打开时读列值、切换时写列值');
    expect(
      src.contains('detectReadingMode'),
      isTrue,
      reason: 'null 覆盖必须回落自动判定',
    );
  });

  // ── 查词/制卡接线 ────────────────────────────────────────────────────

  test('漫画页接在共享查词链路上（BaseSourcePage + buildDictionary + 弹窗入口）', () {
    final String src = read('lib/src/media/manga/reader/manga_fushi_page.dart');
    expect(
      src.contains('class MangaFushiPage extends BaseSourcePage'),
      isTrue,
      reason: '漫画页必须是 BaseSourcePage 才能复用查词弹窗链路',
    );
    expect(src.contains('BaseSourcePageState<MangaFushiPage>'), isTrue);
    expect(
      src.contains('buildDictionary()'),
      isTrue,
      reason: '弹窗层必须在 widget 树里，否则查词结果不渲染',
    );
    expect(src.contains('searchDictionaryResult('), isTrue);
    expect(
      src.contains('setCurrentSentence('),
      isTrue,
      reason: '整句必须经 setCurrentSentence 送出，制卡/收藏才拿得到句子',
    );
  });

  test('制卡走 onMineFromPopup + AnkiMiningContext，卡图=当前页图文件路径', () {
    final String src = read('lib/src/media/manga/reader/manga_fushi_page.dart');
    expect(src.contains('onMineFromPopup'), isTrue, reason: '制卡入口');
    expect(src.contains('AnkiMiningContext('), isTrue);
    expect(
      src.contains('coverPath'),
      isTrue,
      reason: '卡图经 coverPath 传**文件路径**（页图本就在盘上）',
    );
    expect(src.contains('AnkiMiningSource.book'), isTrue);
    expect(src.contains('mineEntry('), isTrue);
    expect(
      src.contains('_updateCurrentPageImagePath'),
      isTrue,
      reason: '卡图路径必须在加载/翻页/滚动/切模式全路径更新，否则封面恒 null',
    );
  });

  test('卡图更新在全部推进路径被调用（加载/翻页/滚动/切模式）', () {
    final String src = read('lib/src/media/manga/reader/manga_fushi_page.dart');
    // 至少 4 处调用点：_loadInitialWindow、_onMangaTurn（窗口内分支）、
    // _onMangaScroll（spread 变化）、_toggleReadingMode。
    final int calls = '_updateCurrentPageImagePath()'.allMatches(src).length;
    expect(
      calls >= 4,
      isTrue,
      reason:
          '卡图更新调用点不足（$calls < 4）——旧分支修过的坑：'
          '漏路径会让制卡封面在该路径后恒为旧页/null',
    );
  });
}
