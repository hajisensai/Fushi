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

/// 导出内容范围（可勾选；至少勾一项才可导出）。TODO-914。
///
/// `{mined, favorites}`（两个都勾）= 「全部」；勾选集天然表达全部，无需独立 `all`。
enum ExportScope { mined, favorites }

/// 导出用的轻量制卡句载体（与 `MinedSentenceRow` 解耦，纯数据，便于单测）。
class ExportMinedSentence {
  const ExportMinedSentence({
    required this.sentence,
    required this.expression,
    required this.reading,
    required this.glossary,
    required this.bookTitle,
    required this.createdAt,
    this.source,
  });

  /// 制卡时的整句上下文（可能为空：独立查词页制卡无句）。
  final String sentence;
  final String expression;
  final String reading;
  final String glossary;

  /// 分组键：恒非空（`documentTitle` 可空时回退到「制卡语句」占位）。
  final String bookTitle;
  final DateTime createdAt;

  /// 制卡来源（`book`/`video`/`audiobook`/`lyrics`），可空。
  final String? source;
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

/// 把 [items] 按 [ExportMinedSentence.bookTitle] 分组（保持首次出现的书序）。
Map<String, List<ExportMinedSentence>> _groupMinedByBook(
  List<ExportMinedSentence> items,
) {
  final Map<String, List<ExportMinedSentence>> grouped =
      <String, List<ExportMinedSentence>>{};
  for (final ExportMinedSentence m in items) {
    grouped.putIfAbsent(m.bookTitle, () => <ExportMinedSentence>[]).add(m);
  }
  return grouped;
}

/// 制卡句（含整句 + 词条/读音/释义）导出为指定格式的完整文件内容。
///
/// - Markdown：按书名分组（`## 书名` + 引用块整句 + 词条/读音/释义行），不带 BOM。
/// - TXT：逐条纯文本，不带 BOM。
/// - CSV：表头 + 每行（sentence,expression,reading,glossary,source,createdAt），
///   默认带 UTF-8 BOM。
/// - JSON：结构化数组，不带 BOM。
String buildMinedExport(
  List<ExportMinedSentence> items, {
  required ExportFormat format,
  bool csvBom = true,
}) {
  switch (format) {
    case ExportFormat.markdown:
      return _buildMinedMarkdown(items);
    case ExportFormat.txt:
      return _buildMinedTxt(items);
    case ExportFormat.csv:
      return _buildMinedCsv(items, csvBom: csvBom);
    case ExportFormat.json:
      return _buildMinedJson(items);
  }
}

String _buildMinedMarkdown(List<ExportMinedSentence> items) {
  final Map<String, List<ExportMinedSentence>> grouped =
      _groupMinedByBook(items);
  final StringBuffer buf = StringBuffer();
  buf.writeln('# ${t.collection_export_mined_title}');
  buf.writeln();
  bool firstBook = true;
  grouped.forEach((String bookTitle, List<ExportMinedSentence> group) {
    if (!firstBook) buf.writeln();
    firstBook = false;
    buf.writeln('## $bookTitle');
    buf.writeln();
    for (final ExportMinedSentence m in group) {
      if (m.sentence.isNotEmpty) {
        for (final String line in const LineSplitter().convert(m.sentence)) {
          buf.writeln('> $line');
        }
      }
      final String head = m.reading.isEmpty
          ? '**${m.expression}**'
          : '**${m.expression}**（${m.reading}）';
      buf.writeln('>');
      buf.writeln('> $head');
      if (m.glossary.isNotEmpty) {
        for (final String line in const LineSplitter().convert(m.glossary)) {
          buf.writeln('> - $line');
        }
      }
      buf.writeln('>');
      buf.writeln('> *${_formatDateTime(m.createdAt)}*');
      buf.writeln();
    }
  });
  return buf.toString().trimRight();
}

String _buildMinedTxt(List<ExportMinedSentence> items) {
  final StringBuffer buf = StringBuffer();
  for (final ExportMinedSentence m in items) {
    if (m.sentence.isNotEmpty) buf.writeln(m.sentence);
    final String head =
        m.reading.isEmpty ? m.expression : '${m.expression}（${m.reading}）';
    if (m.glossary.isEmpty) {
      buf.writeln(head);
    } else {
      buf.writeln('$head\t${m.glossary.replaceAll('\n', ' ')}');
    }
  }
  return buf.toString().trimRight();
}

String _buildMinedCsv(List<ExportMinedSentence> items, {required bool csvBom}) {
  final StringBuffer buf = StringBuffer();
  if (csvBom) buf.write(_utf8Bom);
  buf.write(<String>[
    'sentence',
    'expression',
    'reading',
    'glossary',
    'source',
    'createdAt',
  ].map(_csvEscape).join(','));
  buf.write(_csvNewline);
  for (final ExportMinedSentence m in items) {
    buf.write(<String>[
      m.sentence,
      m.expression,
      m.reading,
      m.glossary,
      m.source ?? '',
      m.createdAt.toIso8601String(),
    ].map(_csvEscape).join(','));
    buf.write(_csvNewline);
  }
  return buf.toString();
}

String _buildMinedJson(List<ExportMinedSentence> items) {
  final List<Map<String, dynamic>> list = items
      .map((ExportMinedSentence m) => <String, dynamic>{
            'sentence': m.sentence,
            'expression': m.expression,
            'reading': m.reading,
            'glossary': m.glossary,
            'bookTitle': m.bookTitle,
            if (m.source != null) 'source': m.source,
            'createdAt': m.createdAt.toIso8601String(),
          })
      .toList();
  return const JsonEncoder.withIndent('  ').convert(list);
}

/// 按句聚合后的单个生词（喂 AI 友好：去掉 createdAt/source，只留词三元组）。TODO-914。
class ExportMinedWord {
  const ExportMinedWord({
    required this.expression,
    required this.reading,
    required this.glossary,
  });

  final String expression;
  final String reading;
  final String glossary;
}

/// 按句聚合后的制卡句（一句 + 该句生词表）。喂 AI / 复习友好。TODO-914。
class ExportMinedSentenceGroup {
  const ExportMinedSentenceGroup({
    required this.sentence,
    required this.words,
    required this.bookTitle,
    required this.createdAt,
    this.source,
  });

  /// 组内首条原文（不归一，归一只决定是否同句）。
  final String sentence;

  /// 该句聚合到的所有生词（三元组去重、保持首现序）。
  final List<ExportMinedWord> words;
  final String bookTitle;

  /// 组内最新制卡时间（最近优先，与列表 createdAt desc 一致）。
  final DateTime createdAt;
  final String? source;
}

/// 句键归一（仅用于分组判同句，**不改输出文本**）。TODO-914。
///
/// 规则：①`trim()` 去首尾空白；②内部连续空白（含全角空格 `　` U+3000、`\t`、
/// `\r\n`、`\n`）折叠为单个半角空格；③全角 ASCII（U+FF01–U+FF5E）→ 半角。
/// **不依赖 NFKC**（Dart 标准库无 `String.normalize`），用确定的小映射即可覆盖
/// 全角句号/标点折叠，且可单测。不做大小写折叠（日文无意义、误伤罗马字）。
///
/// 取舍：U+200B 零宽空格、NFC↔NFD 组合假名差异**不处理**——这类 codepoint 级
/// 差异在真实收藏/制卡数据里罕见，且引入 ICU 归一是过度依赖；如出现会被判为
/// 不同句（保守不误合并），符合「宁可不合并也不错合」的导出语义。
/// 常见 CJK 标点 → 对应半角 ASCII（仅用于归一判同句，不改输出文本）。让「本。」≡「本.」。
const Map<int, int> _cjkPunctToAscii = <int, int>{
  0x3002: 0x2E, // 。 → .
  0x3001: 0x2C, // 、 → ,
  0x30FB: 0x2E, // ・ → .
  0x3008: 0x3C, // 〈 → <
  0x3009: 0x3E, // 〉 → >
};

String _normalizeSentenceKey(String s) {
  // ③④ 全角 ASCII / 全角空格 U+3000 / CJK 标点（。、・〈〉）→ 半角 ASCII。
  final StringBuffer halfWidth = StringBuffer();
  for (final int rune in s.runes) {
    if (rune == 0x3000) {
      halfWidth.writeCharCode(0x20); // 全角空格 → 半角空格
    } else if (rune >= 0xFF01 && rune <= 0xFF5E) {
      halfWidth.writeCharCode(rune - 0xFEE0); // 全角 ASCII → 半角
    } else if (_cjkPunctToAscii.containsKey(rune)) {
      halfWidth.writeCharCode(_cjkPunctToAscii[rune]!); // CJK 标点 → 半角
    } else {
      halfWidth.writeCharCode(rune);
    }
  }
  // ② 内部连续空白（此时全角空格已转半角）折叠为单个半角空格；① trim。
  return halfWidth.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// 制卡句去重聚合：把 [rows] 按归一句键分组，同句的多个挖词合进一组的 [words]。
///
/// - 空 `sentence` 的行（独立查词制卡，无句）按 `(expression,reading,glossary)`
///   三元组各自成组（不与他句、也不互相塌成一桶）。
/// - 保持每组首次出现的顺序；组内词按传入顺序、按三元组去重。
/// - `createdAt` 取组内**最新**；`bookTitle`/`source` 取组内首条（首次出现）。
/// TODO-914。
List<ExportMinedSentenceGroup> dedupeMinedBySentence(
  List<ExportMinedSentence> rows,
) {
  // 分组键 → 可变累加器（保持首现序用 LinkedHashMap 语义，Dart Map 默认即是）。
  final Map<String, _MinedGroupAccumulator> groups =
      <String, _MinedGroupAccumulator>{};
  for (final ExportMinedSentence m in rows) {
    final String normalized = _normalizeSentenceKey(m.sentence);
    // 空句行不塌桶：用词三元组拼独立键（前缀避免与真实空句撞）。
    final String key = normalized.isEmpty
        ? 'word::${m.expression} ${m.reading} ${m.glossary}'
        : 'sentence::$normalized';
    final _MinedGroupAccumulator acc = groups.putIfAbsent(
      key,
      () => _MinedGroupAccumulator(
        sentence: m.sentence,
        bookTitle: m.bookTitle,
        source: m.source,
        createdAt: m.createdAt,
      ),
    );
    if (m.createdAt.isAfter(acc.createdAt)) acc.createdAt = m.createdAt;
    final String wordKey = '${m.expression} ${m.reading} ${m.glossary}';
    if (acc.seenWords.add(wordKey)) {
      acc.words.add(ExportMinedWord(
        expression: m.expression,
        reading: m.reading,
        glossary: m.glossary,
      ));
    }
  }
  return groups.values
      .map((_MinedGroupAccumulator a) => ExportMinedSentenceGroup(
            sentence: a.sentence,
            words: a.words,
            bookTitle: a.bookTitle,
            createdAt: a.createdAt,
            source: a.source,
          ))
      .toList();
}

/// [dedupeMinedBySentence] 内部累加器（可变，仅本文件用）。
class _MinedGroupAccumulator {
  _MinedGroupAccumulator({
    required this.sentence,
    required this.bookTitle,
    required this.source,
    required this.createdAt,
  });

  final String sentence;
  final String bookTitle;
  final String? source;
  DateTime createdAt;
  final List<ExportMinedWord> words = <ExportMinedWord>[];
  final Set<String> seenWords = <String>{};
}

/// 收藏句按归一文本去重（保留首现）。复用 [_normalizeSentenceKey]。TODO-914。
List<ExportSentence> dedupeSentences(List<ExportSentence> rows) {
  final Set<String> seen = <String>{};
  final List<ExportSentence> out = <ExportSentence>[];
  for (final ExportSentence s in rows) {
    if (seen.add(_normalizeSentenceKey(s.text))) out.add(s);
  }
  return out;
}

/// 把按句聚合后的 [groups] 按 [ExportMinedSentenceGroup.bookTitle] 分组（保持首现书序）。
Map<String, List<ExportMinedSentenceGroup>> _groupMinedGroupsByBook(
  List<ExportMinedSentenceGroup> groups,
) {
  final Map<String, List<ExportMinedSentenceGroup>> grouped =
      <String, List<ExportMinedSentenceGroup>>{};
  for (final ExportMinedSentenceGroup g in groups) {
    grouped.putIfAbsent(g.bookTitle, () => <ExportMinedSentenceGroup>[]).add(g);
  }
  return grouped;
}

/// 去重聚合制卡句导出（一句一对象，含 words 数组）。四格式。TODO-914。
///
/// - Markdown：`## 书名` → `> 整句` → 每词 `- **expr**（reading）· glossary`。
/// - TXT：整句行 + 每词缩进行。
/// - CSV：表头 `sentence,expression,reading,glossary,source,createdAt`，**一词一行**
///   （sentence 列在同句多词时重复），带 BOM（Excel 友好）。
/// - JSON：`[{sentence, words:[{expression,reading,glossary}], bookTitle, source, createdAt}]`。
String buildMinedGroupedExport(
  List<ExportMinedSentenceGroup> groups, {
  required ExportFormat format,
  bool csvBom = true,
}) {
  switch (format) {
    case ExportFormat.markdown:
      return _buildMinedGroupedMarkdown(groups);
    case ExportFormat.txt:
      return _buildMinedGroupedTxt(groups);
    case ExportFormat.csv:
      return _buildMinedGroupedCsv(groups, csvBom: csvBom);
    case ExportFormat.json:
      return _buildMinedGroupedJson(groups);
  }
}

String _buildMinedGroupedMarkdown(List<ExportMinedSentenceGroup> groups) {
  final Map<String, List<ExportMinedSentenceGroup>> grouped =
      _groupMinedGroupsByBook(groups);
  final StringBuffer buf = StringBuffer();
  buf.writeln('# ${t.collection_export_mined_title}');
  buf.writeln();
  bool firstBook = true;
  grouped.forEach((String bookTitle, List<ExportMinedSentenceGroup> list) {
    if (!firstBook) buf.writeln();
    firstBook = false;
    buf.writeln('## $bookTitle');
    buf.writeln();
    for (final ExportMinedSentenceGroup g in list) {
      if (g.sentence.isNotEmpty) {
        for (final String line in const LineSplitter().convert(g.sentence)) {
          buf.writeln('> $line');
        }
        buf.writeln('>');
      }
      for (final ExportMinedWord w in g.words) {
        final String head = w.reading.isEmpty
            ? '**${w.expression}**'
            : '**${w.expression}**（${w.reading}）';
        final String gloss =
            w.glossary.isEmpty ? '' : ' · ${w.glossary.replaceAll('\n', ' ')}';
        buf.writeln('> - $head$gloss');
      }
      buf.writeln('>');
      buf.writeln('> *${_formatDateTime(g.createdAt)}*');
      buf.writeln();
    }
  });
  return buf.toString().trimRight();
}

String _buildMinedGroupedTxt(List<ExportMinedSentenceGroup> groups) {
  final StringBuffer buf = StringBuffer();
  for (final ExportMinedSentenceGroup g in groups) {
    if (g.sentence.isNotEmpty) buf.writeln(g.sentence);
    for (final ExportMinedWord w in g.words) {
      final String head =
          w.reading.isEmpty ? w.expression : '${w.expression}（${w.reading}）';
      if (w.glossary.isEmpty) {
        buf.writeln('\t$head');
      } else {
        buf.writeln('\t$head\t${w.glossary.replaceAll('\n', ' ')}');
      }
    }
  }
  return buf.toString().trimRight();
}

String _buildMinedGroupedCsv(
  List<ExportMinedSentenceGroup> groups, {
  required bool csvBom,
}) {
  final StringBuffer buf = StringBuffer();
  if (csvBom) buf.write(_utf8Bom);
  buf.write(<String>[
    'sentence',
    'expression',
    'reading',
    'glossary',
    'source',
    'createdAt',
  ].map(_csvEscape).join(','));
  buf.write(_csvNewline);
  for (final ExportMinedSentenceGroup g in groups) {
    for (final ExportMinedWord w in g.words) {
      buf.write(<String>[
        g.sentence,
        w.expression,
        w.reading,
        w.glossary,
        g.source ?? '',
        g.createdAt.toIso8601String(),
      ].map(_csvEscape).join(','));
      buf.write(_csvNewline);
    }
  }
  return buf.toString();
}

List<Map<String, dynamic>> _minedGroupsToJsonList(
  List<ExportMinedSentenceGroup> groups,
) =>
    groups
        .map((ExportMinedSentenceGroup g) => <String, dynamic>{
              'sentence': g.sentence,
              'words': g.words
                  .map((ExportMinedWord w) => <String, dynamic>{
                        'expression': w.expression,
                        'reading': w.reading,
                        'glossary': w.glossary,
                      })
                  .toList(),
              'bookTitle': g.bookTitle,
              if (g.source != null) 'source': g.source,
              'createdAt': g.createdAt.toIso8601String(),
            })
        .toList();

String _buildMinedGroupedJson(List<ExportMinedSentenceGroup> groups) =>
    const JsonEncoder.withIndent('  ').convert(_minedGroupsToJsonList(groups));

List<Map<String, dynamic>> _sentencesToJsonList(List<ExportSentence> rows) =>
    rows
        .map((ExportSentence s) => <String, dynamic>{
              'text': s.text,
              'bookTitle': s.bookTitle,
              if (s.chapterLabel != null) 'chapterLabel': s.chapterLabel,
              if (s.source != null) 'source': s.source,
              'createdAt': s.createdAt.toIso8601String(),
            })
        .toList();

/// 「全部」导出：制卡句段 + 收藏句段，按格式各自渲染后拼接（两段**分开**，段间不互消）。
///
/// 符合用户「收藏和制卡应该分开」：同一句既被制卡又被收藏时，两段各出现一次。
/// - Markdown / TXT：`# 制卡句` 段 + `# 收藏句` 段。
/// - JSON：`{"mined":[...句+words...], "favorites":[...纯句...]}`（两键天然分开）。
/// - CSV：单表加 `kind` 首列（`mined`/`favorite`），列并集（收藏句无词字段留空），
///   制卡句一词一行。带 BOM。
/// TODO-914。
String buildCombinedExport({
  required List<ExportMinedSentenceGroup> mined,
  required List<ExportSentence> favorites,
  required ExportFormat format,
  bool csvBom = true,
}) {
  switch (format) {
    case ExportFormat.markdown:
      // Markdown 内层 builder 各自已写 `# 段标题`（_buildMinedGroupedMarkdown /
      // _buildSentenceMarkdown），combined 不再重复写，否则每段标题出现两次。
      final StringBuffer mdBuf = StringBuffer();
      mdBuf.writeln(buildMinedGroupedExport(mined, format: format));
      mdBuf.writeln();
      mdBuf.writeln();
      mdBuf.writeln(buildSentenceExport(favorites, format: format));
      return mdBuf.toString().trimRight();
    case ExportFormat.txt:
      // TXT 内层 builder 不写标题，故 combined 自己写两段 `# 段标题` 分隔。
      final StringBuffer buf = StringBuffer();
      buf.writeln('# ${t.collection_export_mined_title}');
      buf.writeln();
      buf.writeln(buildMinedGroupedExport(mined, format: format));
      buf.writeln();
      buf.writeln();
      buf.writeln('# ${t.collection_export_sentences_title}');
      buf.writeln();
      buf.writeln(buildSentenceExport(favorites, format: format));
      return buf.toString().trimRight();
    case ExportFormat.json:
      return const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
        'mined': _minedGroupsToJsonList(mined),
        'favorites': _sentencesToJsonList(favorites),
      });
    case ExportFormat.csv:
      final StringBuffer buf = StringBuffer();
      if (csvBom) buf.write(_utf8Bom);
      buf.write(<String>[
        'kind',
        'sentence',
        'expression',
        'reading',
        'glossary',
        'bookTitle',
        'chapter',
        'source',
        'createdAt',
      ].map(_csvEscape).join(','));
      buf.write(_csvNewline);
      for (final ExportMinedSentenceGroup g in mined) {
        for (final ExportMinedWord w in g.words) {
          buf.write(<String>[
            'mined',
            g.sentence,
            w.expression,
            w.reading,
            w.glossary,
            g.bookTitle,
            '',
            g.source ?? '',
            g.createdAt.toIso8601String(),
          ].map(_csvEscape).join(','));
          buf.write(_csvNewline);
        }
      }
      for (final ExportSentence s in favorites) {
        buf.write(<String>[
          'favorite',
          s.text,
          '',
          '',
          '',
          s.bookTitle,
          s.chapterLabel ?? '',
          s.source ?? '',
          s.createdAt.toIso8601String(),
        ].map(_csvEscape).join(','));
        buf.write(_csvNewline);
      }
      return buf.toString();
  }
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
