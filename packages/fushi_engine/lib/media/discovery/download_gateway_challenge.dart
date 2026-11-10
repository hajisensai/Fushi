/// 下载网关的人机验证挑战（工作量证明 / 验证码门）：识别、上浮、拿到放行凭据后续下。
///
/// BUG-4347：内置 AList（alist.erogame.space）`/api/fs/get` 给的 `raw_url` 302 到
/// 一台下载网关，网关对**任何**不带放行凭据的请求一律回
/// `403 {"code":"pow_required"}`（浏览器请求则回一页 Equihash 解题脚本），下载器
/// 以前只把它当普通 403 报错。站点只给浏览器留了路：页面 JS 解完题后 POST
/// `<apiPrefix>/verify` 换一次性 `consume` 凭据，再写一个短命 cookie（或拼查询参数）
/// 并 `location.replace` 回原资源 URL——那一跳才真正开始下载。
///
/// 所以这里只定义**协议无关**的部分（判据 + 契约），不在 Dart 里重写各站的解题
/// 算法：解题交给 app 层注入的 [DownloadGatewayChallengeSolver]（WebView 让站点
/// 自己的 JS 跑完，截下回跳那一刻的 URL 与 cookie），下载器带着凭据重开同一资源。
/// 触发判据只看响应体的 `code`（[kDownloadGatewayChallengeCodes]），不认域名。
library;

import 'dart:async';
import 'dart:convert';

import 'package:fushi_engine/utils/misc/resumable_downloader.dart';

/// 网关在拒绝响应体里自报「要先过人机验证」的 `code` 取值。
///
/// 只收**明确表示挑战**的取值；普通鉴权失败（401 / `unauthorized`）不在此列——
/// 那种错误换个浏览器也过不去，弹验证页只会让用户白等。
const Set<String> kDownloadGatewayChallengeCodes = <String>{'pow_required'};

/// 嗅探挑战时最多读多少字节的错误响应体；超出即视为不是挑战信封（挑战信封是
/// 几十字节的 JSON，真正的大错误页不值得整份缓冲）。
const int kDownloadGatewayChallengeSniffLimit = 64 * 1024;

/// 下载被网关的人机验证挡住。不是瞬时错误：原样重试必然再挡一次。
class DownloadGatewayChallengeRequired implements Exception {
  const DownloadGatewayChallengeRequired({
    required this.challengeUrl,
    required this.code,
  });

  /// 回挑战的那一跳 URL（重定向跟完之后的网关地址）。解题页 / 「在浏览器中打开」
  /// 都打开它：网关正是对这个 URL 下发题目、解完也回跳到它。
  final Uri challengeUrl;

  /// 网关自报的挑战类型（如 `pow_required`）。
  final String code;

  @override
  String toString() =>
      'DownloadGatewayChallengeRequired($code): ${challengeUrl.host}';
}

/// 解题拿到的放行凭据：带着它重开资源。
class DownloadGatewayClearance {
  const DownloadGatewayClearance({
    required this.url,
    this.headers = const <String, String>{},
  });

  /// 放行后应请求的 URL（站点可能把一次性凭据拼在查询参数里，所以不能沿用原 URL）。
  final Uri url;

  /// 放行凭据头（`Cookie`，以及解题时浏览器用的 `User-Agent`——凭据可能绑 UA）。
  final Map<String, String> headers;
}

/// 解一次挑战。返回 null = 解不了（用户关掉了验证页 / 平台没有 WebView / 没装
/// 解题器），调用方按 [DownloadGatewayChallengeRequired] 失败上浮。
typedef DownloadGatewayChallengeSolver =
    Future<DownloadGatewayClearance?> Function(Uri challengeUrl);

/// 从错误响应体里读出挑战 `code`；不是挑战信封返回 null。
///
/// 只认 4xx 且顶层 JSON 对象的字符串 `code` 落在 [kDownloadGatewayChallengeCodes] 里。
String? downloadGatewayChallengeCodeOf(int statusCode, List<int> body) {
  if (statusCode < 400 || statusCode >= 500) return null;
  if (body.isEmpty || body.length > kDownloadGatewayChallengeSniffLimit) {
    return null;
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(body, allowMalformed: true));
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final Object? code = decoded['code'];
  if (code is! String) return null;
  return kDownloadGatewayChallengeCodes.contains(code) ? code : null;
}

/// 包住一次 `open` 的结果：4xx 响应先把（有界的）响应体读出来判挑战，是挑战就抛
/// [DownloadGatewayChallengeRequired]，不是就把已读字节原样还给下游
/// （`ResumableDownloader` 照旧按状态码报错）。2xx / 3xx / 5xx 原样透传、不读体。
///
/// 416 也透传：那是续传偏移越界，下载器自己会删 `.part` 从零重下。
Future<ResumableDownloadResponse> guardDownloadGatewayChallenge(
  ResumableDownloadResponse response,
  Uri requestedUrl,
) async {
  final int status = response.statusCode;
  if (status < 400 || status >= 500 || status == 416) return response;
  final List<int> buffered = <int>[];
  bool overflow = false;
  await for (final List<int> chunk in response.stream) {
    if (overflow) continue; // 超限后只排空不缓冲，连接才能释放
    buffered.addAll(chunk);
    if (buffered.length > kDownloadGatewayChallengeSniffLimit) overflow = true;
  }
  if (!overflow) {
    final String? code = downloadGatewayChallengeCodeOf(status, buffered);
    if (code != null) {
      throw DownloadGatewayChallengeRequired(
        challengeUrl: requestedUrl,
        code: code,
      );
    }
  }
  return ResumableDownloadResponse.bytes(
    statusCode: status,
    body: buffered,
    headers: response.headers,
  );
}
