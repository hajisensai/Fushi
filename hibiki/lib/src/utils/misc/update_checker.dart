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
/// 否则一个坏镜像就能拖垮整轮检查（BUG-276）。
const Duration _kPerAttemptTimeout = Duration(seconds: 15);

/// GitHub 直连不通时（GFW 机器，且 app 运行时**不走**本机命令行代理）套在 GitHub
/// API / 直链前的加速代理前缀。逐个尝试（见 [fetchFirstSuccessfulBody]），任一成功即
/// 返回，全部失败才优雅放弃。这些公共镜像会不定期轮换/下线（`mirror.ghproxy.com` 已
/// 下线移除），具体哪个通取决于用户机器与时段，故多备几个——用户日志里连不上的
/// `ghproxy.cc` 也保留为多候选之一（BUG-276：单点不可达不该让整轮检查失败）。
///
/// 与 `video_shader_downloader.dart` 的 `_kGhProxyPrefixes`（BUG-319/271）同一范式。
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
/// 响应体；全部失败才返回 null。这是更新检查可达性的真正逻辑（BUG-276 把它从原
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

  /// 多镜像回退的更新检查请求（BUG-276）。生成「直连 + 各 gh 代理前缀」候选列表
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
          ErrorLogService.instance.log('UpdateChecker.httpGet',
              t.update_network_unreachable(host: host));
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

  static Future<Map<String, dynamic>?> _fetchStableRelease(
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

      // 下载与检查共用同一组 GitHub 镜像候选（updateCheckUrls）：直连优先、各 gh
      // 代理前缀兜底。下载的写盘/安装逻辑不变，只是镜像清单与检查保持同步（BUG-276）。
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
            ErrorLogService.instance.log('UpdateChecker.download',
                t.update_network_unreachable(host: hostLabelForUpdateUrl(u)));
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
