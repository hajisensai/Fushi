import 'dart:async';
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
import 'package:hibiki/src/sync/smb_sync_backend.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_compare_dialog.dart';
import 'package:hibiki/src/sync/sync_error_messages.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/webdav_sync_backend.dart';
import 'package:hibiki/utils.dart';
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
      SettingsSection(
        title: t.sync_backend,
        items: <SettingsItem>[
          SettingsCustomItem(
            id: 'sync.mode',
            icon: Icons.cloud_outlined,
            builder: (SettingsContext ctx) =>
                _BackendSelectorWidget(settingsContext: ctx),
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
            id: 'sync.smb_config',
            icon: Icons.dns_outlined,
            visible: (SettingsContext ctx) =>
                _syncSettings(ctx).backendType == SyncBackendType.smb,
            builder: (SettingsContext ctx) =>
                _SmbConfigWidget(settingsContext: ctx),
          ),
          SettingsCustomItem(
            id: 'sync.hibiki_server_config',
            icon: Icons.devices_outlined,
            visible: (SettingsContext ctx) =>
                _syncSettings(ctx).backendType == SyncBackendType.hibikiServer,
            builder: (SettingsContext ctx) =>
                _HibikiServerConfigWidget(settingsContext: ctx),
          ),
        ],
      ),
      SettingsSection(
        title: t.sync_server_enable,
        items: <SettingsItem>[
          SettingsCustomItem(
            id: 'sync.server_mode',
            icon: Icons.router_outlined,
            builder: (SettingsContext ctx) =>
                _ServerModeWidget(settingsContext: ctx),
          ),
        ],
      ),
      SettingsSection(
        title: t.sync_lan_discovery,
        items: <SettingsItem>[
          SettingsCustomItem(
            id: 'sync.lan_devices',
            icon: Icons.wifi_find_outlined,
            builder: (SettingsContext ctx) =>
                _LanDiscoveryWidget(settingsContext: ctx),
          ),
        ],
      ),
      SettingsSection(
        title: t.sync_account,
        items: <SettingsItem>[
          SettingsCustomItem(
            id: 'sync.account_status',
            icon: Icons.account_circle_outlined,
            builder: (SettingsContext ctx) =>
                _SyncAccountWidget(settingsContext: ctx),
          ),
        ],
      ),
      SettingsSection(
        title: t.sync_options,
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
      SettingsSection(
        title: t.sync_actions,
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
      SettingsSection(
        title: t.backup_local,
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
  if (isCupertinoPlatform(context)) {
    showCupertinoDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => CupertinoAlertDialog(
        content: Text(message),
        actions: <Widget>[
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(t.dialog_done),
          ),
        ],
      ),
    );
    return;
  }
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
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
    } catch (_) {
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
        visualDensity: VisualDensity.compact,
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
        visualDensity: VisualDensity.compact,
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
    final repo = SyncRepository(widget.settingsContext.appModel.database);
    final url = _urlController.text.trim();
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    await repo.setWebDavUrl(url.isEmpty ? null : url);
    await repo.setWebDavUsername(username.isEmpty ? null : username);
    await repo.setWebDavPassword(password.isEmpty ? null : password);
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

      final confirmed = await _showConfirmDialog(meta);
      if (confirmed != true || !mounted) return;

      await appModel.closeDatabase();
      await BackupService.importBackupFiles(
        dbDirectory: appModel.databaseDirectory.path,
        zipPath: filePath,
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

  Future<bool?> _showConfirmDialog(BackupMeta meta) {
    final dateStr =
        '${meta.createdAt.year}-${meta.createdAt.month.toString().padLeft(2, '0')}-${meta.createdAt.day.toString().padLeft(2, '0')}';
    return showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => adaptiveAlertDialog(
        context: ctx,
        title: Text(t.backup_import_confirm_title),
        content: Text(
          t.backup_import_confirm(
            date: dateStr,
            bookCount: meta.bookCount.toString(),
            statsCount: meta.statsCount.toString(),
          ),
        ),
        actions: <Widget>[
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
    );
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
    case SyncBackendType.smb:
    case SyncBackendType.hibikiServer:
      return true;
  }
}

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
    case SyncBackendType.smb:
      return t.sync_backend_smb;
    case SyncBackendType.hibikiServer:
      return t.sync_backend_hibiki_server;
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
    return AdaptiveSettingsRow(
      title: t.sync_backend,
      icon: Icons.cloud_outlined,
      controlBelow: true,
      trailing: DropdownButton<SyncBackendType>(
        value: state.backendType,
        underline: const SizedBox.shrink(),
        items: _selectableBackends(state.backendType)
            .map((SyncBackendType type) => DropdownMenuItem<SyncBackendType>(
                  value: type,
                  child: Text(_backendLabel(type)),
                ))
            .toList(),
        onChanged: (SyncBackendType? value) async {
          if (value == null || value == state.backendType) return;
          state.backendType = value;
          final repo = SyncRepository(widget.settingsContext.appModel.database);
          await repo.setBackendType(value);
          await repo.clearFolderCache();
          widget.settingsContext.refresh();
        },
      ),
    );
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
          SwitchListTile.adaptive(
            title: Text(t.sync_use_tls),
            value: _useTls,
            contentPadding: EdgeInsets.zero,
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

// ── SMB config widget ───────────────────────────────────────────────

class _SmbConfigWidget extends StatefulWidget {
  const _SmbConfigWidget({required this.settingsContext});
  final SettingsContext settingsContext;

  @override
  State<_SmbConfigWidget> createState() => _SmbConfigWidgetState();
}

class _SmbConfigWidgetState extends State<_SmbConfigWidget> {
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
    final url = await repo.getSmbWebDavUrl();
    final user = await repo.getSmbUsername();
    final pass = await repo.getSmbPassword();
    if (mounted) {
      setState(() {
        _urlController.text = url ?? '';
        _usernameController.text = user ?? '';
        _passwordController.text = pass ?? '';
        _loaded = true;
      });
    }
  }

  Future<void> _saveCredentials() async {
    final repo = SyncRepository(widget.settingsContext.appModel.database);
    final url = _urlController.text.trim();
    final user = _usernameController.text.trim();
    final pass = _passwordController.text;
    await repo.setSmbWebDavUrl(url.isEmpty ? null : url);
    await repo.setSmbUsername(user.isEmpty ? null : user);
    await repo.setSmbPassword(pass.isEmpty ? null : pass);
  }

  Future<void> _testConnection() async {
    await _saveCredentials();
    setState(() => _isTesting = true);
    try {
      await SmbSyncBackend.instance.testConnection(
        url: _urlController.text.trim(),
        username: _usernameController.text.trim(),
        password: _passwordController.text,
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
            controller: _urlController,
            labelText: 'WebDAV URL',
            hintText: 'http://nas.local:5005/webdav',
            keyboardType: TextInputType.url,
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
    _load();
  }

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
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
  }

  Future<void> _persistUrls() => _repo.setHibikiClientUrls(_urls);

  Future<void> _saveToken() async {
    final String token = _tokenController.text.trim();
    await _repo.setHibikiClientToken(token.isEmpty ? null : token);
  }

  /// Add a new address, or edit the one at [index]. Reuses the URL field
  /// labels/actions that already exist in i18n (no new keys).
  Future<void> _addOrEditUrl({int? index}) async {
    final TextEditingController controller = TextEditingController(
      text: index != null ? _urls[index].url : '',
    );
    final String? result = await showAppDialog<String>(
      context: context,
      builder: (BuildContext ctx) => adaptiveAlertDialog(
        context: ctx,
        title: const Text('URL'),
        content: HibikiTextField(
          controller: controller,
          labelText: 'URL',
          hintText: 'http://192.168.1.100:8765',
          keyboardType: TextInputType.url,
        ),
        actions: <Widget>[
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
      } catch (_) {
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
                return ListTile(
                  key: ValueKey<String>(u.url),
                  contentPadding: EdgeInsets.zero,
                  leading: ReorderableDragStartListener(
                    index: index,
                    child: Icon(Icons.drag_handle,
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
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
                            color: ok ? Colors.green : theme.colorScheme.error,
                          ),
                        ),
                  onTap: () => _addOrEditUrl(index: index),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Switch.adaptive(
                        value: u.enabled,
                        onChanged: (_) => _toggleUrl(index),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _deleteUrl(index),
                      ),
                    ],
                  ),
                );
              },
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _addOrEditUrl(),
              icon: const Icon(Icons.add, size: 18),
              label: Text(t.dialog_add),
            ),
          ),
          const SizedBox(height: 12),
          HibikiTextField(
            controller: _tokenController,
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
  int _port = 8765;
  String? _token;
  HibikiSyncServer? _server;
  late final TextEditingController _portController;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _portController = TextEditingController(text: '$_port');
    _loadSettings();
  }

  @override
  void dispose() {
    _portController.dispose();
    _server?.stop();
    super.dispose();
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

  /// A failed bind must not leave the toggle stuck "on" — it would re-fail on
  /// every launch. Reset to off and persist so the user can change the port
  /// and re-enable.
  Future<void> _disableAfterStartFailure() async {
    await SyncRepository(widget.settingsContext.appModel.database)
        .setServerEnabled(false);
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
    );
    try {
      await _server!.start();
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

  Future<void> _stopServer() async {
    await _server?.stop();
    _server = null;
    if (mounted) setState(() {});
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SwitchListTile.adaptive(
            title: Text(t.sync_server_enable),
            subtitle:
                Text(running ? t.sync_server_running : t.sync_server_stopped),
            value: _enabled,
            contentPadding: EdgeInsets.zero,
            onChanged: (bool v) async {
              final repo =
                  SyncRepository(widget.settingsContext.appModel.database);
              await repo.setServerEnabled(v);
              setState(() => _enabled = v);
              if (v) {
                await _startServer();
              } else {
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
  late LanDiscoveryService _discovery;
  List<HibikiDevice> _devices = <HibikiDevice>[];
  bool _scanning = false;
  StreamSubscription<List<HibikiDevice>>? _devicesSub;

  @override
  void initState() {
    super.initState();
    _discovery = LanDiscoveryService(
      deviceName: 'Hibiki',
      port: 8765,
      deviceId: 'settings-scan',
    );
    _startScan();
  }

  @override
  void dispose() {
    _devicesSub?.cancel();
    _discovery.dispose();
    super.dispose();
  }

  Future<void> _startScan() async {
    setState(() => _scanning = true);
    _devicesSub = _discovery.devices.listen((List<HibikiDevice> devices) {
      if (mounted) setState(() => _devices = devices);
    });
    try {
      await _discovery.startDiscovery();
    } catch (_) {
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _connectToDevice(HibikiDevice device) async {
    final state = _syncSettings(widget.settingsContext);
    state.backendType = SyncBackendType.hibikiServer;
    final repo = SyncRepository(widget.settingsContext.appModel.database);
    await repo.setBackendType(SyncBackendType.hibikiServer);
    // Add the discovered address to the candidate list (deduped) instead of
    // overwriting the whole config — and keep any token the user already set.
    await repo.addHibikiClientUrl(device.webDavUrl);
    widget.settingsContext.refresh();
    if (mounted) _showSnackBar(context, '${device.name} (${device.webDavUrl})');
  }

  @override
  Widget build(BuildContext context) {
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
          if (_devices.isEmpty)
            Text(t.sync_lan_no_devices,
                style: Theme.of(context).textTheme.bodySmall),
          for (final HibikiDevice device in _devices)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.devices, size: 20),
              title: Text(device.name),
              subtitle: Text(device.webDavUrl),
              onTap: () => _connectToDevice(device),
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
  bool syncContent = false;
  bool _loaded = false;
  bool _loading = false;

  Future<void> load() async {
    if (_loaded || _loading) return;

    _loading = true;
    try {
      backendType = await _repo.getBackendType();
      autoSync = await _repo.isAutoSyncEnabled();
      syncStats = await _repo.isSyncStatsEnabled();
      syncAudioBook = await _repo.isSyncAudioBookEnabled();
      syncContent = await _repo.isSyncContentEnabled();
      _loaded = true;
      _settingsContext.refresh();
    } finally {
      _loading = false;
    }
  }
}
