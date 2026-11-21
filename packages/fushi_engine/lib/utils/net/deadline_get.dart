/// 带总截止的小文件 GET（字幕这类几 KB～几 MB 的整份读取）。
///
/// 单独给 `client.get(...)` 套 `.timeout` 只会让等待方放弃，底层请求与响应流仍挂着
/// （孤儿连接，BUG-1248 同一类）。这里用 package:http 的 [http.AbortableRequest]：到点
/// 先让等待方拿到 [TimeoutException]，再 abort 底层传输——与
/// `media/metadata/image_download.dart` 的 `CoverDownloadDeadline` 同一顺序契约。
library;

import 'dart:async';

import 'package:http/http.dart' as http;

/// 远端字幕下载（扩展源 / 直链流的外挂字幕）的总预算：从发请求到读完整份正文。
///
/// 起播时默认字幕挡在开流之前（所有者定不并行化），第三方字幕站接了连接却不回数据
/// 时没有上限，页面就永远停在「正在下载字幕」。字幕是小文件，20 秒足够慢网读完；
/// 到点后起播照常继续，只是这一次不挂默认字幕。
const Duration kRemoteSubtitleFetchTimeout = Duration(seconds: 20);

/// GET [url] 并读完整份正文，总耗时超过 [timeout] 抛 [TimeoutException] 并中止底层传输。
///
/// [client] 不关闭（所有权在调用方）。非 2xx 不在这里判，原样返回给调用方。
Future<http.Response> getWithDeadline(
  http.Client client,
  Uri url, {
  required Duration timeout,
  Map<String, String>? headers,
}) async {
  final Completer<void> abort = Completer<void>();
  final Completer<http.Response> expiration = Completer<http.Response>();
  // 正常路径没有等待方会去听 expiration，先挂一个吞错 handler。
  expiration.future.ignore();
  final Timer timer = Timer(timeout, () {
    // 顺序即契约：先让等待方拿到 TimeoutException，再中止底层传输。
    if (!expiration.isCompleted) {
      expiration.completeError(
        TimeoutException('GET ${url.host} timed out', timeout),
        StackTrace.current,
      );
    }
    if (!abort.isCompleted) abort.complete();
  });
  final http.AbortableRequest request = http.AbortableRequest(
    'GET',
    url,
    abortTrigger: abort.future,
  );
  if (headers != null) request.headers.addAll(headers);
  try {
    final Future<http.Response> response = client
        .send(request)
        .then(http.Response.fromStream);
    // Future.any：先到者说了算，后到的错误被静默丢弃（不会成为未处理异常）。
    return await Future.any(<Future<http.Response>>[
      response,
      expiration.future,
    ]);
  } finally {
    timer.cancel();
  }
}
