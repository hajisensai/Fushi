import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:hibiki/src/utils/misc/platform_updater.dart';
import 'package:hibiki/utils.dart';

const String _kGitHubRepo = 'hdjsadgfwtg/hibiki';

/// 单个候选 URL 的尝试超时。`HttpClient.connectionTimeout` 只管「建立 TCP 连接」
/// 那一跳；某个镜像 TCP 连上却挂起不返回时，需要这个整体超时把它判死、回退到下一个，
/// 否则一个坏镜像就能拖垮整轮检查（BUG-277）。
const Duration _kPerAttemptTimeout = Duration(seconds: 15);

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

final RegExp _kBetaReleaseTagPattern = RegExp(r'^v\d+(?:\.\d+)*-beta\.\d+$');
final RegExp _kDebugReleaseTagPattern =
    RegExp(r'^v\d+(?:\.\d+)*-debug\.\d+\+[0-9A-Fa-f]{7,40}$');
final RegExp _kBetaVersionPattern = RegExp(r'^\d+(?:\.\d+)*-beta\.\d+$');
final RegExp _kDebugVersionPattern = RegExp(r'^\d+(?:\.\d+)*-debug\.\d+$');

@visibleForTesting
class UpdateReleaseSelection {
  const UpdateReleaseSelection({
    required this.release,
    required this.version,
    required this.releaseNotes,
    required this.downloadUrl,
  });

  final Map<String, dynamic> release;
  final String version;
  final String releaseNotes;
  final String? downloadUrl;

  String? get htmlUrl => release['html_url'] as String?;
}

class UpdateChecker {
  UpdateChecker._();

  static void scheduleCheck(
    BuildContext context,
    String currentVersion, {
    bool neverRemind = false,
    bool autoInstall = false,
    bool betaChannel = false,
    bool debugChannel = false,
  }) {
    final UpdateChannel channel = debugChannel
        ? UpdateChannel.debug
        : betaChannel
            ? UpdateChannel.beta
            : UpdateChannel.stable;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _check(context, currentVersion,
          neverRemind: neverRemind, autoInstall: autoInstall, channel: channel);
    });
  }

  static Future<void> _cleanupOldApks(String currentVersion) async {
    try {
      final cacheDir = await getTemporaryDirectory();
      const prefix = 'hibiki-';
      for (final f in cacheDir.listSync()) {
        if (f is! File) continue;
        final String name = f.uri.pathSegments.last;
        if (!name.startsWith(prefix)) continue;
        const List<String> exts = <String>['.apk', '.exe', '.AppImage', '.zip'];
        final String ext =
            exts.firstWhere((String e) => name.endsWith(e), orElse: () => '');
        if (ext.isEmpty) continue;
        final String fileVersion =
            name.substring(prefix.length, name.length - ext.length);
        if (!_isNewer(fileVersion, currentVersion)) {
          try {
            f.deleteSync();
          } catch (e) {
            debugPrint('[UpdateChecker] cleanup delete failed: $e');
          }
        }
      }
    } catch (e) {
      debugPrint('[UpdateChecker] cleanup scan failed: $e');
    }
  }

  static Future<void> _check(
    BuildContext context,
    String currentVersion, {
    bool neverRemind = false,
    bool autoInstall = false,
    UpdateChannel channel = UpdateChannel.stable,
  }) async {
    final PlatformUpdater updater = updaterForCurrentPlatform();
    if (!updater.supportsUpdateCheck) return;
    final bool canInstall = updater.supportsInAppInstall;
    // 不能自装的平台忽略 autoInstall（无意义），但仍可「检查→打开发布页」。
    if (neverRemind && !(canInstall && autoInstall)) return;
    HttpClient? client;
    try {
      await _cleanupOldApks(currentVersion);
      client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 30);
      // 走系统/环境代理：用户开着 clash/v2ray 时检查请求经其出口直连 api.github.com
      // （纯 GFW 下唯一可成功路径，BUG-292）。无代理则等价直连，不破坏镜像回退。
      await applyUpdateProxy(client);

      final List<Map<String, dynamic>> releases =
          await _fetchReleasesForChannel(client, channel);
      final UpdateReleaseSelection? selection =
          await selectUpdateReleaseForCurrentPlatform(
        releases,
        currentVersion: currentVersion,
        channel: channel,
        updater: updater,
      );
      if (selection == null) return;
      final Map<String, dynamic> json = selection.release;

      final String? tagName =
          normalizeReleaseVersionTag(json['tag_name'] as String? ?? '');
      if (tagName == null || tagName.isEmpty) {
        return;
      }

      if (!isUpdateVersionNewer(tagName, currentVersion, channel)) {
        return;
      }

      final releaseBody = json['body'] as String? ?? '';

      final assets = json['assets'] as List<dynamic>? ?? [];
      final List<Map<String, dynamic>> assetMaps =
          assets.whereType<Map<String, dynamic>>().toList(growable: false);
      final String? downloadUrl =
          await updater.selectAsset(assetMaps, channel: channel);

      // 无适配本平台的 asset（iOS / 未实现桌面 / 该 release 没传本平台包）→ 打开发布页。
      if (downloadUrl == null) {
        final String? htmlUrl = json['html_url'] as String?;
        if (htmlUrl != null && context.mounted) {
          _showFallbackDialog(context, tagName, releaseBody, htmlUrl);
        }
        return;
      }
      if (!context.mounted) return;
      if (canInstall && autoInstall) {
        _downloadAndInstall(context, downloadUrl, tagName, updater);
      } else if (canInstall) {
        _showUpdateDialog(context, tagName, releaseBody, downloadUrl, updater);
      } else {
        // 能检查但不能自装（本期 iOS/mac/Linux）：弹「前往下载」打开发布页。
        final String? htmlUrl = json['html_url'] as String?;
        if (htmlUrl != null) {
          _showFallbackDialog(context, tagName, releaseBody, htmlUrl);
        }
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('UpdateChecker.check', e, stack);
      debugPrint('[Hibiki] update check failed: $e');
    } finally {
      client?.close();
    }
  }

  /// 多镜像回退的更新检查请求（BUG-277）。生成「直连 + 各 gh 代理前缀」候选列表
  /// （[updateCheckUrls]），交给可注入核心 [fetchFirstSuccessfulBody] 逐个尝试：任一
  /// 返回 HTTP 200 即整体成功，单点不可达/超时自动回退下一个，全失败才返回 null。
  /// 每个候选带 [_kPerAttemptTimeout] 整体超时，避免坏镜像拖垮整轮检查。
  static Future<String?> _httpGetString(
    HttpClient client,
    String url, {
    Map<String, String> headers = const {},
  }) {
    return fetchFirstSuccessfulBody(
      updateCheckUrls(url),
      fetch: (String u) => _fetchOne(client, u, headers),
      onFailure: (String host, Object? error) {
        // 网络类失败（连不上/超时/TLS 握手）记一条可读的 i18n 摘要、不带堆栈，
        // 让用户在日志里看到「连不上哪个源」而不被原始堆栈噪音淹没；其它异常
        // （解析/逻辑错误）才是真问题，连堆栈一起记。
        if (error == null || isExpectedUpdateNetworkFailure(error)) {
          ErrorLogService.instance.log(
              'UpdateChecker.httpGet',
              t.update_network_failure(
                host: host,
                reason: describeUpdateNetworkFailureReason(error),
              ));
        } else {
          ErrorLogService.instance.log('UpdateChecker.httpGet', error);
        }
        debugPrint('[Hibiki] update check failed ($host): $error');
      },
    );
  }

  /// 单个候选 URL 的一次抓取：HTTP 200 返回响应体，否则返回 null（让回退继续）。
  /// 带 [_kPerAttemptTimeout] 整体超时——TCP 连上却挂起的镜像会被判死并回退。
  static Future<String?> _fetchOne(
    HttpClient client,
    String url,
    Map<String, String> headers,
  ) async {
    Future<String?> attempt() async {
      final HttpClientRequest request = await client.getUrl(Uri.parse(url));
      for (final MapEntry<String, String> e in headers.entries) {
        request.headers.set(e.key, e.value);
      }
      final HttpClientResponse response = await request.close();
      if (response.statusCode == 200) {
        return response.transform(utf8.decoder).join();
      }
      await response.drain<void>();
      return null;
    }

    return attempt().timeout(_kPerAttemptTimeout);
  }

  static Future<List<Map<String, dynamic>>> _fetchReleasesForChannel(
    HttpClient client,
    UpdateChannel channel,
  ) async {
    if (channel == UpdateChannel.stable) {
      final Map<String, dynamic>? release = await _fetchStableRelease(client);
      return release == null
          ? const <Map<String, dynamic>>[]
          : <Map<String, dynamic>>[release];
    }

    final body = await _httpGetString(
      client,
      'https://api.github.com/repos/$_kGitHubRepo/releases?per_page=20',
      headers: {'Accept': 'application/vnd.github+json'},
    );
    if (body == null) return const <Map<String, dynamic>>[];
    final list = jsonDecode(body) as List<dynamic>;
    return list
        .whereType<Map<String, dynamic>>()
        .where((Map<String, dynamic> release) {
      return releaseMatchesUpdateChannel(release, channel);
    }).toList(growable: false);
  }

  /// stable 通道检查（TODO-404 根因修复）：**优先**走 `github.com/.../releases/latest`
  /// 的 302 网页跳转拿最新 tag（公共 gh 代理可透传，纯 GFW 无代理也能成功），据 tag +
  /// 命名规则重建一个与 API 同构的 release map（[buildStableReleaseFromTag]）；**回退**到
  /// 原 `api.github.com` 直连（有 VPN/系统代理时更权威、还带真实 assets/release notes）。
  ///
  /// 两条路返回值结构一致，对上层 [_fetchReleasesForChannel] /
  /// [selectUpdateReleaseForCurrentPlatform] 完全透明——纯叠加，不破坏既有行为。
  static Future<Map<String, dynamic>?> _fetchStableRelease(
      HttpClient client) async {
    final String? tag = await _fetchStableTagViaRedirect(client);
    if (tag != null) {
      final Map<String, dynamic> release = buildStableReleaseFromTag(tag);
      if (releaseMatchesUpdateChannel(release, UpdateChannel.stable)) {
        return release;
      }
    }
    return _fetchStableReleaseViaApi(client);
  }

  /// 原 `api.github.com/.../releases/latest` 直连路径（保留作 302 失败后的回退）。
  static Future<Map<String, dynamic>?> _fetchStableReleaseViaApi(
      HttpClient client) async {
    final body = await _httpGetString(
      client,
      'https://api.github.com/repos/$_kGitHubRepo/releases/latest',
      headers: {'Accept': 'application/vnd.github+json'},
    );
    if (body == null) return null;
    final Map<String, dynamic> release =
        jsonDecode(body) as Map<String, dynamic>;
    if (!releaseMatchesUpdateChannel(release, UpdateChannel.stable)) {
      return null;
    }
    return release;
  }

  /// 逐候选（[updateCheckUrls]：直连优先 + 各 gh 代理前缀兜底）请求
  /// `releases/latest`，**关重定向跟随**读 3xx 的 `Location` 头，解析出 stable
  /// 最新 tag；任一候选拿到合法 tag 即整体成功，全失败返 null（TODO-404）。
  ///
  /// 复用 [fetchFirstSuccessfulBody] 保持「直连恒首位 / 逐镜像回退 / 任一成功即成功 /
  /// 全失败才失败 / 失败记日志」不变式（与 [_httpGetString] 同一范式）。
  static Future<String?> _fetchStableTagViaRedirect(HttpClient client) {
    return fetchFirstSuccessfulBody(
      updateCheckUrls(kStableReleasesLatestUrl),
      fetch: (String u) => _fetchRedirectTagOne(client, u),
      onFailure: (String host, Object? error) {
        if (error == null || isExpectedUpdateNetworkFailure(error)) {
          ErrorLogService.instance.log(
              'UpdateChecker.redirectTag',
              t.update_network_failure(
                host: host,
                reason: describeUpdateNetworkFailureReason(error),
              ));
        } else {
          ErrorLogService.instance.log('UpdateChecker.redirectTag', error);
        }
        debugPrint('[Hibiki] update redirect-tag failed ($host): $error');
      },
    );
  }

  /// 单个候选 URL 的「读 302 → 解析 tag」一次尝试：关闭重定向跟随，3xx 且
  /// `Location` 头能解析出合法 tag 才返回该 tag（非 null = 成功），否则返 null（让回退
  /// 继续）。带 [_kPerAttemptTimeout] 整体超时——TCP 连上却挂起的镜像会被判死并回退。
  static Future<String?> _fetchRedirectTagOne(
    HttpClient client,
    String url,
  ) async {
    Future<String?> attempt() async {
      final HttpClientRequest request = await client.getUrl(Uri.parse(url));
      // 关重定向跟随：我们要的是 302 本身的 Location，而非跟到目标网页拿一坨 HTML。
      request.followRedirects = false;
      final HttpClientResponse response = await request.close();
      final int code = response.statusCode;
      final String? location =
          response.headers.value(HttpHeaders.locationHeader);
      await response.drain<void>();
      if (code >= 300 && code < 400) {
        return parseLatestTagFromRedirectLocation(location);
      }
      return null;
    }

    return attempt().timeout(_kPerAttemptTimeout);
  }

  static bool _isNewer(String remote, String local) =>
      isVersionNewer(remote, local);

  static void _showUpdateDialog(
    BuildContext context,
    String version,
    String releaseNotes,
    String downloadUrl,
    PlatformUpdater updater,
  ) {
    showAppDialog<void>(
      context: context,
      builder: (ctx) => UpdateAvailableDialog(
        version: version,
        releaseNotes: releaseNotes,
        primaryLabel: t.update_download,
        onPrimary: () {
          Navigator.of(ctx).pop();
          _downloadAndInstall(context, downloadUrl, version, updater);
        },
      ),
    );
  }

  /// Fallback dialog for when no APK asset exists — opens browser.
  static void _showFallbackDialog(
    BuildContext context,
    String version,
    String releaseNotes,
    String htmlUrl,
  ) {
    showAppDialog<void>(
      context: context,
      builder: (ctx) => UpdateAvailableDialog(
        version: version,
        releaseNotes: releaseNotes,
        primaryLabel: t.update_download,
        onPrimary: () {
          Navigator.of(ctx).pop();
          launchUrl(
            Uri.parse(htmlUrl),
            mode: LaunchMode.externalApplication,
          );
        },
      ),
    );
  }

  static Future<void> _downloadAndInstall(
    BuildContext context,
    String url,
    String version,
    PlatformUpdater updater,
  ) async {
    final progress = ValueNotifier<double>(0);
    final status = ValueNotifier<String>(t.update_downloading);
    final overlayVisible = ValueNotifier<bool>(true);
    late final OverlayEntry overlay;
    overlay = OverlayEntry(
      builder: (ctx) => ValueListenableBuilder<bool>(
        valueListenable: overlayVisible,
        builder: (_, visible, __) {
          if (!visible) return const SizedBox.shrink();
          return _DownloadOverlay(
            progress: progress,
            status: status,
            onHide: () => overlayVisible.value = false,
          );
        },
      ),
    );

    final overlayState = Overlay.of(context);
    overlayState.insert(overlay);

    HttpClient? client;
    try {
      final cacheDir = await getTemporaryDirectory();
      final String ext = _extOf(url);
      final File outFile = File('${cacheDir.path}/hibiki-$version$ext');

      client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 30);
      client.idleTimeout = const Duration(seconds: 60);
      // 下载同样走系统/环境代理（与检查一致）：直连/镜像不通时经用户代理出口下载。
      await applyUpdateProxy(client);

      // 下载与检查共用同一组 GitHub 镜像候选（updateCheckUrls）：直连优先、各 gh
      // 代理前缀兜底。下载的写盘/安装逻辑不变，只是镜像清单与检查保持同步（BUG-277）。
      final List<String> urls = updateCheckUrls(url);
      var downloaded = false;
      for (final u in urls) {
        try {
          progress.value = 0;
          final request = await client.getUrl(Uri.parse(u));
          request.headers.set('User-Agent', 'Hibiki/$version');
          final response = await request.close();
          if (response.statusCode == 200) {
            await _writeResponse(response, outFile, progress);
            downloaded = true;
            break;
          }
          await response.drain<void>();
        } catch (e, stack) {
          // 逐个下载源回退：网络类失败记 i18n 摘要、不带堆栈；其它异常带堆栈。
          // 全部源失败时下面的 throw 仍会被外层 catch 统一记一条并弹 SnackBar。
          if (isExpectedUpdateNetworkFailure(e)) {
            ErrorLogService.instance.log(
                'UpdateChecker.download',
                t.update_network_failure(
                  host: hostLabelForUpdateUrl(u),
                  reason: describeUpdateNetworkFailureReason(e),
                ));
          } else {
            ErrorLogService.instance.log('UpdateChecker.download', e, stack);
          }
          debugPrint('[Hibiki] download source failed ($u): $e');
        }
      }
      if (!downloaded) {
        throw Exception('All download sources failed');
      }

      status.value = t.update_installing;

      await updater.apply(outFile, version);
    } catch (e, stack) {
      ErrorLogService.instance
          .log('UpdateChecker.downloadAndInstall', e, stack);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${t.update_download_failed}: $e')),
        );
      }
    } finally {
      client?.close();
      overlay.remove();
      progress.dispose();
      status.dispose();
      overlayVisible.dispose();
    }
  }

  static Future<void> _writeResponse(
    HttpClientResponse response,
    File file,
    ValueNotifier<double> progress,
  ) async {
    final contentLength = response.contentLength;
    int received = 0;
    final sink = file.openWrite();

    await for (final chunk in response) {
      sink.add(chunk);
      received += chunk.length;
      if (contentLength > 0) {
        progress.value = received / contentLength;
      }
    }

    await sink.flush();
    await sink.close();
  }
}

String _extOf(String url) {
  final String path = Uri.parse(url).path;
  final int slash = path.lastIndexOf('/');
  final String name = slash >= 0 ? path.substring(slash + 1) : path;
  final int dot = name.lastIndexOf('.');
  return dot >= 0 ? name.substring(dot) : '';
}

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

/// stable 通道 release 列表页「最新版」入口。GitHub 对它返回 302 → 真实
/// `.../releases/tag/<tag>` 网页（**不是** API），公共 gh 代理会原样透传这个 302
/// （实测 ghfast.top 返回 302），所以纯 GFW 无代理用户也能从 `Location` 头解析出最新 tag
/// （TODO-404 / BUG-292）。与 `_fetchReleasesForChannel` 打的 `api.github.com` 形成
/// 对比：那个被镜像 403、检查注定失败。
const String kStableReleasesLatestUrl =
    'https://github.com/$_kGitHubRepo/releases/latest';

/// release 资产下载基址（`releases/download/<tag>/<name>` 拼在其后）。下载阶段经
/// [updateCheckUrls] 套镜像前缀；这些「下载」路径镜像真正可用（BUG-292）。
const String _kReleaseDownloadBase =
    'https://github.com/$_kGitHubRepo/releases/download';

/// **纯函数**：从 `releases/latest` 的 302 `Location` 头解析最新 tag。
///
/// [location] 形如 `https://github.com/owner/repo/releases/tag/v0.4.1`，也可能被镜像
/// 改写成 `https://ghfast.top/https://github.com/.../releases/tag/v0.4.1`、相对路径
/// `/owner/repo/releases/tag/v0.4.1`、或带 `?`/`#` 查询片段。安全做法：**只认
/// `releases/tag/<tag>` 这一段、丢弃域名**（防镜像把域名改写成钓鱼站后我们误信），用
/// `normalizeReleaseVersionTag` 归一化校验（非版本串返 null）。无 `releases/tag/` 段、
/// tag 段非合法版本、或入参为空 → 返 null（调用方回退 API 直连）。
@visibleForTesting
String? parseLatestTagFromRedirectLocation(String? location) {
  if (location == null) return null;
  final RegExpMatch? match =
      RegExp(r'releases/tag/(v?[^/?#]+)').firstMatch(location);
  if (match == null) return null;
  final String rawTag = Uri.decodeComponent(match.group(1)!);
  final String? normalized = normalizeReleaseVersionTag(rawTag);
  if (normalized == null || normalized.isEmpty) return null;
  // 把原始 tag 串保留下来交给下游（download URL 用原始 tag 段，含可能的前导 v），
  // 但调用方拿到这里的 [normalized] 仅用于「是否更新」判断；tag 段单独由
  // [buildStableReleaseFromTag] 处理。返回原始 tag 段（trim 后）以便拼下载 URL。
  return rawTag.trim();
}

/// **纯函数**：把 302 解析出的 stable [tag] 重建成与 GitHub API release 同构的 map，
/// 让它能直接喂给现有 [selectUpdateReleaseForCurrentPlatform] / `selectAsset` 整条链路，
/// 不在更新流程里另搞一套特例分支（TODO-404）。
///
/// 302 网页跳转拿不到 API 的 `assets` 清单与 `body`（release notes），故：
/// * `prerelease: false`、`draft: false`、`tag_name: <tag>` —— 让 stable 通道匹配通过。
/// * `assets`：用 [synthesizeStableAssetNames] 按命名规则重建（Android 全 ABI + Windows
///   setup），`browser_download_url` 拼 `releases/download/<tag>/<name>`，由 `selectAsset`
///   按平台/设备 ABI 自行挑。
/// * `body: ''`、`html_url`：notes 缺失时上层自然退化到「打开发布页」对话框。
@visibleForTesting
Map<String, dynamic> buildStableReleaseFromTag(String tag) {
  final String trimmedTag = tag.trim();
  final String version = normalizeReleaseVersionTag(trimmedTag) ?? '';
  final List<Map<String, dynamic>> assets = <Map<String, dynamic>>[
    for (final String name in synthesizeStableAssetNames(version))
      <String, dynamic>{
        'name': name,
        'browser_download_url': '$_kReleaseDownloadBase/$trimmedTag/$name',
      },
  ];
  return <String, dynamic>{
    'tag_name': trimmedTag,
    'prerelease': false,
    'draft': false,
    'body': '',
    'html_url': '$_kStableReleasesHtmlUrl/tag/$trimmedTag',
    'assets': assets,
  };
}

/// stable release 网页基址（`tag/<tag>` 拼其后，作为 fallback「打开发布页」目标）。
const String _kStableReleasesHtmlUrl =
    'https://github.com/$_kGitHubRepo/releases';

@visibleForTesting
Future<UpdateReleaseSelection?> selectUpdateReleaseForCurrentPlatform(
  List<Map<String, dynamic>> releases, {
  required String currentVersion,
  required UpdateChannel channel,
  required PlatformUpdater updater,
}) async {
  UpdateReleaseSelection? fallback;
  for (final Map<String, dynamic> release in releases) {
    if (!releaseMatchesUpdateChannel(release, channel)) continue;
    final String? version =
        normalizeReleaseVersionTag(release['tag_name'] as String? ?? '');
    if (version == null || version.isEmpty) continue;
    if (!isUpdateVersionNewer(version, currentVersion, channel)) continue;

    final List<Map<String, dynamic>> assetMaps =
        (release['assets'] as List<dynamic>? ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .toList(growable: false);
    final String? downloadUrl =
        await updater.selectAsset(assetMaps, channel: channel);
    final UpdateReleaseSelection selection = UpdateReleaseSelection(
      release: release,
      version: version,
      releaseNotes: release['body'] as String? ?? '',
      downloadUrl: downloadUrl,
    );
    if (downloadUrl != null) return selection;
    // Self-installing platforms must ignore wrong-platform releases instead of
    // treating independent Android/Windows workflow run numbers as comparable.
    if (!updater.supportsInAppInstall) fallback ??= selection;
  }
  return fallback;
}

@visibleForTesting
String? normalizeReleaseVersionTag(String tag) {
  final String normalized = tag.trim().replaceFirst(RegExp(r'^[vV]'), '');
  if (!_looksLikeVersion(normalized)) return null;
  return _stripBuildMetadata(normalized);
}

@visibleForTesting
bool releaseMatchesUpdateChannel(
  Map<String, dynamic> release,
  UpdateChannel channel,
) {
  if (release['draft'] == true) return false;
  final String tag = release['tag_name'] as String? ?? '';
  final String? version = normalizeReleaseVersionTag(tag);
  if (version == null) return false;
  final bool prerelease = release['prerelease'] == true;
  return switch (channel) {
    UpdateChannel.stable => !prerelease && _prereleasePart(version) == null,
    UpdateChannel.beta =>
      prerelease && _releaseTagMatchesChannel(tag, UpdateChannel.beta),
    UpdateChannel.debug =>
      prerelease && _releaseTagMatchesChannel(tag, UpdateChannel.debug),
  };
}

@visibleForTesting
bool isUpdateVersionNewer(
  String remote,
  String local,
  UpdateChannel channel,
) {
  if (channel == UpdateChannel.stable) return isVersionNewer(remote, local);

  final String remoteVersion = _stripBuildMetadata(remote.trim());
  final String localVersion = _stripBuildMetadata(local.trim());
  if (!_versionBelongsToChannel(remoteVersion, channel)) return false;

  final int baseCompare = _compareBaseVersion(remoteVersion, localVersion);
  if (baseCompare != 0) return baseCompare > 0;

  final String? localPrerelease = _prereleasePart(localVersion);
  if (localPrerelease == null) return true;
  if (!_prereleaseBelongsToChannel(localPrerelease, channel)) return true;

  final String remotePrerelease = _prereleasePart(remoteVersion)!;
  return _comparePrerelease(remotePrerelease, localPrerelease) > 0;
}

bool isVersionNewer(String remote, String local) {
  final String remoteVersion = _stripBuildMetadata(remote.trim());
  final String localVersion = _stripBuildMetadata(local.trim());
  final int baseCompare = _compareBaseVersion(remoteVersion, localVersion);
  if (baseCompare != 0) return baseCompare > 0;

  final String? remotePrerelease = _prereleasePart(remoteVersion);
  final String? localPrerelease = _prereleasePart(localVersion);
  if (remotePrerelease == null && localPrerelease != null) return true;
  if (remotePrerelease == null || localPrerelease == null) return false;
  return _comparePrerelease(remotePrerelease, localPrerelease) > 0;
}

String _stripBuildMetadata(String version) => version.split('+').first;

bool _looksLikeVersion(String version) => RegExp(
      r'^\d+(?:\.\d+)*(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?(?:\+[0-9A-Za-z][0-9A-Za-z.-]*)?$',
    ).hasMatch(version);

String _basePart(String version) =>
    _stripBuildMetadata(version).split('-').first;

String? _prereleasePart(String version) {
  final String stripped = _stripBuildMetadata(version);
  final int hyphen = stripped.indexOf('-');
  if (hyphen < 0 || hyphen == stripped.length - 1) return null;
  return stripped.substring(hyphen + 1);
}

List<int> _baseSegments(String version) => _basePart(version)
    .split('.')
    .map((String part) => int.tryParse(part) ?? 0)
    .toList(growable: false);

int _compareBaseVersion(String remote, String local) {
  final List<int> r = _baseSegments(remote);
  final List<int> l = _baseSegments(local);
  final int len = r.length > l.length ? r.length : l.length;
  for (int i = 0; i < len; i++) {
    final int rv = i < r.length ? r[i] : 0;
    final int lv = i < l.length ? l[i] : 0;
    if (rv != lv) return rv.compareTo(lv);
  }
  return 0;
}

bool _versionBelongsToChannel(String version, UpdateChannel channel) {
  final String normalized = _stripBuildMetadata(version.trim());
  return switch (channel) {
    UpdateChannel.beta => _kBetaVersionPattern.hasMatch(normalized),
    UpdateChannel.debug => _kDebugVersionPattern.hasMatch(normalized),
    UpdateChannel.stable => false,
  };
}

bool _releaseTagMatchesChannel(String tag, UpdateChannel channel) {
  final String normalized = tag.trim();
  return switch (channel) {
    UpdateChannel.beta => _kBetaReleaseTagPattern.hasMatch(normalized),
    UpdateChannel.debug => _kDebugReleaseTagPattern.hasMatch(normalized),
    UpdateChannel.stable => false,
  };
}

bool _prereleaseBelongsToChannel(String prerelease, UpdateChannel channel) {
  final String normalized = prerelease.trim();
  return switch (channel) {
    UpdateChannel.beta => _kBetaVersionPattern.hasMatch('0.0.0-$normalized'),
    UpdateChannel.debug => _kDebugVersionPattern.hasMatch('0.0.0-$normalized'),
    UpdateChannel.stable => false,
  };
}

int _comparePrerelease(String remote, String local) {
  final List<String> r = remote.split('.');
  final List<String> l = local.split('.');
  final int len = r.length > l.length ? r.length : l.length;
  for (int i = 0; i < len; i++) {
    if (i >= r.length) return -1;
    if (i >= l.length) return 1;
    final int part = _comparePrereleasePart(r[i], l[i]);
    if (part != 0) return part;
  }
  return 0;
}

int _comparePrereleasePart(String remote, String local) {
  final int? ri = int.tryParse(remote);
  final int? li = int.tryParse(local);
  if (ri != null && li != null) return ri.compareTo(li);
  if (ri != null) return -1;
  if (li != null) return 1;
  return remote.compareTo(local);
}

@visibleForTesting
class UpdateAvailableDialog extends StatelessWidget {
  const UpdateAvailableDialog({
    required this.version,
    required this.releaseNotes,
    required this.primaryLabel,
    required this.onPrimary,
    super.key,
  });

  final String version;
  final String releaseNotes;
  final String primaryLabel;
  final VoidCallback onPrimary;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);

    return HibikiDialogFrame(
      maxWidth: 520,
      maxHeightFactor: 0.9,
      scrollable: false,
      insetPadding: EdgeInsets.all(tokens.spacing.gap),
      child: HibikiModalSheetFrame(
        title: t.update_available,
        leadingIcon: Icons.system_update_alt_outlined,
        scrollable: true,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              t.update_message(version: version),
              style: tokens.type.listSubtitle,
            ),
            if (releaseNotes.isNotEmpty) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              MarkdownBody(
                data: releaseNotes,
                selectable: true,
                onTapLink: (_, href, __) {
                  if (href == null) return;
                  launchUrl(
                    Uri.parse(href),
                    mode: LaunchMode.externalApplication,
                  );
                },
                styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                  p: tokens.type.listSubtitle,
                ),
              ),
            ],
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t.update_skip),
            ),
            adaptiveDialogAction(
              context: context,
              isDefaultAction: true,
              onPressed: onPrimary,
              child: Text(primaryLabel),
            ),
          ],
        ),
      ),
    );
  }
}

class _DownloadOverlay extends StatelessWidget {
  const _DownloadOverlay({
    required this.progress,
    required this.status,
    required this.onHide,
  });
  final ValueNotifier<double> progress;
  final ValueNotifier<String> status;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Positioned.fill(
      child: Material(
        color: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.54),
        child: Center(
          child: HibikiCard(
            margin: const EdgeInsets.symmetric(horizontal: 48),
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ValueListenableBuilder<String>(
                  valueListenable: status,
                  builder: (_, s, __) => Text(
                    s,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                SizedBox(height: tokens.spacing.card),
                ValueListenableBuilder<double>(
                  valueListenable: progress,
                  builder: (_, p, __) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LinearProgressIndicator(value: p > 0 ? p : null),
                      SizedBox(height: tokens.spacing.gap),
                      Text('${(p * 100).toStringAsFixed(0)}%'),
                    ],
                  ),
                ),
                SizedBox(height: tokens.spacing.card),
                TextButton(
                  onPressed: onHide,
                  child: Text(t.update_hide),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
