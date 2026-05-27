import 'dart:convert';

import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 同步配置和缓存的持久化层（基于 Preferences 表）。
///
/// 桌面 OAuth 凭据（refresh token, client secret）存储在用户级 SQLite 数据库中，
/// 采用 base64 编码。安全模型与 gcloud/aws-cli 等桌面 CLI 工具一致：
/// 依赖操作系统文件权限保护用户数据目录。
class SyncRepository {
  SyncRepository(this._db);
  final HibikiDatabase _db;

  static const _keyRootFolderId = 'sync_root_folder_id';
  static const _keyFolderCache = 'sync_folder_cache';
  static const _keySyncStats = 'sync_stats_enabled';
  static const _keySyncAudioBook = 'sync_audiobook_enabled';
  static const _keyAutoSync = 'sync_auto_enabled';
  static const _keyLastSyncMs = 'sync_last_sync_ms';
  static const _keyDesktopCredentials = 'sync_desktop_credentials';
  static const _keyBackendType = 'sync_backend_type';
  static const _keySyncContent = 'sync_content_enabled';
  static const _keyWebDavUrl = 'sync_webdav_url';
  static const _keyWebDavUsername = 'sync_webdav_username';
  static const _keyWebDavPassword = 'sync_webdav_password';

  static const String syncStatsPreferenceKey = _keySyncStats;
  static const String syncAudioBookPreferenceKey = _keySyncAudioBook;

  // ── Folder cache ──────────────────────────────────────────────────

  Future<String?> getRootFolderId() async {
    final row = await (_db.select(_db.preferences)
          ..where((t) => t.key.equals(_keyRootFolderId)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> setRootFolderId(String? id) async {
    if (id == null) {
      await (_db.delete(_db.preferences)
            ..where((t) => t.key.equals(_keyRootFolderId)))
          .go();
      return;
    }
    await _db.into(_db.preferences).insertOnConflictUpdate(
          PreferencesCompanion.insert(key: _keyRootFolderId, value: id),
        );
  }

  Future<Map<String, String>> getFolderCache() async {
    final row = await (_db.select(_db.preferences)
          ..where((t) => t.key.equals(_keyFolderCache)))
        .getSingleOrNull();
    if (row == null) return {};
    return Map<String, String>.from(
        jsonDecode(row.value) as Map<String, dynamic>);
  }

  Future<void> setFolderCache(Map<String, String> cache) async {
    await _db.into(_db.preferences).insertOnConflictUpdate(
          PreferencesCompanion.insert(
              key: _keyFolderCache, value: jsonEncode(cache)),
        );
  }

  Future<void> clearFolderCache() async {
    await (_db.delete(_db.preferences)
          ..where((t) => t.key.isIn([_keyRootFolderId, _keyFolderCache])))
        .go();
  }

  // ── Sync settings ─────────────────────────────────────────────────

  Future<bool> isSyncStatsEnabled() =>
      _db.getPrefTyped<bool>(_keySyncStats, true);
  Future<void> setSyncStatsEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keySyncStats, v);

  Future<bool> isSyncAudioBookEnabled() =>
      _db.getPrefTyped<bool>(_keySyncAudioBook, true);
  Future<void> setSyncAudioBookEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keySyncAudioBook, v);

  Future<bool> isAutoSyncEnabled() =>
      _db.getPrefTyped<bool>(_keyAutoSync, false);
  Future<void> setAutoSyncEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyAutoSync, v);

  Future<int?> getLastSyncMs() async {
    final s = await _getStringOrNull(_keyLastSyncMs);
    return s == null ? null : int.tryParse(s);
  }

  Future<void> setLastSyncMs(int ms) =>
      _setString(_keyLastSyncMs, ms.toString());

  // ── Desktop OAuth credentials ──────────────────────────────────────

  Future<String?> getDesktopCredentials() async {
    final encoded = await _getStringOrNull(_keyDesktopCredentials);
    return encoded != null ? _decodeSecret(encoded) : null;
  }

  Future<void> setDesktopCredentials(String? json) async {
    if (json == null) {
      await (_db.delete(_db.preferences)
            ..where((t) => t.key.equals(_keyDesktopCredentials)))
          .go();
      return;
    }
    await _setString(_keyDesktopCredentials, _encodeSecret(json));
  }

  Future<void> clearDesktopSession() async {
    await (_db.delete(_db.preferences)
          ..where((t) => t.key.equals(_keyDesktopCredentials)))
        .go();
  }

  // ── Backend type ───────────────────────────────────────────────────

  Future<SyncBackendType> getBackendType() async {
    final raw = await _getStringOrNull(_keyBackendType);
    if (raw == 'webDav') return SyncBackendType.webDav;
    return SyncBackendType.googleDrive;
  }

  Future<void> setBackendType(SyncBackendType type) =>
      _setString(_keyBackendType, type.name);

  // ── Content sync ──────────────────────────────────────────────────

  Future<bool> isSyncContentEnabled() =>
      _db.getPrefTyped<bool>(_keySyncContent, false);
  Future<void> setSyncContentEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keySyncContent, v);

  // ── WebDAV credentials ────────────────────────────────────────────

  Future<String?> getWebDavUrl() => _getStringOrNull(_keyWebDavUrl);
  Future<void> setWebDavUrl(String? url) async {
    if (url == null) {
      await (_db.delete(_db.preferences)
            ..where((t) => t.key.equals(_keyWebDavUrl)))
          .go();
      return;
    }
    await _setString(_keyWebDavUrl, url);
  }

  Future<String?> getWebDavUsername() => _getStringOrNull(_keyWebDavUsername);
  Future<void> setWebDavUsername(String? username) async {
    if (username == null) {
      await (_db.delete(_db.preferences)
            ..where((t) => t.key.equals(_keyWebDavUsername)))
          .go();
      return;
    }
    await _setString(_keyWebDavUsername, username);
  }

  Future<String?> getWebDavPassword() async {
    final encoded = await _getStringOrNull(_keyWebDavPassword);
    return encoded != null ? _decodeSecret(encoded) : null;
  }

  Future<void> setWebDavPassword(String? password) async {
    if (password == null) {
      await (_db.delete(_db.preferences)
            ..where((t) => t.key.equals(_keyWebDavPassword)))
          .go();
      return;
    }
    await _setString(_keyWebDavPassword, _encodeSecret(password));
  }

  // ── Encoding ─────────────────────────────────────────────────────

  static String _encodeSecret(String value) => base64Encode(utf8.encode(value));

  static String _decodeSecret(String encoded) {
    try {
      return utf8.decode(base64Decode(encoded));
    } catch (_) {
      return encoded;
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────

  Future<String?> _getStringOrNull(String key) async {
    final row = await (_db.select(_db.preferences)
          ..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> _setString(String key, String value) async {
    await _db.into(_db.preferences).insertOnConflictUpdate(
          PreferencesCompanion.insert(key: key, value: value),
        );
  }
}
