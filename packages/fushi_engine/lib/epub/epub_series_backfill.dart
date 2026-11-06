import 'dart:io';

import 'package:fushi_core/fushi_core.dart';

import 'package:fushi_engine/epub/epub_parser.dart';
import 'package:fushi_engine/epub/epub_series.dart';
import 'package:fushi_engine/foundation/engine_log.dart';

/// 给导入时还不读系列声明的存量 EPUB 回填 OPF 系列（n4KC1azJvw），返回本次写入的
/// 书数。
///
/// 只读每本书已解压目录里的 container.xml + OPF（[EpubParser.readSeriesFromExtracted]），
/// 结果按 [encodeEpubSeriesMetadata] 写进 `sourceMetadata`——包里没有声明也写一份
/// 只带类型标记的描述符，所以每本书一辈子只读一次。单本读失败（解压目录暂时不在 /
/// XML 坏了）只记日志、保持为空，下次再试。
///
/// 同步读盘、不进后台 isolate：每本两个小 XML、且只发生一次；书架页在 widget 测试
/// 的假异步区里也会调到这里，`Isolate.run` 在那里永不完成。
Future<int> backfillEpubSeries(FushiDatabase db) async {
  final List<({String bookKey, String extractDir})> pending = await db
      .getEpubBooksMissingSourceMetadata();
  int written = 0;
  for (final ({String bookKey, String extractDir}) book in pending) {
    // 解压目录不在（外置数据根没挂上）不能记成「读过、没有声明」。
    if (!Directory(book.extractDir).existsSync()) continue;
    final EpubSeries? series;
    try {
      series = EpubParser.readSeriesFromExtracted(book.extractDir);
    } catch (e, stack) {
      engineLog.log('backfillEpubSeries(${book.bookKey})', e, stack);
      continue;
    }
    written += await db.setEpubBookSourceMetadataIfMissing(
      book.bookKey,
      encodeEpubSeriesMetadata(series),
    );
  }
  return written;
}
