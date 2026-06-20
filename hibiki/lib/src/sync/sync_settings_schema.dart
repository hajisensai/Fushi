import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipboard/clipboard.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_exit_app/flutter_exit_app.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/sync/backup_service.dart';
import 'package:hibiki/src/sync/dropbox_sync_backend.dart';
import 'package:hibiki/src/sync/ftp_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/onedrive_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_server_controller.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/lan_discovery_service.dart';
import 'package:hibiki/src/sync/sftp_sync_backend.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_auto_trigger.dart';
import 'package:hibiki/src/sync/sync_compare_dialog.dart';
import 'package:hibiki/src/sync/sync_conflict_prompter.dart';
import 'package:hibiki/src/sync/sync_error_messages.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
import 'package:hibiki/src/sync/sync_progress.dart';
import 'package:hibiki/src/sync/sync_message_dialog.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/webdav_sync_backend.dart';
import 'package:hibiki/utils.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

part 'sync_settings_schema/account.part.dart';
part 'sync_settings_schema/backend_config.part.dart';
part 'sync_settings_schema/interconnect.part.dart';
part 'sync_settings_schema/actions.part.dart';
part 'sync_settings_schema/backup.part.dart';

SettingsDestination buildSyncBackupDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.syncBackup,
    title: t.settings_destination_sync_backup,
    summary: t.sync_summary,
    icon: Icons.sync,
    sections: <SettingsSection>[
      // ── Group 1: Sync method — the backend + its own auth/config ──────
      // Each control is scoped to the backend it actually applies to:
      // OAuth account row for cloud backends; credential box for WebDAV/FTP/
      // SFTP; URL list + LAN discovery for the Hibiki P2P backend.
      SettingsSection(
        title: t.sync_section_method,
        items: <SettingsItem>[
          SettingsCustomItem(
            id: 'sync.mode',
            icon: Icons.cloud_outlined,
            builder: (SettingsContext ctx) =>
                _BackendSelectorWidget(settingsContext: ctx),
          ),
          SettingsCustomItem(
            id: 'sync.account_status',
            icon: Icons.account_circle_outlined,
            visible: (SettingsContext ctx) =>
                isOAuthSyncBackend(_syncSettings(ctx).backendType),
            builder: (SettingsContext ctx) =>
                _SyncAccountWidget(settingsContext: ctx),
          ),
          SettingsCustomItem(
            id: 'sync.webdav_config',
            icon: Icons.dns_outlined,
            visible: (SettingsContext ctx) =>
                _syncSettings(ctx).backendType == SyncBackendType.webDav,
            builder: (SettingsContext ctx) =>
                _WebDavConfigWidget(settingsContext: ctx),
          ),
          SettingsCustomItem(
            id: 'sync.ftp_config',
            icon: Icons.dns_outlined,
            visible: (SettingsContext ctx) =>
                _syncSettings(ctx).backendType == SyncBackendType.ftp,
            builder: (SettingsContext ctx) =>
                _FtpConfigWidget(settingsContext: ctx),
          ),
          SettingsCustomItem(
            id: 'sync.sftp_config',
            icon: Icons.dns_outlined,
            visible: (SettingsContext ctx) =>
                _syncSettings(ctx).backendType == SyncBackendType.sftp,
            builder: (SettingsContext ctx) =>
                _SftpConfigWidget(settingsContext: ctx),
          ),
          SettingsCustomItem(
            id: 'sync.hibiki_server_config',
            icon: Icons.devices_outlined,
            visible: (SettingsContext ctx) =>
                _syncSettings(ctx).backendType == SyncBackendType.hibikiServer,
            builder: (SettingsContext ctx) =>
                _HibikiServerConfigWidget(settingsContext: ctx),
          ),
          SettingsCustomItem(
            id: 'sync.lan_devices',
            icon: Icons.wifi_find_outlined,
            visible: (SettingsContext ctx) =>
                _syncSettings(ctx).backendType == SyncBackendType.hibikiServer,
            builder: (SettingsContext ctx) =>
                _LanDiscoveryWidget(settingsContext: ctx),
          ),
        ],
      ),
      // ── Group 2: This device as a sync server ─────────────────────────
      // Hosting this device as a server is only meaningful for the Hibiki P2P
      // interconnect ("Hibiki 互联") — the other backends sync your own data
      // outward and never serve it. Gate the whole group on that backend so it
      // matches the hibiki_server_config / lan_devices items in Group 1.
      SettingsSection(
        title: t.sync_section_host_server,
        footer: t.sync_section_host_server_footer,
        visible: (SettingsContext ctx) =>
            _syncSettings(ctx).backendType == SyncBackendType.hibikiServer,
        items: <SettingsItem>[
          SettingsCustomItem(
            id: 'sync.server_mode',
            icon: Icons.router_outlined,
            builder: (SettingsContext ctx) =>
                _ServerModeWidget(settingsContext: ctx),
          ),
        ],
      ),
      // ── Group 3: What to sync — global, applies to every backend ──────
      SettingsSection(
        title: t.sync_section_content,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'sync.auto_sync',
            title: t.sync_auto_sync,
            icon: Icons.sync_outlined,
            value: (SettingsContext ctx) => _syncSettings(ctx).autoSync,
            onChanged: (SettingsContext ctx, bool value) async {
              _syncSettings(ctx).autoSync = value;
              await SyncRepository(ctx.appModel.database)
                  .setAutoSyncEnabled(value);
            },
          ),
          SettingsSwitchItem(
            id: 'sync.statistics',
            title: t.sync_statistics,
            icon: Icons.query_stats_outlined,
            value: (SettingsContext ctx) => _syncSettings(ctx).syncStats,
            onChanged: (SettingsContext ctx, bool value) async {
              _syncSettings(ctx).syncStats = value;
              await SyncRepository(ctx.appModel.database)
                  .setSyncStatsEnabled(value);
            },
          ),
          SettingsSwitchItem(
            id: 'sync.dictionary',
            title: t.sync_dictionary,
            subtitle: t.sync_dictionary_warning,
            icon: Icons.menu_book_outlined,
            value: (SettingsContext ctx) => _syncSettings(ctx).syncDictionary,
            onChanged: (SettingsContext ctx, bool value) async {
              _syncSettings(ctx).syncDictionary = value;
              await SyncRepository(ctx.appModel.database)
                  .setSyncDictionaryEnabled(value);
            },
          ),
          SettingsSwitchItem(
            id: 'sync.local_audio',
            title: t.sync_local_audio,
            subtitle: t.sync_local_audio_warning,
            icon: Icons.graphic_eq_outlined,
            value: (SettingsContext ctx) => _syncSettings(ctx).syncLocalAudio,
            onChanged: (SettingsContext ctx, bool value) async {
              _syncSettings(ctx).syncLocalAudio = value;
              await SyncRepository(ctx.appModel.database)
                  .setSyncLocalAudioEnabled(value);
            },
          ),
          SettingsSwitchItem(
            id: 'sync.content',
            title: t.sync_content,
            subtitle: t.sync_content_warning,
            icon: Icons.book_outlined,
            value: (SettingsContext ctx) => _syncSettings(ctx).syncContent,
            onChanged: (SettingsContext ctx, bool value) async {
              _syncSettings(ctx).syncContent = value;
              await SyncRepository(ctx.appModel.database)
                  .setSyncContentEnabled(value);
            },
          ),
          SettingsSwitchItem(
            id: 'sync.audiobook_files',
            title: t.sync_audiobook_files,
            subtitle: t.sync_audiobook_files_warning,
            icon: Icons.audio_file_outlined,
            value: (SettingsContext ctx) =>
                _syncSettings(ctx).syncAudioBookFiles,
            onChanged: (SettingsContext ctx, bool value) async {
              _syncSettings(ctx).syncAudioBookFiles = value;
              await SyncRepository(ctx.appModel.database)
                  .setSyncAudioBookFilesEnabled(value);
            },
          ),
        ],
      ),
      // ── Group 4: Manual sync actions — global ────────────────────────
      SettingsSection(
        title: t.sync_section_actions,
        items: <SettingsItem>[
          // Hosting as a Hibiki server has no OUTBOUND sync: the host is a
          // passive data source that connected clients pull from / push to, so
          // "sync now" / "compare" resolve to an unconfigured outbound backend
          // and used to misleadingly say "set up sync first". Hide them in
          // server mode and explain instead (BUG-084).
          SettingsCustomItem(
            id: 'sync.server_mode_note',
            icon: Icons.router_outlined,
            visible: (SettingsContext ctx) => _isHostingInterconnect(ctx),
            builder: (SettingsContext ctx) => AdaptiveSettingsRow(
              title: t.sync_server_mode_active,
              subtitle: t.sync_server_mode_clients_drive,
              icon: Icons.router_outlined,
            ),
          ),
          SettingsCustomItem(
            id: 'sync.sync_now',
            icon: Icons.sync,
            visible: (SettingsContext ctx) => !_isHostingInterconnect(ctx),
            builder: (SettingsContext ctx) =>
                _SyncNowWidget(settingsContext: ctx),
          ),
          SettingsActionItem(
            id: 'sync.compare',
            title: t.sync_compare,
            icon: Icons.compare_arrows,
            visible: (SettingsContext ctx) => !_isHostingInterconnect(ctx),
            onTap: (SettingsContext ctx) => showSyncCompareDialog(
              ctx.context,
              ctx.appModel.database,
            ),
          ),
        ],
      ),
      // ── Group 5: Local backup — independent of sync ──────────────────
      SettingsSection(
        title: t.sync_section_backup,
        items: <SettingsItem>[
          SettingsCustomItem(
            id: 'sync.backup_export',
            icon: Icons.upload_file_outlined,
            builder: (SettingsContext ctx) =>
                _BackupExportWidget(settingsContext: ctx),
          ),
          SettingsCustomItem(
            id: 'sync.backup_import',
            icon: Icons.download_outlined,
            builder: (SettingsContext ctx) =>
                _BackupImportWidget(settingsContext: ctx),
          ),
        ],
      ),
    ],
  );
}

// HBK-AUDIT-044: 同步设置的内存态由所有者 AppModel（持有 database）拥有，
// 而不是某个 widget。之前 _activeSyncState 的生命周期挂在 _BackendSelectorWidget
// 上（initState 创建、dispose 置 null），其它开关和 _LanDiscoveryWidget 却共享同一
// 全局；当选择器在 master-detail 宽布局或任意 rebuild 中被 dispose 后重建时，全局被
// 置 null 再用硬编码默认值（googleDrive/autoSync=false/syncStats=true/...）懒重建，
// 在异步 load() 落地前，开关会短暂读到默认值而非持久化值。
//
// 改为按 AppModel 身份缓存：只要数据库实例不变就复用已加载的状态，不再随 widget
// dispose 而失效，从根本上消除 "重建即回退默认值" 的竞态窗口。
_SyncSettingsState? _activeSyncState;
AppModel? _activeSyncOwner;

/// Whether this device is actively HOSTING a Hibiki interconnect server — the
/// only role with no outbound "sync now" / "compare" (BUG-084). Requires BOTH
/// the persisted host flag AND the interconnect backend: a stale serverEnabled
/// left over from a past hibikiServer session must NOT gate manual sync on a
/// cloud backend (observed in the wild: serverEnabled=true while
/// backendType=googleDrive, which would otherwise hide sync-now on Drive).
bool _isHostingInterconnect(SettingsContext ctx) =>
    _syncSettings(ctx).serverEnabled &&
    _syncSettings(ctx).backendType == SyncBackendType.hibikiServer;

_SyncSettingsState _syncSettings(SettingsContext ctx) {
  final AppModel owner = ctx.appModel;
  if (_activeSyncState == null || !identical(_activeSyncOwner, owner)) {
    _activeSyncOwner = owner;
    _activeSyncState = _SyncSettingsState(ctx)..load();
  }
  return _activeSyncState!;
}

void _showSnackBar(BuildContext context, String message) {
  showSyncMessage(context, message);
}

class _SyncSettingsState {
  _SyncSettingsState(this._settingsContext)
      : _repo = SyncRepository(_settingsContext.appModel.database);

  final SettingsContext _settingsContext;
  final SyncRepository _repo;
  SyncBackendType backendType = SyncBackendType.googleDrive;
  bool autoSync = false;
  bool syncStats = true;
  bool syncDictionary = false;
  bool syncLocalAudio = false;
  bool syncContent = false;
  bool syncAudioBookFiles = false;
  bool _loaded = false;
  bool _loading = false;

  /// Bumped whenever the persisted Hibiki *client* config (URLs / token) is
  /// mutated from outside the client-config widget (e.g. LAN pairing). The
  /// client-config widget listens and reloads — this is the single source of
  /// truth replacing the previous "loaded once in initState" stale state.
  final ValueNotifier<int> clientConfigRevision = ValueNotifier<int>(0);

  void reloadClientConfig() => clientConfigRevision.value++;

  /// Mutual-exclusion role state for the Hibiki interconnect: a device may be a
  /// host (server on, others connect to it) OR a client (connected outward to a
  /// peer), never both. The two flags below are the shared truth the server and
  /// client widgets read to gate each other; [roleRevision] notifies on change.
  bool serverEnabled = false;
  bool hasClientConnection = false;
  final ValueNotifier<int> roleRevision = ValueNotifier<int>(0);

  void setServerEnabled(bool value) {
    if (serverEnabled == value) return;
    serverEnabled = value;
    roleRevision.value++;
    // Re-evaluate section/item visibility predicates (the manual-sync actions
    // are gated on serverEnabled, BUG-084) so toggling the host role re-gates
    // them live, not just on the next page open.
    _settingsContext.refresh();
  }

  void setHasClientConnection(bool value) {
    if (hasClientConnection == value) return;
    hasClientConnection = value;
    roleRevision.value++;
  }

  Future<void> load() async {
    if (_loaded || _loading) return;

    _loading = true;
    try {
      backendType = await _repo.getBackendType();
      autoSync = await _repo.isAutoSyncEnabled();
      syncStats = await _repo.isSyncStatsEnabled();
      syncDictionary = await _repo.isSyncDictionaryEnabled();
      syncLocalAudio = await _repo.isSyncLocalAudioEnabled();
      syncContent = await _repo.isSyncContentEnabled();
      syncAudioBookFiles = await _repo.isSyncAudioBookFilesEnabled();
      serverEnabled = await _repo.isServerEnabled();
      hasClientConnection = (await _repo.getHibikiClientUrls()).isNotEmpty;
      _loaded = true;
      _settingsContext.refresh();
    } finally {
      _loading = false;
    }
  }
}
