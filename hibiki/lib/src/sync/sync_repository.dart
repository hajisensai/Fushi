import 'dart:convert';

import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 触达一台 Hibiki 同步服务器的一个候选地址。同一台服务器通常可经多条路由
/// 触达（局域网、外网），它们共享同一个 token，按列表顺序尝试、第一个可达者胜出。
class HibikiClientUrl {
  const HibikiClientUrl({required this.url, this.enabled = true});

  final String url;
  final bool enabled;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'url': url,
        'enabled': enabled,
      };

  factory HibikiClientUrl.fromJson(Map<String, dynamic> json) =>
      HibikiClientUrl(
        url: json['url'] as String,
        enabled: json['enabled'] as bool? ?? true,
      );
}

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
    if (raw == null) return SyncBackendType.googleDrive;
    for (final type in SyncBackendType.values) {
      if (type.name == raw) return type;
    }
    return SyncBackendType.googleDrive;
  }

  Future<void> setBackendType(SyncBackendType type) =>
      _setString(_keyBackendType, type.name);

  // ── Content sync ──────────────────────────────────────────────────

  Future<bool> isSyncContentEnabled() =>
      _db.getPrefTyped<bool>(_keySyncContent, false);
  Future<void> setSyncContentEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keySyncContent, v);

  // ── Per-book audiobook position (synced) ──────────────────────────

  static const _keyAudiobookPositionPrefix = 'audiobook_pos_';

  /// 每本书的有声书播放位置（毫秒）。默认 0 表示无记录。集中走仓库层，避免
  /// 散落的 `_db.getPrefTyped('audiobook_pos_...')` 字面量与类型漂移。
  Future<int> getAudiobookPosition(int bookId) =>
      _db.getPrefTyped<int>('$_keyAudiobookPositionPrefix$bookId', 0);
  Future<void> setAudiobookPosition(int bookId, int positionMs) =>
      _db.setPrefTyped<int>('$_keyAudiobookPositionPrefix$bookId', positionMs);

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

  // ── OneDrive credentials ────────────────────────────────────────

  static const _keyOneDriveToken = 'sync_onedrive_token';

  Future<String?> getOneDriveToken() async {
    final encoded = await _getStringOrNull(_keyOneDriveToken);
    return encoded != null ? _decodeSecret(encoded) : null;
  }

  Future<void> setOneDriveToken(String? token) async {
    if (token == null) {
      await _deleteKey(_keyOneDriveToken);
      return;
    }
    await _setString(_keyOneDriveToken, _encodeSecret(token));
  }

  // ── Dropbox credentials ─────────────────────────────────────────

  static const _keyDropboxToken = 'sync_dropbox_token';

  Future<String?> getDropboxToken() async {
    final encoded = await _getStringOrNull(_keyDropboxToken);
    return encoded != null ? _decodeSecret(encoded) : null;
  }

  Future<void> setDropboxToken(String? token) async {
    if (token == null) {
      await _deleteKey(_keyDropboxToken);
      return;
    }
    await _setString(_keyDropboxToken, _encodeSecret(token));
  }

  // ── FTP credentials ─────────────────────────────────────────────

  static const _keyFtpHost = 'sync_ftp_host';
  static const _keyFtpPort = 'sync_ftp_port';
  static const _keyFtpUsername = 'sync_ftp_username';
  static const _keyFtpPassword = 'sync_ftp_password';
  static const _keyFtpUseTls = 'sync_ftp_use_tls';

  Future<String?> getFtpHost() => _getStringOrNull(_keyFtpHost);
  Future<void> setFtpHost(String? v) => _setOrDelete(_keyFtpHost, v);
  Future<int> getFtpPort() => _db.getPrefTyped<int>(_keyFtpPort, 21);
  Future<void> setFtpPort(int v) => _db.setPrefTyped<int>(_keyFtpPort, v);
  Future<String?> getFtpUsername() => _getStringOrNull(_keyFtpUsername);
  Future<void> setFtpUsername(String? v) => _setOrDelete(_keyFtpUsername, v);

  Future<String?> getFtpPassword() async {
    final encoded = await _getStringOrNull(_keyFtpPassword);
    return encoded != null ? _decodeSecret(encoded) : null;
  }

  Future<void> setFtpPassword(String? v) async {
    if (v == null) {
      await _deleteKey(_keyFtpPassword);
      return;
    }
    await _setString(_keyFtpPassword, _encodeSecret(v));
  }

  Future<bool> isFtpTlsEnabled() =>
      _db.getPrefTyped<bool>(_keyFtpUseTls, false);
  Future<void> setFtpTlsEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyFtpUseTls, v);

  // ── SFTP credentials ────────────────────────────────────────────

  static const _keySftpHost = 'sync_sftp_host';
  static const _keySftpPort = 'sync_sftp_port';
  static const _keySftpUsername = 'sync_sftp_username';
  static const _keySftpPassword = 'sync_sftp_password';
  static const _keySftpPrivateKey = 'sync_sftp_private_key';

  Future<String?> getSftpHost() => _getStringOrNull(_keySftpHost);
  Future<void> setSftpHost(String? v) => _setOrDelete(_keySftpHost, v);
  Future<int> getSftpPort() => _db.getPrefTyped<int>(_keySftpPort, 22);
  Future<void> setSftpPort(int v) => _db.setPrefTyped<int>(_keySftpPort, v);
  Future<String?> getSftpUsername() => _getStringOrNull(_keySftpUsername);
  Future<void> setSftpUsername(String? v) => _setOrDelete(_keySftpUsername, v);

  Future<String?> getSftpPassword() async {
    final encoded = await _getStringOrNull(_keySftpPassword);
    return encoded != null ? _decodeSecret(encoded) : null;
  }

  Future<void> setSftpPassword(String? v) async {
    if (v == null) {
      await _deleteKey(_keySftpPassword);
      return;
    }
    await _setString(_keySftpPassword, _encodeSecret(v));
  }

  Future<String?> getSftpPrivateKey() async {
    final encoded = await _getStringOrNull(_keySftpPrivateKey);
    return encoded != null ? _decodeSecret(encoded) : null;
  }

  Future<void> setSftpPrivateKey(String? v) async {
    if (v == null) {
      await _deleteKey(_keySftpPrivateKey);
      return;
    }
    await _setString(_keySftpPrivateKey, _encodeSecret(v));
  }

  // ── SMB credentials ─────────────────────────────────────────────

  static const _keySmbHost = 'sync_smb_host';
  static const _keySmbShare = 'sync_smb_share';
  static const _keySmbUsername = 'sync_smb_username';
  static const _keySmbPassword = 'sync_smb_password';
  static const _keySmbDomain = 'sync_smb_domain';
  static const _keySmbWebDavUrl = 'sync_smb_webdav_url';

  Future<String?> getSmbHost() => _getStringOrNull(_keySmbHost);
  Future<void> setSmbHost(String? v) => _setOrDelete(_keySmbHost, v);
  Future<String?> getSmbShare() => _getStringOrNull(_keySmbShare);
  Future<void> setSmbShare(String? v) => _setOrDelete(_keySmbShare, v);
  Future<String?> getSmbUsername() => _getStringOrNull(_keySmbUsername);
  Future<void> setSmbUsername(String? v) => _setOrDelete(_keySmbUsername, v);

  Future<String?> getSmbPassword() async {
    final encoded = await _getStringOrNull(_keySmbPassword);
    return encoded != null ? _decodeSecret(encoded) : null;
  }

  Future<void> setSmbPassword(String? v) async {
    if (v == null) {
      await _deleteKey(_keySmbPassword);
      return;
    }
    await _setString(_keySmbPassword, _encodeSecret(v));
  }

  Future<String?> getSmbDomain() => _getStringOrNull(_keySmbDomain);
  Future<void> setSmbDomain(String? v) => _setOrDelete(_keySmbDomain, v);

  Future<String?> getSmbWebDavUrl() => _getStringOrNull(_keySmbWebDavUrl);
  Future<void> setSmbWebDavUrl(String? v) => _setOrDelete(_keySmbWebDavUrl, v);

  // ── Hibiki Server config ────────────────────────────────────────

  static const _keyServerEnabled = 'sync_server_enabled';
  static const _keyServerPort = 'sync_server_port';
  static const _keyServerPassword = 'sync_server_password';

  /// Single source of truth for the default Hibiki sync-server port.
  /// 38765 is in the IANA User Ports range (1024–49151) but unassigned and
  /// clear of the crowded 8xxx dev-server band and the 49152+ ephemeral range,
  /// so initial bind conflicts are unlikely. Referenced everywhere the default
  /// is needed so the value can never drift between call sites.
  static const int defaultServerPort = 38765;

  Future<bool> isServerEnabled() =>
      _db.getPrefTyped<bool>(_keyServerEnabled, false);
  Future<void> setServerEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keyServerEnabled, v);
  Future<int> getServerPort() =>
      _db.getPrefTyped<int>(_keyServerPort, defaultServerPort);
  Future<void> setServerPort(int v) => _db.setPrefTyped<int>(_keyServerPort, v);

  Future<String?> getServerPassword() async {
    final encoded = await _getStringOrNull(_keyServerPassword);
    return encoded != null ? _decodeSecret(encoded) : null;
  }

  Future<void> setServerPassword(String? v) async {
    if (v == null) {
      await _deleteKey(_keyServerPassword);
      return;
    }
    await _setString(_keyServerPassword, _encodeSecret(v));
  }

  // ── Hibiki Client (connect to another Hibiki instance) ─────────

  static const _keyHibikiClientUrl = 'sync_hibiki_client_url';
  static const _keyHibikiClientUrls = 'sync_hibiki_client_urls';
  static const _keyHibikiClientToken = 'sync_hibiki_client_token';

  /// 旧的单地址 API，仅为向后兼容保留；新代码请用 [getHibikiClientUrls]。
  @Deprecated('Use getHibikiClientUrls / setHibikiClientUrls')
  Future<String?> getHibikiClientUrl() => _getStringOrNull(_keyHibikiClientUrl);
  @Deprecated('Use getHibikiClientUrls / setHibikiClientUrls')
  Future<void> setHibikiClientUrl(String? v) =>
      _setOrDelete(_keyHibikiClientUrl, v);

  /// 有序候选地址列表（下标即优先级）。新键缺失时，从旧的单地址键迁移种子，
  /// 保证老用户无感。
  Future<List<HibikiClientUrl>> getHibikiClientUrls() async {
    final raw = await _getStringOrNull(_keyHibikiClientUrls);
    if (raw != null) {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      return list.map(HibikiClientUrl.fromJson).toList();
    }
    final legacy = await _getStringOrNull(_keyHibikiClientUrl);
    if (legacy != null && legacy.isNotEmpty) {
      return <HibikiClientUrl>[HibikiClientUrl(url: legacy)];
    }
    return const <HibikiClientUrl>[];
  }

  Future<void> setHibikiClientUrls(List<HibikiClientUrl> urls) async {
    if (urls.isEmpty) {
      await _deleteKey(_keyHibikiClientUrls);
      return;
    }
    await _setString(
      _keyHibikiClientUrls,
      jsonEncode(urls.map((HibikiClientUrl u) => u.toJson()).toList()),
    );
  }

  /// 追加一个候选地址（已存在则去重），保持原有顺序与 token 不变。返回最终列表。
  /// 用于 LAN 发现：点设备把它的地址加入列表，而不是覆盖整套配置。
  Future<List<HibikiClientUrl>> addHibikiClientUrl(String url) async {
    final List<HibikiClientUrl> urls = await getHibikiClientUrls();
    if (urls.any((HibikiClientUrl u) => u.url == url)) return urls;
    final List<HibikiClientUrl> updated = <HibikiClientUrl>[
      ...urls,
      HibikiClientUrl(url: url),
    ];
    await setHibikiClientUrls(updated);
    return updated;
  }

  Future<String?> getHibikiClientToken() async {
    final encoded = await _getStringOrNull(_keyHibikiClientToken);
    return encoded != null ? _decodeSecret(encoded) : null;
  }

  Future<void> setHibikiClientToken(String? v) async {
    if (v == null) {
      await _deleteKey(_keyHibikiClientToken);
      return;
    }
    await _setString(_keyHibikiClientToken, _encodeSecret(v));
  }

  // ── Helpers ───────────────────────────────────────────────────────

  Future<void> _setOrDelete(String key, String? value) async {
    if (value == null || value.isEmpty) {
      await _deleteKey(key);
      return;
    }
    await _setString(key, value);
  }

  Future<void> _deleteKey(String key) async {
    await (_db.delete(_db.preferences)..where((t) => t.key.equals(key))).go();
  }

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
