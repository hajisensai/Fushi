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

const List<String> _kProxyPrefixes = [
  'https://ghfast.top/',
  'https://mirror.ghproxy.com/',
];

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
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _check(context, currentVersion,
          neverRemind: neverRemind,
          autoInstall: autoInstall,
          betaChannel: betaChannel || debugChannel);
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
    bool betaChannel = false,
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

      final json = betaChannel
          ? await _fetchLatestRelease(client)
          : await _fetchStableRelease(client);
      if (json == null) return;

      final tagName =
          (json['tag_name'] as String? ?? '').replaceAll(RegExp('^v'), '');
      if (tagName.isEmpty) {
        return;
      }

      if (!_isNewer(tagName, currentVersion)) {
        return;
      }

      final releaseBody = json['body'] as String? ?? '';

      final assets = json['assets'] as List<dynamic>? ?? [];
      final List<Map<String, dynamic>> assetMaps =
          assets.whereType<Map<String, dynamic>>().toList(growable: false);
      final String? downloadUrl = await updater.selectAsset(assetMaps);

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

  static Future<String?> _httpGetString(
    HttpClient client,
    String url, {
    Map<String, String> headers = const {},
  }) async {
    final urls = [url, ..._kProxyPrefixes.map((p) => '$p$url')];
    for (final u in urls) {
      try {
        final request = await client.getUrl(Uri.parse(u));
        for (final e in headers.entries) {
          request.headers.set(e.key, e.value);
        }
        final response = await request.close();
        if (response.statusCode == 200) {
          return await response.transform(utf8.decoder).join();
        }
        await response.drain<void>();
      } catch (e, stack) {
        // 更新检查是 best-effort：连不上/超时/TLS 握手失败是预期网络现象（尤其
        // GFW 下访问 GitHub 与代理），只 debugPrint，不带堆栈污染错误日志。
        if (isExpectedUpdateNetworkFailure(e)) {
          debugPrint('[Hibiki] update check skipped ($u): $e');
        } else {
          ErrorLogService.instance.log('UpdateChecker.httpGet', e, stack);
          debugPrint('[Hibiki] request failed ($u): $e');
        }
      }
    }
    return null;
  }

  static Future<Map<String, dynamic>?> _fetchStableRelease(
      HttpClient client) async {
    final body = await _httpGetString(
      client,
      'https://api.github.com/repos/$_kGitHubRepo/releases/latest',
      headers: {'Accept': 'application/vnd.github+json'},
    );
    if (body == null) return null;
    return jsonDecode(body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>?> _fetchLatestRelease(
      HttpClient client) async {
    final body = await _httpGetString(
      client,
      'https://api.github.com/repos/$_kGitHubRepo/releases?per_page=1',
      headers: {'Accept': 'application/vnd.github+json'},
    );
    if (body == null) return null;
    final list = jsonDecode(body) as List<dynamic>;
    if (list.isEmpty) return null;
    return list.first as Map<String, dynamic>;
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

      final urls = [url, ..._kProxyPrefixes.map((p) => '$p$url')];
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
          // 单个下载源连不上是预期的，逐源静默回退；只 debugPrint。全部失败时
          // 下面的 throw 会被外层 catch 统一记录一条并弹 SnackBar 提示用户。
          if (isExpectedUpdateNetworkFailure(e)) {
            debugPrint('[Hibiki] download source skipped ($u): $e');
          } else {
            ErrorLogService.instance.log('UpdateChecker.download', e, stack);
            debugPrint('[Hibiki] download failed ($u): $e');
          }
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
/// 失败、底层 HTTP 协议错误——是预期现象（尤其 GFW 下访问 GitHub / 代理本就
/// 不稳），不该当错误带完整堆栈塞进用户可见的错误日志，否则真正的 bug 信号会
/// 被这类噪音淹没。返回 true 表示该异常只需 debugPrint，无需写 ErrorLogService。
bool isExpectedUpdateNetworkFailure(Object e) =>
    e is SocketException || e is HandshakeException || e is HttpException;

bool isVersionNewer(String remote, String local) {
  String strip(String v) => v.split('+').first;
  List<int> base(String s) =>
      s.split('-').first.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  bool pre(String s) => s.contains('-');

  final String rs = strip(remote);
  final String ls = strip(local);
  final List<int> r = base(rs);
  final List<int> l = base(ls);

  final int len = r.length > l.length ? r.length : l.length;
  for (int i = 0; i < len; i++) {
    final int rv = i < r.length ? r[i] : 0;
    final int lv = i < l.length ? l[i] : 0;
    if (rv > lv) return true;
    if (rv < lv) return false;
  }
  if (!pre(rs) && pre(ls)) return true;
  return false;
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
