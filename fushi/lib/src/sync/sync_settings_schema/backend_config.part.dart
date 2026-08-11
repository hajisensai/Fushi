// GENERATED-NOTE: extracted from sync_settings_schema.dart (TODO-585).
part of '../sync_settings_schema.dart';

// Backend picker + per-backend credential config widgets (WebDAV / FTP / SFTP) and their selection helpers.
// Shares the parent library's imports + private scope (_syncSettings / _showSnackBar / _SyncSettingsState).
// The three credential forms are thin configurations of one shared scaffold
// (_CredentialConfigWidget); per-backend trim/parse/persist semantics live in
// each form's static callbacks, moved verbatim from the former copies.

// ── Shared credential form scaffold ─────────────────────────────────

/// One text field of a [_CredentialConfigWidget] form. [initialText] is only
/// the pre-load controller seed (the form renders nothing until the async
/// load lands, mirroring the former per-backend widgets).
class _CredentialFieldSpec {
  const _CredentialFieldSpec({
    required this.label,
    this.hint,
    this.obscure = false,
    this.keyboardType = TextInputType.text,
    this.maxLines = 1,
    this.initialText = '',
  });

  final String label;
  final String? hint;
  final bool obscure;
  final TextInputType keyboardType;
  final int maxLines;
  final String initialText;
}

/// Shared scaffold for the WebDAV / FTP / SFTP credential forms: owns the
/// [TextEditingController] lifecycle, the load-once gate, the fire-and-forget
/// save with [ErrorLogService] logging (HBK-AUDIT-162), and the test-connection
/// spinner/button row. Persistence and probe semantics stay per-backend:
/// [load] returns one text per [fields] entry (plus the switch value), [save]
/// receives the RAW controller texts (each backend keeps its own trim/parse
/// rules verbatim), and [runTest] performs the probe and returns the snackbar
/// message (success or failure — it must not throw).
class _CredentialConfigWidget extends StatefulWidget {
  const _CredentialConfigWidget({
    required this.settingsContext,
    required this.fields,
    required this.load,
    required this.save,
    required this.runTest,
    required this.saveLogTag,
    this.switchTitle,
    this.testButtonChild,
  });

  final SettingsContext settingsContext;
  final List<_CredentialFieldSpec> fields;

  /// Reads the persisted values: one string per [fields] entry, plus the
  /// switch value (ignored when [switchTitle] is null).
  final Future<(List<String>, bool)> Function(SyncRepository repo) load;

  /// Persists the raw controller texts (+ switch value).
  final Future<void> Function(
      SyncRepository repo, List<String> texts, bool switchValue) save;

  /// Probes the backend with the raw controller texts (+ switch value) and
  /// returns the snackbar message. Must handle its own errors.
  final Future<String> Function(List<String> texts, bool switchValue) runTest;

  /// [ErrorLogService] tag for save failures (called fire-and-forget from
  /// onChanged, so failures must be logged, not silently dropped).
  final String saveLogTag;

  /// When non-null, renders an [AdaptiveSettingsSwitchRow] between the fields
  /// and the test button (FTP's TLS toggle).
  final String? switchTitle;

  /// Custom test-button content; defaults to `Text(t.sync_test_connection)`.
  final Widget? testButtonChild;

  @override
  State<_CredentialConfigWidget> createState() =>
      _CredentialConfigWidgetState();
}

class _CredentialConfigWidgetState extends State<_CredentialConfigWidget> {
  late final List<TextEditingController> _controllers;
  bool _switchValue = false;
  bool _isTesting = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _controllers = <TextEditingController>[
      for (final _CredentialFieldSpec field in widget.fields)
        TextEditingController(text: field.initialText),
    ];
    _loadCredentials();
  }

  @override
  void dispose() {
    for (final TextEditingController controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  List<String> get _texts => _controllers
      .map((TextEditingController c) => c.text)
      .toList(growable: false);

  Future<void> _loadCredentials() async {
    final repo = SyncRepository(widget.settingsContext.appModel.database);
    final (List<String> texts, bool switchValue) = await widget.load(repo);
    if (mounted) {
      setState(() {
        for (int i = 0; i < _controllers.length; i++) {
          _controllers[i].text = texts[i];
        }
        _switchValue = switchValue;
        _loaded = true;
      });
    }
  }

  Future<void> _saveCredentials() async {
    // Called fire-and-forget from onChanged; log write failures so they are
    // not silently dropped (HBK-AUDIT-162).
    try {
      final repo = SyncRepository(widget.settingsContext.appModel.database);
      await widget.save(repo, _texts, _switchValue);
    } catch (e, stack) {
      ErrorLogService.instance.log(widget.saveLogTag, e, stack);
    }
  }

  Future<void> _testConnection() async {
    await _saveCredentials();
    setState(() => _isTesting = true);
    try {
      final String message = await widget.runTest(_texts, _switchValue);
      if (mounted) _showSnackBar(context, message);
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
          for (int i = 0; i < widget.fields.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: 12),
            FushiTextField(
              controller: _controllers[i],
              labelText: widget.fields[i].label,
              hintText: widget.fields[i].hint,
              obscureText: widget.fields[i].obscure,
              keyboardType: widget.fields[i].keyboardType,
              maxLines: widget.fields[i].maxLines,
              onChanged: (_) => _saveCredentials(),
            ),
          ],
          if (widget.switchTitle != null) ...<Widget>[
            const SizedBox(height: 8),
            AdaptiveSettingsSwitchRow(
              title: widget.switchTitle!,
              value: _switchValue,
              onChanged: (bool v) {
                setState(() => _switchValue = v);
                _saveCredentials();
              },
            ),
            const SizedBox(height: 8),
          ] else
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
                    child:
                        widget.testButtonChild ?? Text(t.sync_test_connection),
                  ),
          ),
        ],
      ),
    );
  }
}

// ── WebDAV config widget ─────────────────────────────────────────────

class _WebDavConfigWidget extends StatelessWidget {
  const _WebDavConfigWidget({required this.settingsContext});
  final SettingsContext settingsContext;

  static Future<(List<String>, bool)> _load(SyncRepository repo) async {
    return (
      <String>[
        await repo.getWebDavUrl() ?? '',
        await repo.getWebDavUsername() ?? '',
        await repo.getWebDavPassword() ?? '',
      ],
      false,
    );
  }

  static Future<void> _save(
      SyncRepository repo, List<String> texts, bool _) async {
    final String url = texts[0].trim();
    final String username = texts[1].trim();
    final String password = texts[2];
    await repo.setWebDavUrl(url.isEmpty ? null : url);
    await repo.setWebDavUsername(username.isEmpty ? null : username);
    await repo.setWebDavPassword(password.isEmpty ? null : password);
  }

  static Future<String> _runTest(List<String> texts, bool _) async {
    final String url = texts[0].trim();
    final String username = texts[1].trim();
    final String password = texts[2];
    // 仅 URL 必填；用户名/密码留空 = 匿名 / 无鉴权 WebDAV（局域网自建、本机服务
    // 等合法场景），不再当作「缺少字段」硬拦（BUG-1016）。
    if (url.isEmpty) {
      return t.sync_webdav_test_failed(message: t.sync_webdav_missing_fields);
    }
    try {
      await WebDavSyncBackend.instance.testConnection(
        url: url,
        username: username,
        password: password,
      );
      return t.sync_connection_success;
    } catch (e) {
      // SyncAuthError / SyncBackendError / anything else all render the same
      // friendly detail (the former three catch arms were identical).
      return t.sync_webdav_test_failed(message: friendlySyncErrorDetail(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return _CredentialConfigWidget(
      settingsContext: settingsContext,
      saveLogTag: 'SyncConfig.saveWebDav',
      fields: <_CredentialFieldSpec>[
        _CredentialFieldSpec(
          label: t.sync_webdav_url,
          hint: 'https://cloud.example.com/remote.php/dav/files/user',
          keyboardType: TextInputType.url,
        ),
        _CredentialFieldSpec(label: t.sync_username),
        _CredentialFieldSpec(label: t.sync_password, obscure: true),
      ],
      load: _load,
      save: _save,
      runTest: _runTest,
      testButtonChild: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.wifi_find, size: 18),
          const SizedBox(width: 8),
          Text(t.sync_test_connection),
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
    // BUG-1088：互联回到「同步方式」选择器。解耦（独立分类 + 独立开关，可与云备份
    // 并存）保留，但把备份后端指向互联必须能从这里直接选——曾经唯一的入口是互联页
    // 的「设为备份后端」按钮，而它又被 host 门控藏掉，host 设备上入口彻底消失。
    // 选中后连接配置仍在「Hibiki 互联」分类（选择器下方有指引行）。
    case SyncBackendType.fushiServer:
      return true;
    case SyncBackendType.googleDrive:
    case SyncBackendType.webDav:
    case SyncBackendType.ftp:
    case SyncBackendType.sftp:
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
    case SyncBackendType.fushiServer:
      return t.sync_backend_fushi_server;
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
    await applyBackupBackendChange(
      SyncRepository(widget.settingsContext.appModel.database),
      previous: previous,
      next: value,
    );
    // BUG-1088：选互联做同步方式时顺手打开互联总开关——不开互联，连接配置区不显示、
    // 通道认证也过不去，选完就是个死后端。反向（选回云盘）不动互联开关，二者可并存。
    if (value == SyncBackendType.fushiServer && !state.interconnectEnabled) {
      await state.setInterconnectEnabled(true);
    }
    widget.settingsContext.refresh();
  }
}

/// 切换云备份后端时必须一起做的持久化副作用，集中一处：写 backendType、清目录缓存
/// （缓存的 folder id 只对旧后端有意义）、离开 FTP 时清掉 FTP 专属的 TLS 标记。
///
/// 后端选择器（[_BackendSelectorWidgetState._selectBackend]）与互联页的
/// 「用互联做备份后端」按钮（[_InterconnectBackupBackendWidget]）共用本函数，两个
/// 入口不会漂成两套切换语义。不碰内存态 `_SyncSettingsState.backendType`——那是调用方
/// 各自的 UI 状态。
Future<void> applyBackupBackendChange(
  SyncRepository repo, {
  required SyncBackendType previous,
  required SyncBackendType next,
}) async {
  await repo.setBackendType(next);
  // BUG-1576：清**这次切换涉及的两格**（切走的 + 切到的），不再一刀切清空全局
  // 单份键。旧行为下「切后端 = 目录缓存归零」这个保证逐字保留（切到的那格里可能
  // 躺着上一次配这个后端时的布局，服务器地址早改了也说不定）；变化只在于互联
  // 通道那格不再被无关的云后端切换连累、白白重解析一遍目录。
  await repo.clearFolderCache(SyncChannelScope.forBackendType(previous));
  await repo.clearFolderCache(SyncChannelScope.forBackendType(next));
  if (previous == SyncBackendType.ftp && next != SyncBackendType.ftp) {
    await repo.setFtpTlsEnabled(false);
  }
}

// ── FTP config widget ───────────────────────────────────────────────

class _FtpConfigWidget extends StatelessWidget {
  const _FtpConfigWidget({required this.settingsContext});
  final SettingsContext settingsContext;

  static Future<(List<String>, bool)> _load(SyncRepository repo) async {
    return (
      <String>[
        await repo.getFtpHost() ?? '',
        (await repo.getFtpPort()).toString(),
        await repo.getFtpUsername() ?? '',
        await repo.getFtpPassword() ?? '',
      ],
      await repo.isFtpTlsEnabled(),
    );
  }

  static Future<void> _save(
      SyncRepository repo, List<String> texts, bool useTls) async {
    final String host = texts[0].trim();
    final String user = texts[2].trim();
    final String pass = texts[3];
    final int port = int.tryParse(texts[1].trim()) ?? 21;
    await repo.setFtpHost(host.isEmpty ? null : host);
    await repo.setFtpPort(port);
    await repo.setFtpUsername(user.isEmpty ? null : user);
    await repo.setFtpPassword(pass.isEmpty ? null : pass);
    await repo.setFtpTlsEnabled(useTls);
  }

  static Future<String> _runTest(List<String> texts, bool useTls) async {
    try {
      await FtpSyncBackend.testConnection(
        host: texts[0].trim(),
        port: int.tryParse(texts[1].trim()) ?? 21,
        username: texts[2].trim(),
        password: texts[3],
        useTls: useTls,
      );
      return t.sync_connection_success;
    } catch (e) {
      return '${t.sync_connection_failed}: ${friendlySyncErrorDetail(e)}';
    }
  }

  @override
  Widget build(BuildContext context) {
    return _CredentialConfigWidget(
      settingsContext: settingsContext,
      saveLogTag: 'SyncConfig.saveFtp',
      fields: <_CredentialFieldSpec>[
        _CredentialFieldSpec(label: t.sync_host, hint: 'ftp.example.com'),
        _CredentialFieldSpec(
          label: t.sync_port,
          keyboardType: TextInputType.number,
          initialText: '21',
        ),
        _CredentialFieldSpec(label: t.sync_username),
        _CredentialFieldSpec(label: t.sync_password, obscure: true),
      ],
      load: _load,
      save: _save,
      runTest: _runTest,
      switchTitle: t.sync_use_tls,
    );
  }
}

// ── SFTP config widget ──────────────────────────────────────────────

class _SftpConfigWidget extends StatelessWidget {
  const _SftpConfigWidget({required this.settingsContext});
  final SettingsContext settingsContext;

  static Future<(List<String>, bool)> _load(SyncRepository repo) async {
    return (
      <String>[
        await repo.getSftpHost() ?? '',
        (await repo.getSftpPort()).toString(),
        await repo.getSftpUsername() ?? '',
        await repo.getSftpPassword() ?? '',
        await repo.getSftpPrivateKey() ?? '',
      ],
      false,
    );
  }

  static Future<void> _save(
      SyncRepository repo, List<String> texts, bool _) async {
    final String host = texts[0].trim();
    final String user = texts[2].trim();
    final String pass = texts[3];
    final int port = int.tryParse(texts[1].trim()) ?? 22;
    final String key = texts[4].trim();
    await repo.setSftpHost(host.isEmpty ? null : host);
    await repo.setSftpPort(port);
    await repo.setSftpUsername(user.isEmpty ? null : user);
    await repo.setSftpPassword(pass.isEmpty ? null : pass);
    await repo.setSftpPrivateKey(key.isEmpty ? null : key);
  }

  static Future<String> _runTest(List<String> texts, bool _) async {
    try {
      final String pass = texts[3];
      final String key = texts[4].trim();
      await SftpSyncBackend.instance.testConnection(
        host: texts[0].trim(),
        port: int.tryParse(texts[1].trim()) ?? 22,
        username: texts[2].trim(),
        password: pass.isEmpty ? null : pass,
        privateKey: key.isEmpty ? null : key,
      );
      return t.sync_connection_success;
    } catch (e) {
      return '${t.sync_connection_failed}: ${friendlySyncErrorDetail(e)}';
    }
  }

  @override
  Widget build(BuildContext context) {
    return _CredentialConfigWidget(
      settingsContext: settingsContext,
      saveLogTag: 'SyncConfig.saveSftp',
      fields: <_CredentialFieldSpec>[
        _CredentialFieldSpec(label: t.sync_host, hint: 'ssh.example.com'),
        _CredentialFieldSpec(
          label: t.sync_port,
          keyboardType: TextInputType.number,
          initialText: '22',
        ),
        _CredentialFieldSpec(label: t.sync_username),
        _CredentialFieldSpec(label: t.sync_password, obscure: true),
        _CredentialFieldSpec(
          label: t.sync_private_key,
          hint: '-----BEGIN OPENSSH PRIVATE KEY-----',
          maxLines: 4,
        ),
      ],
      load: _load,
      save: _save,
      runTest: _runTest,
    );
  }
}
