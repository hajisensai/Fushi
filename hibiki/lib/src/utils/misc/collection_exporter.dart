import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:hibiki/i18n/strings.g.dart';

/// 收藏句/词导出（TODO-829）。
///
/// 设计要点：
/// - **纯函数**（[buildSentenceExport] / [buildWordExport] / [exportFileMeta]）负责把数据
///   拼成各格式字符串，无任何 IO，可单测。
/// - 平台分流（[saveOrShareExport]）照搬 `log_exporter.dart` 的 [_isDesktop] 二分：桌面
///   （含 Linux）严格走 [FilePicker.saveFile]，**绝不触 share_plus**（Linux 无 share_plus
///   注册，误调会崩）；移动端走 [Share.shareXFiles]。
/// - 分组键统一用 [ExportSentence.bookTitle]（恒非空），不用可空的 bookKey。

/// 导出格式。
enum ExportFormat {
  markdown,
  txt,
  csv,
  json,
}

/// 导出用的轻量收藏句载体（与 `FavoriteSentence` 解耦，纯数据，便于单测）。
class ExportSentence {
  const ExportSentence({
    required this.text,
    required this.bookTitle,
    required this.createdAt,
    this.chapterLabel,
    this.source,
  });

  final String text;

  /// 分组键：恒非空（`FavoriteSentence.bookTitle` 是 required）。
  final String bookTitle;
  final DateTime createdAt;
  final String? chapterLabel;

  /// 收藏来源（`book`/`video`/`audiobook`/`lyrics`），可空。
  final String? source;
}

/// 导出用的轻量收藏词载体。
class ExportWord {
  const ExportWord({
    required this.expression,
    required this.reading,
    required this.glossary,
    required this.sourceType,
    required this.createdAt,
  });

  final String expression;
  final String reading;
  final String glossary;

  /// 来源（`book`/`video`），用于分组。
  final String sourceType;
  final DateTime createdAt;
}

/// 文件元信息：扩展名（不含点）+ MIME 类型。
class ExportFileMeta {
  const ExportFileMeta({required this.extension, required this.mimeType});

  final String extension;
  final String mimeType;
}

/// 各格式的扩展名/MIME。
ExportFileMeta exportFileMeta(ExportFormat format) {
  switch (format) {
    case ExportFormat.markdown:
      return const ExportFileMeta(extension: 'md', mimeType: 'text/markdown');
    case ExportFormat.txt:
      return const ExportFileMeta(extension: 'txt', mimeType: 'text/plain');
    case ExportFormat.csv:
      return const ExportFileMeta(extension: 'csv', mimeType: 'text/csv');
    case ExportFormat.json:
      return const ExportFileMeta(
        extension: 'json',
        mimeType: 'application/json',
      );
  }
}

/// UTF-8 BOM。**仅 CSV** 默认带（Excel 中文友好）；JSON/Markdown/TXT 绝不带
/// （污染 JSON.parse / Obsidian）。
const String _utf8Bom = '﻿';

const String _csvNewline = '\r\n';

String _formatDateTime(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
      '${two(dt.hour)}:${two(dt.minute)}';
}

/// CSV（RFC4180）字段转义：含逗号/引号/换行的字段加双引号包裹并把内部 `"` 翻倍。
String _csvEscape(String field) {
  final bool needsQuote = field.contains(',') ||
      field.contains('"') ||
      field.contains('\n') ||
      field.contains('\r');
  if (!needsQuote) return field;
  return '"${field.replaceAll('"', '""')}"';
}

/// 把 [sentences] 按 [ExportSentence.bookTitle] 分组（保持首次出现的书序，组内保持
/// 传入顺序）。
Map<String, List<ExportSentence>> _groupSentencesByBook(
  List<ExportSentence> sentences,
) {
  final Map<String, List<ExportSentence>> grouped =
      <String, List<ExportSentence>>{};
  for (final ExportSentence s in sentences) {
    grouped.putIfAbsent(s.bookTitle, () => <ExportSentence>[]).add(s);
  }
  return grouped;
}

/// 收藏句导出为指定格式的完整文件内容。
///
/// - Markdown：按书名分组（`## 书名` + `> 引用块` + 斜体章节/时间），不带 BOM。
/// - TXT：逐句纯文本，不带 BOM。
/// - CSV：表头 + 每行（text,bookTitle,chapter,source,createdAt），默认带 UTF-8 BOM。
/// - JSON：结构化数组，键名与 `FavoriteSentence.toJson` 对齐便于回导，不带 BOM。
String buildSentenceExport(
  List<ExportSentence> sentences, {
  required ExportFormat format,
  bool csvBom = true,
}) {
  switch (format) {
    case ExportFormat.markdown:
      return _buildSentenceMarkdown(sentences);
    case ExportFormat.txt:
      return _buildSentenceTxt(sentences);
    case ExportFormat.csv:
      return _buildSentenceCsv(sentences, csvBom: csvBom);
    case ExportFormat.json:
      return _buildSentenceJson(sentences);
  }
}

String _buildSentenceMarkdown(List<ExportSentence> sentences) {
  final Map<String, List<ExportSentence>> grouped =
      _groupSentencesByBook(sentences);
  final StringBuffer buf = StringBuffer();
  buf.writeln('# ${t.collection_export_sentences_title}');
  buf.writeln();
  bool firstBook = true;
  grouped.forEach((String bookTitle, List<ExportSentence> group) {
    if (!firstBook) buf.writeln();
    firstBook = false;
    buf.writeln('## $bookTitle');
    buf.writeln();
    for (final ExportSentence s in group) {
      // 引用块：多行文本每行都加 `> ` 前缀。
      for (final String line in const LineSplitter().convert(s.text)) {
        buf.writeln('> $line');
      }
      final List<String> meta = <String>[
        if (s.chapterLabel != null && s.chapterLabel!.isNotEmpty)
          s.chapterLabel!,
        _formatDateTime(s.createdAt),
      ];
      buf.writeln('>');
      buf.writeln('> *${meta.join(' · ')}*');
      buf.writeln();
    }
  });
  return buf.toString().trimRight();
}

String _buildSentenceTxt(List<ExportSentence> sentences) {
  final StringBuffer buf = StringBuffer();
  for (final ExportSentence s in sentences) {
    buf.writeln(s.text);
  }
  return buf.toString().trimRight();
}

String _buildSentenceCsv(
  List<ExportSentence> sentences, {
  required bool csvBom,
}) {
  final StringBuffer buf = StringBuffer();
  if (csvBom) buf.write(_utf8Bom);
  buf.write(<String>['text', 'bookTitle', 'chapter', 'source', 'createdAt']
      .map(_csvEscape)
      .join(','));
  buf.write(_csvNewline);
  for (final ExportSentence s in sentences) {
    buf.write(<String>[
      s.text,
      s.bookTitle,
      s.chapterLabel ?? '',
      s.source ?? '',
      s.createdAt.toIso8601String(),
    ].map(_csvEscape).join(','));
    buf.write(_csvNewline);
  }
  return buf.toString();
}

String _buildSentenceJson(List<ExportSentence> sentences) {
  final List<Map<String, dynamic>> list = sentences
      .map((ExportSentence s) => <String, dynamic>{
            'text': s.text,
            'bookTitle': s.bookTitle,
            if (s.chapterLabel != null) 'chapterLabel': s.chapterLabel,
            if (s.source != null) 'source': s.source,
            'createdAt': s.createdAt.toIso8601String(),
          })
      .toList();
  return const JsonEncoder.withIndent('  ').convert(list);
}

/// 把 [words] 按 [ExportWord.sourceType] 分组（保持首次出现序）。
Map<String, List<ExportWord>> _groupWordsBySource(List<ExportWord> words) {
  final Map<String, List<ExportWord>> grouped = <String, List<ExportWord>>{};
  for (final ExportWord w in words) {
    grouped.putIfAbsent(w.sourceType, () => <ExportWord>[]).add(w);
  }
  return grouped;
}

/// 收藏词导出（全部导出，按 sourceType 分组）。
String buildWordExport(
  List<ExportWord> words, {
  required ExportFormat format,
  bool csvBom = true,
}) {
  switch (format) {
    case ExportFormat.markdown:
      return _buildWordMarkdown(words);
    case ExportFormat.txt:
      return _buildWordTxt(words);
    case ExportFormat.csv:
      return _buildWordCsv(words, csvBom: csvBom);
    case ExportFormat.json:
      return _buildWordJson(words);
  }
}

String _buildWordMarkdown(List<ExportWord> words) {
  final Map<String, List<ExportWord>> grouped = _groupWordsBySource(words);
  final StringBuffer buf = StringBuffer();
  buf.writeln('# ${t.collection_export_words_title}');
  buf.writeln();
  bool firstGroup = true;
  grouped.forEach((String sourceType, List<ExportWord> group) {
    if (!firstGroup) buf.writeln();
    firstGroup = false;
    buf.writeln('## $sourceType');
    buf.writeln();
    for (final ExportWord w in group) {
      final String head = w.reading.isEmpty
          ? '**${w.expression}**'
          : '**${w.expression}**（${w.reading}）';
      buf.writeln('- $head');
      if (w.glossary.isNotEmpty) {
        for (final String line in const LineSplitter().convert(w.glossary)) {
          buf.writeln('  - $line');
        }
      }
    }
  });
  return buf.toString().trimRight();
}

String _buildWordTxt(List<ExportWord> words) {
  final StringBuffer buf = StringBuffer();
  for (final ExportWord w in words) {
    final String head =
        w.reading.isEmpty ? w.expression : '${w.expression}（${w.reading}）';
    if (w.glossary.isEmpty) {
      buf.writeln(head);
    } else {
      buf.writeln('$head\t${w.glossary.replaceAll('\n', ' ')}');
    }
  }
  return buf.toString().trimRight();
}

String _buildWordCsv(List<ExportWord> words, {required bool csvBom}) {
  final StringBuffer buf = StringBuffer();
  if (csvBom) buf.write(_utf8Bom);
  buf.write(<String>['expression', 'reading', 'glossary', 'source', 'createdAt']
      .map(_csvEscape)
      .join(','));
  buf.write(_csvNewline);
  for (final ExportWord w in words) {
    buf.write(<String>[
      w.expression,
      w.reading,
      w.glossary,
      w.sourceType,
      w.createdAt.toIso8601String(),
    ].map(_csvEscape).join(','));
    buf.write(_csvNewline);
  }
  return buf.toString();
}

String _buildWordJson(List<ExportWord> words) {
  final List<Map<String, dynamic>> list = words
      .map((ExportWord w) => <String, dynamic>{
            'expression': w.expression,
            'reading': w.reading,
            'glossary': w.glossary,
            'sourceType': w.sourceType,
            'createdAt': w.createdAt.toIso8601String(),
          })
      .toList();
  return const JsonEncoder.withIndent('  ').convert(list);
}

bool get _isDesktop =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// 把导出内容落盘（桌面）或分享（移动）。
///
/// 平台分流硬约束：桌面（含 Linux）走 [FilePicker.saveFile]，移动端才用
/// [Share.shareXFiles]（Linux 无 share_plus 注册）。tmp 文件 + `context.mounted`
/// 守卫 + finally 清理，照搬 `log_exporter.dart`。
Future<void> saveOrShareExport({
  required BuildContext context,
  required String content,
  required String fileName,
  required String mimeType,
  required String subject,
}) async {
  void notify(String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  File? tmp;
  try {
    final Directory tmpDir = await getTemporaryDirectory();
    final String tmpPath = '${tmpDir.path}/$fileName';
    tmp = File(tmpPath);
    // BOM 已含在 content 里（仅 CSV）；写字节避免编码二次加 BOM。
    await tmp.writeAsString(content);

    if (_isDesktop) {
      final String? savePath = await FilePicker.platform.saveFile(
        dialogTitle: t.collection_export_save,
        fileName: fileName,
      );
      if (savePath != null) {
        await tmp.copy(savePath);
        notify(t.collection_export_saved);
      }
    } else {
      await Share.shareXFiles(
        <XFile>[XFile(tmpPath, mimeType: mimeType)],
        subject: subject,
      );
    }
  } catch (_) {
    notify(t.collection_export_failed);
  } finally {
    if (_isDesktop && tmp != null) {
      try {
        await tmp.delete();
      } catch (_) {}
    }
  }
}
