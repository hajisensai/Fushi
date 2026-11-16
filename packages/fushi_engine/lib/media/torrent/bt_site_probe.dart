/// 添加 BT 站时的格式自动探测（app 设置页与无头服务端 WebUI 共用）。
///
/// 用户只填一个地址。这里用一个测试关键词把已有的几种站点适配器（Nyaa 式 HTML
/// 搜索页、apibay 式 JSON、Knaben 式 JSON）各试一遍，哪种能把响应解析成功就记下
/// 哪种格式；都不认识报 [BtSiteProbeError.unrecognized]。
///
/// 三种格式**并发**探测，每次请求有单独时限 [kBtSiteProbeAttemptTimeout]，整个
/// 探测有总时限 [kBtSiteProbeTotalTimeout]：总时限到了就用已经成功的那些结果，
/// 一个都没成功且有请求超时 → [BtSiteProbeError.timedOut]。多种同时成功时按
/// Nyaa → apibay → Knaben 的顺序取（Nyaa 式能力最全：排序 / 翻页 / 分类）。
///
/// 用户导入了解析规则（[BtSiteParserRule]）时不做自动探测：直接按规则用
/// [BtSiteParserRule.testQuery] 搜一次，请求失败报 [BtSiteProbeError.ruleRequestFailed]、
/// 一行都没解析出来报 [BtSiteProbeError.ruleMatchedNothing]，成功即
/// [BtSiteFormat.custom]。
library;

import 'dart:async';

import 'package:http/http.dart' as http;

import 'package:fushi_engine/media/torrent/bt_site_config.dart';
import 'package:fushi_engine/media/torrent/bt_site_parser_rule.dart';
import 'package:fushi_engine/media/torrent/custom_bt_site.dart';
import 'package:fushi_engine/media/torrent/nyaa_client.dart';
import 'package:fushi_engine/media/torrent/public_video_index_client.dart';
import 'package:fushi_engine/media/torrent/torznab_client.dart'
    show isSafeExternalProviderEndpoint;

/// 探测用的测试关键词：拉丁字母、各站都会有结果（没有结果也不影响识别）。
const String kBtSiteProbeQuery = 'test';

/// 单次请求时限。
const Duration kBtSiteProbeAttemptTimeout = Duration(seconds: 12);

/// 整个探测的总时限（用户在对话框里等的上限）。
const Duration kBtSiteProbeTotalTimeout = Duration(seconds: 25);

enum BtSiteProbeError {
  /// 地址不是合法的 http(s) 地址。
  invalidUrl,

  /// 明文 HTTP 且没有显式允许（局域网 / 回环之外）。
  insecureHttp,

  /// 各种格式都试过，没有一种能解析。
  unrecognized,

  /// 没有成功、且有请求超时（站点可能被墙或太慢）。
  timedOut,

  /// 按导入的解析规则请求搜索页失败（非 200 / 网络错误；登录站多半是 Cookie 缺失
  /// 或过期）。
  ruleRequestFailed,

  /// 按导入的解析规则拿到了搜索页，但结果行 / 标题选择器一行都没匹配上。
  ruleMatchedNothing,
}

class BtSiteProbeException implements Exception {
  const BtSiteProbeException(this.error);

  final BtSiteProbeError error;

  @override
  String toString() => 'BtSiteProbeException(${error.name})';
}

/// 探测成功：格式、打通的接口根地址、（Nyaa 式）分类映射。
class BtSiteProbeResult {
  const BtSiteProbeResult({
    required this.format,
    required this.baseUrl,
    this.nyaaCategories = const <BtSiteDomain, String>{},
    this.parser,
  });

  final BtSiteFormat format;
  final Uri baseUrl;
  final Map<BtSiteDomain, String> nyaaCategories;

  /// [BtSiteFormat.custom]：验证通过的解析规则。
  final BtSiteParserRule? parser;

  /// 把探测结果写进一条站点配置（新增或「重新检测」共用）。
  BtSiteConfig applyTo({
    required String id,
    String name = '',
    Set<BtSiteDomain> domains = const <BtSiteDomain>{},
    bool enabled = true,
    bool allowInsecureHttp = false,
    String cookie = '',
  }) => BtSiteConfig(
    id: id,
    name: name,
    baseUrl: baseUrl,
    format: format,
    domains: domains,
    nyaaCategories: nyaaCategories,
    enabled: enabled,
    allowInsecureHttp: allowInsecureHttp,
    parser: parser,
    // Cookie 只对按规则抓取的站点有意义；自动识别出的通用接口不带登录态。
    cookie: format == BtSiteFormat.custom ? cookie : '',
  );
}

/// 把用户输入规范成站点地址：去空白、补 `https://`、丢 query / fragment / 结尾
/// 斜杠。不合法抛 [BtSiteProbeException]（[BtSiteProbeError.invalidUrl] /
/// [BtSiteProbeError.insecureHttp]）。
Uri normalizeBtSiteUrl(String raw, {bool allowInsecureHttp = false}) {
  String text = raw.trim();
  if (text.isEmpty) {
    throw const BtSiteProbeException(BtSiteProbeError.invalidUrl);
  }
  if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(text)) {
    text = 'https://$text';
  }
  final Uri? parsed = Uri.tryParse(text);
  if (parsed == null ||
      (parsed.scheme != 'http' && parsed.scheme != 'https') ||
      parsed.host.isEmpty ||
      parsed.userInfo.isNotEmpty) {
    throw const BtSiteProbeException(BtSiteProbeError.invalidUrl);
  }
  if (!isSafeExternalProviderEndpoint(
    parsed,
    allowInsecureHttp: allowInsecureHttp,
  )) {
    throw const BtSiteProbeException(BtSiteProbeError.insecureHttp);
  }
  String path = parsed.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return Uri(
    scheme: parsed.scheme,
    host: parsed.host,
    port: parsed.hasPort ? parsed.port : null,
    path: path,
  );
}

Uri _originOf(Uri url) => Uri(
  scheme: url.scheme,
  host: url.host,
  port: url.hasPort ? url.port : null,
);

/// 某种格式要试的接口根地址（按序，第一个成功即止）。
List<Uri> btSiteProbeCandidates(BtSiteFormat format, Uri normalized) {
  final Uri origin = _originOf(normalized);
  final List<Uri> candidates = switch (format) {
    // Nyaa 式搜索页固定在站点根；apibay 式接口固定在 `/q.php`。用户贴的是首页、
    // 某个详情页还是搜索结果页都一样只取 origin。
    BtSiteFormat.nyaa || BtSiteFormat.apibay => <Uri>[origin],
    // Knaben 式接口带版本路径；用户填的多半是网站首页，接口在 `api.` 子域。
    BtSiteFormat.knaben => <Uri>[
      if (normalized.path.isNotEmpty) normalized,
      origin.replace(path: '/v1'),
      if (!normalized.host.startsWith('api.'))
        origin.replace(host: 'api.${normalized.host}', path: '/v1'),
    ],
    // 规则里的搜索路径以 `/` 开头，按站点 origin 解析。
    BtSiteFormat.custom => <Uri>[origin],
  };
  final Set<String> seen = <String>{};
  return <Uri>[
    for (final Uri candidate in candidates)
      if (seen.add(candidate.toString())) candidate,
  ];
}

/// 探测 [rawUrl] 是哪种站点。[client] 由调用方持有、这里不关。
///
/// 给了 [parser] 就不自动探测，改为按规则验证（[cookie] 随请求发给站点）。
Future<BtSiteProbeResult> probeBtSite(
  String rawUrl, {
  required http.Client client,
  bool allowInsecureHttp = false,
  BtSiteParserRule? parser,
  String cookie = '',
  Duration attemptTimeout = kBtSiteProbeAttemptTimeout,
  Duration totalTimeout = kBtSiteProbeTotalTimeout,
}) async {
  final Uri normalized = normalizeBtSiteUrl(
    rawUrl,
    allowInsecureHttp: allowInsecureHttp,
  );
  if (parser != null) {
    return _verifyParserRule(
      _originOf(normalized),
      parser,
      client: client,
      cookie: cookie,
      allowInsecureHttp: allowInsecureHttp,
      timeout: totalTimeout < attemptTimeout ? totalTimeout : attemptTimeout,
    );
  }
  final Map<BtSiteFormat, BtSiteProbeResult> successes =
      <BtSiteFormat, BtSiteProbeResult>{};
  bool sawTimeout = false;

  Future<void> tryFormat(BtSiteFormat format) async {
    for (final Uri candidate in btSiteProbeCandidates(format, normalized)) {
      if (!isSafeExternalProviderEndpoint(
        candidate,
        allowInsecureHttp: allowInsecureHttp,
      )) {
        continue;
      }
      try {
        final BtSiteProbeResult result = await _probeOne(
          format,
          candidate,
          client: client,
          timeout: attemptTimeout,
        );
        successes[format] = result;
        return;
      } on TimeoutException {
        sawTimeout = true;
      } on Object {
        // 不是这种格式（或这个候选地址不通）：试下一个候选 / 交给别的格式。
      }
    }
  }

  final Future<void> all = Future.wait(<Future<void>>[
    for (final BtSiteFormat format in kAutoDetectedBtSiteFormats)
      tryFormat(format),
  ]);
  try {
    await all.timeout(totalTimeout);
  } on TimeoutException {
    sawTimeout = true;
    // 还在跑的请求随它们各自的单次时限结束；结果不再采用。
    unawaited(all.catchError((Object _) {}));
  }
  for (final BtSiteFormat format in kAutoDetectedBtSiteFormats) {
    final BtSiteProbeResult? result = successes[format];
    if (result != null) return result;
  }
  throw BtSiteProbeException(
    sawTimeout ? BtSiteProbeError.timedOut : BtSiteProbeError.unrecognized,
  );
}

/// 自动探测会试的格式（按优先序）。[BtSiteFormat.custom] 只能靠导入规则得到。
const List<BtSiteFormat> kAutoDetectedBtSiteFormats = <BtSiteFormat>[
  BtSiteFormat.nyaa,
  BtSiteFormat.apibay,
  BtSiteFormat.knaben,
];

Future<BtSiteProbeResult> _verifyParserRule(
  Uri origin,
  BtSiteParserRule parser, {
  required http.Client client,
  required String cookie,
  required bool allowInsecureHttp,
  required Duration timeout,
}) async {
  final int rows;
  try {
    rows = await CustomBtSiteClient(
      baseUrl: origin,
      rule: parser,
      cookie: cookie,
      allowInsecureHttp: allowInsecureHttp,
      client: _BorrowedClient(client),
      requestTimeout: timeout,
    ).verifyRule();
  } on TimeoutException {
    throw const BtSiteProbeException(BtSiteProbeError.timedOut);
  } on Object {
    throw const BtSiteProbeException(BtSiteProbeError.ruleRequestFailed);
  }
  if (rows == 0) {
    throw const BtSiteProbeException(BtSiteProbeError.ruleMatchedNothing);
  }
  return BtSiteProbeResult(
    format: BtSiteFormat.custom,
    baseUrl: origin,
    parser: parser,
  );
}

Future<BtSiteProbeResult> _probeOne(
  BtSiteFormat format,
  Uri baseUrl, {
  required http.Client client,
  required Duration timeout,
}) async {
  final _BorrowedClient borrowed = _BorrowedClient(client);
  switch (format) {
    case BtSiteFormat.nyaa:
      final NyaaSiteProbe probe = await NyaaClient(
        baseUrl: baseUrl.toString(),
        client: borrowed,
        requestTimeout: timeout,
        // 一个新地址只打一次请求，不进同 host 节流队列（否则同一站点已有搜索在
        // 排队时，探测要白等）。
        minRequestInterval: Duration.zero,
      ).probeSite(kBtSiteProbeQuery);
      return BtSiteProbeResult(
        format: format,
        baseUrl: baseUrl,
        nyaaCategories: mapNyaaCategoriesToDomains(probe.categories),
      );
    case BtSiteFormat.apibay:
      await ApibayClient(
        baseUrl: baseUrl.toString(),
        client: borrowed,
        requestTimeout: timeout,
      ).verifyEndpoint(kBtSiteProbeQuery);
      return BtSiteProbeResult(format: format, baseUrl: baseUrl);
    case BtSiteFormat.knaben:
      await KnabenClient(
        baseUrl: baseUrl.toString(),
        client: borrowed,
        requestTimeout: timeout,
      ).verifyEndpoint(kBtSiteProbeQuery);
      return BtSiteProbeResult(format: format, baseUrl: baseUrl);
    case BtSiteFormat.custom:
      throw StateError('custom BT sites are verified with a parser rule');
  }
}

/// 借用调用方的 client：适配器 close 时不真关。
class _BorrowedClient extends http.BaseClient {
  _BorrowedClient(this._inner);

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() {}
}
