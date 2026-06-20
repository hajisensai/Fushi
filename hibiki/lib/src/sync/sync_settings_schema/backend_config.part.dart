// GENERATED-NOTE: extracted from sync_settings_schema.dart (TODO-585).
part of '../sync_settings_schema.dart';

// Backend picker + per-backend credential config widgets (WebDAV / FTP / SFTP) and their selection helpers.
// Shares the parent library's imports + private scope (_syncSettings / _showSnackBar / _SyncSettingsState); moved verbatim.

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
          _showSnackBar(context,
              t.sync_webdav_test_failed(message: t.sync_webdav_missing_fields));
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
