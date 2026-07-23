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
}
