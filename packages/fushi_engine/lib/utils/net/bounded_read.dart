/// 有上限的正文读取：边读边计数，一旦累计超过上限立刻停止订阅并抛
/// [BodyTooLargeException]——绝不先把整份正文读进内存再比长度。
///
/// 远端 IPTV 列表、`.strm` 指针、频道台标这类「内容由第三方决定」的下载都该走它：
/// `http.Response.bodyBytes` 与 `File.readAsBytes` 是先全量读完才能比长度，
/// 误填成一条几 GB 的视频直链时内存先被打满，上限形同虚设。
library;

import 'dart:async';
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

/// 读 HTTP **请求**体（服务端用）：先看对端声明的 Content-Length——超过 [maxBytes]
/// 就不等任何数据直接抛 [BodyTooLargeException]（声明 100 MB 却只发 1 KiB 的慢速
/// 请求不会把处理器挂在「等体」上）；未声明（chunked）或声明在限内时按块累计，
/// 累计超限立即抛。声明值只用来提前拒绝，不当作可信长度——实际读到的字节仍按
/// [maxBytes] 封顶。
///
/// 超限时订阅停在**暂停**而不是取消，这是 dart:io HttpServer 的边界契约决定的：
/// - 从没订阅过的请求体，写响应头前会被整份 drain（`_HttpOutgoing.writeHeaders`），
///   对端声明巨大长度却不发，413 永远发不出去；
/// - 取消订阅会让解析器关闭连接（`_HttpParser` body 的 onCancel → 连接 destroy），
///   连 413 也来不及写。
/// 暂停既不再读、也不触发 drain，413 写完后 dart:io 因正文未读完直接关闭连接
/// （不复用），暂停中的订阅随连接一起释放。
Future<Uint8List> readBoundedRequestBody(
  Stream<List<int>> body, {
  required int? declaredLength,
  required int maxBytes,
}) {
  final Completer<Uint8List> result = Completer<Uint8List>();
  final BytesBuilder builder = BytesBuilder(copy: false);
  // 超限时故意只暂停不取消（见上），读完 / 出错时订阅自行结束。
  // ignore: cancel_subscriptions
  late final StreamSubscription<List<int>> subscription;
  void reject() {
    subscription.pause();
    if (!result.isCompleted) {
      result.completeError(BodyTooLargeException(maxBytes));
    }
  }

  subscription = body.listen(
    (List<int> chunk) {
      if (result.isCompleted) return;
      if (builder.length + chunk.length > maxBytes) {
        reject();
        return;
      }
      builder.add(chunk);
    },
    onError: (Object error, StackTrace stack) {
      if (!result.isCompleted) result.completeError(error, stack);
    },
    onDone: () {
      if (!result.isCompleted) result.complete(builder.takeBytes());
    },
    cancelOnError: true,
  );
  if (declaredLength != null && declaredLength > maxBytes) reject();
  return result.future;
}
