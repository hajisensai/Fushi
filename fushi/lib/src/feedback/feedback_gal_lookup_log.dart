// 反馈日志里的「游戏内查词诊断」一节（反馈 Ny1bK1hFeJ）。
//
// 游戏内查词 / attached 表面 / 输入屏蔽的状态行（`gal-attached:`、`gal-shield:`、
// `gal-click:` …）只写进 `<systemTemp>/hibiki_glookup.log`，从不进错误日志，所以反馈
// 附带的日志里一行都没有：BUG-4046 让用户「附日志再查」，附上来的却永远查不到。
//
// 这里只摘**白名单前缀**的结构化行：它们只含状态名、序号、句柄、毫秒数，不含台词
// 正文与查询词（`lookupText …` 这类带词的行不在白名单里）。整份文件可达 16 MB，只读
// 末尾一段。

import 'dart:convert';
import 'dart:io';

import 'package:fushi/src/lookup/global_lookup_log.dart';

/// 读文件末尾的字节上限。
const int kFeedbackGalLookupLogTailBytes = 2 * 1024 * 1024;

/// 最多带这么多行（取最近的）。
const int kFeedbackGalLookupLogMaxLines = 600;

/// 允许进反馈的行前缀（去掉时间戳与 `[native] ` 之后匹配）。
const List<String> kFeedbackGalLookupLogPrefixes = <String>[
  'gal-attached:',
  'gal-shield:',
  'gal-click:',
  'gal-ingame:',
  'gal-overlay:',
  'global click',
  'lookup hide',
  'lookup reveal',
  'lookup activation',
  'lookup repark',
];

/// 从 [raw]（hibiki_glookup.log 的一段文本）里摘白名单诊断行，保留最近
/// [maxLines] 行。行格式：`<时间戳>  [native] <消息>` 或 `<时间戳>  <消息>`。
List<String> galLookupDiagnosticLines(
  String raw, {
  int maxLines = kFeedbackGalLookupLogMaxLines,
}) {
  final List<String> kept = <String>[];
  for (final String line in const LineSplitter().convert(raw)) {
    final int split = line.indexOf('  ');
    if (split <= 0) continue;
    String message = line.substring(split + 2);
    if (message.startsWith('[native] ')) {
      message = message.substring('[native] '.length);
    }
    if (kFeedbackGalLookupLogPrefixes.any(message.startsWith)) {
      kept.add(line);
    }
  }
  return kept.length <= maxLines ? kept : kept.sublist(kept.length - maxLines);
}

/// 读 [file]（默认 [glookupLogFile]）末尾 [tailBytes] 字节并摘诊断行。文件不存在
/// 或读失败返回空列表——这一节只是锦上添花，不能让反馈提交失败。
List<String> readGalLookupDiagnosticLines({
  File? file,
  int tailBytes = kFeedbackGalLookupLogTailBytes,
}) {
  final File source = file ?? glookupLogFile();
  RandomAccessFile? handle;
  try {
    if (!source.existsSync()) return const <String>[];
    handle = source.openSync();
    final int length = handle.lengthSync();
    final int start = length > tailBytes ? length - tailBytes : 0;
    handle.setPositionSync(start);
    final List<int> bytes = handle.readSync(length - start);
    String text = utf8.decode(bytes, allowMalformed: true);
    if (start > 0) {
      // 从中间截开的首行不完整，丢掉。
      final int firstBreak = text.indexOf('\n');
      text = firstBreak < 0 ? '' : text.substring(firstBreak + 1);
    }
    return galLookupDiagnosticLines(text);
  } on FileSystemException {
    return const <String>[];
  } finally {
    handle?.closeSync();
  }
}
