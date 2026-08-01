import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/utils/net/app_proxy.dart';

/// Connection-establishment timeout for cloud sync HTTP requests.
const Duration kSyncConnectionTimeout = Duration(seconds: 60);

/// 建一个**独占**的云同步 HTTP client：60s 连接超时 + 全应用代理出口。
///
/// BUG-1348 根因就在这里。云同步的每个出站请求原先都用裸 `HttpClient()` / `http.Client()`，
/// 而 Dart 的 `HttpClient` 默认 `findProxy` 为空——**连 `HTTPS_PROXY` 环境变量都不读**，更不
/// 读 clash/v2ray 写进 Windows 注册表的系统代理。于是同一台机器上，浏览器那半程 OAuth 走
/// 系统代理拿到了授权码，app 这半程直连 `oauth2.googleapis.com` 换 token 必然被切
/// （`errno = 121` 信号灯超时）。所有云同步出站请求必须经这里建 client，才不会再漏出一条
/// 直连暗路。
///
/// 60s 超时只覆盖**连接建立**（DNS + TCP + TLS 握手），响应体传输故意不设时限，大文件
/// 上传/下载才能跑完并持续汇报进度，而不是被一刀切断。
///
/// 返回的 client 归调用方所有（用完自己 `close()`）。需要与旁人共享连接池的，用
/// [obtainSyncHttpClient]。
Future<http.Client> createSyncHttpClient() async {
  final HttpClient io = HttpClient()
    ..connectionTimeout = kSyncConnectionTimeout;
  await applyAppProxy(io);
  return IOClient(io);
}

/// 云同步后端（OneDrive / Dropbox）共享的 HTTP client。
///
/// 惰性构造：代理解析要跑 `reg query` / `scutil` / `gsettings`，是异步的，没法在顶层
/// `final` 初始化里完成——这正是它以前是个裸同步单例、也就没有代理的原因。首次调用解析
/// 一次并缓存，之后零开销。
///
/// **不要 `close()` 它**（那会掐断其他后端正在用的连接）；需要独占所有权时用
/// [createSyncHttpClient]。
Future<http.Client> obtainSyncHttpClient() async =>
    _sharedClient ??= await createSyncHttpClient();

http.Client? _sharedClient;

/// 丢弃共享 client，让下次调用按**当前**代理设置重建。
///
/// 用户在设置里改了代理却仍走旧出口，就等于这个修复对他不生效；缓存必须能失效。
void resetSyncHttpClient() {
  _sharedClient?.close();
  _sharedClient = null;
}

/// Stream [file] as the body of a pre-configured [request] (headers/content
/// length already set), reporting transfer progress as a 0..1 fraction.
///
/// Uses `sink.addStream`, so a file-read error propagates as a thrown
/// exception instead of being silently dropped (which could truncate the
/// upload or surface as an unhandled async error). The in-flight response
/// future is always awaited so it can never linger as an unhandled future.
Future<http.Response> streamUpload(
  http.StreamedRequest request,
  File file,
  int fileLength,
  void Function(double fraction)? onProgress,
) async {
  final responseFuture = (await obtainSyncHttpClient()).send(request);
  var sent = 0;
  Object? pumpError;
  try {
    await request.sink.addStream(file.openRead().map((chunk) {
      sent += chunk.length;
      onProgress?.call(fileLength > 0 ? sent / fileLength : 0);
      return chunk;
    }));
  } catch (e) {
    pumpError = e;
  } finally {
    await request.sink.close();
  }

  final http.StreamedResponse streamed;
  try {
    streamed = await responseFuture;
  } catch (e) {
    throw SyncBackendError('Upload failed: ${pumpError ?? e}');
  }
  if (pumpError != null) {
    throw SyncBackendError('Upload failed reading file: $pumpError');
  }
  return http.Response.fromStream(streamed);
}
