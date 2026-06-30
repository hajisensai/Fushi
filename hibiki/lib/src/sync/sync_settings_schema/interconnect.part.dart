// GENERATED-NOTE: extracted from sync_settings_schema.dart (TODO-585).
part of '../sync_settings_schema.dart';

// Hibiki P2P interconnect: client config, host server mode, LAN discovery.
// Shares the parent library's imports + private scope (_syncSettings / _showSnackBar / _SyncSettingsState); moved verbatim.

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
  // TODO-963 M2: a manual-IP pairing handshake is in flight (drives a busy
  // indicator + blocks concurrent add/edit while the host approval dialog runs).
  bool _pairingManual = false;

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
              hintText: 'https://192.168.1.100:38765',
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

    bool added = false;
    setState(() {
      final List<HibikiClientUrl> copy = <HibikiClientUrl>[..._urls];
      if (index != null) {
        final bool dupElsewhere = copy.asMap().entries.any(
            (MapEntry<int, HibikiClientUrl> e) =>
                e.key != index && e.value.url == result);
        if (!dupElsewhere) {
          // 编辑保留已有指纹/展示名（copyWith），只换 URL 文本。
          copy[index] = copy[index].copyWith(url: result);
        }
      } else if (!copy.any((HibikiClientUrl u) => u.url == result)) {
        copy.add(HibikiClientUrl(url: result));
        added = true;
      }
      _urls = copy;
    });
    await _persistUrls();

    // TODO-963 M2: 新增地址后走「探测 → 配对」。手动输入 IP 也能发起配对（不再只挂
    // mDNS 发现设备）：ping 探测可达 + 取指纹做 TOFU → 双确认 → pair/v2 → 自动落
    // token + 指纹（免手粘 token）。探测失败 / 非 hibiki 时静默保留地址（向后兼容：
    // 用户仍可手填 token）。
    if (added) {
      await _attemptManualPair(result);
    }
  }

  /// TODO-963 M2: 手动 IP 配对编排（与 LAN 发现共用 [_runPairingV2]）。
  /// 流程：normalize URL → /api/ping 探测（https 先 TOFU 捕获指纹核对）→ host 支持
  /// v2 配对则双确认（确认身份 + 输 PIN）→ pair/v2 → 落 token + 指纹（TOFU 记录）。
  Future<void> _attemptManualPair(String rawUrl) async {
    final String baseUrl = WebDavOps.normalizeUrl(rawUrl);
    final Uri? parsed = Uri.tryParse(baseUrl);
    if (parsed == null || parsed.host.isEmpty) return;
    final bool isHttps = parsed.scheme.toLowerCase() == 'https';

    // https 首连：先用一次性 TOFU 探测捕获 host 证书指纹（仅取指纹，不传数据）。
    String? capturedFingerprint;
    if (isHttps) {
      final int port = parsed.hasPort ? parsed.port : 443;
      capturedFingerprint =
          await HibikiTofuProbe.captureFingerprint(parsed.host, port);
      if (!mounted) return;
    }

    // /api/ping 探测：确认 hibiki + 支持 v2 + 取展示名/指纹（https 用捕获指纹钉扎读）。
    final HibikiPingResult? ping = await fetchHibikiPing(
      baseUrl,
      pinnedFingerprint: capturedFingerprint,
    );
    if (!mounted) return;
    if (ping == null || !ping.isHibiki || !ping.supportsPairV2) {
      _showSnackBar(context, t.sync_pair_not_hibiki);
      return;
    }
    // https host 的钉扎指纹以 ping 回传为准（与捕获一致），明文 http 无指纹。
    final String? fingerprint =
        isHttps ? (ping.fingerprint ?? capturedFingerprint) : null;
    // https 必须有指纹才能继续（否则无法钉扎，拒绝裸 https）。
    if (isHttps && (fingerprint == null || fingerprint.isEmpty)) {
      _showSnackBar(context, t.sync_pair_failed);
      return;
    }

    await _runPairingV2(
      baseUrl: baseUrl,
      fingerprint: fingerprint,
      deviceName: ping.deviceName,
    );
  }

  /// TODO-963 M2: 双确认 v2 配对的共享编排（手动 IP + 可选 LAN 复用）。
  /// 第一步弹窗确认 host 身份（展示名 + 指纹），第二步收 6 位 PIN（host pinRequired
  /// 时），随后跑 [HibikiPairV2Client.pair]，成功后经 TOFU 记录器落 url+指纹+token。
  /// [fingerprint] 为 null 表示明文 http（无钉扎，pinned 探测退化为普通连接）。
  Future<void> _runPairingV2({
    required String baseUrl,
    required String? fingerprint,
    String? deviceName,
  }) async {
    // 第一重确认：核对要连接的设备身份（展示名 + 证书指纹）。
    final bool confirmed = await _confirmPairIdentity(
      deviceName: deviceName,
      fingerprint: fingerprint,
    );
    if (!mounted || !confirmed) return;

    // 第二重：收 PIN（公网/host 要求时）。LAN 免 PIN 时 host 会返回 pinRequired:false，
    // pair() 不带 proof；这里仍先收 PIN（可留空）以覆盖公网强制场景——pair() 内部按
    // pinRequired 决定是否真正使用。
    final String? pin = await _promptPairPinInput();
    if (!mounted || pin == null) return; // 取消。

    setState(() => _pairingManual = true);
    String message;
    try {
      final HibikiPairV2Client client = HibikiPairV2Client(
        baseUrl: baseUrl,
        // 明文 http 无指纹钉扎：传空指纹时 pinned client 仍会构造但 http 不触发
        // 证书校验，故安全；真正的 https 必有指纹。
        expectedFingerprint: fingerprint ?? '',
      );
      final HibikiPairV2Outcome outcome = await client.pair(
        deviceName: _localDeviceName(),
        pin: pin.isEmpty ? null : pin,
      );
      if (!mounted) return;
      switch (outcome) {
        case HibikiPairV2Success(:final String token):
          message = await _onPairSuccess(baseUrl, token, fingerprint);
        case HibikiPairV2Failure(:final String reason):
          message = _pairV2FailureMessage(reason);
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('ManualPair:$baseUrl', e, stack);
      message = t.sync_pair_failed;
    } finally {
      if (mounted) setState(() => _pairingManual = false);
    }
    if (mounted) _showSnackBar(context, message);
  }

  /// 配对成功收尾：经 TOFU 记录器把 url+指纹+展示名写进候选列表（指纹变更会抛
  /// [HibikiFingerprintMismatchException] → 告警，绝不覆盖），落 token，刷新 UI。
  Future<String> _onPairSuccess(
    String baseUrl,
    String token,
    String? fingerprint,
  ) async {
    try {
      await _repo.addHibikiClientUrl(
        baseUrl,
        fingerprint: fingerprint,
        deviceName: null,
      );
    } on HibikiFingerprintMismatchException catch (e, stack) {
      ErrorLogService.instance.log('ManualPair.fingerprintChanged', e, stack);
      return t.sync_pair_fingerprint_changed;
    }
    await _repo.setHibikiClientToken(token);
    await _reloadFromStore();
    _syncSettings(widget.settingsContext).reloadClientConfig();
    return t.sync_pair_success;
  }

  String _pairV2FailureMessage(String reason) {
    switch (reason) {
      case 'pin':
        return t.sync_pair_pin_wrong;
      case 'declined':
        return t.sync_pair_denied;
      case 'unavailable':
        return t.sync_pair_unavailable;
      default:
        return t.sync_pair_failed;
    }
  }

  /// 第一重确认弹窗：展示要连接的设备身份（名 + 指纹），让用户核对后再继续。
  Future<bool> _confirmPairIdentity({
    String? deviceName,
    String? fingerprint,
  }) async {
    final bool? ok = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) {
        final HibikiDesignTokens tokens = HibikiDesignTokens.of(ctx);
        return HibikiDialogFrame(
          maxWidth: 460,
          insetPadding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.card,
            vertical: tokens.spacing.card,
          ),
          scrollable: false,
          child: HibikiModalSheetFrame(
            title: t.sync_pair_confirm_identity_title,
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
                Text(t.sync_pair_confirm_identity_body(
                  device: (deviceName != null && deviceName.trim().isNotEmpty)
                      ? deviceName
                      : t.sync_pair_unknown_device,
                )),
                if (fingerprint != null && fingerprint.isNotEmpty) ...<Widget>[
                  SizedBox(height: tokens.spacing.gap),
                  Text(t.sync_pair_fingerprint_label,
                      style: Theme.of(ctx).textTheme.labelSmall),
                  const SizedBox(height: 4),
                  SelectableText(
                    fingerprint,
                    style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                        ),
                  ),
                ],
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
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(t.sync_pair_continue),
                ),
              ],
            ),
          ),
        );
      },
    );
    return ok ?? false;
  }

  /// 第二重确认弹窗：收 host 屏幕显示的 6 位 PIN。返回 null=取消；空串=免 PIN 继续。
  Future<String?> _promptPairPinInput() async {
    final TextEditingController pinController = TextEditingController();
    final String? pin = await showAppDialog<String>(
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
            title: t.sync_pair_enter_pin_title,
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
                Text(t.sync_pair_enter_pin_body),
                SizedBox(height: tokens.spacing.gap),
                HibikiTextField(
                  controller: pinController,
                  labelText: t.sync_pair_enter_pin_title,
                  keyboardType: TextInputType.number,
                ),
              ],
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
                  onPressed: () =>
                      Navigator.pop(ctx, pinController.text.trim()),
                  child: Text(t.sync_pair_continue),
                ),
              ],
            ),
          ),
        );
      },
    );
    pinController.dispose();
    return pin;
  }

  /// This device's own advertised name, sent to the host so its approval prompt
  /// can identify who is asking. Mirrors [_LanDiscoveryWidgetState._localDeviceName].
  String _localDeviceName() {
    try {
      final String host = Platform.localHostname;
      if (host.trim().isNotEmpty) return 'Hibiki · $host';
    } catch (_) {/* localHostname can throw on some platforms */}
    return 'Hibiki';
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
                return HibikiReorderDragListener(
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
              onPressed: (lockedByServer || _pairingManual)
                  ? null
                  : () => _addOrEditUrl(),
              icon: _pairingManual
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child:
                          adaptiveIndicator(context: context, strokeWidth: 2),
                    )
                  : const Icon(Icons.add, size: 18),
              label: Text(_pairingManual ? t.sync_pair_pairing : t.dialog_add),
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
  late final TextEditingController _portController;
  bool _loaded = false;

  // The HibikiSyncServer + LAN broadcast are owned app-wide by
  // appModel.syncServerController now, NOT by this page (BUG-085). This widget
  // is a thin view that drives start/stop and reflects its running state.
  HibikiSyncServerController get _serverController =>
      widget.settingsContext.appModel.syncServerController;

  @override
  void initState() {
    super.initState();
    _portController = TextEditingController(text: '$_port');
    _serverController.addListener(_onServerChanged);
    // Rebuild when the client-connection flag flips so the toggle re-gates.
    _syncSettings(widget.settingsContext)
        .roleRevision
        .addListener(_onRoleRevision);
    _loadSettings();
  }

  @override
  void dispose() {
    _serverController.removeListener(_onServerChanged);
    _syncSettings(widget.settingsContext)
        .roleRevision
        .removeListener(_onRoleRevision);
    _portController.dispose();
    // NOTE: do NOT stop the server here. It is owned app-wide by AppModel now
    // (BUG-085); leaving this settings page must not kill the running host.
    super.dispose();
  }

  void _onRoleRevision() {
    if (mounted) setState(() {});
  }

  void _onServerChanged() {
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
      // The app-level controller already starts the host on launch; this is an
      // idempotent belt-and-suspenders for the rare case the page opens before
      // that ran. start() no-ops when already running.
      if (enabled) await _serverController.startIfEnabled();
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

  Future<void> _regenerateToken() async {
    final newToken = HibikiSyncServer.generateToken();
    final repo = SyncRepository(widget.settingsContext.appModel.database);
    await repo.setServerPassword(newToken);
    setState(() => _token = newToken);
    // Bounce the running host so the freshly-persisted token takes effect.
    if (_serverController.isRunning) await _serverController.restart();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    final bool running = _serverController.isRunning;
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
                      // Reflect the toggle while starting; the controller
                      // persists enabled on success and resets it on failure
                      // (HBK-AUDIT-167).
                      setState(() => _enabled = true);
                      final HibikiServerStartOutcome outcome =
                          await _serverController.start();
                      if (!mounted) return;
                      switch (outcome) {
                        case HibikiServerStarted():
                          _syncSettings(widget.settingsContext)
                              .setServerEnabled(true);
                          setState(() {});
                        case HibikiServerPortInUse(:final int port):
                          setState(() => _enabled = false);
                          _syncSettings(widget.settingsContext)
                              .setServerEnabled(false);
                          // this.context (State.context) is guarded by the
                          // !mounted early-return above.
                          _showSnackBar(this.context,
                              t.sync_server_port_in_use(port: port));
                        case HibikiServerStartError(:final String message):
                          setState(() => _enabled = false);
                          _syncSettings(widget.settingsContext)
                              .setServerEnabled(false);
                          _showSnackBar(
                              this.context, t.sync_error(message: message));
                      }
                    } else {
                      setState(() => _enabled = false);
                      _syncSettings(widget.settingsContext)
                          .setServerEnabled(false);
                      await _serverController.stop(persistDisabled: true);
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
                child: Text(
                    '${t.sync_server_running}: ${_serverController.boundPort}',
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
      final LanDiscoveryService discovery =
          LanDiscoveryService(deviceId: deviceId);
      _discovery = discovery;
      // Register with the app-level controller so the app-exit hook can stop
      // this Bonsoir browser before the engine is torn down (TODO-036). The
      // widget still owns dispose()/unregister for the normal page-close path.
      widget.settingsContext.appModel.syncServerController
          .registerDiscovery(discovery);
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
    final LanDiscoveryService? discovery = _discovery;
    if (discovery != null) {
      // Drop it from the exit-teardown set first (idempotent) so the controller
      // never double-disposes an already-disposed browser.
      widget.settingsContext.appModel.syncServerController
          .unregisterDiscovery(discovery);
      discovery.dispose();
    }
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
