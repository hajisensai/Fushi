import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:hibiki/src/utils/misc/channel_constants.dart';
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
        if (f is! File || !f.path.endsWith('.apk')) continue;
        final name = f.uri.pathSegments.last;
        if (!name.startsWith(prefix)) continue;
        final apkVersion = name.substring(prefix.length, name.length - 4);
        if (!_isNewer(apkVersion, currentVersion)) {
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
    if (!Platform.isAndroid) return;
    if (neverRemind && !autoInstall) return;
    HttpClient? client;
    try {
      await _cleanupOldApks(currentVersion);
      client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);

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

      String? apkUrl;
      String? fallbackApkUrl;
      final assets = json['assets'] as List<dynamic>? ?? [];

      List<String> supportedAbis = [];
      try {
        final androidInfo = await DeviceInfoPlugin().androidInfo;
        supportedAbis = androidInfo.supportedAbis;
      } catch (e, stack) {
        ErrorLogService.instance.log('UpdateChecker.getAbi', e, stack);
        debugPrint('[Hibiki] failed to get device ABI info: $e');
      }

      final abiTags =
          supportedAbis.map((abi) => abi.replaceAll('_', '-')).toList();

      for (final asset in assets) {
        final assetMap = asset as Map<String, dynamic>;
        final name = assetMap['name'] as String? ?? '';
        if (!name.endsWith('.apk')) continue;
        final url = assetMap['browser_download_url'] as String?;
        if (url == null) continue;

        if (abiTags.any(name.contains)) {
          apkUrl = url;
          break;
        }
        fallbackApkUrl ??= url;
      }
      apkUrl ??= fallbackApkUrl;

      // No APK asset — fall back to opening release page in browser.
      if (apkUrl == null) {
        final htmlUrl = json['html_url'] as String?;
        if (htmlUrl != null && context.mounted) {
          _showFallbackDialog(context, tagName, releaseBody, htmlUrl);
        }
        return;
      }

      if (!context.mounted) {
        return;
      }

      if (autoInstall) {
        _downloadAndInstall(context, apkUrl, tagName);
      } else {
        _showUpdateDialog(context, tagName, releaseBody, apkUrl);
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
        ErrorLogService.instance.log('UpdateChecker.httpGet', e, stack);
        debugPrint('[Hibiki] request failed ($u): $e');
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
  ) {
    showAppDialog<void>(
      context: context,
      builder: (ctx) => adaptiveAlertDialog(
        context: ctx,
        title: Text(t.update_available),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.update_message(version: version)),
              if (releaseNotes.isNotEmpty) ...[
                const SizedBox(height: 12),
                MarkdownBody(
                  data: releaseNotes,
                  selectable: true,
                  onTapLink: (_, href, __) {
                    if (href != null) {
                      launchUrl(
                        Uri.parse(href),
                        mode: LaunchMode.externalApplication,
                      );
                    }
                  },
                  styleSheet:
                      MarkdownStyleSheet.fromTheme(Theme.of(ctx)).copyWith(
                    p: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          adaptiveDialogAction(
            context: ctx,
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(t.update_skip),
          ),
          adaptiveDialogAction(
            context: ctx,
            onPressed: () {
              Navigator.of(ctx).pop();
              _downloadAndInstall(context, downloadUrl, version);
            },
            child: Text(t.update_download),
          ),
        ],
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
      builder: (ctx) => adaptiveAlertDialog(
        context: ctx,
        title: Text(t.update_available),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.update_message(version: version)),
              if (releaseNotes.isNotEmpty) ...[
                const SizedBox(height: 12),
                MarkdownBody(
                  data: releaseNotes,
                  selectable: true,
                  onTapLink: (_, href, __) {
                    if (href != null) {
                      launchUrl(
                        Uri.parse(href),
                        mode: LaunchMode.externalApplication,
                      );
                    }
                  },
                  styleSheet:
                      MarkdownStyleSheet.fromTheme(Theme.of(ctx)).copyWith(
                    p: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          adaptiveDialogAction(
            context: ctx,
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(t.update_skip),
          ),
          adaptiveDialogAction(
            context: ctx,
            onPressed: () {
              Navigator.of(ctx).pop();
              launchUrl(
                Uri.parse(htmlUrl),
                mode: LaunchMode.externalApplication,
              );
            },
            child: Text(t.update_download),
          ),
        ],
      ),
    );
  }

  static Future<void> _downloadAndInstall(
    BuildContext context,
    String url,
    String version,
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
      final apkFile = File('${cacheDir.path}/hibiki-$version.apk');

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
            await _writeResponse(response, apkFile, progress);
            downloaded = true;
            break;
          }
          await response.drain<void>();
        } catch (e, stack) {
          ErrorLogService.instance.log('UpdateChecker.download', e, stack);
          debugPrint('[Hibiki] download failed ($u): $e');
        }
      }
      if (!downloaded) {
        throw Exception('All download sources failed');
      }

      status.value = t.update_installing;

      await HibikiChannels.update.invokeMethod('installApk', {
        'path': apkFile.path,
      });
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
                const SizedBox(height: 16),
                ValueListenableBuilder<double>(
                  valueListenable: progress,
                  builder: (_, p, __) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LinearProgressIndicator(value: p > 0 ? p : null),
                      const SizedBox(height: 8),
                      Text('${(p * 100).toStringAsFixed(0)}%'),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
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
