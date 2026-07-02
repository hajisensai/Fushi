import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists and restores macOS sandbox access for a custom data root.
///
/// `com.apple.security.files.user-selected.read-write` grants access only to
/// the running process that received the NSOpenPanel selection. After restart,
/// a sandboxed app must resolve a security-scoped bookmark before touching the
/// selected directory again.
class MacOSDataRootAccess {
  const MacOSDataRootAccess._();

  static const String dataRootBookmarkPrefKey = 'data_root_bookmark';
  static const MethodChannel _channel =
      MethodChannel('app.hibiki/data_root_access');

  static Future<String?> createBookmarkForPath(String path) async {
    if (!Platform.isMacOS) return null;
    final String? bookmark = await _channel.invokeMethod<String>(
      'createBookmark',
      <String, Object?>{'path': path},
    );
    if (bookmark == null || bookmark.isEmpty) {
      throw StateError('macOS data root bookmark was empty for "$path"');
    }
    return bookmark;
  }

  static Future<String?> startAccessingStoredBookmark(
    SharedPreferences prefs,
  ) async {
    if (!Platform.isMacOS) return null;
    final String? bookmark = prefs.getString(dataRootBookmarkPrefKey);
    if (bookmark == null || bookmark.isEmpty) return null;
    try {
      final Map<Object?, Object?>? result =
          await _channel.invokeMapMethod<Object?, Object?>(
        'startAccessingBookmark',
        <String, Object?>{'bookmark': bookmark},
      );
      final Object? path = result?['path'];
      return path is String && path.isNotEmpty ? path : null;
    } on PlatformException catch (e) {
      debugPrint('MacOSDataRootAccess: failed to restore bookmark: $e');
      return null;
    } on MissingPluginException catch (e) {
      debugPrint('MacOSDataRootAccess: native bridge missing: $e');
      return null;
    }
  }

  static Future<bool> storeBookmark(
    SharedPreferences prefs,
    String? bookmark,
  ) async {
    if (!Platform.isMacOS || bookmark == null || bookmark.isEmpty) return true;
    return prefs.setString(dataRootBookmarkPrefKey, bookmark);
  }

  static Future<bool> restoreBookmark(
    SharedPreferences prefs,
    String? bookmark,
  ) async {
    if (!Platform.isMacOS) return true;
    if (bookmark == null || bookmark.isEmpty) {
      return prefs.remove(dataRootBookmarkPrefKey);
    }
    return prefs.setString(dataRootBookmarkPrefKey, bookmark);
  }
}
