import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:hibiki/utils.dart';

/// GitHub repository owner/name used for update checks.
/// Change this if the repository is moved.
const String _kGitHubRepo = 'hdjsadgfwtg/hibiki';

/// Checks for new releases on GitHub and prompts the user to download.
class UpdateChecker {
  UpdateChecker._();

  /// Fire-and-forget: schedule an update check after the first frame.
  static void scheduleCheck(BuildContext context, String currentVersion) {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _check(context, currentVersion);
    });
  }

  static Future<void> _check(
    BuildContext context,
    String currentVersion,
  ) async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);

      final uri = Uri.parse(
        'https://api.github.com/repos/$_kGitHubRepo/releases/latest',
      );
      final request = await client.getUrl(uri);
      request.headers.set('Accept', 'application/vnd.github+json');

      final response = await request.close();
      if (response.statusCode != 200) {
        await response.drain<void>();
        return;
      }

      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;

      final tagName =
          (json['tag_name'] as String? ?? '').replaceAll(RegExp('^v'), '');
      if (tagName.isEmpty) {
        return;
      }

      if (!_isNewer(tagName, currentVersion)) {
        return;
      }

      final releaseBody = json['body'] as String? ?? '';

      // Find the first APK asset download URL.
      String? apkUrl;
      final assets = json['assets'] as List<dynamic>? ?? [];
      for (final asset in assets) {
        final assetMap = asset as Map<String, dynamic>;
        final name = assetMap['name'] as String? ?? '';
        if (name.endsWith('.apk')) {
          apkUrl = assetMap['browser_download_url'] as String?;
          break;
        }
      }
      // Fallback to the release HTML page if no APK asset found.
      apkUrl ??= json['html_url'] as String?;
      if (apkUrl == null) {
        return;
      }

      if (!context.mounted) {
        return;
      }

      _showUpdateDialog(context, tagName, releaseBody, apkUrl);
    } catch (_) {
      // Network / parse errors — silently ignore.
    }
  }

  /// Compare two semver-ish version strings.
  /// Returns true when [remote] is strictly newer than [local].
  static bool _isNewer(String remote, String local) {
    // Strip everything after '+' (build metadata).
    final r = remote.split('+').first.split('.').map(_parseInt).toList();
    final l = local.split('+').first.split('.').map(_parseInt).toList();

    final len = r.length > l.length ? r.length : l.length;
    for (int i = 0; i < len; i++) {
      final rv = i < r.length ? r[i] : 0;
      final lv = i < l.length ? l[i] : 0;
      if (rv > lv) {
        return true;
      }
      if (rv < lv) {
        return false;
      }
    }
    return false;
  }

  static int _parseInt(String s) => int.tryParse(s) ?? 0;

  static void _showUpdateDialog(
    BuildContext context,
    String version,
    String releaseNotes,
    String downloadUrl,
  ) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.update_available),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.update_message(version: version)),
              if (releaseNotes.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  releaseNotes,
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(t.update_skip),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              launchUrl(
                Uri.parse(downloadUrl),
                mode: LaunchMode.externalApplication,
              );
            },
            child: Text(t.update_download),
          ),
        ],
      ),
    );
  }
}
