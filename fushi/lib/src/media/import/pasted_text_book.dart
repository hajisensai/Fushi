import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/media/audiobook/text_to_epub.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';

// 「粘贴文本阅读」（反馈 f2k9m1oU0j）：把用户粘贴 / 输入的一段文本落成书库里的
// 一本普通书，再交给 EPUB 阅读器打开——点词查词、制卡、阅读位置、出处跳回全部
// 复用阅读器既有能力，不另起一个只读文本视图（那会把查词 / 制卡 / 进度再实现一遍）。
//
// 载体与「导入 .txt 文件」完全同一条管线：[TextToEpub.convertText] 生成 EPUB 3，
// [EpubImporter.import] 落库；区别只是正文来自内存而不是文件。

/// 默认标题最多取多少个字符（按 Unicode 码点计，不切开代理对）。
const int kPastedTextBookTitleMaxChars = 40;

/// 纯函数：文本里有没有可读内容（全空白不算）。
bool pastedTextHasContent(String text) => text.trim().isNotEmpty;

/// 纯函数：由粘贴文本推导默认书名——第一行非空行、连续空白折成一个空格、
/// 超过 [maxChars] 截断并补 `…`。没有可读内容返回 null，由调用方用本地化的兜底名。
String? pastedTextBookTitle(
  String text, {
  int maxChars = kPastedTextBookTitleMaxChars,
}) {
  for (final String line in text.split(RegExp(r'\r\n|\r|\n'))) {
    // 去掉 BOM 与首尾空白，行内连续空白（含全角空格）折叠。
    final String collapsed = line
        .replaceAll('﻿', '')
        .replaceAll(RegExp(r'[\s　]+'), ' ')
        .trim();
    if (collapsed.isEmpty) continue;
    final List<int> runes = collapsed.runes.toList();
    if (runes.length <= maxChars) return collapsed;
    return '${String.fromCharCodes(runes.take(maxChars)).trimRight()}…';
  }
  return null;
}

/// 把 [text] 以 [title] 为书名落库，返回新书的 bookKey。
///
/// 同名默认 [DuplicatePolicy.suffix]（`粘贴的文本 (2)`）：粘贴文本是一次性内容，
/// 同名不代表同一本书，不该询问或跳过。[title] 写进 OPF `dc:title`，导入层据此
/// 定库内书名；`fileName` 只是兜底，用净化过的书名避免路径分隔符。
Future<String> importPastedTextBook({
  required FushiDatabase db,
  required String text,
  required String title,
  DuplicatePolicy policy = const DuplicatePolicy.suffix(),
}) {
  final Uint8List bytes = TextToEpub.convertText(content: text, title: title);
  return EpubImporter.import(
    db: db,
    bytes: bytes,
    fileName: '${sanitizeTtuFilename(title)}.epub',
    policy: policy,
  );
}
