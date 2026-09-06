import 'package:flutter/foundation.dart';

import '../audiobook/audiobook_model.dart';

/// 字幕解析器（SRT / ASS / VTT）共用的 isolate 派发脚手架。
///
/// 解析主体是各格式自己的纯函数 `parseString`；这里只负责统一的
/// 「大文件切 isolate、小文件同步解析」决策，避免三份逐字复制。
class CueParseDispatch {
  /// 超过该字节数（UTF-8 编码后）的内容切 isolate 解析，避免阻塞 UI。
  ///
  /// 256 KB：一份 1 MB 的日文 SRT 有一两万条 cue，留在 UI isolate 要上百毫秒；
  /// isolate 派发本身只要十来毫秒，阈值定在几十毫秒的解析量级即可。
  static const int largeContentComputeThreshold = 256 * 1024;

  /// [content] 的 UTF-8 字节长度——**不分配**编码副本。以前是
  /// `utf8.encode(content).length`：每次解析先把整个文件再编码一份只为量长度。
  static int utf8ContentByteLength(String content) {
    int bytes = 0;
    for (int i = 0; i < content.length; i++) {
      final int unit = content.codeUnitAt(i);
      if (unit < 0x80) {
        bytes += 1;
      } else if (unit < 0x800) {
        bytes += 2;
      } else if (unit >= 0xD800 && unit <= 0xDBFF) {
        // 代理对：两个 code unit 合成一个 4 字节码点。
        bytes += 4;
        i++;
      } else {
        bytes += 3;
      }
    }
    return bytes;
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
