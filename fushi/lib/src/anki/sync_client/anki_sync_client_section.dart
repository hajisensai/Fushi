import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/anki_sync/anki_sync_session.dart';

import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/anki/sync_client/anki_sync_client_actions.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 本节启用开关的设置搜索落点 id（与 settings_schema_card_creation.dart 的
/// `SettingsBodySearchEntry` 同一个）。
const String kAnkiSyncClientSearchTargetId = 'card_creation.anki.sync_client';

/// 「Anki 同步（无需安装 Anki）」设置节：选后端、登录同步服务器、看同步状态。
///
/// 本机没有 `fushi-anki-sync` 时整节不渲染（[PlatformServices.offersAnkiSyncClient]）。
/// 登录凭据只落本机（[AnkiSyncAccount]），密码不保存：登录换回 hkey 后就丢掉。
class AnkiSyncClientSection extends ConsumerStatefulWidget {
  const AnkiSyncClientSection({super.key});

  @override
  ConsumerState<AnkiSyncClientSection> createState() =>
      _AnkiSyncClientSectionState();
}

class _AnkiSyncClientSectionState extends ConsumerState<AnkiSyncClientSection> {
  final TextEditingController _server = TextEditingController();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();
  StreamSubscription<AnkiSyncState>? _sub;
  AnkiSyncState? _state;
  AnkiSyncAccount? _account;
  bool _switching = false;

  /// 用户亲手展开 / 折叠过的结果；null = 还没动过，跟随 [_defaultExpanded]。
  bool? _userExpanded;

  /// 已消费的设置搜索跳转代号（[SettingsSearchReveal.generation]）。
  int _searchGeneration = -1;

  /// 默认展开态只对**未启用**的用户折叠：这是高风险的实验功能（同步到 AnkiWeb
  /// 可能被拒绝或动账号），不该让不了解的用户一眼点到；但已启用的用户必须一眼
  /// 看到同步状态与「还有 N 张卡没同步」——折起来等于把告警藏掉。跟随 [enabled]
  /// 实时求值（而不是 initState 抄一次）：页面开着时经 CLI / 档案切换启用，
  /// 这里同样立刻展开。
  static bool _defaultExpanded({required bool enabled}) => enabled;

  /// 搜索跳到本节的开关（`card_creation.anki.sync_client`）时，落点
  /// [SettingsSearchTarget] 只在展开时才构建；折叠着就没人消费挂点，跳转落空且
  /// [SettingsSearchReveal.pendingItemId] 一直悬挂。所以在构建子树**之前**先认领
  /// 这次跳转并展开（同 SettingsSectionContainer 的搜索展开），同一帧里落点随即
  /// 构建、消费挂点、滚动高亮。
  void _expandForPendingSearchReveal() {
    if (_searchGeneration == SettingsSearchReveal.generation) return;
    if (SettingsSearchReveal.pendingItemId != kAnkiSyncClientSearchTargetId) {
      return;
    }
    _searchGeneration = SettingsSearchReveal.generation;
    _userExpanded = true;
  }

  /// 已登录时点了「重新登录」（凭据过期 / 改了密码）：显示预填好的登录表单。
  bool _relogin = false;

  AnkiSyncSession? get _session => ankiSyncClientSessionOf(ref);

  @override
  void initState() {
    super.initState();
    final AnkiSyncSession? session = _session;
    if (session == null) return;
    _sub = session.states.listen((AnkiSyncState s) {
      if (mounted) setState(() => _state = s);
      unawaited(_loadAccount());
    });
    unawaited(session.refresh());
    unawaited(_loadAccount());
  }

  Future<void> _loadAccount() async {
    final AnkiSyncAccount? account = await _session?.account();
    if (!mounted) return;
    setState(() {
      _account = account;
      if (account != null && _username.text.isEmpty) {
        _server.text = account.server ?? '';
        _username.text = account.username;
      }
    });
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final PlatformServices platform = ref.watch(platformServicesProvider);
    if (!platform.offersAnkiSyncClient) return const SizedBox.shrink();
    final bool enabled = ref.watch(
      ankiViewModelProvider.select((s) => s.settings.useAnkiSyncClient),
    );
    final AnkiSyncState? state = _state;
    final bool busy = state?.phase == AnkiSyncPhase.busy;
    _expandForPendingSearchReveal();
    final bool expanded = _userExpanded ?? _defaultExpanded(enabled: enabled);
    return AdaptiveSettingsSection(
      title: t.anki_sync_client_section_title,
      children: <Widget>[
        AdaptiveSettingsRow(
          key: const ValueKey<String>('anki-sync-client-expander'),
          title: t.anki_sync_client_advanced_title,
          subtitle: t.anki_sync_client_advanced_hint,
          icon: expanded ? FushiIcons.expandLess : FushiIcons.expandMore,
          showIcon: true,
          onTap: () => setState(() => _userExpanded = !expanded),
        ),
        if (expanded)
          SettingsSearchTarget(
            id: kAnkiSyncClientSearchTargetId,
            child: AdaptiveSettingsSwitchRow(
              title: t.anki_sync_client_use_title,
              subtitle: t.anki_sync_client_use_hint,
              value: enabled,
              onChanged: _switching ? null : _setEnabled,
            ),
          ),
        if (expanded && enabled) ...<Widget>[
          AdaptiveSettingsRow(
            // 状态行首图标按阶段换语义：同步中 / 受阻 / 失败 / 已同步 / 未登录。
            icon: _statusIcon(state),
            showIcon: true,
            title: _statusTitle(),
            subtitle: _statusDetail(state),
            titleMaxLines: 2,
            subtitleMaxLines: 6,
            trailing: busy
                ? const SizedBox.square(
                    dimension: 24,
                    child: FushiCircularProgressIndicator(strokeWidth: 3),
                  )
                : null,
          ),
          if (_account == null || _relogin)
            ..._signInRows(busy)
          else
            ..._signedInRows(busy),
        ],
      ],
    );
  }

  List<Widget> _signInRows(bool busy) => <Widget>[
    AdaptiveSettingsRow(
      title: t.anki_sync_client_server_title,
      controlBelow: true,
      trailing: AdaptiveSettingsTextField(
        controller: _server,
        hintText: t.anki_sync_client_server_hint,
        keyboardType: TextInputType.url,
      ),
    ),
    AdaptiveSettingsRow(
      title: t.anki_sync_client_username_title,
      controlBelow: true,
      trailing: AdaptiveSettingsTextField(controller: _username),
    ),
    AdaptiveSettingsRow(
      title: t.anki_sync_client_password_title,
      controlBelow: true,
      trailing: AdaptiveSettingsTextField(
        controller: _password,
        obscureText: true,
      ),
    ),
    AdaptiveSettingsRow(
      title: t.anki_sync_client_sign_in,
      icon: FushiIcons.login,
      showIcon: true,
      onTap: busy ? null : _signIn,
    ),
    if (_account != null)
      AdaptiveSettingsRow(
        title: t.cancel,
        icon: FushiIcons.close,
        showIcon: true,
        onTap: () => setState(() => _relogin = false),
      ),
  ];

  List<Widget> _signedInRows(bool busy) => <Widget>[
    AdaptiveSettingsRow(
      title: t.anki_sync_client_sync_now,
      icon: FushiIcons.sync,
      showIcon: true,
      onTap: busy ? null : _syncNow,
    ),
    AdaptiveSettingsRow(
      title: t.anki_sync_client_relogin,
      icon: FushiIcons.key,
      showIcon: true,
      onTap: busy ? null : () => setState(() => _relogin = true),
    ),
    AdaptiveSettingsRow(
      title: t.anki_sync_client_sign_out,
      icon: FushiIcons.logout,
      showIcon: true,
      onTap: busy ? null : _signOut,
    ),
  ];

  IconData _statusIcon(AnkiSyncState? state) {
    if (_account == null) return FushiIcons.cloudOff;
    return switch (state?.phase) {
      AnkiSyncPhase.busy => FushiIcons.cloudSync,
      AnkiSyncPhase.blocked => FushiIcons.warning,
      AnkiSyncPhase.failed => FushiIcons.error,
      _ =>
        (state?.unsynced ?? 0) == 0
            ? FushiIcons.success
            : FushiIcons.cloudUpload,
    };
  }

  String _statusTitle() {
    final AnkiSyncAccount? account = _account;
    if (account == null) return t.anki_sync_client_status_signed_out;
    return t.anki_sync_client_status_signed_in(
      user: account.username,
      server: account.server ?? 'AnkiWeb',
    );
  }

  String? _statusDetail(AnkiSyncState? state) {
    if (state == null || _account == null) return null;
    final List<String> lines = <String>[
      switch (state.phase) {
        AnkiSyncPhase.busy => t.anki_sync_client_status_busy,
        AnkiSyncPhase.blocked => t.anki_sync_client_status_blocked,
        // 限流（HTTP 429）给人话与自动重试时刻，不给 helper 的 Rust 原文。
        AnkiSyncPhase.failed when state.rateLimitedUntil != null =>
          t.anki_sync_client_status_rate_limited(
            time: _formatTime(state.rateLimitedUntil!),
          ),
        AnkiSyncPhase.failed => t.anki_sync_client_status_failed(
          error: state.message ?? '',
        ),
        _ =>
          state.unsynced == 0
              ? t.anki_sync_client_status_all_synced
              : t.anki_sync_client_status_unsynced(count: state.unsynced),
      },
      if (state.phase != AnkiSyncPhase.idle && state.unsynced > 0)
        t.anki_sync_client_status_unsynced(count: state.unsynced),
      if (state.failing > 0)
        t.anki_sync_client_status_failing(
          count: state.failing,
          error: state.lastError ?? '',
        ),
      if (state.lastSyncAt != null)
        t.anki_sync_client_status_last_sync(
          time: _formatTime(state.lastSyncAt!),
        ),
    ];
    return lines.join('\n');
  }

  static String _formatTime(int ms) {
    final DateTime d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  /// 切后端的唯一落地路径：持久化 → 运行时选择 → 重建仓库 provider（与移动端
  /// 「改用 AnkiConnect」同一顺序，三步缺一步就是存储与运行时不一致）。
  Future<void> _setEnabled(bool value) async {
    if (value && !await _confirmEnable()) return;
    // 确认框期间页面可能已被关掉。
    if (!mounted) return;
    setState(() => _switching = true);
    try {
      await setAnkiSyncClientEnabled(ref, value);
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  Future<void> _signIn() async {
    final AnkiSyncSession? session = _session;
    if (session == null) return;
    final String server = _server.text.trim();
    final String? endpoint = server.isEmpty ? null : server;
    if (endpoint == null && !await _confirmAnkiWeb()) return;
    try {
      await signInAnkiSyncClient(
        ref,
        session,
        endpoint: endpoint,
        username: _username.text.trim(),
        password: _password.text,
      );
      _password.clear();
      if (mounted) setState(() => _relogin = false);
      await _loadAccount();
    } on AnkiSyncHasUnsyncedNotes catch (e) {
      _toast(t.anki_sync_client_has_unsynced(count: e.count));
    } catch (e) {
      _toast(t.anki_sync_client_sign_in_failed(error: '$e'));
    }
  }

  Future<void> _syncNow() async {
    try {
      await _session?.syncNow();
    } catch (_) {
      // 原因已经进了状态行（AnkiSyncPhase.failed）。
    }
  }

  Future<void> _signOut() async {
    final AnkiSyncSession? session = _session;
    if (session == null) return;
    try {
      await session.signOut();
    } on AnkiSyncHasUnsyncedNotes catch (e) {
      // 退出会丢掉这些卡：只有用户明确确认放弃才继续。
      if (!await _confirmDiscard(e.count)) return;
      await session.signOut(discardUnsynced: true);
    }
    await _loadAccount();
  }

  /// 破坏性确认：M3E 对话框 + errorContainer 图标徽标 + error 色确认键。
  Future<bool> _confirmDiscard(int count) => showFushiConfirmDialog(
    context: context,
    title: t.anki_sync_client_sign_out,
    message: t.anki_sync_client_discard_confirm(count: count),
    cancelLabel: t.cancel,
    confirmLabel: t.anki_sync_client_discard_action,
    icon: FushiIcons.logout,
    destructive: true,
  );

  Future<bool> _confirmEnable() => showFushiConfirmDialog(
    context: context,
    title: t.anki_sync_client_enable_warn_title,
    message: t.anki_sync_client_enable_warn_body,
    cancelLabel: t.cancel,
    confirmLabel: t.anki_sync_client_enable_warn_confirm,
    icon: FushiIcons.warning,
    destructive: true,
  );

  Future<bool> _confirmAnkiWeb() => showFushiConfirmDialog(
    context: context,
    title: t.anki_sync_client_ankiweb_title,
    message: t.anki_sync_client_ankiweb_body,
    cancelLabel: t.cancel,
    confirmLabel: t.anki_sync_client_ankiweb_confirm,
    icon: FushiIcons.cloud,
  );

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(FushiSnackBar(content: Text(msg)));
  }
}
