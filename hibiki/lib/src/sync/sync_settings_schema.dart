import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/sync/google_drive_auth.dart';
import 'package:hibiki/src/sync/google_drive_handler.dart';
import 'package:hibiki/src/sync/sync_manager.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki/utils.dart';

SettingsDestination buildSyncBackupDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.syncBackup,
    title: t.settings_destination_sync_backup,
    summary: t.sync_summary,
    icon: Icons.sync,
    sections: <SettingsSection>[
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
          SettingsSegmentedItem<String>(
            id: 'sync.mode',
            title: t.sync_mode,
            icon: Icons.sync_alt_outlined,
            controlBelow: true,
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: 'merge',
                label: t.sync_mode_merge,
              ),
              SettingsSegmentOption<String>(
                value: 'replace',
                label: t.sync_mode_replace,
              ),
            ],
            selected: (SettingsContext ctx) => _syncSettings(ctx).syncMode,
            onChanged: (SettingsContext ctx, String value) async {
              _syncSettings(ctx).syncMode = value;
              await SyncRepository(ctx.appModel.database).setSyncMode(value);
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
        ],
      ),
      SettingsSection(
        title: t.sync_actions,
        items: <SettingsItem>[
          SettingsActionItem(
            id: 'sync.sync_all',
            title: t.sync_all,
            icon: Icons.sync,
            onTap: (SettingsContext ctx) =>
                _performSync(ctx, importOnly: false),
          ),
          SettingsActionItem(
            id: 'sync.import_only',
            title: t.sync_import_only,
            icon: Icons.cloud_download_outlined,
            onTap: (SettingsContext ctx) => _performSync(ctx, importOnly: true),
          ),
        ],
      ),
    ],
  );
}

bool _syncInProgress = false;
final Expando<_SyncSettingsState> _syncSettingsByContext =
    Expando<_SyncSettingsState>('sync settings state');

_SyncSettingsState _syncSettings(SettingsContext ctx) {
  return _syncSettingsByContext[ctx.context] ??= _SyncSettingsState(ctx)
    ..load();
}

Future<void> _performSync(
  SettingsContext ctx, {
  required bool importOnly,
}) async {
  if (_syncInProgress) return;
  _syncInProgress = true;
  try {
    await _performSyncInner(ctx, importOnly: importOnly);
  } finally {
    _syncInProgress = false;
  }
}

Future<void> _performSyncInner(
  SettingsContext ctx, {
  required bool importOnly,
}) async {
  final context = ctx.context;
  final auth = GoogleDriveAuth.instance;
  if (!await auth.isAuthenticated) {
    if (!context.mounted) return;
    _showSnackBar(context, t.sync_not_signed_in);
    return;
  }

  if (!context.mounted) return;
  _showSnackBar(context, t.sync_in_progress);

  try {
    final repo = SyncRepository(ctx.appModel.database);
    final syncStats = await repo.isSyncStatsEnabled();
    final syncAudioBook = await repo.isSyncAudioBookEnabled();
    final syncModeStr = await repo.getSyncMode();
    final syncMode = syncModeStr == 'replace'
        ? StatisticsSyncMode.replace
        : StatisticsSyncMode.merge;

    final manager = SyncManager(db: ctx.appModel.database);
    final results = await manager.syncAllBooks(
      syncStats: syncStats,
      statsSyncMode: syncMode,
      syncAudioBook: syncAudioBook,
      importOnly: importOnly,
    );

    int imported = 0, exported = 0, synced = 0;
    for (final r in results) {
      switch (r.direction) {
        case SyncResult.imported:
          imported++;
        case SyncResult.exported:
          exported++;
        case SyncResult.synced:
          synced++;
        case SyncResult.skipped:
          break;
      }
    }

    if (context.mounted) {
      _showSnackBar(
        context,
        t.sync_complete(imported: imported, exported: exported, synced: synced),
      );
      ctx.refresh();
    }
  } on GoogleDriveAuthError catch (e) {
    if (context.mounted) {
      _showSnackBar(context, t.sync_auth_error(message: e.message));
    }
  } catch (e) {
    if (context.mounted) {
      _showSnackBar(context, t.sync_error(message: e.toString()));
    }
  }
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

class _SyncAccountWidget extends StatefulWidget {
  const _SyncAccountWidget({required this.settingsContext});
  final SettingsContext settingsContext;

  @override
  State<_SyncAccountWidget> createState() => _SyncAccountWidgetState();
}

class _SyncAccountWidgetState extends State<_SyncAccountWidget> {
  bool _isAuthenticated = false;
  bool _isLoading = false;
  String? _email;

  @override
  void initState() {
    super.initState();
    _checkAuth();
  }

  Future<void> _checkAuth() async {
    final auth = GoogleDriveAuth.instance;
    final authed = await auth.isAuthenticated;
    final email = authed ? await auth.currentEmail : null;
    if (mounted) {
      setState(() {
        _isAuthenticated = authed;
        _email = email;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
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
      await GoogleDriveAuth.instance.authenticate();
      await _checkAuth();
    } on GoogleDriveAuthError catch (e) {
      if (mounted) {
        _showSnackBar(context, t.sync_auth_error(message: e.message));
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar(context, t.sync_error(message: e.toString()));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _signOut() async {
    setState(() => _isLoading = true);
    await GoogleDriveAuth.instance.signOut();
    GoogleDriveHandler.instance.clearCache();
    await SyncRepository(widget.settingsContext.appModel.database)
        .clearFolderCache();
    await _checkAuth();
    if (mounted) setState(() => _isLoading = false);
  }
}

class _SyncSettingsState {
  _SyncSettingsState(this._settingsContext)
      : _repo = SyncRepository(_settingsContext.appModel.database);

  final SettingsContext _settingsContext;
  final SyncRepository _repo;
  String _syncMode = 'merge';
  bool _syncStats = true;
  bool _syncAudioBook = true;
  bool _loaded = false;
  bool _loading = false;

  String get syncMode => _syncMode;
  set syncMode(String value) => _syncMode = value;

  bool get syncStats => _syncStats;
  set syncStats(bool value) => _syncStats = value;

  bool get syncAudioBook => _syncAudioBook;
  set syncAudioBook(bool value) => _syncAudioBook = value;

  Future<void> load() async {
    if (_loaded || _loading) return;

    _loading = true;
    try {
      _syncMode = await _repo.getSyncMode();
      _syncStats = await _repo.isSyncStatsEnabled();
      _syncAudioBook = await _repo.isSyncAudioBookEnabled();
      _loaded = true;
      _settingsContext.refresh();
    } finally {
      _loading = false;
    }
  }
}
