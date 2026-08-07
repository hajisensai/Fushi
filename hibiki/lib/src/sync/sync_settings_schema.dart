import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipboard/clipboard.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_exit_app/flutter_exit_app.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/migration_page.dart';
import 'package:fushi/src/pages/implementations/migration_import_page.dart';
import 'package:fushi/src/migration/migration_target_channel.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_lookup.dart'
    show buildManageAudioSourcesItem, buildRemoteDictionaryLookupItem;
import 'package:fushi/src/startup/media_handle_registry.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/data_root_migrator.dart';
import 'package:fushi/src/storage/macos_data_root_access.dart';
import 'package:fushi/src/sync/backup_merge_engine.dart'
    show BackupMergePreview;
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/dropbox_sync_backend.dart';
import 'package:fushi/src/sync/ftp_sync_backend.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/interconnect_device_name.dart';
import 'package:fushi/src/sync/interconnect_url.dart';
import 'package:fushi/src/sync/onedrive_sync_backend.dart';
import 'package:fushi/src/sync/hibiki_server_controller.dart';
import 'package:fushi/src/sync/hibiki_sync_server.dart';
import 'package:fushi/src/sync/lan_discovery_service.dart';
import 'package:fushi/src/sync/manual_sync_ui.dart';
import 'package:fushi/src/sync/pairing/hibiki_pair_v2_client.dart';
import 'package:fushi/src/sync/pairing/hibiki_ping_client.dart';
import 'package:fushi/src/sync/pairing/discovered_pairing_probe.dart';
import 'package:fushi/src/sync/sftp_sync_backend.dart';
import 'package:fushi/src/sync/tls/hibiki_tofu_probe.dart';
import 'package:fushi/src/sync/sync_activity.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_compare_dialog.dart';
import 'package:fushi/src/sync/sync_error_messages.dart';
import 'package:fushi/src/sync/sync_progress.dart';
import 'package:fushi/src/sync/sync_message_dialog.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/webdav_ops.dart';
import 'package:fushi/src/sync/webdav_sync_backend.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_platform/fushi_platform.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:fushi/src/utils/misc/hibiki_share.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';

/// [summarizeSyncReport] 的实现搬去了 manual_sync_ui.dart（媒体页下拉同步共用），
/// 这里再导出一次以保持既有导入点（test/sync/sync_summary_test.dart）不变。
export 'package:fushi/src/sync/manual_sync_ui.dart' show summarizeSyncReport;

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
          // 「与 Hoshi/ッツ 共享 Google Drive」开关：仅 Google Drive 后端可见。开启后
          // Drive 同步改用可见 My Drive / ttu-reader-data + 完整 drive scope，与
          // Hoshi-Reader-Android / ッツ ebook-reader 落进同一云文件夹互相读写进度
          // （[GoogleDriveSyncSpace]）。切换即换 scope（consent 时固定），必须登出重授权。
          SettingsSwitchItem(
            id: 'sync.google_drive_hoshi_compat',
            title: t.sync_google_drive_hoshi_compat,
            subtitle: t.sync_google_drive_hoshi_compat_desc,
            icon: Icons.share_outlined,
            visible: (SettingsContext ctx) =>
                _syncSettings(ctx).backendType == SyncBackendType.googleDrive,
            value: (SettingsContext ctx) =>
                _syncSettings(ctx).googleDriveHoshiCompat,
            onChanged: (SettingsContext ctx, bool value) async {
              _syncSettings(ctx).googleDriveHoshiCompat = value;
              final SyncRepository repo = SyncRepository(ctx.appModel.database);
              await repo.setGoogleDriveHoshiCompat(value);
              // 换存储空间 = 换 OAuth scope，旧授权覆盖不了新 scope。登出当前 Google
              // 账号并清缓存，让下次登录/同步以新 space 的 scope 重新授权（复用与账号行
              // 登出一致的 signOut + clearCache + clearFolderCache 序列）。
              final SyncBackend backend =
                  resolveSyncBackend(SyncBackendType.googleDrive);
              await backend.signOut(repo: repo);
              backend.clearCache();
              await repo.clearFolderCache();
            },
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
          // 互联被选为同步方式时的指引行（BUG-1088）：连接配置（URL/token/配对/
          // LAN 发现/host 开关）在独立的「Hibiki 互联」分类里，这里只指路不复制。
          SettingsCustomItem(
            id: 'sync.interconnect_config_note',
            icon: Icons.devices_outlined,
            visible: (SettingsContext ctx) =>
                _syncSettings(ctx).backendType == SyncBackendType.hibikiServer,
            builder: (SettingsContext ctx) => AdaptiveSettingsRow(
              title: t.sync_backend_hibiki_server,
              subtitle: t.interconnect_moved_note,
              icon: Icons.devices_outlined,
            ),
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
            // Auto-sync is an OUTBOUND switch: it triggers app-open/background/
            // book-close pushes through the resolved backend. Outbound only
            // vanishes when the selected sync method IS the interconnect and
            // this device is the host (clients pull from / push to it, BUG-084).
            // A cloud backend keeps its outbound regardless of hosting — hiding
            // on host identity alone blanked Google Drive users' toggle
            // (BUG-1088).
            visible: (SettingsContext ctx) => !_cloudOutboundUnavailable(ctx),
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
          // 「上传X文件」三个开关都是 OUTBOUND：把本机资产推给**云备份**后端。BUG-988
          // 起互联通道不再复用这套共享开关——互联的内容上传由「上传到互联对端」分项开关
          // 单独控制（见 buildInterconnectDestination），二者互不牵连。故这三个开关只在
          // 云通道本身没有出站语义时才隐藏：同步方式被选成互联（该通道按互联专属开关
          // 走，共享开关是死开关）。云后端（Google Drive/WebDAV/...）无论本机是否在做
          // 互联 host 都照常出站——旧的 `!_isHostingInterconnect` 门控把 host 设备上的
          // 云盘上传开关整排藏掉，是解耦前遗留的错误特例（BUG-1088）。
          SettingsSwitchItem(
            id: 'sync.content',
            title: t.sync_content,
            subtitle: t.sync_content_warning,
            icon: Icons.book_outlined,
            visible: (SettingsContext ctx) =>
                _syncSettings(ctx).backendType != SyncBackendType.hibikiServer,
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
            visible: (SettingsContext ctx) =>
                _syncSettings(ctx).backendType != SyncBackendType.hibikiServer,
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
          // 只看 show_remote_entries，从不受此开关门控）。可见性同上两个上传开关。
          SettingsSwitchItem(
            id: 'sync.video_files',
            title: t.sync_video_files,
            subtitle: t.sync_video_files_warning,
            icon: Icons.video_file_outlined,
            visible: (SettingsContext ctx) =>
                _syncSettings(ctx).backendType != SyncBackendType.hibikiServer,
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
          // Sync-method-is-interconnect + hosting has no OUTBOUND sync: the host
          // is a passive data source that connected clients pull from / push to,
          // so "sync now" / "compare" would misleadingly say "set up sync
          // first". Hide them for that combination only and explain instead
          // (BUG-084); a cloud backend keeps outbound while hosting (BUG-1088).
          SettingsCustomItem(
            id: 'sync.server_mode_note',
            icon: Icons.router_outlined,
            visible: (SettingsContext ctx) => _cloudOutboundUnavailable(ctx),
            builder: (SettingsContext ctx) => AdaptiveSettingsRow(
              title: t.sync_server_mode_active,
              subtitle: t.sync_server_mode_clients_drive,
              icon: Icons.router_outlined,
            ),
          ),
          SettingsCustomItem(
            id: 'sync.sync_now',
            icon: Icons.sync,
            visible: (SettingsContext ctx) => !_cloudOutboundUnavailable(ctx),
            builder: (SettingsContext ctx) =>
                _SyncNowWidget(settingsContext: ctx),
          ),
          SettingsActionItem(
            id: 'sync.compare',
            title: t.sync_compare,
            icon: Icons.compare_arrows,
            visible: (SettingsContext ctx) => !_cloudOutboundUnavailable(ctx),
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
          // Hibiki→Fushi 跨包名迁移入口（改名迁移计划 P1-3/P2-2）；仅 Android——
          // 桌面端数据目录可直接搬迁，不走导出/导入通道。同一份代码按**运行时
          // 包名**切方向：老包（app.hibiki.reader，过渡版基线）显示导出入口，
          // Fushi 显示导入入口，基线分支无需分叉。
          if (!kIsWeb && Platform.isAndroid)
            SettingsCustomItem(
              id: 'sync.migration_to_fushi',
              icon: Icons.drive_file_move_outlined,
              builder: (SettingsContext ctx) {
                final bool runningAsLegacy =
                    ctx.appModel.packageInfo.packageName == kHibikiPackageName;
                return AdaptiveSettingsRow(
                  title: runningAsLegacy
                      ? t.migration_settings_entry
                      : t.migration_import_entry,
                  subtitle: runningAsLegacy
                      ? t.migration_settings_entry_subtitle
                      : t.migration_import_entry_subtitle,
                  icon: Icons.drive_file_move_outlined,
                  onTap: () => Navigator.of(ctx.context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => runningAsLegacy
                          ? MigrationPage(appModel: ctx.appModel)
                          : MigrationImportPage(appModel: ctx.appModel),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    ],
  );
}

/// 桌面端「数据存储位置」小节（TODO-935 E2）。历史上挂在同步备份大类尾部，
/// 2026-07-26 用户拍板挪到「系统」大类展示——数据根是设备级存储配置，与备份无关。
/// 构建函数留在本库（[_DataRootWidget] 是本库私有 part），由
/// `settings_schema_system.dart` 调用；item id 保持 'sync.data_storage_location'
/// 不变（历史命名前缀，搜索/导航锚点，仅换展示分类）。移动端沙箱固定，整个
/// section 用 isDesktopPlatform 门控隐藏；桌面选新目录后走已实现的
/// DataRootMigrator 整目录迁移 + 迁移成功后自动重启。
SettingsSection buildDataStorageLocationSection() {
  return SettingsSection(
    title: t.settings_section_data_storage,
    visible: (SettingsContext ctx) => isDesktopPlatform,
    collapsedByDefault: true,
    items: <SettingsItem>[
      SettingsCustomItem(
        id: 'sync.data_storage_location',
        icon: Icons.folder_special_outlined,
        visible: (SettingsContext ctx) => isDesktopPlatform,
        builder: (SettingsContext ctx) => _DataRootWidget(settingsContext: ctx),
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
      // 副标题说明互联与云同步互不排斥。footer 用一句话讲清角色模型（哪台开服务器、
      // 哪台连接、角色互斥）——此前整页没有任何地方交代这一点，用户面对平铺的
      // client/host 两大区不知道该在哪台设备上动哪个开关。
      SettingsSection(
        footer: t.interconnect_enable_footer,
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
      // BUG-988：上传到互联对端——互联通道专属的「本设备内容要不要上传给对端」分项开关，
      // 独立于云备份的同名开关（那套只管云通道），也独立于上面的「启用互联」连接开关。
      // 默认全关：用户开互联只为远端看/读时不会被自动上传裹挟，想传哪类自己勾。与云备份
      // 上传开关同为 OUTBOUND，host 模式（本机做服务端，client 往它推）无 outbound → 隐藏。
      SettingsSection(
        title: t.interconnect_upload_section,
        footer: t.interconnect_upload_section_footer,
        visible: (SettingsContext ctx) =>
            interconnectActive(ctx) && !_isHostingInterconnect(ctx),
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'interconnect.upload_content',
            title: t.interconnect_upload_content,
            subtitle: t.interconnect_upload_content_hint,
            icon: Icons.book_outlined,
            value: (SettingsContext ctx) =>
                _syncSettings(ctx).interconnectSyncContent,
            onChanged: (SettingsContext ctx, bool value) async {
              _syncSettings(ctx).interconnectSyncContent = value;
              await SyncRepository(ctx.appModel.database)
                  .setInterconnectSyncContentEnabled(value);
            },
          ),
          SettingsSwitchItem(
            id: 'interconnect.upload_dictionary',
            title: t.interconnect_upload_dictionary,
            subtitle: t.interconnect_upload_dictionary_hint,
            icon: Icons.menu_book_outlined,
            value: (SettingsContext ctx) =>
                _syncSettings(ctx).interconnectSyncDictionary,
            onChanged: (SettingsContext ctx, bool value) async {
              _syncSettings(ctx).interconnectSyncDictionary = value;
              await SyncRepository(ctx.appModel.database)
                  .setInterconnectSyncDictionaryEnabled(value);
            },
          ),
          SettingsSwitchItem(
            id: 'interconnect.upload_audiobook_files',
            title: t.interconnect_upload_audiobook_files,
            subtitle: t.interconnect_upload_audiobook_files_hint,
            icon: Icons.audio_file_outlined,
            value: (SettingsContext ctx) =>
                _syncSettings(ctx).interconnectSyncAudioBookFiles,
            onChanged: (SettingsContext ctx, bool value) async {
              _syncSettings(ctx).interconnectSyncAudioBookFiles = value;
              await SyncRepository(ctx.appModel.database)
                  .setInterconnectSyncAudioBookFilesEnabled(value);
            },
          ),
          SettingsSwitchItem(
            id: 'interconnect.upload_video_files',
            title: t.interconnect_upload_video_files,
            subtitle: t.interconnect_upload_video_files_hint,
            icon: Icons.video_file_outlined,
            value: (SettingsContext ctx) =>
                _syncSettings(ctx).interconnectSyncVideoFiles,
            onChanged: (SettingsContext ctx, bool value) async {
              _syncSettings(ctx).interconnectSyncVideoFiles = value;
              await SyncRepository(ctx.appModel.database)
                  .setInterconnectSyncVideoFilesEnabled(value);
            },
          ),
        ],
      ),
      // 交给已配对设备：本机把某类工作整个甩给对端主机去做。两项都只有 client 角色
      // 讲得通（host 没有「对端」可交），故与上面的上传区同门控——互联启用且本机不在
      // host 模式。
      //   · 制卡到已配对设备：制卡改由主机的 Anki 落卡（原在「制卡」分类，但它的前置
      //     条件、目标设备、失效条件全由互联决定，互联关掉时在制卡页是个纯死开关）。
      //   · 用互联做备份后端：把云备份通道也指向对端（详见 _InterconnectBackupBackendWidget）。
      SettingsSection(
        title: t.interconnect_section_delegate,
        visible: (SettingsContext ctx) =>
            interconnectActive(ctx) && !_isHostingInterconnect(ctx),
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'interconnect.mine_to_server',
            title: t.anki_mine_to_server,
            subtitle: t.anki_mine_to_server_hint,
            icon: Icons.note_add_outlined,
            value: (SettingsContext ctx) => ctx.appModel.mineToServerEnabled,
            onChanged: (SettingsContext ctx, bool value) =>
                ctx.appModel.setMineToServer(value),
          ),
          SettingsCustomItem(
            id: 'interconnect.backup_backend',
            icon: Icons.backup_outlined,
            builder: (SettingsContext ctx) =>
                _InterconnectBackupBackendWidget(settingsContext: ctx),
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

/// 云备份通道此刻是否真的没有出站同步（BUG-1088）：仅当「同步方式」本身选的是互联、
/// 且本机正在做互联 host——host 是被动数据源，client 从它拉/往它推，它自己无出站
/// （BUG-084）。云后端（Google Drive/WebDAV/...）的出站与互联 host 身份无关：host
/// 设备照样往云盘备份。旧门控只看 host 身份，把云通道的上传开关、自动同步、立即
/// 同步整排藏掉，是互联还与云备份互斥时代遗留的错误特例。
bool _cloudOutboundUnavailable(SettingsContext ctx) =>
    _syncSettings(ctx).backendType == SyncBackendType.hibikiServer &&
    _isHostingInterconnect(ctx);

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

  /// 「与 Hoshi/ッツ 共享 Google Drive」开关（仅 Google Drive 后端有效）。
  bool googleDriveHoshiCompat = false;

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
  // BUG-988：互联通道专属的「上传内容到对端」开关，独立于上面的云备份 sync* 开关。
  bool interconnectSyncContent = false;
  bool interconnectSyncDictionary = false;
  bool interconnectSyncAudioBookFiles = false;
  bool interconnectSyncVideoFiles = false;
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
      googleDriveHoshiCompat = await _repo.isGoogleDriveHoshiCompat();
      interconnectEnabled = await _repo.isInterconnectEnabled();
      autoSync = await _repo.isAutoSyncEnabled();
      syncStats = await _repo.isSyncStatsEnabled();
      syncDictionary = await _repo.isSyncDictionaryEnabled();
      syncLocalAudio = await _repo.isSyncLocalAudioEnabled();
      syncContent = await _repo.isSyncContentEnabled();
      syncAudioBookFiles = await _repo.isSyncAudioBookFilesEnabled();
      syncVideoFiles = await _repo.isSyncVideoFilesEnabled();
      interconnectSyncContent = await _repo.isInterconnectSyncContentEnabled();
      interconnectSyncDictionary =
          await _repo.isInterconnectSyncDictionaryEnabled();
      interconnectSyncAudioBookFiles =
          await _repo.isInterconnectSyncAudioBookFilesEnabled();
      interconnectSyncVideoFiles =
          await _repo.isInterconnectSyncVideoFilesEnabled();
      serverEnabled = await _repo.isServerEnabled();
      hasClientConnection = (await _repo.getHibikiClientUrls()).isNotEmpty;
      _loaded = true;
      _settingsContext.refresh();
    } finally {
      _loading = false;
    }
  }
}
