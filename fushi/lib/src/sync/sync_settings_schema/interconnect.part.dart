// GENERATED-NOTE: extracted from sync_settings_schema.dart (TODO-585).
part of '../sync_settings_schema.dart';

// Hibiki P2P interconnect: client config, host server mode, LAN discovery.
// Shares the parent library's imports + private scope (_syncSettings / _showSnackBar / _SyncSettingsState); moved verbatim.

// ── Hibiki server config widget (connect to another Hibiki instance) ─

class _FushiServerConfigWidget extends StatefulWidget {
  const _FushiServerConfigWidget({required this.settingsContext});
  final SettingsContext settingsContext;

  @override
  State<_FushiServerConfigWidget> createState() =>
      _FushiServerConfigWidgetState();
}

class _FushiServerConfigWidgetState extends State<_FushiServerConfigWidget>
    with _PairingV2FlowMixin<_FushiServerConfigWidget> {
  @override
  SettingsContext get _pairSettingsContext => widget.settingsContext;

  @override
  void _setPairV2Busy(bool active) {
    if (mounted) setState(() => _pairingManual = active);
  }

  late final TextEditingController _tokenController;
  late final FocusNode _tokenFocus;
  List<FushiClientUrl> _urls = <FushiClientUrl>[];
  // url -> last test-connection result (null = not tested this session).
  final Map<String, bool> _reachable = <String, bool>{};
  bool _isTesting = false;
  bool _loaded = false;
  // BUG-1562：「已连接 ✓」那一行的判据是 token 非空，而 token 活在
  // [_tokenController] 里。build 直接读 controller.text 却没人监听它 —— 手贴/清空
  // token（[_saveToken] 只落库不 setState）后本行状态原地不动，直到别的原因触发
  // 重建。改为把「有没有 token」提成 State 字段，由 controller 监听驱动。
  bool _tokenPresent = false;
  // TODO-963 M2: a manual-IP pairing handshake is in flight (drives a busy
  // indicator + blocks concurrent add/edit while the host approval dialog runs).
  bool _pairingManual = false;

  SyncRepository get _repo =>
      SyncRepository(widget.settingsContext.appModel.database);

  @override
  void initState() {
    super.initState();
    _tokenController = TextEditingController();
    _tokenController.addListener(_onTokenTextChanged);
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
    _tokenController.removeListener(_onTokenTextChanged);
    _tokenController.dispose();
    super.dispose();
  }

  void _onRoleRevision() {
    if (mounted) setState(() {});
  }

  /// token 文本变化 → 只在「有/没有」翻面时重建（BUG-1562）。逐字符 setState 没有
  /// 意义，而 [_load] / [_reloadFromStore] 在自己的 setState 里已同步过
  /// [_tokenPresent]，所以那两条路径进到这里时值相同、直接 no-op，不会嵌套 setState。
  void _onTokenTextChanged() {
    final bool present = _tokenController.text.trim().isNotEmpty;
    if (present == _tokenPresent || !mounted) return;
    setState(() => _tokenPresent = present);
  }

  Future<void> _load() async {
    final List<FushiClientUrl> urls = await _repo.getFushiClientUrls();
    final String? token = await _repo.getFushiClientToken();
    if (!mounted) return;
    setState(() {
      _urls = urls;
      _tokenController.text = token ?? '';
      _tokenPresent = _tokenController.text.trim().isNotEmpty;
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
    final List<FushiClientUrl> urls = await _repo.getFushiClientUrls();
    final String? token = await _repo.getFushiClientToken();
    if (!mounted) return;
    setState(() {
      _urls = urls;
      if (!_tokenFocus.hasFocus) {
        _tokenController.text = token ?? '';
      }
      _tokenPresent = _tokenController.text.trim().isNotEmpty;
    });
    _syncSettings(widget.settingsContext)
        .setHasClientConnection(urls.isNotEmpty);
  }

  Future<void> _persistUrls() async {
    // BUG-1693：连通性结果按 URL 键控，URL 集合一变（删除/改址）就把不再对应任何
    // 列表行的结果清掉——否则删掉再重加同一地址会立刻显示上一轮的 ✓/✗（陈旧结果
    // 冒充新测）。收在这里而不是各调用点：所有 URL 变更都必经本方法（见下），
    // 单点清理消除「哪个入口忘了清」的特例。
    _reachable.removeWhere(
        (String url, bool _) => !_urls.any((FushiClientUrl u) => u.url == url));
    await _repo.setFushiClientUrls(_urls);
    // Keep the role lock honest: deleting the last URL must release the server
    // toggle; adding one must lock it. Every URL mutation routes through here.
    _syncSettings(widget.settingsContext)
        .setHasClientConnection(_urls.isNotEmpty);
  }

  Future<void> _saveToken() async {
    try {
      final String token = _tokenController.text.trim();
      await _repo.setFushiClientToken(token.isEmpty ? null : token);
      // BUG-1550：手贴 token 是用户的显式覆盖动作，必须压过各地址行上残留的
      // per-peer token（否则那些行仍用旧凭据，用户贴了也不生效、还查不出为什么）。
      await _repo.clearFushiClientUrlTokens();
    } catch (e, stack) {
      ErrorLogService.instance.log('SyncConfig.saveFushiToken', e, stack);
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
        final FushiDesignTokens tokens = FushiDesignTokens.of(ctx);
        return FushiDialogFrame(
          maxWidth: 420,
          insetPadding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.card,
            vertical: tokens.spacing.card,
          ),
          scrollable: false,
          child: FushiModalSheetFrame(
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
            body: FushiTextField(
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
    // BUG-1562：弹窗是个 async gap，期间宿主 section 可能被门控藏掉（关互联总开关
    // → interconnectActive 变 false → 本 widget dispose）。下面就要 setState，
    // 没有这道守卫就是 dispose 后 setState 崩溃。同文件 [_load]/[_reloadFromStore]
    // 是现成范式。
    if (!mounted) return;
    if (result == null || result.isEmpty) return;
    final String normalizedResult;
    try {
      normalizedResult = normalizeFushiInterconnectManualUrl(result);
    } catch (e, stack) {
      // BUG-1741：这里根本没发起过连接——normalize 只是解析字符串。说「连接失败」
      // 会把用户支去查网络/防火墙，而真正要改的是他刚敲错的那行地址。
      ErrorLogService.instance.log('SyncConfig.addFushiUrl', e, stack);
      if (mounted) _showSnackBar(context, t.sync_pair_invalid_url);
      return;
    }

    // BUG-987：add 模式（index==null）一律触发配对，与「是否新增列表条目」解耦。旧实现
    // 只在 added==true 时配对，导致「重加一个列表里已存在的地址」被去重守卫吞成 added=false
    // → 不再发起配对 → 点「添加」毫无反应。去重只应防列表出现重复条目，不该拦住重新配对
    // （尤其首次配对失败后用户想靠再点「添加」重试）。
    bool shouldPair = false;
    setState(() {
      final List<FushiClientUrl> copy = <FushiClientUrl>[..._urls];
      if (index != null) {
        final bool dupElsewhere = copy.asMap().entries.any(
            (MapEntry<int, FushiClientUrl> e) =>
                e.key != index && e.value.url == normalizedResult);
        if (!dupElsewhere) {
          final FushiClientUrl edited = copy[index];
          // BUG-1557：只有「还是同一个端点」（scheme+host+port 未变，只是补斜杠/改
          // 大小写）才保留已铉扎的指纹；改指另一台机器时旧指纹就是一把开不了
          // 新锁的旧钥匙，https 握手次次失败而 UI 里无处清除——那条地址就此死掉。
          // 清指纹后下次配对重新 TOFU；令牌不动（同一台 host 换 IP 时它仍有效）。
          copy[index] = isSameInterconnectEndpoint(edited.url, normalizedResult)
              ? edited.copyWith(url: normalizedResult)
              : FushiClientUrl(
                  url: normalizedResult,
                  enabled: edited.enabled,
                  deviceName: edited.deviceName,
                  token: edited.token,
                );
        }
      } else {
        // 新地址才加进列表（去重防重复条目）；已存在则不重复加，但仍会在下方发起配对。
        if (!copy.any((FushiClientUrl u) => u.url == normalizedResult)) {
          copy.add(FushiClientUrl(url: normalizedResult));
        }
        shouldPair = true;
      }
      _urls = copy;
    });
    await _persistUrls();

    // TODO-963 M2: 新增/重加地址后走「探测 → 配对」。手动输入 IP 也能发起配对（不再只挂
    // mDNS 发现设备）：ping 探测可达 + 取指纹做 TOFU → 双确认 → pair/v2 → 自动落
    // token + 指纹（免手粘 token）。探测失败 / 非 hibiki 时静默保留地址（向后兼容：
    // 用户仍可手填 token）。
    if (shouldPair) {
      await _attemptManualPair(normalizedResult);
    }
  }

  /// TODO-963 M2: 手动 IP 配对编排（与 LAN 发现共用 [_runPairingV2]）。
  /// 流程：normalize URL → /api/ping 探测（https 先 TOFU 捕获指纹核对）→ host 支持
  /// v2 配对则双确认（确认身份 + 输 PIN）→ pair/v2 → 落 token + 指纹（TOFU 记录）。
  Future<void> _attemptManualPair(String rawUrl) async {
    // BUG-1562：忙态必须覆盖**全程**。此前 [_pairingManual] 只由 [_runPairingV2]
    // 内部置起，而它前面还有 TOFU 指纹捕获 + /api/ping 探测两次秒级网络往返；那段
    // 窗口里「添加」和各行「重新配对」按钮都还是亮的，用户多点几下就能并发跑起两条
    // 配对流程 —— 两条都会走到 [_onPairSuccess] 写 token，后写的覆盖先写的，最终
    // 落库的凭据可能不是最后成功那台的。入口先自查再置忙，两道一起才封得住窗口
    // （LAN 发现路径的 [_pairingUrl] 全程覆盖就是现成范式）。
    if (_pairingManual) return;
    final String baseUrl = WebDavOps.normalizeUrl(rawUrl);
    final Uri? parsed = Uri.tryParse(baseUrl);
    if (parsed == null || parsed.host.isEmpty) return;
    final bool isHttps = parsed.scheme.toLowerCase() == 'https';
    _setPairV2Busy(true);
    try {
      final int port = parsed.hasPort ? parsed.port : (isHttps ? 443 : 80);

      // https 首连：先用一次性 TOFU 探测捕获 host 证书指纹（仅取指纹，不传数据）。
      String? capturedFingerprint;
      if (isHttps) {
        final FushiTofuOutcome tofu =
            await FushiTofuProbe.probeFingerprint(parsed.host, port);
        if (!mounted) return;
        if (!tofu.speaksTls) {
          // BUG-1741：握手都没成，后面的 ping 必然也失败。此前这里不作分辨地
          // 一路走到「未找到 Fushi 设备」——而真相往往只是用户把 http host 写成了
          // https。分型后直接告诉他该改哪个字。
          _showSnackBar(context, _tofuFailureMessage(tofu.failure));
          return;
        }
        capturedFingerprint = tofu.fingerprint;
      }

      // /api/ping 探测：确认 hibiki + 支持 v2 + 取展示名/指纹（https 用捕获指纹钉扎读）。
      final FushiPingOutcome outcome = await probeFushiPing(
        baseUrl,
        pinnedFingerprint: capturedFingerprint,
      );
      if (!mounted) return;
      final FushiPingResult? ping = outcome.result;
      if (ping == null) {
        // BUG-1741：明文地址打不通时回头确认对端是不是 TLS-only。那不是「这里没有
        // 设备」，是「地址的 scheme 写错了」——两句话指向完全相反的排查方向，而旧
        // 实现把它们说成同一句。
        if (!isHttps && outcome.failure == FushiPingFailure.unreachable) {
          final FushiTofuOutcome tofu =
              await FushiTofuProbe.probeFingerprint(parsed.host, port);
          if (!mounted) return;
          if (tofu.speaksTls) {
            _showSnackBar(context, t.sync_pair_peer_requires_https);
            return;
          }
        }
        _showSnackBar(context, _pingFailureMessage(outcome.failure));
        return;
      }
      if (!ping.supportsPairV2) {
        // 连上了、确实是 Hibiki，只是版本太旧——与「找不到设备」是两回事。
        _showSnackBar(context, t.sync_pair_unavailable);
        return;
      }
      // https host 的钉扎指纹以 ping 回传为准（与捕获一致），明文 http 无指纹。
      final String? fingerprint =
          isHttps ? (ping.fingerprint ?? capturedFingerprint) : null;
      // https 必须有指纹才能继续（否则无法钉扎，拒绝裸 https）。
      if (isHttps && (fingerprint == null || fingerprint.isEmpty)) {
        // 语义就是「拿不到可钉扎的证书」，不是笼统的「配对失败」。
        _showSnackBar(context, t.sync_pair_tls_failed);
        return;
      }

      // 内层 [_runPairingV2] 自己也会置/清忙态；清完由本函数的 finally 兜底再清一次
      // （幂等），所以嵌套不会留下悬空忙态。
      await _runPairingV2(
        baseUrl: baseUrl,
        fingerprint: fingerprint,
        deviceName: ping.deviceName,
      );
    } finally {
      _setPairV2Busy(false);
    }
  }

  Future<void> _toggleUrl(int index) async {
    setState(() {
      final List<FushiClientUrl> copy = <FushiClientUrl>[..._urls];
      final FushiClientUrl u = copy[index];
      // TODO-961 gap②：copyWith 保留指纹/展示名（对齐编辑路径）；裸构造会把已
      // TOFU 钉扎的 fingerprintSha256 静默清掉，回明文降级。
      copy[index] = u.copyWith(enabled: !u.enabled);
      _urls = copy;
    });
    await _persistUrls();
  }

  Future<void> _deleteUrl(int index) async {
    setState(() {
      _urls = <FushiClientUrl>[..._urls]..removeAt(index);
    });
    await _persistUrls();
  }

  /// [newIndex] 是**最终下标**（FushiReorderableColumn 语义），不是 SDK
  /// `ReorderableListView` 的「移除前下标」——故这里没有 `newIndex--` 修正。
  /// 上/下移按钮同样按最终下标传（下移传 index+1）。
  Future<void> _reorderUrls(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    setState(() {
      final List<FushiClientUrl> copy = <FushiClientUrl>[..._urls];
      final FushiClientUrl item = copy.removeAt(oldIndex);
      copy.insert(newIndex, item);
      _urls = copy;
    });
    await _persistUrls();
  }

  Future<void> _testAll() async {
    // BUG-1693：这里不再先调 [_saveToken]——它带着 BUG-1550 的显式覆盖语义
    // （落全局键 + **清掉全部地址行的 per-peer token**），让「测试连接」变成一次
    // 静默的凭据改写。手动输入路径的 onChanged 已逐次落库，此处没有要补存的东西。
    if (_urls.isEmpty) {
      if (mounted) _showSnackBar(context, t.sync_connection_failed);
      return;
    }
    final String globalToken = _tokenController.text.trim();
    setState(() => _isTesting = true);
    for (final FushiClientUrl u in _urls) {
      // BUG-1693：凭据逐地址取（行上 per-peer token 优先、回落全局键），与全部
      // 真实同步消费点的 BUG-1550 规则一致。旧实现拿全局键测每一台：配对第二台
      // 后全局键被覆写，第一台恒被误报失败；全局键为空时更是整体早退，哪怕各
      // 地址行都带着自己的有效凭据。
      final String? token = interconnectTokenFor(u, globalToken);
      bool ok = false;
      if (token != null) {
        try {
          // 必须带上该地址钉扎的证书指纹：新版 host 默认走 https 自签证书，漏传指纹会
          // 让测试连接在 TLS 握手处失败，把可连的 host 误报成失败（TODO-1330）。
          await InterconnectSyncBackend.instance
              .testConnection(
                url: u.url,
                token: token,
                fingerprint: u.fingerprintSha256,
              )
              .timeout(const Duration(seconds: 5));
          ok = true;
        } catch (e, stack) {
          // Record why an address probe failed (auth vs network vs timeout)
          // instead of only showing a generic ✗ (HBK-AUDIT-165).
          ErrorLogService.instance.log('SyncTestAll:${u.url}', e, stack);
        }
      }
      // token == null：两头都拿不出凭据，不发必然 401 的请求，直接标失败。
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
          // 列表标题与下方 _LanDiscoveryWidget 的「局域网设备」同级对齐：section 标题
          // 「连接到其他设备」罩着两个 widget，此前本列表裸露无题，空列表时更是只剩一个
          // 孤零零的「添加」按钮，用户不知道这块是什么、该怎么连。
          Text(t.interconnect_peer_list_title,
              style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          if (_urls.isEmpty)
            Text(
              t.interconnect_peer_list_empty,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          if (_urls.isNotEmpty)
            // 自实现的 FushiReorderableColumn 而非 SDK ReorderableListView：
            // 整棵树活在 FushiAppUiScale 的 Transform.scale 之下，而 SDK 的
            // _DragItemProxy 用「全局坐标 − overlay 原点」纯平移、不认祖先缩放，
            // 「界面大小」非 100% 时拖拽浮层按 (1−s)×距离 漂移、缩小时一拖即飞出
            // 屏幕（BUG-778 同根因，当时只修了合集与词典两条链路，这里漏了）。
            // 本组件把浮层渲染在列表自身 Stack、指针经 globalToLocal 消掉祖先
            // 缩放，任意缩放系数下都精确跟手。原本就是 shrinkWrap +
            // NeverScrollableScrollPhysics（外层滚动），与本组件语义一致。
            FushiReorderableColumn(
              itemCount: _urls.length,
              keyForIndex: (int index) => ValueKey<String>(_urls[index].url),
              onReorder: _reorderUrls,
              itemBuilder: (BuildContext context, int index) {
                final FushiClientUrl u = _urls[index];
                final bool? ok = _reachable[u.url];
                return FushiReorderDragListener(
                  key: ValueKey<String>(u.url),
                  index: index,
                  child: FushiListItem(
                    padding: EdgeInsets.zero,
                    // BUG-1184：标题是对端 URL，右侧还有一排控件；单行 ellipsis 在窄屏
                    // 上只显示得到 `http…`，等于认不出是哪台设备。行高自由，放宽两行。
                    titleMaxLines: 2,
                    title: Text(
                      u.url,
                      maxLines: 2,
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
                        FushiIconButton(
                          icon: Icons.keyboard_arrow_up,
                          size: 18,
                          tooltip: t.move_up,
                          enabled: index > 0,
                          onTap: () => _reorderUrls(index, index - 1),
                        ),
                        FushiIconButton(
                          icon: Icons.keyboard_arrow_down,
                          size: 18,
                          tooltip: t.move_down,
                          enabled: index < _urls.length - 1,
                          onTap: () => _reorderUrls(index, index + 1),
                        ),
                        adaptiveSwitch(
                          context: context,
                          value: u.enabled,
                          onChanged: (_) => _toggleUrl(index),
                        ),
                        // TODO-1330：失败后「重新配对」入口——复用 _attemptManualPair
                        // 的 v2 编排（探测 → 确认身份 → 按需输 PIN → 落 token+指纹），
                        // 不必删地址再手动重加。LAN 免 PIN 会话重配对无需任何输入；公网
                        // 会话仍需按对方 PIN（安全设计使然，host 屏此时会常驻显示 PIN）。
                        FushiIconButton(
                          icon: Icons.sync,
                          size: 18,
                          tooltip: t.sync_pair_repair,
                          enabled: !lockedByServer && !_pairingManual,
                          onTap: () => _attemptManualPair(u.url),
                        ),
                        FushiIconButton(
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
          // TODO-1330 ④（改）：客户端令牌在配对成功后由 host 自动签发并填入，值是 host 按
          // 设备铸造的 per-peer token，与 host 面板显示的共享令牌天生不同。旧设计把这枚
          // 原始令牌当成一个显眼数字摆出来、再加说明解释「为何两端不一样」，反而让用户困惑。
          // 现在改为：已连接就只显示状态，原始令牌收进「手动填写」折叠项——手动粘贴对端令牌
          // 连接的回退路径仍在，只是不再和 host 端令牌摆成两个对不上的数字。per-peer 签发/
          // 鉴权/按设备吊销等后端安全机制一概不动。
          if (_tokenPresent)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: <Widget>[
                  Icon(Icons.check_circle_outline,
                      size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    t.sync_client_connected,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.primary),
                  ),
                ],
              ),
            ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            // 唯一的展开子项是带浮动标签的轮廓边框输入框：浮动后的标签骑在
            // 字段顶边、上半部分会溢出到字段上方（14sp 标签约 7px）。ExpansionTile 的
            // 展开体被 Expansible 包在 ClipRect 里（flutter widgets/expansible.dart），
            // childrenPadding 顶部为 0 时这半个标签被裁掉（BUG-755：「对端访问令牌」
            // 上半截不显示）。顶部留出浮动标签的溢出高度即可让标签完整渲染。
            childrenPadding: const EdgeInsets.only(top: 10),
            title: Text(
              t.sync_client_token_manual,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            children: <Widget>[
              FushiTextField(
                controller: _tokenController,
                focusNode: _tokenFocus,
                labelText: t.sync_client_token,
                onChanged: (_) => _saveToken(),
              ),
            ],
          ),
          // 「测试连接」只在本机作为客户端（连出到其它 host）时有意义：它探测配置的
          // 出站地址是否可达。本机作为服务端（serverEnabled → lockedByServer）时是一台
          // 被动数据源，没有出站连接可测，此时显示测试连接按钮既无意义又误导用户（与
          // BUG-084「服务端隐藏 sync now / compare」同一设计）。故服务端模式下隐藏。
          if (!lockedByServer) ...<Widget>[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: _isTesting
                  ? SizedBox(
                      width: 24,
                      height: 24,
                      child:
                          adaptiveIndicator(context: context, strokeWidth: 2),
                    )
                  : FilledButton.tonal(
                      onPressed: _testAll,
                      child: Text(t.sync_test_connection),
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Shared v2 pairing orchestration ─────────────────────────────────

/// TODO-961: v2 配对编排共享层——手动 IP（[_FushiServerConfigWidget]）与 LAN 发现
/// （[_LanDiscoveryWidget]）共用同一套「确认身份 → 收 PIN → pair/v2 → 落
/// token+指纹」流程，杜绝两份编排漂移。宿主只需提供 [SettingsContext] 与忙态回调。
mixin _PairingV2FlowMixin<T extends StatefulWidget> on State<T> {
  /// 宿主 widget 的 SettingsContext（读 AppModel/database + 广播配置刷新）。
  SettingsContext get _pairSettingsContext;

  /// 配对进行中的忙态（宿主用它驱动 spinner / 禁点；可为 no-op，若宿主在外层
  /// 自己管理忙态）。
  void _setPairV2Busy(bool active);

  SyncRepository get _pairRepo =>
      SyncRepository(_pairSettingsContext.appModel.database);

  /// TODO-963 M2: 双确认 v2 配对的共享编排（手动 IP + LAN 发现复用）。
  /// 第一步弹窗确认 host 身份（展示名 + 指纹），第二步收 6 位 PIN（host pinRequired
  /// 时），随后跑 [FushiPairV2Client.pair]，成功后经 TOFU 记录器落 url+指纹+token。
  /// [fingerprint] 为 null 表示明文 http（无钉扎，pinned 探测退化为普通连接）。
  Future<void> _runPairingV2({
    required String baseUrl,
    required String? fingerprint,
    String? deviceName,
  }) async {
    // BUG-1557：**最先**拿已存指纹比。旧顺序是先用新指纹把整套跑完（确认身份 →
    // 输 PIN → pair/v2 把本机设备名/deviceId 送给对方 → host 都把 peer 行落了库），
    // 最后才在 [_onPairSuccess] → `addFushiClientUrl` 里发现指纹不符。那时中止已经晚了：
    // 一个冒充已知 host 的对端已经拿到了我的设备标识。铉扎的意义就是「握手前先判」。
    if (!await _ensurePinnedFingerprintTrusted(baseUrl, fingerprint)) return;

    // 第一重确认：核对要连接的设备身份（展示名 + 证书指纹）。
    final bool confirmed = await _confirmPairIdentity(
      deviceName: deviceName,
      fingerprint: fingerprint,
    );
    if (!mounted || !confirmed) return;

    // 第二重：收 PIN——但**只有 host 要求 PIN 时才弹输入框**。是否需要 PIN 由 host 的
    // pair/v2 响应（pinRequired）决定，client 不能在得到该响应前就盲目弹「输入对方
    // PIN」（TODO-1273：LAN 免 PIN 时 host 根本不显示 PIN，旧实现却总是弹，造成「让我
    // 输 PIN 但对方没 PIN、我没输 PIN 却还是配上了」的困惑）。故把 PIN 收集下沉为回调，
    // 交给 pair() 在确认 pinRequired 后按需触发。
    _setPairV2Busy(true);
    String? message;
    try {
      final FushiPairV2Client client = FushiPairV2Client(
        baseUrl: baseUrl,
        // 明文 http 无指纹钉扎：传空指纹时 pinned client 仍会构造但 http 不触发
        // 证书校验，故安全；真正的 https 必有指纹。
        expectedFingerprint: fingerprint ?? '',
      );
      // TODO-961 M1b: 上报本机稳定 deviceId，host 据此发 per-peer token 并落库。
      final String clientDeviceId = await _pairRepo.getOrCreateDeviceId();
      final FushiPairV2Outcome outcome = await client.pair(
        deviceName: await _localDeviceName(),
        // 仅当 host 回报 pinRequired 时才被调用；LAN 免 PIN 全程不弹 PIN 框。
        pinProvider: _promptPairPinInput,
        clientDeviceId: clientDeviceId,
      );
      if (!mounted) return;
      switch (outcome) {
        case FushiPairV2Success(:final String token):
          message = await _onPairSuccess(baseUrl, token, fingerprint);
        case FushiPairV2Failure(:final String reason):
          // 'cancelled' = 用户在 PIN 输入框点了取消，静默收场不弹提示。
          message =
              reason == 'cancelled' ? null : _pairV2FailureMessage(reason);
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('PairV2:$baseUrl', e, stack);
      message = t.sync_pair_failed;
    } finally {
      _setPairV2Busy(false);
    }
    if (mounted && message != null) _showSnackBar(context, message);
  }

  /// BUG-1557：握手前的 TOFU 闸。返回 true = 可以继续配对。
  ///
  /// - 本地没存过这条地址的指纹（首连）/ 本次是明文 http（无指纹）→ 放行，保持原行为。
  /// - 存过且相等 → 放行。
  /// - 存过但不等 → **当场中止**，并给用户一个显式的「清除已存指纹重新信任」出口：
  ///   host 真的重装 / 重置了证书时，没这个入口那条地址就永远修不好（只能删了重加）；
  ///   同意后只清指纹、**不**惄悉新指纹，下一步仍走完整双确认（展示新指纹供核对）。
  Future<bool> _ensurePinnedFingerprintTrusted(
    String baseUrl,
    String? fingerprint,
  ) async {
    if (fingerprint == null || fingerprint.isEmpty) return true;
    final String? stored = await _pairRepo.getFushiClientFingerprint(baseUrl);
    if (!mounted) return false;
    if (stored == null || stored.isEmpty) return true;
    if (fingerprintEquals(stored, fingerprint)) return true;
    final bool retrust = await _confirmFingerprintRetrust(
      stored: stored,
      incoming: fingerprint,
    );
    if (!mounted) return false;
    if (!retrust) {
      _showSnackBar(context, t.sync_pair_fingerprint_changed);
      return false;
    }
    await _pairRepo.clearFushiClientFingerprint(baseUrl);
    return mounted;
  }

  /// BUG-1557：指纹不符的告警弹窗 + 唯一的重新信任入口。两个指纹都展示出来供
  /// 用户与对方屏幕核对；默认动作是取消（安全侧）。
  Future<bool> _confirmFingerprintRetrust({
    required String stored,
    required String incoming,
  }) async {
    final bool? ok = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) {
        final FushiDesignTokens tokens = FushiDesignTokens.of(ctx);
        final TextStyle? mono = Theme.of(ctx)
            .textTheme
            .bodySmall
            ?.copyWith(fontFamily: 'monospace');
        return FushiDialogFrame(
          maxWidth: 460,
          insetPadding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.card,
            vertical: tokens.spacing.card,
          ),
          scrollable: false,
          child: FushiModalSheetFrame(
            title: t.sync_pair_fingerprint_changed_title,
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
                Text(t.sync_pair_fingerprint_changed_body),
                SizedBox(height: tokens.spacing.gap),
                Text(t.sync_pair_fingerprint_stored_label,
                    style: Theme.of(ctx).textTheme.labelSmall),
                const SizedBox(height: 4),
                SelectableText(stored, style: mono),
                SizedBox(height: tokens.spacing.gap),
                Text(t.sync_pair_fingerprint_new_label,
                    style: Theme.of(ctx).textTheme.labelSmall),
                const SizedBox(height: 4),
                SelectableText(incoming, style: mono),
              ],
            ),
            footer: Wrap(
              alignment: WrapAlignment.end,
              spacing: tokens.spacing.gap,
              children: <Widget>[
                adaptiveDialogAction(
                  context: ctx,
                  isDefaultAction: true,
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(t.dialog_cancel),
                ),
                adaptiveDialogAction(
                  context: ctx,
                  isDestructiveAction: true,
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(t.sync_pair_fingerprint_retrust),
                ),
              ],
            ),
          ),
        );
      },
    );
    return ok ?? false;
  }

  /// 配对成功收尾：经 TOFU 记录器把 url+指纹+展示名写进候选列表（指纹变更会抛
  /// [FushiFingerprintMismatchException] → 告警，绝不覆盖），落 token，bump
  /// clientConfigRevision（client-config widget 监听后自动重载，单一真相源）。
  Future<String> _onPairSuccess(
    String baseUrl,
    String token,
    String? fingerprint,
  ) async {
    try {
      await _pairRepo.addFushiClientUrl(
        baseUrl,
        fingerprint: fingerprint,
        deviceName: null,
      );
    } on FushiFingerprintMismatchException catch (e, stack) {
      ErrorLogService.instance.log('PairV2.fingerprintChanged', e, stack);
      return t.sync_pair_fingerprint_changed;
    }
    // BUG-1550：per-peer token 落在**这条地址**上（同时写全局键作老配置回落）。
    // 只写全局键会让「配对第二台对端」把第一台的凭据覆盖掉，而第一台地址仍排在
    // 候选前列且可达 → 拿着别人的 token 撞 401 → 整个互联瘫痪。
    await _pairRepo.setFushiClientTokenForUrl(baseUrl, token);
    // BUG-1693：配对**成功**才代表互联真的投入使用，此刻才落「互联已启用」。
    // 已启用时（本 UI 的常态——配置区本就门控于互联开关）是幂等 no-op。
    await _syncSettings(_pairSettingsContext).setInterconnectEnabled(true);
    _syncSettings(_pairSettingsContext).reloadClientConfig();
    return t.sync_pair_success;
  }

  /// BUG-1741：把**配对前探测**的失败分型翻成人话。
  ///
  /// 探测层此前把「证书对不上」「超时」「端口没人」「不是 Hibiki」全压成一个
  /// null，UI 只能一律说「此地址未找到 Fushi 设备」——对着一台明明在线、只是证书
  /// 换了的机器说「这里没有设备」，用户的排查方向从第一步就是错的。
  String _pingFailureMessage(FushiPingFailure? failure) {
    switch (failure) {
      case FushiPingFailure.tls:
        return t.sync_pair_tls_failed;
      case FushiPingFailure.timeout:
        return t.sync_pair_timeout;
      case FushiPingFailure.unreachable:
        return t.sync_connection_failed;
      case FushiPingFailure.notFushi:
      case null:
        return t.sync_pair_not_fushi;
    }
  }

  /// BUG-1741：TOFU 握手失败的人话。`notTls` 是最常见的一种——用户把明文 host
  /// 写成了 https，此时该说的是「改 scheme」而不是「配对失败」。
  String _tofuFailureMessage(FushiTofuFailure? failure) {
    switch (failure) {
      case FushiTofuFailure.notTls:
        return t.sync_pair_peer_not_https;
      case FushiTofuFailure.timeout:
        return t.sync_pair_timeout;
      case FushiTofuFailure.unreachable:
      case null:
        return t.sync_connection_failed;
    }
  }

  /// BUG-1553：把 client 的机器可读 reason 翻成人话。此前只认三个 reason，
  /// 限速 / TLS 指纹不符 / 超时统统落进 default 的「配对失败」——用户被 host 锁了
  /// 15 分钟却看不出来，只会一遍遍重试；证书不符这种安全事件也说成一样的话。
  String _pairV2FailureMessage(String reason) {
    switch (reason) {
      case 'pin':
        return t.sync_pair_pin_wrong;
      case 'declined':
        return t.sync_pair_denied;
      case 'unavailable':
        return t.sync_pair_unavailable;
      case 'rate_limited':
        return t.sync_pair_rate_limited;
      case 'tls':
        return t.sync_pair_tls_failed;
      case 'timeout':
        return t.sync_pair_timeout;
      case 'expired':
        // BUG-1556：会话超时与「对端拒绝」不是一回事——前者重试就行，
        // 后者再试多少次都白搭。
        return t.sync_pair_expired;
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
        final FushiDesignTokens tokens = FushiDesignTokens.of(ctx);
        return FushiDialogFrame(
          maxWidth: 460,
          insetPadding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.card,
            vertical: tokens.spacing.card,
          ),
          scrollable: false,
          child: FushiModalSheetFrame(
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
        final FushiDesignTokens tokens = FushiDesignTokens.of(ctx);
        return FushiDialogFrame(
          maxWidth: 420,
          insetPadding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.card,
            vertical: tokens.spacing.card,
          ),
          scrollable: false,
          child: FushiModalSheetFrame(
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
                FushiTextField(
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
  /// (and later its paired-devices list) can identify who is asking. Sourced
  /// from the platform device-info service so mobile clients report their real
  /// hardware model instead of Android's meaningless "localhost" hostname
  /// (TODO-1356), never advertising "localhost" as the device name.
  Future<String> _localDeviceName() => resolveInterconnectDeviceName(
        _pairSettingsContext.appModel.platformServices.deviceInfo,
      );
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
  // TODO-961: 互联加密（HTTPS/TLS + TOFU 指纹钉扎）开关状态，镜像
  // sync_server_tls_enabled 偏好。
  bool _tlsEnabled = false;
  String? _token;
  late final TextEditingController _portController;
  bool _loaded = false;

  // TODO-961 M1b: 已配对设备（per-peer token 表 fushi_paired_peers 的行）。开启
  // 主机时加载，用于「移除已配对设备」列表；吊销后刷新。
  List<FushiPairedPeerRow> _pairedPeers = const <FushiPairedPeerRow>[];

  // The FushiSyncServer + LAN broadcast are owned app-wide by
  // appModel.syncServerController now, NOT by this page (BUG-085). This widget
  // is a thin view that drives start/stop and reflects its running state.
  FushiSyncServerController get _serverController =>
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
    if (!mounted) return;
    setState(() {});
    // BUG-1558：controller 在已配对设备表变动时也会通知（新设备配对成功 /
    // 吊销）。只 setState 重建不够——列表数据在 [_pairedPeers] 里，不重拉就永远
    // 是进页那一刻的快照，用户在设置页看着对方配对成功却不见新设备。
    unawaited(_reloadPairedPeers());
  }

  Future<void> _loadSettings() async {
    final repo = SyncRepository(widget.settingsContext.appModel.database);
    final enabled = await repo.isServerEnabled();
    final port = await repo.getServerPort();
    final bool tlsEnabled = await repo.getServerTlsEnabled();
    var token = await repo.getServerPassword();
    if (token == null) {
      token = FushiSyncServer.generateToken();
      await repo.setServerPassword(token);
    }
    // TODO-961 M1b: 预取已配对设备（server 开启时才展示列表，但不阻塞开关加载）。
    final List<FushiPairedPeerRow> peers =
        await _serverController.pairedPeers();
    if (mounted) {
      setState(() {
        _enabled = enabled;
        _tlsEnabled = tlsEnabled;
        _port = port;
        _portController.text = '$port';
        _token = token;
        _pairedPeers = peers;
        _loaded = true;
      });
      _syncSettings(widget.settingsContext).setServerEnabled(enabled);
      // The app-level controller already starts the host on launch; this is an
      // idempotent belt-and-suspenders for the rare case the page opens before
      // that ran. start() no-ops when already running.
      // BUG-1563：这次启动同样可能失败（端口被别的进程占了）。丢掉 outcome 就会让
      // 开关停在「已启用」而 host 根本没起来。
      if (enabled) {
        _applyStartOutcome(await _serverController.startIfEnabled());
      }
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

  /// 消费一次 host 启动/重启的结果（BUG-1563）。
  ///
  /// 成功 → 同步角色锁；失败 → 把开关拨回**真实**状态（host 并没有在跑）并把原因
  /// 上屏。此前只有开关那条路径认真读了 outcome，换 token / 开 TLS / 开页兜底启动
  /// 三处都把返回值直接丢掉：端口被占或证书生成失败时 host 静默消失，UI 却一直显示
  /// 「正在运行」，对端连不上而用户完全不知道发生过什么。
  ///
  /// 注意只动内存态：`serverEnabled` 这个持久意图由 controller 自己管（瞬时端口冲突
  /// 不该抹掉用户的选择，见 [FushiSyncServerController.start] 的 BUG-160 说明）。
  void _applyStartOutcome(FushiServerStartOutcome outcome) {
    if (!mounted) return;
    switch (outcome) {
      case FushiServerStarted():
        setState(() => _enabled = true);
        _syncSettings(widget.settingsContext).setServerEnabled(true);
      case FushiServerPortInUse(:final int port):
        setState(() => _enabled = false);
        _syncSettings(widget.settingsContext).setServerEnabled(false);
        _showSnackBar(context, t.sync_server_port_in_use(port: port));
      case FushiServerStartError(:final String message):
        setState(() => _enabled = false);
        _syncSettings(widget.settingsContext).setServerEnabled(false);
        _showSnackBar(context, t.sync_error(message: message));
    }
  }

  Future<void> _regenerateToken() async {
    final newToken = FushiSyncServer.generateToken();
    final repo = SyncRepository(widget.settingsContext.appModel.database);
    await repo.setServerPassword(newToken);
    setState(() => _token = newToken);
    // Bounce the running host so the freshly-persisted token takes effect.
    // BUG-1563：重启结果必须消费——重启是先 stop 再 start，start 失败就等于用户
    // 点了「重新生成令牌」把自己的 host 关掉了，静默丢弃返回值毫无道理。
    if (_serverController.isRunning) {
      _applyStartOutcome(await _serverController.restart());
    }
  }

  /// TODO-961: 切换互联加密（HTTPS/TLS）。持久化后若 host 正在运行则重启使新
  /// scheme 立即生效（含 mDNS TXT tls 标志随广播更新）；scheme 变了已配对设备的
  /// 存量 URL/指纹不再匹配，提示需重新配对。
  Future<void> _setTlsEnabled(bool v) async {
    setState(() => _tlsEnabled = v);
    await SyncRepository(widget.settingsContext.appModel.database)
        .setServerTlsEnabled(v);
    if (_serverController.isRunning) {
      // BUG-1563：开 TLS 要生成/加载自签证书再重新绑端口，是最容易失败的一次重启；
      // 失败时旧代码照样弹「已配对设备需重新配对」，等于对着一台已经不存在的 host
      // 给操作建议。失败改走 [_applyStartOutcome]：说清原因 + 开关回落真实状态。
      final FushiServerStartOutcome outcome = await _serverController.restart();
      if (!mounted) return;
      if (outcome is! FushiServerStarted) {
        _applyStartOutcome(outcome);
        return;
      }
    }
    if (mounted) _showSnackBar(context, t.sync_server_tls_repair_hint);
  }

  /// TODO-961 M1b: 重新拉取已配对设备列表（吊销 / 页面重进后刷新）。
  Future<void> _reloadPairedPeers() async {
    final List<FushiPairedPeerRow> peers =
        await _serverController.pairedPeers();
    if (mounted) setState(() => _pairedPeers = peers);
  }

  /// TODO-961 M1b: 移除一台已配对设备——删其 per-peer token 行，该设备下次请求即被
  /// 401 拒绝（吊销即时生效，controller 内部会清 server token 缓存）。
  Future<void> _revokePeer(FushiPairedPeerRow peer) async {
    final bool removed = await _serverController.revokePeer(peer.peerId);
    await _reloadPairedPeers();
    if (mounted && removed) {
      _showSnackBar(context, t.sync_paired_peer_removed);
    }
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
                      // TODO-961 B 段：全新设备首次启用 hosting 默认勾上 TLS（仅当
                      // TLS 与 serverEnabled 两个偏好 key 都从未写入过；存量用户
                      // 保持现状不动，见 applyFirstHostingTlsDefault 文档）。
                      final bool tlsDefaulted = await SyncRepository(
                              widget.settingsContext.appModel.database)
                          .applyFirstHostingTlsDefault();
                      if (!mounted) return;
                      if (tlsDefaulted) setState(() => _tlsEnabled = true);
                      // Reflect the toggle while starting; the controller
                      // persists enabled on success and resets it on failure
                      // (HBK-AUDIT-167).
                      setState(() => _enabled = true);
                      // BUG-1563：四个启动路径（开关 / 换 token / 开 TLS / 开页
                      // 兜底）共用同一个 outcome 消费点，不再各写各的 switch。
                      _applyStartOutcome(await _serverController.start());
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
            FushiTextField(
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
            const SizedBox(height: 8),
            // TODO-961: 互联加密开关——接 setServerTlsEnabled（自签证书 + TOFU
            // 指纹钉扎的用户入口）。
            AdaptiveSettingsSwitchRow(
              title: t.sync_server_tls_enable,
              subtitle: t.sync_server_tls_repair_hint,
              value: _tlsEnabled,
              onChanged: (bool v) => _setTlsEnabled(v),
            ),
            const SizedBox(height: 12),
            Text(t.sync_server_token,
                style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 4),
            // BUG-1184：令牌是等宽长串，原先硬钳 2 行且无 ellipsis —— 窄屏上尾部被
            // 直接切掉且毫无提示。令牌必须整串可见（用户要照着输/核对），去掉行数上限。
            SelectableText(
              _token ?? '',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
            ),
            const SizedBox(height: 8),
            // BUG-1184：两个 icon+label 按钮此前用 Row，窄屏（尤其英文/德文文案更长）
            // 合计宽度超过设置面板宽 → 真 RenderFlex overflow。改 Wrap 自然换行。
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
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
                TextButton.icon(
                  onPressed: _regenerateToken,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(t.sync_server_regenerate_token),
                ),
              ],
            ),
            // TODO-961 M1b: 已配对设备列表 + 逐台移除（吊销 per-peer token）。
            const SizedBox(height: 16),
            Text(t.sync_paired_peers_title,
                style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 4),
            if (_pairedPeers.isEmpty)
              Text(
                t.sync_paired_peers_empty,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              )
            else
              ..._pairedPeers.map(
                (FushiPairedPeerRow peer) => FushiListItem(
                  padding: EdgeInsets.zero,
                  // BUG-1184：设备名由用户自定义，可以很长；行高自由，放宽两行。
                  titleMaxLines: 2,
                  title: Text(
                    (peer.deviceName != null &&
                            peer.deviceName!.trim().isNotEmpty)
                        ? peer.deviceName!
                        : t.sync_paired_peer_unknown,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: (peer.lastSeenIp != null &&
                          peer.lastSeenIp!.trim().isNotEmpty)
                      ? Text(
                          peer.lastSeenIp!,
                          style: Theme.of(context).textTheme.bodySmall,
                        )
                      : null,
                  trailing: FushiIconButton(
                    icon: Icons.delete_outline,
                    size: 18,
                    tooltip: t.sync_paired_peer_remove,
                    onTap: () => _revokePeer(peer),
                  ),
                ),
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

class _LanDiscoveryWidgetState extends State<_LanDiscoveryWidget>
    with _PairingV2FlowMixin<_LanDiscoveryWidget> {
  @override
  SettingsContext get _pairSettingsContext => widget.settingsContext;

  /// 忙态由 [_pairingUrl] 在 [_connectToDevice] 全程驱动（进入即设、finally 清、
  /// 覆盖整个 v2 编排 await），无需在编排回调里二次翻转。
  @override
  void _setPairV2Busy(bool active) {}

  LanDiscoveryService? _discovery;
  List<FushiDevice> _devices = <FushiDevice>[];
  bool _scanning = false;
  bool _scanFailed = false;
  StreamSubscription<List<FushiDevice>>? _devicesSub;
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
    // BUG-1554：重扫前先退订上一条，否则每次重扫都留下一条仍在派发的订阅
    // （设备列表被多份同源事件反复刷、页面关闭时只取消得掉最后一条）。
    await _devicesSub?.cancel();
    _devicesSub = discovery.devices.listen((List<FushiDevice> devices) {
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

  /// TODO-961: 发现列表点击配对走 v2——先探测 scheme（TXT tls 标志定顺序、
  /// /api/ping 定案；https 先 TOFU 捕获指纹再钉扎读），再复用与手动 IP 同一条
  /// [_runPairingV2] 编排（TOFU→PIN→token+指纹落库）。老 host（无 /api/ping 或
  /// 不支持 v2）回落 [_pairLegacyV1] 明文老路径，行为零变化。
  Future<void> _connectToDevice(FushiDevice device) async {
    // One pairing attempt at a time: the awaited flow can hang for up to a
    // minute waiting on the host's approval dialog.
    if (_pairingUrl != null) return;
    final state = _syncSettings(widget.settingsContext);
    final repo = SyncRepository(widget.settingsContext.appModel.database);
    // BUG-1693：这里**不再**预写「互联已启用」。旧实现在探测/配对之前就
    // setInterconnectEnabled(true) 且失败不回滚——点一下就把开关写死。启用挪到
    // 配对真正成功的收尾（v2 走 [_onPairSuccess]，v1 走 [_pairLegacyV1] 拿到
    // token 之后），失败路径不留任何持久化副作用。

    setState(() => _pairingUrl = device.webDavUrl);
    try {
      final DiscoveredPairingProbeOutcome outcome =
          await probeDiscoveredPairingEndpointDetailed(
        host: device.host,
        port: device.port,
        tlsAdvertised: device.tlsEnabled,
      );
      if (!mounted) return;
      final DiscoveredPairingProbeResult? probe = outcome.result;
      if (probe != null && probe.ping.supportsPairV2) {
        // 先记录探明 scheme 的地址（host 拒绝也保留，可回退手粘 token）；钉扎
        // 指纹在配对成功后经 _onPairSuccess 落库（TOFU 记录器）。
        await repo.addFushiClientUrl(probe.baseUrl);
        // A client connection now exists → lock this device out of server mode.
        state.setHasClientConnection(true);
        await _runPairingV2(
          baseUrl: probe.baseUrl,
          fingerprint: probe.fingerprint,
          deviceName: (probe.ping.deviceName?.trim().isNotEmpty ?? false)
              ? probe.ping.deviceName
              : device.name,
        );
        return;
      }
      // BUG-1741：对端确证讲 TLS（或 mDNS 明说 tls=1）时**禁止**回落 v1。
      //
      // v1 只会往 `device.webDavUrl` 发明文 POST，而那个 getter 硬编码
      // `http://`（lan_discovery_service.dart）。TLS host 根本不 bind 明文端口，
      // 这一发必然抛，最后换来一句「配对失败」——真实原因（证书不符 / 超时）在
      // 三层探测里已经被吞光。更糟的是它还会把那条错的 http:// 地址写进候选列表，
      // 从此那台设备每次「测试连接」都失败，且 UI 里看不出 scheme 错了。
      if (probe == null && (outcome.peerSpeaksTls || device.tlsEnabled)) {
        _showSnackBar(
          context,
          '${device.name}: ${_pingFailureMessage(outcome.failure)}',
        );
        return;
      }
      // 探明是 https 端点却不支持 v2：同样不能拿明文 v1 去敲，只能如实说版本过旧。
      if (probe != null && probe.baseUrl.startsWith('https://')) {
        _showSnackBar(context, '${device.name}: ${t.sync_pair_unavailable}');
        return;
      }
      // 旧版 host：无 /api/ping 或不支持 v2 → v1 明文配对老路径（行为零变化）。
      // 已探明端点时用探明的 baseUrl，不再盲信硬编码 http 的 webDavUrl。
      await _pairLegacyV1(
        probe?.baseUrl ?? device.webDavUrl,
        device,
        repo,
        state,
      );
    } finally {
      if (mounted) setState(() => _pairingUrl = null);
      // Single source of truth bumped → client-config widget reloads URL + token.
      state.reloadClientConfig();
      widget.settingsContext.refresh();
    }
  }

  /// v1 明文配对（旧版 host 兼容路径，与 v2 化前的实现一致）：直接 POST
  /// /api/pair 等 host 审批发 token。仅在对端不支持 v2 时走到。
  Future<void> _pairLegacyV1(
    String baseUrl,
    FushiDevice device,
    SyncRepository repo,
    _SyncSettingsState state,
  ) async {
    // Always record the address (deduped) so the user keeps the URL even if
    // the host declines and they fall back to pasting the token.
    await repo.addFushiClientUrl(baseUrl);
    // A client connection now exists → lock this device out of server mode.
    state.setHasClientConnection(true);

    String message;
    try {
      final http.Response resp = await http
          .post(
            Uri.parse('$baseUrl/api/pair'),
            headers: <String, String>{'Content-Type': 'application/json'},
            body:
                jsonEncode(<String, String>{'name': await _localDeviceName()}),
          )
          // Outlast the host's 60s approval window so its auto-deny 403 reaches
          // us instead of us timing out first.
          .timeout(const Duration(seconds: 65));
      if (resp.statusCode == 200) {
        final dynamic body = jsonDecode(resp.body);
        final String? token =
            body is Map<String, dynamic> ? body['token'] as String? : null;
        if (token != null && token.isNotEmpty) {
          // BUG-1550：v1 老路径同样把凭据落在这条地址上（理由见 _onPairSuccess）。
          await repo.setFushiClientTokenForUrl(baseUrl, token);
          // BUG-1693：与 v2 路径一致——拿到 token（配对成功）才落「互联已启用」。
          await state.setInterconnectEnabled(true);
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
      ErrorLogService.instance.log('LanDiscovery.pair:$baseUrl', e, stack);
      message = t.sync_pair_failed;
    }
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
      // BUG-1555：host 对本会话强制 PIN，而 v1 根本没有 PIN 环节 → 直接拒。
      // 说清楚是「对方需要升级」，别让用户以为是对方手动拒了自己。
      if (decoded is Map && decoded['reason'] == 'upgrade_required') {
        return t.sync_pair_upgrade_required;
      }
    } catch (_) {/* older peers reply with a plain-text 403 body */}
    return t.sync_pair_unavailable;
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
          for (final FushiDevice device in _devices)
            FushiListItem(
              leading: const Icon(Icons.devices_outlined, size: 20),
              // BUG-1184：发现到的设备名 + WebDAV URL 都可能超出窄屏一行。
              titleMaxLines: 2,
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

// ── 用互联做备份后端 ────────────────────────────────────────────────
//
// 互联从「互斥的 backendType==fushiServer 单选」解耦成独立开关（PR#223）之后，
// 后端选择器不再列出互联（[_isBackendSelectable] 对 fushiServer 返回 false），
// 于是「备份/同步写到已配对设备而不是云盘」这条路径整个从 UI 上消失了——能力还在
// （[resolveSyncBackend] 仍把 fushiServer 解析成 [InterconnectSyncBackend]），只是
// 没有入口。这一行把入口放回互联自己的分类里：一个动作，把云备份通道指向对端主机。
//
// 退路：[_selectableBackends] 恒把当前值插回选项列表，所以设成互联之后，「同步与
// 备份」的后端选择器里仍能选回 Google Drive / WebDAV 等，不是单向门。
class _InterconnectBackupBackendWidget extends StatefulWidget {
  const _InterconnectBackupBackendWidget({required this.settingsContext});
  final SettingsContext settingsContext;

  @override
  State<_InterconnectBackupBackendWidget> createState() =>
      _InterconnectBackupBackendWidgetState();
}

class _InterconnectBackupBackendWidgetState
    extends State<_InterconnectBackupBackendWidget> {
  bool _busy = false;

  _SyncSettingsState get _state => _syncSettings(widget.settingsContext);

  @override
  void initState() {
    super.initState();
    // 同页配对成功后 hasClientConnection 才翻 true（roleRevision 通知），按钮据此解禁；
    // 不听就会停在「请先连接一台设备」直到重开页面。
    _state.roleRevision.addListener(_onRoleRevision);
  }

  @override
  void dispose() {
    _state.roleRevision.removeListener(_onRoleRevision);
    super.dispose();
  }

  void _onRoleRevision() {
    if (mounted) setState(() {});
  }

  Future<void> _useInterconnectAsBackend() async {
    final _SyncSettingsState state = _state;
    final SyncBackendType previous = state.backendType;
    if (previous == SyncBackendType.fushiServer) return;
    setState(() => _busy = true);
    try {
      await applyBackupBackendChange(
        SyncRepository(widget.settingsContext.appModel.database),
        previous: previous,
        next: SyncBackendType.fushiServer,
      );
      state.backendType = SyncBackendType.fushiServer;
      if (!mounted) return;
      _showSnackBar(context, t.interconnect_backup_backend_active);
      // 同步分类的后端选择器/凭据区都按 backendType 门控，刷新让它们立刻跟上。
      widget.settingsContext.refresh();
    } catch (e, stack) {
      // BUG-1563：原来只有 try/finally。[applyBackupBackendChange] 会连写多个偏好
      // （切后端 + 清上一后端的 root/cache），中途抛异常时库里已经半写、内存态却还是
      // 旧值 —— UI 显示「当前后端：Google Drive」而库里可能已经是互联，且异常逃逸成
      // unhandled zone error，用户零提示。真值回库里重读，让 UI 与库一致。
      ErrorLogService.instance.log('Interconnect.useAsBackupBackend', e, stack);
      state.backendType = await SyncRepository(
        widget.settingsContext.appModel.database,
      ).getBackendType();
      if (!mounted) return;
      // BUG-1693：走统一的友好错误翻译（对端全部探不到 → SyncPeerUnreachableError
      // → 「无法连接配对设备」），不再把裸异常 toString 直接上屏。
      _showSnackBar(context, t.sync_error(message: friendlySyncErrorDetail(e)));
      widget.settingsContext.refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final _SyncSettingsState state = _state;
    final bool active = state.backendType == SyncBackendType.fushiServer;
    final bool paired = state.hasClientConnection;
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AdaptiveSettingsRow(
            title: t.interconnect_backup_backend,
            subtitle: active
                ? t.interconnect_backup_backend_active
                : (paired
                    ? t.interconnect_backup_backend_hint
                    : t.interconnect_backup_backend_needs_pairing),
            icon: Icons.backup_outlined,
          ),
          Text(
            t.interconnect_backup_backend_current(
              backend: _backendLabel(state.backendType),
            ),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (!active) ...<Widget>[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                FilledButton.tonal(
                  onPressed:
                      (paired && !_busy) ? _useInterconnectAsBackend : null,
                  child: Text(t.interconnect_backup_backend_apply),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
