/// 在线源（Mihon / Aidoku / LNReader / 互联）失败给用户看的文案。
///
/// 2026-10 体验优化：此前各页直接 `'$error'` 把原始异常甩给用户——
/// `Exception: SocketException: Failed host lookup ...`、
/// `MihonRuntimeException(BRIDGE_HTTP_503) ...` 之类既长又看不懂。这里统一：
/// 常见的网络 / 超时 / HTTP 状态映射成本地化短句；其余的只去掉
/// `Exception:` / `Bad state:` 这类前缀后原样露出（扩展抛的
/// `Log in via WebView ...` 正是用户要知道的下一步，BUG-2479，不能一律抹成
/// 「加载失败」）。原文由调用点（或传 [logTag] 时由这里）写进错误日志。
library;

import 'dart:async';
import 'dart:io';

import 'package:fushi/utils.dart';

/// HTTP 状态码：`HTTP 404`、`HTTP error 503`、`STORE_HTTP_404`、`HTTP: 500`。
final RegExp _httpStatusPattern = RegExp(
  r'HTTP(?:[\s_]+error)?[\s_:]*([1-5]\d\d)\b',
  caseSensitive: false,
);

/// 可剥掉的异常类型前缀（可能叠多层：`Exception: Exception: ...`）。
///
/// 类型名后可带一段括号限定：`MihonRuntimeException(CODE): ...`、
/// 漫画在线源包装异常的 `OnlineMangaUnavailable(<reason>): ...`——后者经
/// `'$error'` 落进下载任务的 `lastError` 后只剩字符串，必须在这里认。
final RegExp _exceptionPrefixPattern = RegExp(
  r'^(?:[A-Za-z0-9_]*(?:Exception|Error)|OnlineMangaUnavailable|Bad state'
  r'|Invalid argument(?:\(s\))?)(?:\([^)]*\))?\s*:\s*',
);

const List<String> _timeoutMarkers = <String>[
  'timeoutexception',
  'sockettimeoutexception',
  'timed out',
  'timeout',
];

const List<String> _networkMarkers = <String>[
  'socketexception',
  'handshakeexception',
  'unknownhostexception',
  'connectexception',
  'clientexception',
  'failed host lookup',
  'connection refused',
  'connection reset',
  'connection closed',
  'network is unreachable',
  'no address associated with hostname',
];

/// 把在线源异常转成给用户看的一句话。
///
/// 传 [logTag] 时顺手把原始异常（含 [stackTrace]）写进错误日志；在 `build`
/// 里反复调用的地方不要传，免得每次重建都记一条。
String describeOnlineSourceError(
  Object error, {
  String? logTag,
  StackTrace? stackTrace,
}) {
  if (logTag != null) {
    ErrorLogService.instance.log(logTag, error, stackTrace);
  }
  if (error is TimeoutException) return t.online_source_error_timeout;
  if (error is SocketException || error is HandshakeException) {
    return t.online_source_error_network;
  }
  return describeOnlineSourceErrorText('$error');
}

/// [describeOnlineSourceError] 的字符串入口：给**已经落成字符串**的原始
/// 异常（如下载任务持久化的 `lastError`、包装异常里的 `message`）用。
///
/// 与异常对象入口共用同一套映射——`'$error'` 本来就是那边类型判断之后的
/// 兜底路径，原始串里的 `SocketException` / `TimeoutException` / HTTP 状态
/// 码都能按文本认出来。原始串本身由调用方保留（诊断、日志、导出不变）。
String describeOnlineSourceErrorText(String rawError) {
  final String raw = rawError.trim();
  final String lower = raw.toLowerCase();
  if (_timeoutMarkers.any(lower.contains)) {
    return t.online_source_error_timeout;
  }
  final RegExpMatch? http = _httpStatusPattern.firstMatch(raw);
  if (http != null) {
    return t.online_source_error_http(code: http.group(1)!);
  }
  if (_networkMarkers.any(lower.contains)) {
    return t.online_source_error_network;
  }
  String message = raw;
  while (true) {
    final String stripped = message.replaceFirst(_exceptionPrefixPattern, '');
    if (stripped == message) break;
    message = stripped.trim();
  }
  if (message.isEmpty ||
      message == 'Exception' ||
      message.startsWith("Instance of '")) {
    return t.online_source_error_generic;
  }
  return message;
}
