part of 'update_checker.dart';

/// GitHub 直连不通时（GFW 机器，且 app 运行时**不走**本机命令行代理）套在 GitHub
/// 链接前的加速代理前缀。逐个尝试（见 [fetchFirstSuccessfulBody]），任一成功即返回，
/// 全部失败才优雅放弃。这些公共镜像会不定期轮换/下线（`mirror.ghproxy.com` 已下线
/// 移除），具体哪个通取决于用户机器与时段，故多备几个（BUG-277：单点不可达不该让
/// 整轮检查失败）。
///
/// **重要结构性事实（BUG-292，2026-06-15 实测）**：这些公共 gh 代理**只代理
/// `raw.githubusercontent.com` / release 资源「下载」**，对 `api.github.com` JSON
/// API 一律 HTTP 403（GitHub 对镜像共享出口 IP 的未授权限流，403 头里带
/// `x-ratelimit-remaining: 0`）或直接 TLS 失败。所以更新「**检查**」（命中
/// `api.github.com`，见 [_fetchReleasesForChannel]）经**任何**镜像都不可能成功——
/// 检查阶段唯一能成功的是**直连**（[updateCheckUrls] 把直连放首位正是为此）；镜像
/// 列表只对「**下载**」阶段（[_downloadAndInstall]，命中
/// `github.com/.../releases/download/...`）真正有用，实测 ghfast.top / ghproxy.net
/// 可返回 206 分片。**勿误以为「换/加 API 镜像」能修检查不通**：纯 GFW（直连 API 被
/// 切断）环境下检查注定失败，需用户开代理/VPN 或自建 API 反代。
///
/// 与 `video_shader_downloader.dart` 的 `_kGhProxyPrefixes`（BUG-319/271）同一范式——
/// 那个只下载 raw 资源、不命中 API，故不受本限制影响。
@visibleForTesting
const List<String> updateCheckProxyPrefixes = <String>[
  'https://ghfast.top/',
  'https://gh-proxy.com/',
  'https://ghproxy.net/',
  'https://ghproxy.cc/',
  'https://gh.llkk.cc/',
  'https://ghproxy.homeboyc.cn/',
];

/// **纯函数**：为一个 GitHub API / 直链 [url] 生成按优先级排序的候选 URL 列表。
///
/// 顺序：① 直连 [url] 本身（有 VPN / 系统代理时最快、最权威）→ ② 每个
/// [updateCheckProxyPrefixes] 套在直连前（GFW 兜底）。逐个尝试，任一成功即整体成功
/// （见 [fetchFirstSuccessfulBody]）。直连只出现一次、候选无重复。
@visibleForTesting
List<String> updateCheckUrls(String url) {
  return <String>[
    url,
    for (final String prefix in updateCheckProxyPrefixes) '$prefix$url',
  ];
}

/// **可注入核心**：按顺序对 [urls] 逐个调用 [fetch]，返回**第一个成功**（非 null）的
/// 响应体；全部失败才返回 null。这是更新检查可达性的真正逻辑（BUG-277 把它从原
/// `_httpGetString` 的真实网络 IO 里抽出来，使「首镜像失败自动试下一个 / 任一成功即
/// 成功 / 全失败才失败 / 日志记录正确」可被单测固定）。
///
/// - [fetch] 返回非 null → 视为成功，立即返回，不再试后续候选。
/// - [fetch] 返回 null 或抛异常 → 视为该候选失败，记 [onFailure]（主机标签 +
///   错误对象，异常时非 null）并继续下一个。异常**不冒泡**终止回退。
/// - 全部候选耗尽仍无成功 → 返回 null（由调用方决定如何提示「全失败」）。
@visibleForTesting
Future<String?> fetchFirstSuccessfulBody(
  List<String> urls, {
  required Future<String?> Function(String url) fetch,
  void Function(String host, Object? error)? onFailure,
}) async {
  for (final String url in urls) {
    try {
      final String? body = await fetch(url);
      if (body != null) return body;
      onFailure?.call(hostLabelForUpdateUrl(url), null);
    } catch (e) {
      onFailure?.call(hostLabelForUpdateUrl(url), e);
    }
  }
  return null;
}

/// **根因修复（TODO-384 第二轮）**：让更新检查/下载用的 [HttpClient] 走用户机器上
/// 正在运行的系统/环境代理。
///
/// 背景：BUG-292 已查明纯 GFW（直连 `api.github.com` 被切、公共 gh 代理又不代理 API）
/// 环境下检查注定失败，唯一出路是「经用户自己的代理出口直连 API」。但**裸 `HttpClient()`
/// 默认不设 `findProxy`，连环境变量代理都不读**，所以即便用户开着 clash/v2ray，更新请求
/// 仍走直连被切——这是真正可修的结构性缺口。
///
/// Dart 的 `HttpClient.findProxyFromEnvironment` **只读环境变量**（`HTTPS_PROXY` /
/// `HTTP_PROXY` / `NO_PROXY`，大小写均认），**不读 Windows 注册表 / macOS 系统代理设置**
/// （已实测 + 官方文档确认）。因此：
///   * 所有平台：合并 `Platform.environment`，覆盖「代理 app 导出了 env 变量」「Linux/macOS
///     GUI 代理写了 env」「用户手动 `set HTTPS_PROXY` 后启动」等场景。
///   * Windows：clash/v2ray 的「系统代理」模式只写注册表
///     `HKCU\...\Internet Settings\ProxyServer`，env 变量为空 → 额外读注册表并把它注入
///     environment map（见 [resolveWindowsSystemProxyEnvironment]），让同一个
///     `findProxyFromEnvironment` 能用上。
///
/// 没有任何代理（env 空 + Windows 注册表未启用/读取失败）时，`findProxyFromEnvironment`
/// 自然返回 `DIRECT`，等价于原「裸 HttpClient 直连」行为——**不破坏现有逐镜像回退**。
Future<void> applyUpdateProxy(HttpClient client) async {
  final Map<String, String> environment = <String, String>{
    ...Platform.environment,
  };
  if (Platform.isWindows) {
    // env 变量优先：用户显式 set 的不该被注册表覆盖。仅当 env 没给代理时才补注册表。
    final bool hasEnvProxy = environment.keys.any((String k) {
      final String lower = k.toLowerCase();
      return lower == 'https_proxy' || lower == 'http_proxy';
    });
    if (!hasEnvProxy) {
      final Map<String, String> registryProxy =
          await resolveWindowsSystemProxyEnvironment();
      environment.addAll(registryProxy);
    }
  }
  client.findProxy = (Uri uri) =>
      HttpClient.findProxyFromEnvironment(uri, environment: environment);
}

/// 读取 Windows「系统代理」设置（clash/v2ray 系统代理模式写在这里），返回可喂给
/// [HttpClient.findProxyFromEnvironment] 的 environment 片段（`{'https_proxy': ...,
/// 'http_proxy': ...}`）；未启用 / 读取失败 / 非 Windows 返回空 map（= 不补代理）。
///
/// 走 `reg query`（异步、无需 FFI、无新依赖），在构建 client 前一次性解析；解析逻辑下沉到
/// 纯函数 [parseWindowsRegistryProxy] 以便单测。
Future<Map<String, String>> resolveWindowsSystemProxyEnvironment() async {
  if (!Platform.isWindows) return const <String, String>{};
  try {
    const String key =
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
    final ProcessResult enableResult = await Process.run(
      'reg',
      <String>['query', key, '/v', 'ProxyEnable'],
    );
    final ProcessResult serverResult = await Process.run(
      'reg',
      <String>['query', key, '/v', 'ProxyServer'],
    );
    return parseWindowsRegistryProxy(
      proxyEnableOutput:
          enableResult.stdout is String ? enableResult.stdout as String : '',
      proxyServerOutput:
          serverResult.stdout is String ? serverResult.stdout as String : '',
    );
  } catch (e) {
    // 读不到注册表（权限/环境异常）就当没有系统代理，回退直连——best-effort。
    debugPrint('[UpdateChecker] read windows system proxy failed: $e');
    return const <String, String>{};
  }
}

/// **纯函数**：解析 `reg query ... /v ProxyEnable|ProxyServer` 的原始输出，生成
/// `findProxyFromEnvironment` 用的 environment 片段。
///
/// - `ProxyEnable` 必须为 `0x1`（启用）才返回代理；`0x0`/缺失 → 空 map（系统代理关着）。
/// - `ProxyServer` 形如 `127.0.0.1:7890`（全局）或
///   `http=127.0.0.1:7890;https=127.0.0.1:7890;...`（分协议）。两种都解析：分协议时取
///   `https=`（优先）/`http=` 段；全局时直接用整串。
/// - 输出畸形 / 无 ProxyServer → 空 map。
///
/// `reg query` 单行格式：`    ProxyServer    REG_SZ    127.0.0.1:7890`（前导空白 + 三段，
/// 以连续空白分隔；值本身可能含 `=`/`;`/`:` 但不含空白，故按「类型标记 REG_* 之后」取值）。
@visibleForTesting
Map<String, String> parseWindowsRegistryProxy({
  required String proxyEnableOutput,
  required String proxyServerOutput,
}) {
  final String? enableValue =
      _registryValueAfterType(proxyEnableOutput, 'ProxyEnable');
  // ProxyEnable 是 REG_DWORD，值形如 `0x1`/`0x0`。非 0x1 视为未启用。
  if (enableValue == null || enableValue.toLowerCase() != '0x1') {
    return const <String, String>{};
  }
  final String? serverValue =
      _registryValueAfterType(proxyServerOutput, 'ProxyServer');
  if (serverValue == null || serverValue.isEmpty) {
    return const <String, String>{};
  }

  final String? https = _proxyForScheme(serverValue, 'https');
  final String? http =
      _proxyForScheme(serverValue, 'http') ?? _globalProxy(serverValue);
  final Map<String, String> result = <String, String>{};
  // findProxyFromEnvironment 对 https URL 读 https_proxy、回退 http_proxy；两者都填最稳。
  final String? effectiveHttps = https ?? http;
  if (effectiveHttps != null && effectiveHttps.isNotEmpty) {
    result['https_proxy'] = effectiveHttps;
  }
  final String? effectiveHttp = http ?? https;
  if (effectiveHttp != null && effectiveHttp.isNotEmpty) {
    result['http_proxy'] = effectiveHttp;
  }
  return result;
}

/// 从单条 `reg query` 输出里取出指定值名后、`REG_<TYPE>` 标记之后的那段值。
/// 匹配行必须含 `valueName`，再按空白切出最后一段作为值。无匹配返回 null。
String? _registryValueAfterType(String output, String valueName) {
  for (final String rawLine in const LineSplitter().convert(output)) {
    final String line = rawLine.trim();
    if (!line.startsWith(valueName)) continue;
    final RegExpMatch? m =
        RegExp(r'^' + valueName + r'\s+REG_\w+\s+(.+)$').firstMatch(line);
    if (m != null) return m.group(1)!.trim();
  }
  return null;
}

/// 从分协议代理串（`http=h:p;https=h:p`）里取指定 scheme 的 `host:port`；全局串
/// （不含 `=`）返回 null。
String? _proxyForScheme(String proxyServer, String scheme) {
  if (!proxyServer.contains('=')) return null;
  for (final String part in proxyServer.split(';')) {
    final int eq = part.indexOf('=');
    if (eq < 0) continue;
    if (part.substring(0, eq).trim().toLowerCase() == scheme) {
      return part.substring(eq + 1).trim();
    }
  }
  return null;
}

/// 全局代理串（不含 `=`，形如 `127.0.0.1:7890`）原样返回；分协议串返回 null。
String? _globalProxy(String proxyServer) =>
    proxyServer.contains('=') ? null : proxyServer.trim();

/// 更新检查与下载都是 best-effort。网络类失败——连不上、连接超时、TLS 握手
/// 失败、底层 HTTP 协议错误、单候选整体超时（[_kPerAttemptTimeout]）——是预期现象
/// （尤其 GFW 下访问 GitHub / 代理本就不稳），不该当错误带完整堆栈塞进用户可见的
/// 错误日志，否则真正的 bug 信号会被这类噪音淹没。返回 true 表示该异常只需
/// debugPrint / i18n 摘要，无需写完整堆栈到 ErrorLogService。
bool isExpectedUpdateNetworkFailure(Object e) =>
    e is SocketException ||
    e is HandshakeException ||
    e is HttpException ||
    e is TimeoutException;

/// **纯函数**：把一次更新网络失败的异常翻译成「为什么连不上」的可读原因，供用户
/// 错误日志使用（TODO-371）。原来无论真实异常是 DNS 解析失败、连接被拒、还是真超时，
/// 日志都死板地写「网络超时或不可达」，把瞬时失败也误报成超时、且吞掉了 errno 等
/// 关键线索。这里区分常见底层原因并尽量带上 `SocketException.osError`（errno +
/// 系统 message），让用户一眼看出是 DNS 不通、被拒、超时还是证书问题。
///
/// - [error] 为 null（HTTP 状态非 200、无异常的失败回退）→「服务器无有效响应」。
/// - `SocketException`：按 message / osError 细分 DNS 失败 / 连接被拒 / 超时 / 一般
///   连接失败，并附上 `(errno=…: …)`。
/// - `TimeoutException`：单候选整体超时。
/// - `HandshakeException`：TLS/SSL 握手失败。
/// - `HttpException`：底层 HTTP 协议错误。
/// - 其它：回退到该异常的 `toString()`，不再谎称超时。
String describeUpdateNetworkFailureReason(Object? error) {
  if (error == null) {
    return 'no valid response from server';
  }
  if (error is SocketException) {
    final OSError? os = error.osError;
    final String osPart =
        os != null ? ' (errno=${os.errorCode}: ${os.message})' : '';
    final String message = error.message;
    final String lower = message.toLowerCase();
    final String category;
    if (lower.contains('failed host lookup') ||
        lower.contains('nodename nor servname') ||
        lower.contains('name or service not known')) {
      category = 'DNS lookup failed';
    } else if (lower.contains('connection refused')) {
      category = 'connection refused';
    } else if (lower.contains('timed out') || lower.contains('timeout')) {
      category = 'connection timed out';
    } else {
      category = message.isNotEmpty ? message : 'connection failed';
    }
    return '$category$osPart';
  }
  if (error is TimeoutException) {
    return 'connection timed out';
  }
  if (error is HandshakeException) {
    final String message = error.message;
    return message.isNotEmpty
        ? 'TLS handshake failed: $message'
        : 'TLS handshake failed';
  }
  if (error is HttpException) {
    final String message = error.message;
    return message.isNotEmpty
        ? 'HTTP protocol error: $message'
        : 'HTTP protocol error';
  }
  return error.toString();
}

/// 从更新请求 URL 取主机名，作为日志里「连不上哪个源」的可读标签。代理 URL
/// 形如 `https://ghfast.top/https://api.github.com/...`，其 host 是代理本身
/// （ghfast.top），正好对应真正发起连接、真正超时的那一跳。URL 畸形时回退到原串。
String hostLabelForUpdateUrl(String url) {
  try {
    final String host = Uri.parse(url).host;
    return host.isNotEmpty ? host : url;
  } catch (_) {
    return url;
  }
}
