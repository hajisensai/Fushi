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
import 'package:hibiki/src/settings/settings_schema_lookup.dart'
    show buildManageAudioSourcesItem, buildRemoteDictionaryLookupItem;
import 'package:hibiki/src/startup/media_handle_registry.dart';
import 'package:hibiki/src/storage/app_paths.dart';
import 'package:hibiki/src/storage/data_root_migrator.dart';
import 'package:hibiki/src/storage/macos_data_root_access.dart';
import 'package:hibiki/src/sync/backup_merge_engine.dart'
    show BackupMergePreview;
import 'package:hibiki/src/sync/backup_service.dart';
import 'package:hibiki/src/sync/dropbox_sync_backend.dart';
import 'package:hibiki/src/sync/ftp_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/interconnect_device_name.dart';
import 'package:hibiki/src/sync/interconnect_url.dart';
import 'package:hibiki/src/sync/onedrive_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_server_controller.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/lan_discovery_service.dart';
import 'package:hibiki/src/sync/pairing/hibiki_pair_v2_client.dart';
import 'package:hibiki/src/sync/pairing/hibiki_ping_client.dart';
import 'package:hibiki/src/sync/pairing/discovered_pairing_probe.dart';
import 'package:hibiki/src/sync/sftp_sync_backend.dart';
import 'package:hibiki/src/sync/tls/hibiki_tofu_probe.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_auto_trigger.dart';
import 'package:hibiki/src/sync/sync_compare_dialog.dart';
import 'package:hibiki/src/sync/sync_conflict_prompter.dart';
import 'package:hibiki/src/sync/sync_error_messages.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
import 'package:hibiki/src/sync/sync_progress.dart';
import 'package:hibiki/src/sync/sync_message_dialog.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/webdav_ops.dart';
import 'package:hibiki/src/sync/webdav_sync_backend.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki_platform/hibiki_platform.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:hibiki/src/utils/misc/hibiki_share.dart';

part 'sync_settings_schema/account.part.dart';
part 'sync_settings_schema/backend_config.part.dart';
part 'sync_settings_schema/interconnect.part.dart';
part 'sync_settings_schema/actions.part.dart';
part 'sync_settings_schema/backup.part.dart';
part 'sync_settings_schema/data_root.part.dart';

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
          // 互联（局域网端到端）已从「同步方式」枚举里解耦成独立分类 + 独立开关
          // （buildInterconnectDestination），与云备份后端并存、互不排斥；这里不再
          // 需要「互联被选为同步方式」的指引行。
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
            // Auto-sync is an OUTBOUND switch: it triggers app-open/background/
            // book-close pushes through the resolved backend. A Hibiki host has
            // no outbound sync (clients pull from / push to it), so every
            // auto-sync path early-returns on an unconfigured outbound backend —
            // the toggle does nothing in host mode. Hide it there, matching the
            // sync_now / compare gates (BUG-084). Client-mode hibikiServer DOES
            // have outbound sync, so only hide when actively hosting.
            visible: (SettingsContext ctx) => !_isHostingInterconnect(ctx),
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
          // 「上传X文件」三个开关都是 OUTBOUND：把本机资产推给已解析的后端。互联
          // host（本机在做服务端）没有任何 outbound sync——client 从它拉取/往它推，
          // 它自己不上传（auto_sync 同理已隐藏）。故 host 模式下这三个上传开关纯空转，
          // 一律随 auto_sync 的 `!_isHostingInterconnect` 门控隐藏（client 模式仍可见，
          // client 确实能往 host 推）。
          SettingsSwitchItem(
            id: 'sync.content',
            title: t.sync_content,
            subtitle: t.sync_content_warning,
            icon: Icons.book_outlined,
            visible: (SettingsContext ctx) => !_isHostingInterconnect(ctx),
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
            visible: (SettingsContext ctx) => !_isHostingInterconnect(ctx),
            value: (SettingsContext ctx) =>
                _syncSettings(ctx).syncAudioBookFiles,
            onChanged: (SettingsContext ctx, bool value) async {
              _syncSettings(ctx).syncAudioBookFiles = value;
              await SyncRepository(ctx.appModel.database)
                  .setSyncAudioBookFilesEnabled(value);
            },
          ),
          // 上传视频文件（多端库联合视图 §2.6）：默认关。云后端走 syncVideoAssets 的
          // `__videos__` 伪装资产（run() 非互联分支）；互联（hibikiServer）走
          // _syncVideosLive 的 host 上传端点（client→host）。两条通道同为 upload-only
          // （host→client 仍按需流式/下载，且与本开关正交——客户端手动浏览/下载远端视频
          // 只看 show_remote_entries，从不受此开关门控）。host 模式无 outbound → 隐藏。
          SettingsSwitchItem(
            id: 'sync.video_files',
            title: t.sync_video_files,
            subtitle: t.sync_video_files_warning,
            icon: Icons.video_file_outlined,
            visible: (SettingsContext ctx) => !_isHostingInterconnect(ctx),
            value: (SettingsContext ctx) => _syncSettings(ctx).syncVideoFiles,
            onChanged: (SettingsContext ctx, bool value) async {
              _syncSettings(ctx).syncVideoFiles = value;
              await SyncRepository(ctx.appModel.database)
                  .setSyncVideoFilesEnabled(value);
            },
          ),
          // 远端占位卡开关抽成共享 builder：同步内容分类与 Hibiki 互联分类共享同一份
          // 定义（占位卡渲染的是互联对端的远端条目，逻辑上属互联，故互联分类也提供）。
          buildShowRemoteEntriesItem(),
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
              // 750a：远端独有书带有声书时一并补下音频包（解包落
              // <appDirectory>/audiobooks，与 host 导入位置一致）。
              audioDatabaseRoot: Directory(
                p.join(ctx.appModel.appDirectory.path, 'audiobooks'),
              ),
            ),
          ),
        ],
      ),
      // ── Group 5: Local backup — independent of sync ──────────────────
      SettingsSection(
        title: t.sync_section_backup,
        collapsedByDefault: true,
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
      // Group 6: Data storage location — desktop only (TODO-935 E2), appended last so the
      // existing five-section index contract above is untouched. 移动端沙箱固定，整个 section 用 isDesktopPlatform 门控隐藏；桌面选新目录后走
      // 已实现的 DataRootMigrator 整目录迁移 + 迁移成功后自动重启。
      SettingsSection(
        title: t.settings_section_data_storage,
        visible: (SettingsContext ctx) => isDesktopPlatform,
        collapsedByDefault: true,
        items: <SettingsItem>[
          SettingsCustomItem(
            id: 'sync.data_storage_location',
            icon: Icons.folder_special_outlined,
            visible: (SettingsContext ctx) => isDesktopPlatform,
            builder: (SettingsContext ctx) =>
                _DataRootWidget(settingsContext: ctx),
          ),
        ],
      ),
    ],
  );
}

/// Hibiki 互联独立一级分类：设备直连（client 连接配置 + LAN 发现）与本机作为
/// 服务器（host 模式）。与 [buildSyncBackupDestination] 同库定义，共享
/// `_syncSettings` 私有状态与全部互联 widget；配置区可见性仍以「互联被选为
/// 同步方式」门控（与拆分前在同步分类内的行为一致，零行为变化），未启用时
/// 只显示一行指引说明去哪里启用。
SettingsDestination buildInterconnectDestination() {
  bool interconnectActive(SettingsContext ctx) =>
      _syncSettings(ctx).interconnectEnabled;
  return SettingsDestination(
    id: SettingsDestinationId.interconnect,
    title: t.settings_destination_interconnect,
    summary: t.interconnect_summary,
    icon: Icons.devices_outlined,
    sections: <SettingsSection>[
      // 互联总开关（独立于云备份后端，二者可并存）。开关常显；关闭时下方配置区隐藏，
      // 副标题说明互联与云同步互不排斥。
      SettingsSection(
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'interconnect.enabled',
            title: t.interconnect_enable,
            subtitle: t.interconnect_enable_hint,
            icon: Icons.hub_outlined,
            value: (SettingsContext ctx) =>
                _syncSettings(ctx).interconnectEnabled,
            onChanged: (SettingsContext ctx, bool value) =>
                _syncSettings(ctx).setInterconnectEnabled(value),
          ),
        ],
      ),
      // 连接到其他设备：client 连接配置（URL/token/配对）+ LAN 自动发现。
      // item id 沿用 'sync.' 前缀（历史命名，非持久化 key，保持稳定便于排查）。
      SettingsSection(
        title: t.interconnect_section_client,
        visible: interconnectActive,
        items: <SettingsItem>[
          SettingsCustomItem(
            id: 'sync.hibiki_server_config',
            icon: Icons.devices_outlined,
            builder: (SettingsContext ctx) =>
                _HibikiServerConfigWidget(settingsContext: ctx),
          ),
          SettingsCustomItem(
            id: 'sync.lan_devices',
            icon: Icons.wifi_find_outlined,
            builder: (SettingsContext ctx) =>
                _LanDiscoveryWidget(settingsContext: ctx),
          ),
        ],
      ),
      // 本机作为服务器：host 模式开关（与 client 角色互斥，见 _SyncSettingsState
      // 的 roleRevision 互斥锁）。
      SettingsSection(
        title: t.sync_section_host_server,
        footer: t.sync_section_host_server_footer,
        visible: interconnectActive,
        items: <SettingsItem>[
          SettingsCustomItem(
            id: 'sync.server_mode',
            icon: Icons.router_outlined,
            builder: (SettingsContext ctx) =>
                _ServerModeWidget(settingsContext: ctx),
          ),
        ],
      ),
      // 互联相关配置镜像：这些项散落在查词/同步分类，但逻辑上都作用于互联对端
      // （远端词典查询直连对端词典、音频来源含互联音频源 hibikiRemote、远端占位卡
      // 渲染对端条目）。在互联分类也提供同一入口，用户配互联时一站式可改（原分类
      // 保留，共享同一 builder 单一真相源，非复制）。与其它互联 section 一致，仅在
      // 互联被选为同步方式时可见。
      SettingsSection(
        title: t.interconnect_section_related,
        visible: interconnectActive,
        items: <SettingsItem>[
          buildRemoteDictionaryLookupItem(),
          buildManageAudioSourcesItem(),
          buildShowRemoteEntriesItem(),
        ],
      ),
    ],
  );
}

/// 远端占位卡开关。同步内容分类与 Hibiki 互联分类共享同一份定义（单一真相源）：
/// 多端库联合视图（spec 2026-07-12 §2.1/§2.4），书架/视频页主网格是否把「远端有、
/// 本地无」的条目渲染成占位卡（云角标 + 远端封面，点击下载/流播）。纯显示偏好
/// （PreferencesRepository），默认开；关闭时占位卡全部不渲染。离线/未配对/后端不可达
/// 时占位卡本就不出现，与本开关正交。id 沿用 `sync.` 前缀（非持久化 key）。
SettingsItem buildShowRemoteEntriesItem() {
  return SettingsSwitchItem(
    id: 'sync.show_remote_entries',
    title: t.sync_show_remote_entries,
    subtitle: t.sync_show_remote_entries_warning,
    icon: Icons.devices_other_outlined,
    value: (SettingsContext ctx) => ctx.appModel.prefsRepo.showRemoteEntries,
    onChanged: (SettingsContext ctx, bool value) async {
      await ctx.appModel.prefsRepo.setShowRemoteEntries(value);
    },
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
/// the persisted host flag AND interconnect being enabled: a stale serverEnabled
/// left over from a past interconnect session must NOT gate manual sync when
/// interconnect is off (observed in the wild: serverEnabled=true while the user
/// only uses a cloud backend, which would otherwise hide sync-now on the cloud).
bool _isHostingInterconnect(SettingsContext ctx) =>
    _syncSettings(ctx).serverEnabled && _syncSettings(ctx).interconnectEnabled;

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

  /// 互联总开关（独立于 [backendType] 云备份后端选择）。为 true 时互联作为一条独立
  /// 通道运行，与云备份并存（不再是互斥的 backendType==hibikiServer 单选）。
  bool interconnectEnabled = false;
  bool autoSync = false;
  bool syncStats = true;
  bool syncDictionary = false;
  bool syncLocalAudio = false;
  bool syncContent = false;
  bool syncAudioBookFiles = false;
  bool syncVideoFiles = false;
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

  /// 切换互联总开关并持久化，随后刷新可见性谓词（互联各 section 门控于此），让开关
  /// 即时生效而非等下次开页。关闭时不清空已配置的对端/host 设置（用户重新打开即恢复）。
  Future<void> setInterconnectEnabled(bool value) async {
    if (interconnectEnabled == value) return;
    interconnectEnabled = value;
    await _repo.setInterconnectEnabled(value);
    _settingsContext.refresh();
  }

  Future<void> load() async {
    if (_loaded || _loading) return;

    _loading = true;
    try {
      backendType = await _repo.getBackendType();
      interconnectEnabled = await _repo.isInterconnectEnabled();
      autoSync = await _repo.isAutoSyncEnabled();
      syncStats = await _repo.isSyncStatsEnabled();
      syncDictionary = await _repo.isSyncDictionaryEnabled();
      syncLocalAudio = await _repo.isSyncLocalAudioEnabled();
      syncContent = await _repo.isSyncContentEnabled();
      syncAudioBookFiles = await _repo.isSyncAudioBookFilesEnabled();
      syncVideoFiles = await _repo.isSyncVideoFilesEnabled();
      serverEnabled = await _repo.isServerEnabled();
      hasClientConnection = (await _repo.getHibikiClientUrls()).isNotEmpty;
      _loaded = true;
      _settingsContext.refresh();
    } finally {
      _loading = false;
    }
  }
}
