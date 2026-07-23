import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../audiobook/audiobook_model.dart';

/// 字幕解析器（SRT / ASS / VTT）共用的 isolate 派发脚手架。
///
/// 解析主体是各格式自己的纯函数 `parseString`；这里只负责统一的
/// 「大文件切 isolate、小文件同步解析」决策，避免三份逐字复制。
class CueParseDispatch {
  /// 超过该字节数（UTF-8 编码后）的内容切 isolate 解析，避免阻塞 UI。
  static const int largeContentComputeThreshold = 1024 * 1024;

  static int utf8ContentByteLength(String content) {
    return utf8.encode(content).length;
  }

  static bool shouldParseInIsolate(String content) {
    return utf8ContentByteLength(content) > largeContentComputeThreshold;
  }

  /// 按内容大小决定同步解析或切 isolate。
  ///
  /// [parse] 必须是只捕获不可变入参的纯函数闭包（跨 isolate 发送）。
  static Future<List<AudioCue>> run({
    required String content,
    required List<AudioCue> Function() parse,
  }) {
    if (shouldParseInIsolate(content)) {
      return compute((_) => parse(), null);
    }
    return Future<List<AudioCue>>.value(parse());
  }
}
