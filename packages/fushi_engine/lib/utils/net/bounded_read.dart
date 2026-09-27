/// 有上限的正文读取：边读边计数，一旦累计超过上限立刻停止订阅并抛
/// [BodyTooLargeException]——绝不先把整份正文读进内存再比长度。
///
/// 远端 IPTV 列表、`.strm` 指针、频道台标这类「内容由第三方决定」的下载都该走它：
/// `http.Response.bodyBytes` 与 `File.readAsBytes` 是先全量读完才能比长度，
/// 误填成一条几 GB 的视频直链时内存先被打满，上限形同虚设。
library;

import 'dart:typed_data';

/// 正文超过 [maxBytes] 时由 [readBoundedBytes] 抛出。
class BodyTooLargeException implements Exception {
  const BodyTooLargeException(this.maxBytes);

  final int maxBytes;

  @override
  String toString() => 'BodyTooLargeException(> $maxBytes bytes)';
}

/// 读完 [stream]，累计字节数超过 [maxBytes] 立即抛 [BodyTooLargeException]
/// （`await for` 以异常退出时订阅随之取消，底层连接 / 文件句柄不再继续读）。
Future<Uint8List> readBoundedBytes(
  Stream<List<int>> stream,
  int maxBytes,
) async {
  final BytesBuilder builder = BytesBuilder(copy: false);
  await for (final List<int> chunk in stream) {
    if (builder.length + chunk.length > maxBytes) {
      throw BodyTooLargeException(maxBytes);
    }
    builder.add(chunk);
  }
  return builder.takeBytes();
}
