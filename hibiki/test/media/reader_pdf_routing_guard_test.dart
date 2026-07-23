import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/media.dart';

/// PDF 阅读器 Phase 1 的接线守卫（源码扫描 + 键不变量）。
///
/// PDF 作为「第二种书」复用 EpubBooks/书架/进度/删除管线，正确性依赖四处接线不能被
/// 后续重构悄悄改断——一旦断掉，PDF 行会带 EPUB 源标识被打开、进 EPUB 阅读器的解压/
/// 解析路径 → 崩溃或白屏。ReaderPdfPage 过重无法在纯 widget test 拉起（读 appProvider +
/// pdfrx native），故守卫落在最强可落地的源码语料层，与 BUG 守卫同纪律。
void main() {
  String read(String relativePath) {
    final File file = File(relativePath);
    expect(file.existsSync(), isTrue, reason: '守卫目标文件应存在：$relativePath');
    return file.readAsStringSync();
  }

  test('ReaderPdfSource.kUniqueKey 是独立键 reader_pdf，绝不复用 EPUB 的 reader_ttu', () {
    expect(ReaderPdfSource.kUniqueKey, 'reader_pdf');
    expect(ReaderPdfSource.instance.uniqueKey, 'reader_pdf');
    // reader_ttu 是 EPUB 源的冻结持久化键；两源键必须互异，否则 mediaSources map 覆盖、
    // 路由塌缩到单一源。
    expect(ReaderPdfSource.instance.uniqueKey,
        isNot(ReaderHibikiSource.instance.uniqueKey));
  });

  test('书架列书按 format 路由：format==pdf 的行带 ReaderPdfSource 源标识', () {
    final String src = read('lib/src/media/sources/reader_hibiki_source.dart');
    // _bookToMediaItem 必须按 format 分流 mediaSourceIdentifier；缺这条 → PDF 行用
    // 'reader_ttu' 打开 → EPUB 阅读器解析 PDF → 崩。
    expect(src.contains("book.format == 'pdf'"), isTrue,
        reason: '_bookToMediaItem 应按 format=="pdf" 分流');
    expect(src.contains('ReaderPdfSource.kUniqueKey'), isTrue,
        reason: 'PDF 行 mediaSourceIdentifier 应取 ReaderPdfSource.kUniqueKey');
  });

  test('AppModel 注册 ReaderPdfSource.instance（否则打开 PDF 崩于 map 空断言）', () {
    final String src = read('lib/src/models/app_model.dart');
    expect(src.contains('ReaderPdfSource.instance'), isTrue,
        reason: 'populateMediaSources 必须注册 ReaderPdfSource，'
            'item.getMediaSource 才能解析到它');
  });

  test('导入对话框把 .pdf 路由到 PdfImporter（不经 TextToEpub 文本转换）', () {
    final String src = read('lib/src/media/audiobook/book_import_dialog.dart');
    expect(src.contains("ext == '.pdf'"), isTrue,
        reason: '_importEpubOnly 必须早退分流 .pdf');
    expect(src.contains('PdfImporter.importFromPath'), isTrue,
        reason: '.pdf 走 PdfImporter，而非把 PDF 二进制喂 TextToEpub 转成乱码 EPUB');
    // .pdf 必须在文件选择白名单里，否则用户根本选不到。
    expect(src.contains("'pdf'"), isTrue, reason: '_bookExtensions 白名单应含 pdf');
  });

  // ── Phase 2：点选查词 ────────────────────────────────────────────────

  test('PDF 页接在共享查词链路上（BaseSourcePage + buildDictionary + 弹窗入口）', () {
    final String src =
        read('lib/src/pages/implementations/reader_pdf_page.dart');
    // 必须是 BaseSourcePage 子类，否则拿不到 searchDictionaryResult / 弹窗栈 / 制卡。
    expect(src.contains('class ReaderPdfPage extends BaseSourcePage'), isTrue,
        reason: 'PDF 页必须是 BaseSourcePage 才能复用查词弹窗链路');
    expect(src.contains('BaseSourcePageState<ReaderPdfPage>'), isTrue);
    // buildDictionary() 不在树里 → 查到结果也不显示（静默失败，最难查）。
    expect(src.contains('buildDictionary()'), isTrue,
        reason: '弹窗层必须在 widget 树里，否则查词结果不渲染');
    expect(src.contains('searchDictionaryResult('), isTrue);
    // 句子走 setCurrentSentence 通道喂制卡/收藏（不是 searchDictionaryResult 的参数）。
    expect(src.contains('setCurrentSentence('), isTrue,
        reason: '整句必须经 setCurrentSentence 送出，制卡才拿得到句子');
  });

  test('点选查词用 pdfrx 文档坐标命中字符，且不自行分词', () {
    final String src =
        read('lib/src/pages/implementations/reader_pdf_page.dart');
    expect(src.contains('onGeneralTap'), isTrue, reason: '单击查词入口');
    expect(src.contains('documentPosition'), isTrue,
        reason: '命中测试必须基于 pdfrx 文档坐标');
    expect(src.contains('toPdfPoint('), isTrue,
        reason: '文档坐标要换算成页内 PDF 坐标（原点左下）才能与 charRects 比对');
    expect(src.contains('loadStructuredText()'), isTrue,
        reason: 'charRects 来自结构化文本');
    // 不分词：整串交引擎最长匹配（与视频字幕同构）。出现分词器即是走偏了。
    expect(src.contains('_kLookupWindow'), isTrue,
        reason: '取固定窗口子串交引擎最长匹配，而非自行切词');
  });

  // ── Phase 3：页码进度 ────────────────────────────────────────────────

  test('页码进度落 ReaderPositions.sectionIndex，且显式传 charOffset', () {
    final String src =
        read('lib/src/pages/implementations/reader_pdf_page.dart');
    expect(src.contains('ReaderPositionRepository('), isTrue);
    expect(src.contains('sectionIndex: pageIndex'), isTrue,
        reason: 'PDF 用 sectionIndex 存 0-based 页码');
    // charOffset 传 null 会掉进 EPUB 专用的「跨 section 精确锚失效」启发式。
    expect(src.contains('charOffset: 0'), isTrue,
        reason: 'PDF 必须显式传 charOffset，不能传 null');
    expect(src.contains('onPageChanged'), isTrue, reason: '翻页触发保存');
    expect(src.contains('goToPage('), isTrue, reason: '打开时恢复到已保存页');
    expect(src.contains('markEpubBookCompletedIfUnset'), isTrue,
        reason: '翻到末页写已读完');
  });

  test('书架 PDF 进度按页计，且用 1-based 页序（第 1 页也算在读）', () {
    final String src = read('lib/src/media/sources/reader_hibiki_source.dart');
    // 0-based 会让停在第 1 页的书 position==0 → 不进「继续阅读」。
    expect(src.contains('(pos?.sectionIndex ?? 0) + 1'), isTrue,
        reason: 'PDF 进度用 1-based 页序，停在第 1 页也要计入在读');
    expect(src.contains('book.chapterCount'), isTrue,
        reason: 'PDF 总页数存在 chapterCount');
  });

  test('PDF 阅读统计不把页数当字数（charsRead 恒 0）', () {
    final String src =
        read('lib/src/pages/implementations/reader_pdf_page.dart');
    expect(src.contains('charsRead: 0'), isTrue,
        reason: 'PDF 无字数；把页数塞进 charsRead 会污染统计页的「字数」口径');
    expect(src.contains('ReadingTimeTracker'), isTrue, reason: '复用时长统计');
  });

  // ── Phase 4：制卡 ────────────────────────────────────────────────────

  test('制卡走 onMineFromPopup + AnkiMiningContext，卡图是当前页栅格化 PNG', () {
    final String src =
        read('lib/src/pages/implementations/reader_pdf_page.dart');
    expect(src.contains('onMineFromPopup'), isTrue, reason: '制卡入口');
    expect(src.contains('AnkiMiningContext('), isTrue);
    expect(src.contains('coverPath'), isTrue,
        reason: '卡图经 coverPath 传**文件路径**（不是字节）');
    expect(src.contains('AnkiMiningSource.book'), isTrue);
    expect(src.contains('mineEntry('), isTrue);
  });

  // ── Phase 5：目录 ────────────────────────────────────────────────────

  test('目录导航用 PDF 自带 outline + goToDest', () {
    final String src =
        read('lib/src/pages/implementations/reader_pdf_page.dart');
    expect(src.contains('loadOutline()'), isTrue);
    expect(src.contains('goToDest('), isTrue, reason: '点目录项跳转到该 dest');
  });
}
