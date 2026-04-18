import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_charset_detector/flutter_charset_detector.dart';

/// 读取文本文件并自动识别编码。
///
/// 先按 UTF-8 严格解码。若遇 [FormatException]（例如日文字幕常见的
/// Shift-JIS / CP932 / EUC-JP），退回 [CharsetDetector.autoDecode] 做启发式
/// 识别。BOM（`\uFEFF`）不在此处剥离，由各 parser 自行处理以保持旧行为。
Future<String> readTextWithEncoding(File file) async {
  final Uint8List bytes = await file.readAsBytes();
  try {
    return utf8.decode(bytes);
  } on FormatException {
    final DecodingResult result = await CharsetDetector.autoDecode(bytes);
    return result.string;
  }
}
