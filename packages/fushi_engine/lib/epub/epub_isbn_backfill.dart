import 'dart:isolate';

import 'package:fushi_core/fushi_core.dart';

import 'package:fushi_engine/epub/epub_parser.dart';
import 'package:fushi_engine/foundation/engine_log.dart';

/// v115：给 `epub_books.isbn` 为空的存量 EPUB 回填 ISBN，返回本次写入的书数。
///
/// 只读每本书**已解压目录**（`epub_books.extract_dir`，绝对路径——数据根迁移会
/// rebase 它）里的 container.xml + OPF，经 [EpubParser.readIsbnFromExtracted] 解析
/// `dc:identifier`；不重新导入、不动解压树与其它列。迁移里不做这件事：读几百本书的
/// 文件既慢，解压目录也可能暂时不在（外置数据根未挂载）。
///
/// 读盘在后台 isolate 里做（同步 IO，几百本书会卡 UI）。单本读失败（目录不在 /
/// XML 坏了）只记日志跳过，不影响其它书；包里本来就没有合法 ISBN 的书保持 NULL，
/// 下次调用会再读一次它的 OPF（两个小 XML，成本可忽略，换来不引入「扫过但没有」
/// 这第三种列状态）。写入走 [FushiDatabase.setEpubBookIsbnIfMissing]，不覆盖
/// 期间由导入写下的值。
Future<int> backfillEpubIsbns(FushiDatabase db) async {
  final List<({String bookKey, String extractDir})> pending = await db
      .getEpubBooksMissingIsbn();
  if (pending.isEmpty) return 0;
  final List<_IsbnReadResult> results = await Isolate.run(
    () => <_IsbnReadResult>[
      for (final ({String bookKey, String extractDir}) book in pending)
        _readIsbn(book.bookKey, book.extractDir),
    ],
  );
  int written = 0;
  for (final _IsbnReadResult result in results) {
    final String? error = result.error;
    if (error != null) {
      engineLog.log(
        'backfillEpubIsbns(${result.bookKey})',
        error,
        StackTrace.empty,
      );
      continue;
    }
    final String? isbn = result.isbn;
    if (isbn == null) continue;
    written += await db.setEpubBookIsbnIfMissing(result.bookKey, isbn);
  }
  return written;
}

/// 一本书的读取结果。跨 isolate 边界只传字符串（异常对象未必可发送）。
typedef _IsbnReadResult = ({String bookKey, String? isbn, String? error});

_IsbnReadResult _readIsbn(String bookKey, String extractDir) {
  try {
    return (
      bookKey: bookKey,
      isbn: EpubParser.readIsbnFromExtracted(extractDir),
      error: null,
    );
  } catch (e) {
    return (bookKey: bookKey, isbn: null, error: e.toString());
  }
}
