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
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/lan_discovery_service.dart';
import 'package:hibiki/src/sync/sftp_sync_backend.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_compare_dialog.dart';
import 'package:hibiki/src/sync/sync_error_messages.dart';
import 'package:hibiki/src/sync/sync_message_dialog.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/webdav_sync_backend.dart';
import 'package:hibiki/utils.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

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
            id: 'sync.audiobook',
            title: t.sync_audiobook,
            icon: Icons.headphones_outlined,
            value: (SettingsContext ctx) => _syncSettings(ctx).syncAudioBook,
            onChanged: (SettingsContext ctx, bool value) async {
              _syncSettings(ctx).syncAudioBook = value;
              await SyncRepository(ctx.appModel.database)
                  .setSyncAudioBookEnabled(value);
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
        ],
      ),
      // ── Group 4: Manual sync actions — global ────────────────────────
      SettingsSection(
        title: t.sync_section_actions,
        items: <SettingsItem>[
          SettingsActionItem(
            id: 'sync.compare',
            title: t.sync_compare,
            icon: Icons.compare_arrows,
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

// ── Sync account widget ──────────────────────────────────────────────

class _SyncAccountWidget extends StatefulWidget {
  const _SyncAccountWidget({required this.settingsContext});
  final SettingsContext settingsContext;

  @override
  State<_SyncAccountWidget> createState() => _SyncAccountWidgetState();
}

class _SyncAccountWidgetState extends State<_SyncAccountWidget> {
  bool _isAuthenticated = false;
  bool _isLoading = false;
  bool _initialCheckDone = false;
  String? _email;
  SyncBackend? _backend;

  @override
  void initState() {
    super.initState();
    _checkAuth();
  }

  Future<SyncBackend> _resolveBackend() async {
    final repo = SyncRepository(widget.settingsContext.appModel.database);
    final currentType = await repo.getBackendType();
    final expected = resolveSyncBackend(currentType);
    if (_backend != null && _backend == expected) return _backend!;
    _backend = expected;
    return _backend!;
  }

  Future<void> _checkAuth() async {
    try {
      final backend = await _resolveBackend();
      final repo = SyncRepository(widget.settingsContext.appModel.database);
      await backend.restoreAuth(repo);

      final authed = await backend.isAuthenticated;
      final email = authed ? await backend.currentEmail : null;
      if (mounted) {
        setState(() {
          _isAuthenticated = authed;
          _email = email;
        });
      }
    } catch (e, stack) {
      // Don't silently show "not signed in" on a transient check failure —
      // record it so the cause is diagnosable (HBK-AUDIT-163).
      ErrorLogService.instance.log('SyncAccount.checkAuth', e, stack);
    } finally {
      if (mounted) setState(() => _initialCheckDone = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialCheckDone) {
      return AdaptiveSettingsRow(
        title: t.sync_account,
        subtitle: t.sync_checking_account,
        icon: Icons.account_circle_outlined,
        controlBelow: true,
        trailing: SizedBox(
          width: 24,
          height: 24,
          child: adaptiveIndicator(context: context, strokeWidth: 2),
        ),
      );
    }

    final String subtitle =
        _isAuthenticated ? t.sync_signed_in : t.sync_not_signed_in;

    if (_isAuthenticated) {
      return AdaptiveSettingsRow(
        title: _email ?? t.sync_signed_in,
        subtitle: subtitle,
        icon: Icons.check_circle_outline,
        controlBelow: true,
        trailing: _signOutButton(context),
      );
    }

    return AdaptiveSettingsRow(
      title: t.sync_account,
      subtitle: subtitle,
      icon: Icons.account_circle_outlined,
      controlBelow: true,
      trailing: _signInButton(context),
    );
  }

  Widget _signInButton(BuildContext context) {
    final Widget progress = adaptiveIndicator(context: context, strokeWidth: 2);
    if (isCupertinoPlatform(context)) {
      return CupertinoButton.filled(
        minSize: 32,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        onPressed: _isLoading ? null : _signIn,
        child: _isLoading ? progress : Text(t.sync_sign_in),
      );
    }
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: _isLoading ? null : _signIn,
      icon: _isLoading
          ? SizedBox(width: 16, height: 16, child: progress)
          : const Icon(Icons.login),
      label: Text(t.sync_sign_in),
    );
  }

  Widget _signOutButton(BuildContext context) {
    if (isCupertinoPlatform(context)) {
      return CupertinoButton(
        padding: EdgeInsets.zero,
        minSize: 32,
        onPressed: _isLoading ? null : _signOut,
        child: Text(t.sync_sign_out),
      );
    }
    return TextButton(
      style: TextButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: _isLoading ? null : _signOut,
      child: Text(t.sync_sign_out),
    );
  }

  Future<void> _signIn() async {
    setState(() => _isLoading = true);
    try {
      final backend = await _resolveBackend();
      final repo = SyncRepository(widget.settingsContext.appModel.database);
      await backend.authenticate(repo: repo);
      await _checkAuth();
    } on SyncAuthError catch (e) {
      if (mounted) {
        _showSnackBar(
            context, t.sync_auth_error(message: friendlySyncErrorDetail(e)));
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar(context, friendlySyncError(e));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _signOut() async {
    setState(() => _isLoading = true);
    try {
      final backend = await _resolveBackend();
      final repo = SyncRepository(widget.settingsContext.appModel.database);
      await backend.signOut(repo: repo);
      backend.clearCache();
      await repo.clearFolderCache();
      _backend = null;
      await _checkAuth();
    } catch (e) {
      if (mounted) {
        _showSnackBar(context, friendlySyncError(e));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }
}

// ── WebDAV config widget ─────────────────────────────────────────────

class _WebDavConfigWidget extends StatefulWidget {
  const _WebDavConfigWidget({required this.settingsContext});
  final SettingsContext settingsContext;

  @override
  State<_WebDavConfigWidget> createState() => _WebDavConfigWidgetState();
}

class _WebDavConfigWidgetState extends State<_WebDavConfigWidget> {
  late final TextEditingController _urlController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  bool _isTesting = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController();
    _usernameController = TextEditingController();
    _passwordController = TextEditingController();
    _loadCredentials();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _loadCredentials() async {
    final repo = SyncRepository(widget.settingsContext.appModel.database);
    final url = await repo.getWebDavUrl();
    final username = await repo.getWebDavUsername();
    final password = await repo.getWebDavPassword();
    if (mounted) {
      setState(() {
        _urlController.text = url ?? '';
        _usernameController.text = username ?? '';
        _passwordController.text = password ?? '';
        _loaded = true;
      });
    }
  }

  Future<void> _saveCredentials() async {
    // Called fire-and-forget from onChanged; log write failures so they are
    // not silently dropped (HBK-AUDIT-162).
    try {
      final repo = SyncRepository(widget.settingsContext.appModel.database);
      final url = _urlController.text.trim();
      final username = _usernameController.text.trim();
      final password = _passwordController.text;
      await repo.setWebDavUrl(url.isEmpty ? null : url);
      await repo.setWebDavUsername(username.isEmpty ? null : username);
      await repo.setWebDavPassword(password.isEmpty ? null : password);
    } catch (e, stack) {
      ErrorLogService.instance.log('SyncConfig.saveWebDav', e, stack);
    }
  }

  Future<void> _testConnection() async {
    await _saveCredentials();
    setState(() => _isTesting = true);
    try {
      final url = _urlController.text.trim();
      final username = _usernameController.text.trim();
      final password = _passwordController.text;
      if (url.isEmpty || username.isEmpty || password.isEmpty) {
        if (mounted) {
          _showSnackBar(
              context, t.sync_webdav_test_failed(message: 'Missing fields'));
        }
        return;
      }
      await WebDavSyncBackend.instance.testConnection(
        url: url,
        username: username,
        password: password,
      );
      if (mounted) _showSnackBar(context, t.sync_webdav_test_success);
    } on SyncAuthError catch (e) {
      if (mounted) {
        _showSnackBar(context,
            t.sync_webdav_test_failed(message: friendlySyncErrorDetail(e)));
      }
    } on SyncBackendError catch (e) {
      if (mounted) {
        _showSnackBar(context,
            t.sync_webdav_test_failed(message: friendlySyncErrorDetail(e)));
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar(context,
            t.sync_webdav_test_failed(message: friendlySyncErrorDetail(e)));
      }
    } finally {
      if (mounted) setState(() => _isTesting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          HibikiTextField(
            controller: _urlController,
            labelText: t.sync_webdav_url,
            hintText: 'https://cloud.example.com/remote.php/dav/files/user',
            keyboardType: TextInputType.url,
            onChanged: (_) => _saveCredentials(),
          ),
          const SizedBox(height: 12),
          HibikiTextField(
            controller: _usernameController,
            labelText: t.sync_webdav_username,
            onChanged: (_) => _saveCredentials(),
          ),
          const SizedBox(height: 12),
          HibikiTextField(
            controller: _passwordController,
            labelText: t.sync_webdav_password,
            obscureText: true,
            onChanged: (_) => _saveCredentials(),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: _isTesting
                ? SizedBox(
                    width: 24,
                    height: 24,
                    child: adaptiveIndicator(context: context, strokeWidth: 2),
                  )
                : FilledButton.tonal(
                    onPressed: _testConnection,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        const Icon(Icons.wifi_find, size: 18),
                        const SizedBox(width: 8),
                        Text(t.sync_webdav_test),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

// ── Backup export widget ─────────────────────────────────────────────

class _BackupExportWidget extends StatefulWidget {
  const _BackupExportWidget({required this.settingsContext});
  final SettingsContext settingsContext;

  @override
  State<_BackupExportWidget> createState() => _BackupExportWidgetState();
}

class _BackupExportWidgetState extends State<_BackupExportWidget> {
  bool _isExporting = false;

  Future<void> _export() async {
    setState(() => _isExporting = true);
    try {
      final appModel = widget.settingsContext.appModel;
      final service = BackupService(
        db: appModel.database,
        dbDirectory: appModel.databaseDirectory.path,
        dictionaryResourceDirectory: appModel.dictionaryResourceDirectory.path,
        appVersion: appModel.packageInfo.version,
      );

      final tmpDir = await getTemporaryDirectory();
      final filename = service.defaultFilename();
      final tmpPath = p.join(tmpDir.path, filename);
      await service.exportBackup(tmpPath);

      if (!mounted) return;

      if (Platform.isAndroid || Platform.isIOS) {
        await Share.shareXFiles(
          [XFile(tmpPath, mimeType: 'application/zip')],
          subject: filename,
        );
      } else {
        final savePath = await FilePicker.platform.saveFile(
          dialogTitle: t.backup_export,
          fileName: filename,
          type: FileType.custom,
          allowedExtensions: ['zip'],
        );
        if (savePath != null) {
          await File(tmpPath).copy(savePath);
        }
        await File(tmpPath).delete();
      }

      if (mounted) {
        _showSnackBar(context, t.backup_export_success);
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar(context,
            t.backup_export_failed(message: friendlySyncErrorDetail(e)));
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsRow(
      title: t.backup_export,
      subtitle: t.backup_export_hint,
      icon: Icons.upload_file_outlined,
      controlBelow: true,
      trailing: _isExporting
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox(
                  width: 20,
                  height: 20,
                  child: adaptiveIndicator(context: context, strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(t.backup_exporting),
              ],
            )
          : FilledButton.tonal(
              onPressed: _export,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.upload_file_outlined, size: 18),
                  const SizedBox(width: 8),
                  Text(t.backup_export),
                ],
              ),
            ),
    );
  }
}

// ── Backup import widget ─────────────────────────────────────────────

class _BackupImportWidget extends StatefulWidget {
  const _BackupImportWidget({required this.settingsContext});
  final SettingsContext settingsContext;

  @override
  State<_BackupImportWidget> createState() => _BackupImportWidgetState();
}

class _BackupImportWidgetState extends State<_BackupImportWidget> {
  bool _isImporting = false;

  Future<void> _import() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    if (result == null || result.files.single.path == null) return;
    if (!mounted) return;

    setState(() => _isImporting = true);
    try {
      final filePath = result.files.single.path!;
      final appModel = widget.settingsContext.appModel;
      final service = BackupService(
        db: appModel.database,
        dbDirectory: appModel.databaseDirectory.path,
        dictionaryResourceDirectory: appModel.dictionaryResourceDirectory.path,
        appVersion: appModel.packageInfo.version,
      );

      final meta = await service.validateBackup(filePath);
      if (meta == null) {
        if (mounted) _showSnackBar(context, t.backup_import_invalid);
        return;
      }

      if (meta.schemaVersion > appModel.database.schemaVersion) {
        if (mounted) {
          _showSnackBar(
            context,
            t.backup_schema_newer(version: meta.schemaVersion.toString()),
          );
        }
        return;
      }

      if (!mounted) return;

      final bool? importSettings = await _showConfirmDialog(meta);
      if (importSettings == null || !mounted) return;

      await appModel.closeDatabase();
      await BackupService.importBackupFiles(
        dbDirectory: appModel.databaseDirectory.path,
        zipPath: filePath,
        importSettings: importSettings,
        dictionaryResourceDirectory: appModel.dictionaryResourceDirectory.path,
      );

      if (mounted) {
        _showSnackBar(context, t.backup_import_success);
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (Platform.isAndroid || Platform.isIOS) {
        FlutterExitApp.exitApp();
      } else {
        exit(0);
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar(context,
            t.backup_import_failed(message: friendlySyncErrorDetail(e)));
      }
      // DB is already closed — must exit regardless to avoid dead state.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (Platform.isAndroid || Platform.isIOS) {
        FlutterExitApp.exitApp();
      } else {
        exit(0);
      }
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  /// Returns the chosen import mode: `false` = keep this device's settings &
  /// profiles and restore only content (default); `true` = full restore.
  /// Returns `null` if the user cancels.
  Future<bool?> _showConfirmDialog(BackupMeta meta) async {
    final dateStr =
        '${meta.createdAt.year}-${meta.createdAt.month.toString().padLeft(2, '0')}-${meta.createdAt.day.toString().padLeft(2, '0')}';
    bool importSettings = false; // default: keep this device's settings
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setLocal) {
          final HibikiDesignTokens tokens = HibikiDesignTokens.of(ctx);
          return HibikiDialogFrame(
            maxWidth: 420,
            insetPadding: EdgeInsets.symmetric(
              horizontal: tokens.spacing.card,
              vertical: tokens.spacing.card,
            ),
            scrollable: false,
            child: HibikiModalSheetFrame(
              title: t.backup_import_confirm_title,
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
                    t.backup_import_confirm(
                      date: dateStr,
                      bookCount: meta.bookCount.toString(),
                      statsCount: meta.statsCount.toString(),
                    ),
                  ),
                  const SizedBox(height: 4),
                  AdaptiveSettingsSwitchRow(
                    title: t.backup_import_settings_toggle,
                    subtitle: importSettings
                        ? t.backup_import_settings_on_hint
                        : t.backup_import_settings_off_hint,
                    value: importSettings,
                    onChanged: (bool v) => setLocal(() => importSettings = v),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    t.backup_import_preserve_sync_note,
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ],
              ),
              footer: Wrap(
                alignment: WrapAlignment.end,
                spacing: tokens.spacing.gap,
                children: <Widget>[
                  adaptiveDialogAction(
                    context: ctx,
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(t.dialog_cancel),
                  ),
                  adaptiveDialogAction(
                    context: ctx,
                    isDefaultAction: true,
                    isDestructiveAction: true,
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(t.dialog_ok),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    return confirmed == true ? importSettings : null;
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsRow(
      title: t.backup_import,
      subtitle: t.backup_import_hint,
      icon: Icons.download_outlined,
      controlBelow: true,
      trailing: _isImporting
          ? SizedBox(
              width: 24,
              height: 24,
              child: adaptiveIndicator(context: context, strokeWidth: 2),
            )
          : FilledButton.tonal(
              onPressed: _import,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.download_outlined, size: 18),
                  const SizedBox(width: 8),
                  Text(t.backup_import),
                ],
              ),
            ),
    );
  }
}

/// OAuth backends ship with placeholder client IDs until real credentials
/// are configured. Hide those from the picker so users never select a
/// backend that can only ever fail with "not configured". A backend
/// re-appears automatically once its client ID is filled in.
bool _isBackendSelectable(SyncBackendType type) {
  switch (type) {
    case SyncBackendType.oneDrive:
      return OneDriveSyncBackend.isConfigured;
    case SyncBackendType.dropbox:
      return DropboxSyncBackend.isConfigured;
    case SyncBackendType.googleDrive:
    case SyncBackendType.webDav:
    case SyncBackendType.ftp:
    case SyncBackendType.sftp:
    case SyncBackendType.hibikiServer:
      return true;
  }
}

/// OAuth cloud backends authenticate via a browser sign-in (handled by the
/// account row) rather than an inline credential box. Drives whether the
/// account/sign-in row appears in the sync-method group.
@visibleForTesting
bool isOAuthSyncBackend(SyncBackendType type) =>
    type == SyncBackendType.googleDrive ||
    type == SyncBackendType.oneDrive ||
    type == SyncBackendType.dropbox;

/// Backends shown in the picker: all selectable ones, plus [current] if a
/// previously-persisted value would otherwise be filtered out (DropdownButton
/// requires its value to be present in its items).
List<SyncBackendType> _selectableBackends(SyncBackendType current) {
  final list = SyncBackendType.values.where(_isBackendSelectable).toList();
  if (!list.contains(current)) list.insert(0, current);
  return list;
}

String _backendLabel(SyncBackendType type) {
  switch (type) {
    case SyncBackendType.googleDrive:
      return t.sync_backend_google_drive;
    case SyncBackendType.hibikiServer:
      return t.sync_backend_hibiki_server;
    case SyncBackendType.webDav:
      return t.sync_backend_webdav;
    case SyncBackendType.oneDrive:
      return t.sync_backend_onedrive;
    case SyncBackendType.dropbox:
      return t.sync_backend_dropbox;
    case SyncBackendType.ftp:
      return t.sync_backend_ftp;
    case SyncBackendType.sftp:
      return t.sync_backend_sftp;
  }
}

// ── Backend selector dropdown ───────────────────────────────────────

class _BackendSelectorWidget extends StatefulWidget {
  const _BackendSelectorWidget({required this.settingsContext});
  final SettingsContext settingsContext;

  @override
  State<_BackendSelectorWidget> createState() => _BackendSelectorWidgetState();
}

class _BackendSelectorWidgetState extends State<_BackendSelectorWidget> {
  @override
  void initState() {
    super.initState();
    // HBK-AUDIT-044: 仅触发按 AppModel 缓存的状态创建/加载；不再独占其生命周期，
    // 也不在 dispose 时置 null（避免 dispose→重建窗口里回退硬编码默认值）。
    _syncSettings(widget.settingsContext);
  }

  @override
  Widget build(BuildContext context) {
    final state = _syncSettings(widget.settingsContext);
    return AdaptiveSettingsPickerRow<SyncBackendType>(
      title: t.sync_backend,
      icon: Icons.cloud_outlined,
      selected: state.backendType,
      options: _selectableBackends(state.backendType)
          .map(
            (SyncBackendType type) =>
                AdaptiveSettingsPickerOption<SyncBackendType>(
              value: type,
              label: _backendLabel(type),
            ),
          )
          .toList(growable: false),
      controlBelow: true,
      materialWidth: double.infinity,
      onChanged: _selectBackend,
    );
  }

  Future<void> _selectBackend(SyncBackendType value) async {
    final _SyncSettingsState state = _syncSettings(widget.settingsContext);
    final SyncBackendType previous = state.backendType;
    if (value == previous) return;
    state.backendType = value;
    final SyncRepository repo =
        SyncRepository(widget.settingsContext.appModel.database);
    await repo.setBackendType(value);
    await repo.clearFolderCache();
    // The TLS flag is FTP-only; don't let it linger after switching away.
    if (previous == SyncBackendType.ftp && value != SyncBackendType.ftp) {
      await repo.setFtpTlsEnabled(false);
    }
    widget.settingsContext.refresh();
  }
}

// ── FTP config widget ───────────────────────────────────────────────

class _FtpConfigWidget extends StatefulWidget {
  const _FtpConfigWidget({required this.settingsContext});
  final SettingsContext settingsContext;

  @override
  State<_FtpConfigWidget> createState() => _FtpConfigWidgetState();
}

class _FtpConfigWidgetState extends State<_FtpConfigWidget> {
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  bool _useTls = false;
  bool _isTesting = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _hostController = TextEditingController();
    _portController = TextEditingController(text: '21');
    _usernameController = TextEditingController();
    _passwordController = TextEditingController();
    _loadCredentials();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _loadCredentials() async {
    final repo = SyncRepository(widget.settingsContext.appModel.database);
    final host = await repo.getFtpHost();
    final port = await repo.getFtpPort();
    final user = await repo.getFtpUsername();
    final pass = await repo.getFtpPassword();
    final tls = await repo.isFtpTlsEnabled();
    if (mounted) {
      setState(() {
        _hostController.text = host ?? '';
        _portController.text = port.toString();
        _usernameController.text = user ?? '';
        _passwordController.text = pass ?? '';
        _useTls = tls;
        _loaded = true;
      });
    }
  }

  Future<void> _saveCredentials() async {
    try {
      final repo = SyncRepository(widget.settingsContext.appModel.database);
      final host = _hostController.text.trim();
      final user = _usernameController.text.trim();
      final pass = _passwordController.text;
      final port = int.tryParse(_portController.text.trim()) ?? 21;
      await repo.setFtpHost(host.isEmpty ? null : host);
      await repo.setFtpPort(port);
      await repo.setFtpUsername(user.isEmpty ? null : user);
      await repo.setFtpPassword(pass.isEmpty ? null : pass);
      await repo.setFtpTlsEnabled(_useTls);
    } catch (e, stack) {
      ErrorLogService.instance.log('SyncConfig.saveFtp', e, stack);
    }
  }

  Future<void> _testConnection() async {
    await _saveCredentials();
    setState(() => _isTesting = true);
    try {
      await FtpSyncBackend.testConnection(
        host: _hostController.text.trim(),
        port: int.tryParse(_portController.text.trim()) ?? 21,
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        useTls: _useTls,
      );
      if (mounted) _showSnackBar(context, t.sync_connection_success);
    } catch (e) {
      if (mounted) {
        _showSnackBar(context,
            '${t.sync_connection_failed}: ${friendlySyncErrorDetail(e)}');
      }
    } finally {
      if (mounted) setState(() => _isTesting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          HibikiTextField(
            controller: _hostController,
            labelText: t.sync_host,
            hintText: 'ftp.example.com',
            onChanged: (_) => _saveCredentials(),
          ),
          const SizedBox(height: 12),
          HibikiTextField(
            controller: _portController,
            labelText: t.sync_port,
            keyboardType: TextInputType.number,
            onChanged: (_) => _saveCredentials(),
          ),
          const SizedBox(height: 12),
          HibikiTextField(
            controller: _usernameController,
            labelText: t.sync_username,
            onChanged: (_) => _saveCredentials(),
          ),
          const SizedBox(height: 12),
          HibikiTextField(
            controller: _passwordController,
            labelText: t.sync_password,
            obscureText: true,
            onChanged: (_) => _saveCredentials(),
          ),
          const SizedBox(height: 8),
          AdaptiveSettingsSwitchRow(
            title: t.sync_use_tls,
            value: _useTls,
            onChanged: (bool v) {
              setState(() => _useTls = v);
              _saveCredentials();
            },
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: _isTesting
                ? SizedBox(
                    width: 24,
                    height: 24,
                    child: adaptiveIndicator(context: context, strokeWidth: 2),
                  )
                : FilledButton.tonal(
                    onPressed: _testConnection,
                    child: Text(t.sync_test_connection),
                  ),
          ),
        ],
      ),
    );
  }
}

// ── SFTP config widget ──────────────────────────────────────────────

class _SftpConfigWidget extends StatefulWidget {
  const _SftpConfigWidget({required this.settingsContext});
  final SettingsContext settingsContext;

  @override
  State<_SftpConfigWidget> createState() => _SftpConfigWidgetState();
}

class _SftpConfigWidgetState extends State<_SftpConfigWidget> {
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late final TextEditingController _keyController;
  bool _isTesting = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _hostController = TextEditingController();
    _portController = TextEditingController(text: '22');
    _usernameController = TextEditingController();
    _passwordController = TextEditingController();
    _keyController = TextEditingController();
    _loadCredentials();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _loadCredentials() async {
    final repo = SyncRepository(widget.settingsContext.appModel.database);
    final host = await repo.getSftpHost();
    final port = await repo.getSftpPort();
    final user = await repo.getSftpUsername();
    final pass = await repo.getSftpPassword();
    final key = await repo.getSftpPrivateKey();
    if (mounted) {
      setState(() {
        _hostController.text = host ?? '';
        _portController.text = port.toString();
        _usernameController.text = user ?? '';
        _passwordController.text = pass ?? '';
        _keyController.text = key ?? '';
        _loaded = true;
      });
    }
  }

  Future<void> _saveCredentials() async {
    try {
      final repo = SyncRepository(widget.settingsContext.appModel.database);
      final host = _hostController.text.trim();
      final user = _usernameController.text.trim();
      final pass = _passwordController.text;
      final port = int.tryParse(_portController.text.trim()) ?? 22;
      final key = _keyController.text.trim();
      await repo.setSftpHost(host.isEmpty ? null : host);
      await repo.setSftpPort(port);
      await repo.setSftpUsername(user.isEmpty ? null : user);
      await repo.setSftpPassword(pass.isEmpty ? null : pass);
      await repo.setSftpPrivateKey(key.isEmpty ? null : key);
    } catch (e, stack) {
      ErrorLogService.instance.log('SyncConfig.saveSftp', e, stack);
    }
  }

  Future<void> _testConnection() async {
    await _saveCredentials();
    setState(() => _isTesting = true);
    try {
      final pass = _passwordController.text;
      final key = _keyController.text.trim();
      await SftpSyncBackend.instance.testConnection(
        host: _hostController.text.trim(),
        port: int.tryParse(_portController.text.trim()) ?? 22,
        username: _usernameController.text.trim(),
        password: pass.isEmpty ? null : pass,
        privateKey: key.isEmpty ? null : key,
      );
      if (mounted) _showSnackBar(context, t.sync_connection_success);
    } catch (e) {
      if (mounted) {
        _showSnackBar(context,
            '${t.sync_connection_failed}: ${friendlySyncErrorDetail(e)}');
      }
    } finally {
      if (mounted) setState(() => _isTesting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          HibikiTextField(
            controller: _hostController,
            labelText: t.sync_host,
            hintText: 'ssh.example.com',
            onChanged: (_) => _saveCredentials(),
          ),
          const SizedBox(height: 12),
          HibikiTextField(
            controller: _portController,
            labelText: t.sync_port,
            keyboardType: TextInputType.number,
            onChanged: (_) => _saveCredentials(),
          ),
          const SizedBox(height: 12),
          HibikiTextField(
            controller: _usernameController,
            labelText: t.sync_username,
            onChanged: (_) => _saveCredentials(),
          ),
          const SizedBox(height: 12),
          HibikiTextField(
            controller: _passwordController,
            labelText: t.sync_password,
            obscureText: true,
            onChanged: (_) => _saveCredentials(),
          ),
          const SizedBox(height: 12),
          HibikiTextField(
            controller: _keyController,
            labelText: t.sync_private_key,
            hintText: '-----BEGIN OPENSSH PRIVATE KEY-----',
            maxLines: 4,
            onChanged: (_) => _saveCredentials(),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: _isTesting
                ? SizedBox(
                    width: 24,
                    height: 24,
                    child: adaptiveIndicator(context: context, strokeWidth: 2),
                  )
                : FilledButton.tonal(
                    onPressed: _testConnection,
                    child: Text(t.sync_test_connection),
                  ),
          ),
        ],
      ),
    );
  }
}

// ── Hibiki server config widget (connect to another Hibiki instance) ─

class _HibikiServerConfigWidget extends StatefulWidget {
  const _HibikiServerConfigWidget({required this.settingsContext});
  final SettingsContext settingsContext;

  @override
  State<_HibikiServerConfigWidget> createState() =>
      _HibikiServerConfigWidgetState();
}

class _HibikiServerConfigWidgetState extends State<_HibikiServerConfigWidget> {
  late final TextEditingController _tokenController;
  late final FocusNode _tokenFocus;
  List<HibikiClientUrl> _urls = <HibikiClientUrl>[];
  // url -> last test-connection result (null = not tested this session).
  final Map<String, bool> _reachable = <String, bool>{};
  bool _isTesting = false;
  bool _loaded = false;

  SyncRepository get _repo =>
      SyncRepository(widget.settingsContext.appModel.database);

  @override
  void initState() {
    super.initState();
    _tokenController = TextEditingController();
    _tokenFocus = FocusNode();
    _load();
    _syncSettings(widget.settingsContext)
        .clientConfigRevision
        .addListener(_onClientConfigRevision);
    // Rebuild when the server-enabled flag flips so "add connection" re-gates.
    _syncSettings(widget.settingsContext)
        .roleRevision
        .addListener(_onRoleRevision);
  }

  @override
  void dispose() {
    _syncSettings(widget.settingsContext)
        .clientConfigRevision
        .removeListener(_onClientConfigRevision);
    _syncSettings(widget.settingsContext)
        .roleRevision
        .removeListener(_onRoleRevision);
    _tokenFocus.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  void _onRoleRevision() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final List<HibikiClientUrl> urls = await _repo.getHibikiClientUrls();
    final String? token = await _repo.getHibikiClientToken();
    if (!mounted) return;
    setState(() {
      _urls = urls;
      _tokenController.text = token ?? '';
      _loaded = true;
    });
    _syncSettings(widget.settingsContext)
        .setHasClientConnection(urls.isNotEmpty);
  }

  void _onClientConfigRevision() {
    unawaited(_reloadFromStore());
  }

  /// Reload the persisted client config after an external mutation (LAN
  /// pairing). The URL list always reloads; the token field only reloads when
  /// it has no focus, so we never clobber text the user is actively typing.
  Future<void> _reloadFromStore() async {
    final List<HibikiClientUrl> urls = await _repo.getHibikiClientUrls();
    final String? token = await _repo.getHibikiClientToken();
    if (!mounted) return;
    setState(() {
      _urls = urls;
      if (!_tokenFocus.hasFocus) {
        _tokenController.text = token ?? '';
      }
    });
    _syncSettings(widget.settingsContext)
        .setHasClientConnection(urls.isNotEmpty);
  }

  Future<void> _persistUrls() async {
    await _repo.setHibikiClientUrls(_urls);
    // Keep the role lock honest: deleting the last URL must release the server
    // toggle; adding one must lock it. Every URL mutation routes through here.
    _syncSettings(widget.settingsContext)
        .setHasClientConnection(_urls.isNotEmpty);
  }

  Future<void> _saveToken() async {
    try {
      final String token = _tokenController.text.trim();
      await _repo.setHibikiClientToken(token.isEmpty ? null : token);
    } catch (e, stack) {
      ErrorLogService.instance.log('SyncConfig.saveHibikiToken', e, stack);
    }
  }

  /// Add a new address, or edit the one at [index]. Reuses the URL field
  /// labels/actions that already exist in i18n (no new keys).
  Future<void> _addOrEditUrl({int? index}) async {
    final TextEditingController controller = TextEditingController(
      text: index != null ? _urls[index].url : '',
    );
    final String? result = await showAppDialog<String>(
      context: context,
      builder: (BuildContext ctx) {
        final HibikiDesignTokens tokens = HibikiDesignTokens.of(ctx);
        return HibikiDialogFrame(
          maxWidth: 420,
          insetPadding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.card,
            vertical: tokens.spacing.card,
          ),
          scrollable: false,
          child: HibikiModalSheetFrame(
            title: 'URL',
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
            body: HibikiTextField(
              controller: controller,
              labelText: 'URL',
              hintText: 'http://192.168.1.100:38765',
              keyboardType: TextInputType.url,
            ),
            footer: Wrap(
              alignment: WrapAlignment.end,
              spacing: tokens.spacing.gap,
              children: <Widget>[
                adaptiveDialogAction(
                  context: ctx,
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(t.dialog_cancel),
                ),
                adaptiveDialogAction(
                  context: ctx,
                  isDefaultAction: true,
                  onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                  child: Text(t.dialog_ok),
                ),
              ],
            ),
          ),
        );
      },
    );
    controller.dispose();
    if (result == null || result.isEmpty) return;

    setState(() {
      final List<HibikiClientUrl> copy = <HibikiClientUrl>[..._urls];
      if (index != null) {
        final bool dupElsewhere = copy.asMap().entries.any(
            (MapEntry<int, HibikiClientUrl> e) =>
                e.key != index && e.value.url == result);
        if (!dupElsewhere) {
          copy[index] =
              HibikiClientUrl(url: result, enabled: copy[index].enabled);
        }
      } else if (!copy.any((HibikiClientUrl u) => u.url == result)) {
        copy.add(HibikiClientUrl(url: result));
      }
      _urls = copy;
    });
    await _persistUrls();
  }

  Future<void> _toggleUrl(int index) async {
    setState(() {
      final List<HibikiClientUrl> copy = <HibikiClientUrl>[..._urls];
      final HibikiClientUrl u = copy[index];
      copy[index] = HibikiClientUrl(url: u.url, enabled: !u.enabled);
      _urls = copy;
    });
    await _persistUrls();
  }

  Future<void> _deleteUrl(int index) async {
    setState(() {
      _urls = <HibikiClientUrl>[..._urls]..removeAt(index);
    });
    await _persistUrls();
  }

  Future<void> _reorderUrls(int oldIndex, int newIndex) async {
    setState(() {
      if (newIndex > oldIndex) newIndex--;
      final List<HibikiClientUrl> copy = <HibikiClientUrl>[..._urls];
      final HibikiClientUrl item = copy.removeAt(oldIndex);
      copy.insert(newIndex, item);
      _urls = copy;
    });
    await _persistUrls();
  }

  Future<void> _testAll() async {
    await _saveToken();
    final String token = _tokenController.text.trim();
    if (_urls.isEmpty || token.isEmpty) {
      if (mounted) _showSnackBar(context, t.sync_connection_failed);
      return;
    }
    setState(() => _isTesting = true);
    for (final HibikiClientUrl u in _urls) {
      bool ok;
      try {
        await HibikiClientSyncBackend.instance
            .testConnection(url: u.url, token: token)
            .timeout(const Duration(seconds: 5));
        ok = true;
      } catch (e, stack) {
        // Record why an address probe failed (auth vs network vs timeout)
        // instead of only showing a generic ✗ (HBK-AUDIT-165).
        ErrorLogService.instance.log('SyncTestAll:${u.url}', e, stack);
        ok = false;
      }
      if (!mounted) return;
      setState(() => _reachable[u.url] = ok);
    }
    if (mounted) setState(() => _isTesting = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    // Mutual exclusion: while this device serves peers, it can't also connect
    // out as a client. Block adding/editing connections; deleting stays allowed
    // so the user can clear them and switch roles.
    final bool lockedByServer =
        _syncSettings(widget.settingsContext).serverEnabled;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (_urls.isNotEmpty)
            ReorderableListView.builder(
              buildDefaultDragHandles: false,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _urls.length,
              onReorder: _reorderUrls,
              itemBuilder: (BuildContext context, int index) {
                final HibikiClientUrl u = _urls[index];
                final bool? ok = _reachable[u.url];
                return ReorderableDelayedDragStartListener(
                  key: ValueKey<String>(u.url),
                  index: index,
                  child: HibikiListItem(
                    padding: EdgeInsets.zero,
                    title: Text(
                      u.url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: u.enabled
                            ? theme.colorScheme.onSurface
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    subtitle: ok == null
                        ? null
                        : Text(
                            ok
                                ? t.sync_connection_success
                                : t.sync_connection_failed,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: ok
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.error,
                            ),
                          ),
                    onTap: lockedByServer
                        ? null
                        : () => _addOrEditUrl(index: index),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        // Gamepad/keyboard reorder equivalent for the drag handle.
                        HibikiIconButton(
                          icon: Icons.keyboard_arrow_up,
                          size: 18,
                          tooltip: t.move_up,
                          enabled: index > 0,
                          onTap: () => _reorderUrls(index, index - 1),
                        ),
                        HibikiIconButton(
                          icon: Icons.keyboard_arrow_down,
                          size: 18,
                          tooltip: t.move_down,
                          enabled: index < _urls.length - 1,
                          onTap: () => _reorderUrls(index, index + 2),
                        ),
                        adaptiveSwitch(
                          context: context,
                          value: u.enabled,
                          onChanged: (_) => _toggleUrl(index),
                        ),
                        HibikiIconButton(
                          icon: Icons.delete_outline,
                          size: 18,
                          tooltip: t.dialog_delete,
                          onTap: () => _deleteUrl(index),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          if (lockedByServer)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Text(
                t.sync_role_locked_by_server,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: lockedByServer ? null : () => _addOrEditUrl(),
              icon: const Icon(Icons.add, size: 18),
              label: Text(t.dialog_add),
            ),
          ),
          const SizedBox(height: 12),
          HibikiTextField(
            controller: _tokenController,
            focusNode: _tokenFocus,
            labelText: t.sync_server_token,
            onChanged: (_) => _saveToken(),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: _isTesting
                ? SizedBox(
                    width: 24,
                    height: 24,
                    child: adaptiveIndicator(context: context, strokeWidth: 2),
                  )
                : FilledButton.tonal(
                    onPressed: _testAll,
                    child: Text(t.sync_test_connection),
                  ),
          ),
        ],
      ),
    );
  }
}

// ── Server mode widget ──────────────────────────────────────────────

class _ServerModeWidget extends StatefulWidget {
  const _ServerModeWidget({required this.settingsContext});
  final SettingsContext settingsContext;

  @override
  State<_ServerModeWidget> createState() => _ServerModeWidgetState();
}

class _ServerModeWidgetState extends State<_ServerModeWidget> {
  bool _enabled = false;
  int _port = SyncRepository.defaultServerPort;
  String? _token;
  HibikiSyncServer? _server;
  LanBroadcastService? _broadcast;
  late final TextEditingController _portController;
  bool _loaded = false;
  // True while a pairing-approval dialog is on screen. A peer must not be able
  // to stack prompts on the host by hammering /api/pair, so we serve one at a
  // time and auto-refuse anything that arrives while one is already open.
  bool _pairDialogOpen = false;

  @override
  void initState() {
    super.initState();
    _portController = TextEditingController(text: '$_port');
    // Rebuild when the client-connection flag flips so the toggle re-gates.
    _syncSettings(widget.settingsContext)
        .roleRevision
        .addListener(_onRoleRevision);
    _loadSettings();
  }

  @override
  void dispose() {
    _syncSettings(widget.settingsContext)
        .roleRevision
        .removeListener(_onRoleRevision);
    _portController.dispose();
    _broadcast?.stop();
    _server?.stop();
    super.dispose();
  }

  void _onRoleRevision() {
    if (mounted) setState(() {});
  }

  Future<void> _loadSettings() async {
    final repo = SyncRepository(widget.settingsContext.appModel.database);
    final enabled = await repo.isServerEnabled();
    final port = await repo.getServerPort();
    var token = await repo.getServerPassword();
    if (token == null) {
      token = HibikiSyncServer.generateToken();
      await repo.setServerPassword(token);
    }
    if (mounted) {
      setState(() {
        _enabled = enabled;
        _port = port;
        _portController.text = '$port';
        _token = token;
        _loaded = true;
      });
      _syncSettings(widget.settingsContext).setServerEnabled(enabled);
      if (enabled) await _startServer();
    }
  }

  /// Persist an edited port (no live restart — the new port applies next time
  /// the server starts, so a half-typed value never bounces the running one).
  Future<void> _setPort(String raw) async {
    final int? parsed = int.tryParse(raw.trim());
    if (parsed == null || parsed < 1 || parsed > 65535 || parsed == _port) {
      return;
    }
    setState(() => _port = parsed);
    await SyncRepository(widget.settingsContext.appModel.database)
        .setServerPort(parsed);
  }

  /// On commit, snap the field back to the persisted port when the typed value
  /// is non-numeric or out of range, so the field text can't drift away from
  /// the effective port (e.g. typing 70000 leaves the stored 7000 visible).
  void _reconcilePortField(String raw) {
    final int? parsed = int.tryParse(raw.trim());
    if (parsed == null || parsed < 1 || parsed > 65535) {
      if (_portController.text != '$_port') _portController.text = '$_port';
    }
  }

  /// A failed bind must not leave the toggle stuck "on" — it would re-fail on
  /// every launch. Reset to off and persist so the user can change the port
  /// and re-enable.
  Future<void> _disableAfterStartFailure() async {
    await SyncRepository(widget.settingsContext.appModel.database)
        .setServerEnabled(false);
    _syncSettings(widget.settingsContext).setServerEnabled(false);
    if (mounted) setState(() => _enabled = false);
  }

  Future<void> _startServer() async {
    if (_server != null && _server!.isRunning) return;
    final appModel = widget.settingsContext.appModel;
    _server = HibikiSyncServer(
      syncDataDir: appModel.databaseDirectory.path,
      port: _port,
      token: _token!,
      allowLan: true,
      remoteLookupService: appModel.createRemoteLookupService(),
    )..onPairRequest = _promptPairApproval;
    try {
      await _server!.start();
      // Persist enabled only once the bind actually succeeded, so a failed
      // start never leaves a stuck "on" flag that re-fails every launch
      // (HBK-AUDIT-167).
      await SyncRepository(widget.settingsContext.appModel.database)
          .setServerEnabled(true);
      _syncSettings(widget.settingsContext).setServerEnabled(true);
      // Advertise on the LAN using the ACTUAL bound port so peers discover the
      // host even when the requested port was 0/auto or differs from _port.
      await _startBroadcast(_server!.port);
      if (mounted) setState(() {});
    } on SyncServerPortInUseException catch (e) {
      _server = null;
      await _disableAfterStartFailure();
      if (mounted) {
        _showSnackBar(context, t.sync_server_port_in_use(port: e.port));
      }
    } catch (e) {
      _server = null;
      await _disableAfterStartFailure();
      if (mounted) {
        _showSnackBar(
            context, t.sync_error(message: friendlySyncErrorDetail(e)));
      }
    }
  }

  Future<void> _startBroadcast(int boundPort) async {
    final SyncRepository repo =
        SyncRepository(widget.settingsContext.appModel.database);
    final String deviceId = await repo.getOrCreateDeviceId();
    _broadcast = LanBroadcastService(
      deviceName: _deviceName(),
      deviceId: deviceId,
      port: boundPort,
    );
    await _broadcast!.start();
  }

  /// Human-readable advertisement name. Platform.localHostname is the machine
  /// name on desktop; falls back to a generic label on mobile or on error.
  String _deviceName() {
    try {
      final String host = Platform.localHostname;
      if (host.trim().isNotEmpty) return 'Hibiki · $host';
    } catch (_) {/* localHostname can throw on some platforms */}
    return 'Hibiki';
  }

  /// Server callback: a peer POSTed /api/pair. Ask the host user to allow the
  /// token handout. Uses the app-wide navigator so the prompt appears even if
  /// the user has navigated away from the sync page while the server runs.
  /// Resolves false (refuse) on a stacked request, a missing context, an
  /// explicit deny, or a 60s no-answer timeout.
  Future<bool> _promptPairApproval(HibikiPairRequest request) async {
    if (_pairDialogOpen) return false;
    final BuildContext? ctx =
        widget.settingsContext.appModel.navigatorKey.currentContext;
    if (ctx == null) return false;
    _pairDialogOpen = true;
    Timer? autoDeny;
    try {
      final bool? approved = await showAppDialog<bool>(
        context: ctx,
        builder: (BuildContext dialogCtx) {
          // Auto-refuse after 60s so a forgotten prompt never leaks the token
          // and the waiting client gets a deterministic answer.
          autoDeny ??= Timer(const Duration(seconds: 60), () {
            if (Navigator.of(dialogCtx).canPop()) {
              Navigator.pop(dialogCtx, false);
            }
          });
          final HibikiDesignTokens tokens = HibikiDesignTokens.of(dialogCtx);
          return HibikiDialogFrame(
            maxWidth: 420,
            insetPadding: EdgeInsets.symmetric(
              horizontal: tokens.spacing.card,
              vertical: tokens.spacing.card,
            ),
            scrollable: false,
            child: HibikiModalSheetFrame(
              title: t.sync_pair_request_title,
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
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(t.sync_pair_request_body),
                  SizedBox(height: tokens.spacing.gap),
                  Text(
                    _pairRequesterLabel(request),
                    style: Theme.of(dialogCtx).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ],
              ),
              footer: Wrap(
                alignment: WrapAlignment.end,
                spacing: tokens.spacing.gap,
                children: <Widget>[
                  adaptiveDialogAction(
                    context: dialogCtx,
                    isDestructiveAction: true,
                    onPressed: () => Navigator.pop(dialogCtx, false),
                    child: Text(t.sync_pair_deny),
                  ),
                  adaptiveDialogAction(
                    context: dialogCtx,
                    isDefaultAction: true,
                    onPressed: () => Navigator.pop(dialogCtx, true),
                    child: Text(t.sync_pair_allow),
                  ),
                ],
              ),
            ),
          );
        },
      );
      return approved ?? false;
    } finally {
      autoDeny?.cancel();
      _pairDialogOpen = false;
    }
  }

  /// "<name> · <ip>" when both are known, else whichever is present, else a
  /// generic label so the prompt always names a requester.
  String _pairRequesterLabel(HibikiPairRequest request) {
    final String name = request.deviceName?.trim() ?? '';
    final String ip = request.remoteAddress?.trim() ?? '';
    if (name.isNotEmpty && ip.isNotEmpty) return '$name · $ip';
    if (name.isNotEmpty) return name;
    if (ip.isNotEmpty) return ip;
    return t.sync_pair_unknown_device;
  }

  Future<void> _stopServer() async {
    await _broadcast?.stop();
    _broadcast = null;
    await _server?.stop();
    _server = null;
  }

  Future<void> _regenerateToken() async {
    final newToken = HibikiSyncServer.generateToken();
    final repo = SyncRepository(widget.settingsContext.appModel.database);
    await repo.setServerPassword(newToken);
    setState(() => _token = newToken);
    if (_server != null && _server!.isRunning) {
      await _stopServer();
      await _startServer();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    final bool running = _server != null && _server!.isRunning;
    // Mutual exclusion: block turning the server ON while this device is a
    // client of a peer. Turning OFF an already-running server stays allowed so
    // the user can always escape (and legacy both-on data can't deadlock).
    final bool lockedByClient =
        _syncSettings(widget.settingsContext).hasClientConnection && !_enabled;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AdaptiveSettingsSwitchRow(
            title: t.sync_server_enable,
            subtitle: lockedByClient
                ? t.sync_role_locked_by_client
                : (running ? t.sync_server_running : t.sync_server_stopped),
            value: _enabled,
            onChanged: lockedByClient
                ? null
                : (bool v) async {
                    if (v) {
                      // Reflect the toggle while starting; _startServer persists
                      // enabled on success and resets it on failure
                      // (HBK-AUDIT-167).
                      setState(() => _enabled = true);
                      await _startServer();
                    } else {
                      setState(() => _enabled = false);
                      await SyncRepository(
                              widget.settingsContext.appModel.database)
                          .setServerEnabled(false);
                      _syncSettings(widget.settingsContext)
                          .setServerEnabled(false);
                      await _stopServer();
                    }
                  },
          ),
          if (_enabled) ...<Widget>[
            const SizedBox(height: 8),
            HibikiTextField(
              controller: _portController,
              labelText: t.sync_server_port,
              keyboardType: TextInputType.number,
              onChanged: _setPort,
              onSubmitted: _reconcilePortField,
            ),
            if (running)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('${t.sync_server_running}: ${_server!.port}',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            const SizedBox(height: 12),
            Text(t.sync_server_token,
                style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 4),
            SelectableText(
              _token ?? '',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
              maxLines: 2,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                TextButton.icon(
                  onPressed: () {
                    if (_token != null) {
                      FlutterClipboard.copy(_token!);
                      _showSnackBar(context, t.sync_server_copy_token);
                    }
                  },
                  icon: const Icon(Icons.copy, size: 18),
                  label: Text(t.sync_server_copy_token),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: _regenerateToken,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(t.sync_server_regenerate_token),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ── LAN discovery widget ────────────────────────────────────────────

class _LanDiscoveryWidget extends StatefulWidget {
  const _LanDiscoveryWidget({required this.settingsContext});
  final SettingsContext settingsContext;

  @override
  State<_LanDiscoveryWidget> createState() => _LanDiscoveryWidgetState();
}

class _LanDiscoveryWidgetState extends State<_LanDiscoveryWidget> {
  LanDiscoveryService? _discovery;
  List<HibikiDevice> _devices = <HibikiDevice>[];
  bool _scanning = false;
  bool _scanFailed = false;
  StreamSubscription<List<HibikiDevice>>? _devicesSub;
  // webDavUrl of the device currently awaiting the host's pairing approval, or
  // null when idle. Drives the per-row spinner and blocks concurrent attempts.
  String? _pairingUrl;

  @override
  void initState() {
    super.initState();
    // Rebuild when the server-enabled flag flips so device taps re-gate.
    _syncSettings(widget.settingsContext)
        .roleRevision
        .addListener(_onRoleRevision);
    _init();
  }

  void _onRoleRevision() {
    if (mounted) setState(() {});
  }

  Future<void> _init() async {
    try {
      final String deviceId =
          await SyncRepository(widget.settingsContext.appModel.database)
              .getOrCreateDeviceId();
      if (!mounted) return;
      _discovery = LanDiscoveryService(deviceId: deviceId);
      await _startScan();
    } catch (e, stack) {
      // Loading the device id (a DB read) can throw; surface it as a scan
      // failure instead of silently never starting discovery (don't swallow).
      ErrorLogService.instance.log('LanDiscovery.init', e, stack);
      if (mounted) setState(() => _scanFailed = true);
    }
  }

  @override
  void dispose() {
    _syncSettings(widget.settingsContext)
        .roleRevision
        .removeListener(_onRoleRevision);
    _devicesSub?.cancel();
    _discovery?.dispose();
    super.dispose();
  }

  Future<void> _startScan() async {
    final LanDiscoveryService? discovery = _discovery;
    if (discovery == null) return;
    setState(() {
      _scanning = true;
      _scanFailed = false;
    });
    _devicesSub = discovery.devices.listen((List<HibikiDevice> devices) {
      if (mounted) setState(() => _devices = devices);
    });
    try {
      await discovery.startDiscovery();
    } catch (e, stack) {
      // Surface the failure instead of showing an empty "no devices" list with
      // no hint that the scan itself failed (permissions/firewall) — HBK-AUDIT-164.
      ErrorLogService.instance.log('LanDiscovery.scan', e, stack);
      if (mounted) setState(() => _scanFailed = true);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _connectToDevice(HibikiDevice device) async {
    // One pairing attempt at a time: the awaited request can hang for up to a
    // minute waiting on the host's approval dialog.
    if (_pairingUrl != null) return;
    final state = _syncSettings(widget.settingsContext);
    state.backendType = SyncBackendType.hibikiServer;
    final repo = SyncRepository(widget.settingsContext.appModel.database);
    await repo.setBackendType(SyncBackendType.hibikiServer);
    // Always record the address (deduped) so the user keeps the URL even if
    // the host declines and they fall back to pasting the token.
    await repo.addHibikiClientUrl(device.webDavUrl);
    // A client connection now exists → lock this device out of server mode.
    state.setHasClientConnection(true);

    setState(() => _pairingUrl = device.webDavUrl);
    String message;
    try {
      final http.Response resp = await http
          .post(
            Uri.parse('${device.webDavUrl}/api/pair'),
            headers: <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(<String, String>{'name': _localDeviceName()}),
          )
          // Outlast the host's 60s approval window so its auto-deny 403 reaches
          // us instead of us timing out first.
          .timeout(const Duration(seconds: 65));
      if (resp.statusCode == 200) {
        final dynamic body = jsonDecode(resp.body);
        final String? token =
            body is Map<String, dynamic> ? body['token'] as String? : null;
        if (token != null && token.isNotEmpty) {
          await repo.setHibikiClientToken(token);
          message = t.sync_pair_success;
        } else {
          message = t.sync_pair_failed;
        }
      } else if (resp.statusCode == 403) {
        message = _pairDeniedMessage(resp.body);
      } else {
        message = t.sync_pair_failed;
      }
    } catch (e, stack) {
      // Pairing probe failed (no server/timeout/declined). Keep the URL; record
      // why instead of swallowing.
      ErrorLogService.instance
          .log('LanDiscovery.pair:${device.webDavUrl}', e, stack);
      message = t.sync_pair_failed;
    } finally {
      if (mounted) setState(() => _pairingUrl = null);
    }

    // Single source of truth bumped → client-config widget reloads URL + token.
    state.reloadClientConfig();
    widget.settingsContext.refresh();
    if (mounted) _showSnackBar(context, '${device.name}: $message');
  }

  /// Tell a 403 apart: a peer that explicitly declined ({"reason":"declined"})
  /// vs one with no approval handler / older build ({"reason":"unavailable"} or
  /// a plain-text body), so the user isn't told "declined" when the peer simply
  /// can't prompt. A token-less reply that somehow returns 200 is handled above.
  String _pairDeniedMessage(String body) {
    try {
      final dynamic decoded = jsonDecode(body);
      if (decoded is Map && decoded['reason'] == 'declined') {
        return t.sync_pair_denied;
      }
    } catch (_) {/* older peers reply with a plain-text 403 body */}
    return t.sync_pair_unavailable;
  }

  /// This device's own advertised name, sent to the host so its approval prompt
  /// can identify who is asking. Mirrors the server widget's [_deviceName].
  String _localDeviceName() {
    try {
      final String host = Platform.localHostname;
      if (host.trim().isNotEmpty) return 'Hibiki · $host';
    } catch (_) {/* localHostname can throw on some platforms */}
    return 'Hibiki';
  }

  @override
  Widget build(BuildContext context) {
    // Mutual exclusion: while this device serves peers, it can't connect out as
    // a client, so device taps are inert and a note explains why.
    final bool lockedByServer =
        _syncSettings(widget.settingsContext).serverEnabled;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(t.sync_lan_discovery,
                  style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              if (_scanning)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: adaptiveIndicator(context: context, strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (lockedByServer)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                t.sync_role_locked_by_server,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
          if (_scanFailed)
            Text(t.sync_lan_scan_failed,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ))
          else if (_devices.isEmpty)
            Text(t.sync_lan_no_devices,
                style: Theme.of(context).textTheme.bodySmall),
          for (final HibikiDevice device in _devices)
            HibikiListItem(
              leading: const Icon(Icons.devices_outlined, size: 20),
              title: Text(device.name),
              subtitle: Text(device.webDavUrl),
              trailing: _pairingUrl == device.webDavUrl
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child:
                          adaptiveIndicator(context: context, strokeWidth: 2),
                    )
                  : null,
              minHeight: 52,
              padding: EdgeInsets.zero,
              // Disable taps while serving peers, or while a pairing is running.
              onTap: (lockedByServer || _pairingUrl != null)
                  ? null
                  : () => _connectToDevice(device),
            ),
        ],
      ),
    );
  }
}

class _SyncSettingsState {
  _SyncSettingsState(this._settingsContext)
      : _repo = SyncRepository(_settingsContext.appModel.database);

  final SettingsContext _settingsContext;
  final SyncRepository _repo;
  SyncBackendType backendType = SyncBackendType.googleDrive;
  bool autoSync = false;
  bool syncStats = true;
  bool syncAudioBook = true;
  bool syncDictionary = false;
  bool syncContent = false;
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
      syncAudioBook = await _repo.isSyncAudioBookEnabled();
      syncDictionary = await _repo.isSyncDictionaryEnabled();
      syncContent = await _repo.isSyncContentEnabled();
      serverEnabled = await _repo.isServerEnabled();
      hasClientConnection = (await _repo.getHibikiClientUrls()).isNotEmpty;
      _loaded = true;
      _settingsContext.refresh();
    } finally {
      _loading = false;
    }
  }
}
