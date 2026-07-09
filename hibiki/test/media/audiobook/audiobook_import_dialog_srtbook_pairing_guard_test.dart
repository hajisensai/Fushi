/// TODO-1288 源码守卫：`audiobook_import_dialog`（给已有 EPUB 书加/换音频）在
/// `saveAudiobook` 之后必须补写配对 srt_books 行，否则互联 host 的 hasAudiobook
/// 判据（audiobooks + srt_books 两表齐备）认不出这本书 → 对端下载后显示成普通书、
/// 且 exportAudiobook 抛 StateError → 音频永不同步。
///
/// 完整驱动对话框 `_doImport` 需 mock 文件选择器 + 文件系统，过重；配对逻辑的纯
/// helper [writeEpubBackedSrtBook] 已在 book_import_srtbook_pairing_test.dart 与
/// v36->v37 迁移自愈测试里做了行为断言。本守卫锁住「对话框导入路径确实调用了配对
/// helper」这一接线不被回归删除。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'audiobook_import_dialog pairs a SrtBook after saveAudiobook (TODO-1288)',
      () {
    final File src = File(
      'lib/src/media/audiobook/audiobook_import_dialog.dart',
    );
    expect(src.existsSync(), isTrue, reason: '源文件必须存在（相对 hibiki/ 包根）');
    final String code = src.readAsStringSync();

    final int saveIdx = code.indexOf('saveAudiobook(audiobook)');
    expect(saveIdx, greaterThanOrEqualTo(0),
        reason: '导入路径必须仍调用 saveAudiobook(audiobook)');

    // 匹配调用点（带 '('），避免命中 import 的 show 子句（'writeEpubBackedSrtBook;'）。
    final int pairIdx = code.indexOf('writeEpubBackedSrtBook(');
    expect(pairIdx, greaterThanOrEqualTo(0),
        reason: 'TODO-1288：EPUB-backed 有声书导入必须补写配对 srt_books 行 '
            '（调用 writeEpubBackedSrtBook），否则互联同步认不出有声书');
    expect(pairIdx, greaterThan(saveIdx),
        reason: '配对 SrtBook 必须发生在 saveAudiobook 之后');

    // 判据必须与 v29/v37 backfill 同源：EPUB-backed（epub_books 存在）且非 audioOnly。
    expect(code.contains('getEpubBook(widget.bookKey)'), isTrue,
        reason: '配对判据必须是 epub_books 存在（等价 backfill 的 '
            'audiobooks JOIN epub_books），避免给 standalone 有声书造孤儿行');
    expect(code.contains('!widget.audioOnly'), isTrue,
        reason: 'audioOnly（SrtBook 已存在）必须豁免，不重复写');
  });
}
