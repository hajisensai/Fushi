import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/sync/google_drive_sync_backend.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_compare_dialog.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/webdav_sync_backend.dart';
import 'package:hibiki/utils.dart';

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
          SettingsSegmentedItem<String>(
            id: 'sync.mode',
            title: t.sync_backend,
            icon: Icons.cloud_outlined,
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption(
                value: SyncBackendType.googleDrive.name,
                label: t.sync_backend_google_drive,
              ),
              SettingsSegmentOption(
                value: SyncBackendType.webDav.name,
                label: t.sync_backend_webdav,
              ),
            ],
            selected: (SettingsContext ctx) =>
                _syncSettings(ctx).backendType.name,
            onChanged: (SettingsContext ctx, String value) async {
              final type = value == SyncBackendType.webDav.name
                  ? SyncBackendType.webDav
                  : SyncBackendType.googleDrive;
              _syncSettings(ctx).backendType = type;
              final repo = SyncRepository(ctx.appModel.database);
              await repo.setBackendType(type);
              await repo.clearFolderCache();
            },
            controlBelow: true,
          ),
          SettingsCustomItem(
            id: 'sync.webdav_config',
            icon: Icons.dns_outlined,
            visible: (SettingsContext ctx) =>
                _syncSettings(ctx).backendType == SyncBackendType.webDav,
            builder: (SettingsContext ctx) =>
                _WebDavConfigWidget(settingsContext: ctx),
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
    ],
  );
}

final Expando<_SyncSettingsState> _syncSettingsByContext =
    Expando<_SyncSettingsState>('sync settings state');

_SyncSettingsState _syncSettings(SettingsContext ctx) {
  return _syncSettingsByContext[ctx.context] ??= _SyncSettingsState(ctx)
    ..load();
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
        _showSnackBar(context, t.sync_error(message: e.toString()));
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
        _showSnackBar(
            context, t.sync_webdav_test_failed(message: e.message));
      }
    } on SyncBackendError catch (e) {
      if (mounted) {
        _showSnackBar(
            context, t.sync_webdav_test_failed(message: e.message));
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar(
            context, t.sync_webdav_test_failed(message: e.toString()));
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
          TextField(
            controller: _urlController,
            decoration: InputDecoration(
              labelText: t.sync_webdav_url,
              hintText: 'https://cloud.example.com/remote.php/dav/files/user',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            keyboardType: TextInputType.url,
            onChanged: (_) => _saveCredentials(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _usernameController,
            decoration: InputDecoration(
              labelText: t.sync_webdav_username,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (_) => _saveCredentials(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordController,
            decoration: InputDecoration(
              labelText: t.sync_webdav_password,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
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
