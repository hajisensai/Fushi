import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/sync/google_drive_auth.dart';
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
          SettingsCustomItem(
            id: 'sync.options',
            icon: Icons.tune_outlined,
            builder: (SettingsContext ctx) =>
                _SyncOptionsWidget(settingsContext: ctx),
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

Future<void> _performSync(
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
  final _clientIdController = TextEditingController();
  bool _isAuthenticated = false;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _checkAuth();
  }

  Future<void> _checkAuth() async {
    final authed = await GoogleDriveAuth.instance.isAuthenticated;
    if (mounted) setState(() => _isAuthenticated = authed);
  }

  @override
  void dispose() {
    _clientIdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isAuthenticated) {
      return AdaptiveSettingsRow(
        title: t.sync_signed_in,
        icon: Icons.check_circle_outline,
        trailing: _signOutButton(context),
      );
    }

    return AdaptiveSettingsRow(
      title: t.sync_account,
      icon: Icons.account_circle_outlined,
      controlBelow: true,
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _clientIdField(context),
          const SizedBox(height: 8),
          _signInButton(context),
        ],
      ),
    );
  }

  Widget _clientIdField(BuildContext context) {
    if (isCupertinoPlatform(context)) {
      return CupertinoTextField(
        controller: _clientIdController,
        placeholder: t.sync_client_id_hint,
        clearButtonMode: OverlayVisibilityMode.editing,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      );
    }
    return TextField(
      controller: _clientIdController,
      decoration: InputDecoration(
        labelText: t.sync_client_id,
        hintText: t.sync_client_id_hint,
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _signInButton(BuildContext context) {
    final Widget progress = adaptiveIndicator(context: context, strokeWidth: 2);
    if (isCupertinoPlatform(context)) {
      return CupertinoButton.filled(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        onPressed: _isLoading ? null : _signIn,
        child: _isLoading ? progress : Text(t.sync_sign_in),
      );
    }
    return FilledButton.icon(
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
        onPressed: _isLoading ? null : _signOut,
        child: Text(t.sync_sign_out),
      );
    }
    return TextButton(
      onPressed: _isLoading ? null : _signOut,
      child: Text(t.sync_sign_out),
    );
  }

  Future<void> _signIn() async {
    final clientId = _clientIdController.text.trim();
    if (clientId.isEmpty) return;

    setState(() => _isLoading = true);
    try {
      await GoogleDriveAuth.instance.authenticate(clientId);
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
    await _checkAuth();
    if (mounted) setState(() => _isLoading = false);
  }
}

class _SyncOptionsWidget extends StatefulWidget {
  const _SyncOptionsWidget({required this.settingsContext});
  final SettingsContext settingsContext;

  @override
  State<_SyncOptionsWidget> createState() => _SyncOptionsWidgetState();
}

class _SyncOptionsWidgetState extends State<_SyncOptionsWidget> {
  String _syncMode = 'merge';
  bool _syncStats = true;
  bool _syncAudioBook = true;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadValues();
  }

  Future<void> _loadValues() async {
    final repo = SyncRepository(widget.settingsContext.appModel.database);
    final mode = await repo.getSyncMode();
    final stats = await repo.isSyncStatsEnabled();
    final audio = await repo.isSyncAudioBookEnabled();
    if (mounted) {
      setState(() {
        _syncMode = mode;
        _syncStats = stats;
        _syncAudioBook = audio;
        _loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();

    return Column(
      children: <Widget>[
        AdaptiveSettingsSegmentedRow<String>(
          title: t.sync_mode,
          icon: Icons.sync_alt_outlined,
          controlBelow: true,
          segments: <ButtonSegment<String>>[
            ButtonSegment<String>(
              value: 'merge',
              label: Text(t.sync_mode_merge),
            ),
            ButtonSegment<String>(
              value: 'replace',
              label: Text(t.sync_mode_replace),
            ),
          ],
          selected: _syncMode,
          onChanged: (String value) async {
            setState(() => _syncMode = value);
            final repo =
                SyncRepository(widget.settingsContext.appModel.database);
            await repo.setSyncMode(value);
          },
        ),
        AdaptiveSettingsSwitchRow(
          title: t.sync_statistics,
          icon: Icons.query_stats_outlined,
          value: _syncStats,
          onChanged: (bool value) async {
            setState(() => _syncStats = value);
            final repo =
                SyncRepository(widget.settingsContext.appModel.database);
            await repo.setSyncStatsEnabled(value);
          },
        ),
        AdaptiveSettingsSwitchRow(
          title: t.sync_audiobook,
          icon: Icons.headphones_outlined,
          value: _syncAudioBook,
          onChanged: (bool value) async {
            setState(() => _syncAudioBook = value);
            final repo =
                SyncRepository(widget.settingsContext.appModel.database);
            await repo.setSyncAudioBookEnabled(value);
          },
        ),
      ],
    );
  }
}
