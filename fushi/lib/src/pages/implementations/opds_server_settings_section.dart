/// 「OPDS 书目服务器」设置区：用户自配的 OPDS 目录增删改 + 连接自检。
///
/// 与「发现来源」开关区（`discovery_source_settings_section.dart`）的分界，
/// 沿用视频域内置源 vs 自配 Torznab 的既定切法：
/// - **内置源**只有开/关，停用清单是一个逗号分隔的偏好；
/// - **自配服务器**是一份带 `enabled` 字段的记录列表，增删改都在这里。
///
/// 两者不共用「停用」语义——自配服务器关掉就是不进注册表，不会在源开关区里
/// 再出现一条既在清单里又被排除的幽灵行。
///
/// 草稿态 + 防抖保存 + dispose 时 flush 的形状照抄
/// `video_external_provider_settings_section.dart` 的 Torznab 段：逐字符落盘会
/// 把每个中间态（`http:/`、半截主机名）都塞进偏好并触发一次注册表重建。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/opds_server_config.dart';
import 'package:fushi/src/media/discovery/sources/opds_discovery_source.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/source_toggle_section.dart';
import 'package:fushi/utils.dart';

/// 输入停止多久后落盘（与 Torznab 段同值）。
const Duration _kSaveDebounce = Duration(milliseconds: 600);

class OpdsServerSettingsSection extends ConsumerStatefulWidget {
  const OpdsServerSettingsSection({super.key});

  @override
  ConsumerState<OpdsServerSettingsSection> createState() =>
      _OpdsServerSettingsSectionState();
}

class _OpdsServerSettingsSectionState
    extends ConsumerState<OpdsServerSettingsSection> {
  List<_OpdsDraft> _drafts = <_OpdsDraft>[];
  bool _loaded = false;
  Timer? _saveDebounce;

  /// build 期抓住的 AppModel。
  ///
  /// **不能**在 [dispose] 里 `ref.read`：那时 element 已经 deactivated，
  /// Riverpod 的 `ProviderScope.containerOf` 会抛
  /// 「Looking up a deactivated widget's ancestor is unsafe」。而 dispose 里的
  /// flush 恰恰只在「用户在防抖窗口内切走页面」时才跑——也就是说那条路径**必然**
  /// 走到这里，用 ref 的写法在生产里 100% 触发，并且把用户那次编辑一起吞掉。
  AppModel? _appModel;

  /// 每条服务器的自检结果（key = draft.id）。
  final Map<String, _ProbeState> _probes = <String, _ProbeState>{};

  @override
  void dispose() {
    final bool pending = _saveDebounce?.isActive ?? false;
    _saveDebounce?.cancel();
    // 用户在防抖窗口内切走页面时不能把这次编辑吞掉。
    if (pending) unawaited(_saveValidDrafts());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppModel appModel = ref.watch(appProvider);
    _appModel = appModel;
    if (!appModel.isPreferencesReady) return const SizedBox.shrink();
    if (!_loaded) {
      _loaded = true;
      _drafts = <_OpdsDraft>[
        for (final OpdsServerConfig config
            in appModel.prefsRepo.discoveryOpdsServers)
          _OpdsDraft.fromConfig(config),
      ];
    }

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: FushiDesignTokens.of(context).spacing.rowHorizontal,
      ),
      child: Column(
        key: const ValueKey<String>('opds-server-settings'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SourceSectionHeading(
            title: t.discovery_opds_settings_title,
            hint: t.discovery_opds_settings_hint,
            icon: Icons.menu_book_outlined,
          ),
          for (int index = 0; index < _drafts.length; index++) _card(index),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey<String>('opds-server-add'),
              onPressed: () => setState(
                () => _drafts.add(
                  _OpdsDraft.empty(
                    'opds-${DateTime.now().microsecondsSinceEpoch}',
                  ),
                ),
              ),
              icon: const Icon(Icons.add),
              label: Text(t.discovery_opds_add),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(int index) {
    final _OpdsDraft draft = _drafts[index];
    final _ProbeState? probe = _probes[draft.id];
    return FushiCard(
      key: ValueKey<String>('opds-server-${draft.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: SwitchListTile.adaptive(
                  key: ValueKey<String>('opds-server-$index-enabled'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(t.discovery_opds_enabled),
                  value: draft.enabled,
                  onChanged: (bool value) =>
                      _update(index, draft.copyWith(enabled: value)),
                ),
              ),
              IconButton(
                key: ValueKey<String>('opds-server-$index-remove'),
                tooltip: t.discovery_opds_remove,
                onPressed: () {
                  setState(() {
                    _probes.remove(_drafts[index].id);
                    _drafts.removeAt(index);
                  });
                  unawaited(_saveValidDrafts());
                },
                icon: const Icon(Icons.remove_circle_outline),
              ),
            ],
          ),
          SettingsFormField(
            key: ValueKey<String>('opds-server-$index-name'),
            label: t.discovery_opds_name,
            initialValue: draft.name,
            hintText: t.discovery_opds_name_hint,
            onChanged: (String value) =>
                _update(index, draft.copyWith(name: value)),
          ),
          SettingsFormField(
            key: ValueKey<String>('opds-server-$index-url'),
            label: t.discovery_opds_url,
            initialValue: draft.url,
            helperText: t.discovery_opds_url_hint,
            keyboardType: TextInputType.url,
            errorText: draft.urlError,
            onChanged: (String value) =>
                _update(index, draft.copyWith(url: value)),
          ),
          SettingsFormField(
            key: ValueKey<String>('opds-server-$index-username'),
            label: t.discovery_opds_username,
            initialValue: draft.username,
            helperText: t.discovery_opds_username_hint,
            onChanged: (String value) =>
                _update(index, draft.copyWith(username: value)),
          ),
          SettingsFormField(
            key: ValueKey<String>('opds-server-$index-password'),
            label: t.discovery_opds_password,
            initialValue: draft.password,
            obscureText: true,
            onChanged: (String value) =>
                _update(index, draft.copyWith(password: value)),
          ),
          SwitchListTile.adaptive(
            key: ValueKey<String>('opds-server-$index-allow-http'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(t.discovery_opds_allow_http),
            subtitle: Text(t.discovery_opds_allow_http_hint),
            value: draft.allowInsecureHttp,
            onChanged: (bool value) =>
                _update(index, draft.copyWith(allowInsecureHttp: value)),
          ),
          Row(
            children: <Widget>[
              OutlinedButton.icon(
                key: ValueKey<String>('opds-server-$index-test'),
                // 配置无效时按钮直接不可用，而不是点了再报一个通用错误。
                onPressed: draft.toConfig() == null || probe?.running == true
                    ? null
                    : () => unawaited(_probe(draft)),
                icon: probe?.running == true
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.network_check_outlined),
                label: Text(t.discovery_opds_test),
              ),
              if (probe != null && !probe.running) ...<Widget>[
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    probe.message,
                    key: ValueKey<String>('opds-server-$index-probe-result'),
                    style: TextStyle(
                      color: probe.ok
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  void _update(int index, _OpdsDraft next) {
    setState(() {
      _drafts[index] = next;
      // 配置变了，上一次自检结论作废——留着会让用户照着一条针对旧地址的
      // 「连接成功」去排查新地址的问题。
      _probes.remove(next.id);
    });
    _saveDebounce?.cancel();
    _saveDebounce = Timer(_kSaveDebounce, () => unawaited(_saveValidDrafts()));
  }

  /// 落盘**当前有效**的草稿。
  ///
  /// 无效草稿（URL 还没填完、空记录）跳过而不是报错：用户正在打字，这是中间态。
  /// 它们仍留在 UI 里，等填完下一次防抖就会被保存。
  Future<void> _saveValidDrafts() async {
    // 用 build 期抓住的引用，不用 ref——本方法也从 dispose 里调（见 [_appModel]）。
    final AppModel? appModel = _appModel;
    if (appModel == null) return;
    final List<OpdsServerConfig> configs = <OpdsServerConfig>[
      for (final _OpdsDraft draft in _drafts)
        if (draft.toConfig() case final OpdsServerConfig config) config,
    ];
    await appModel.setDiscoveryOpdsServers(configs);
  }

  /// 连接自检：真发一次根目录请求，报回条目数或稳定的失败原因。
  ///
  /// 值得单独做一个按钮：OPDS 配错（地址少了 `/opds` 后缀、密码错、服务端没开
  /// 目录）的表现全都是「发现页里这个源是空的」，没有自检的话用户没有任何
  /// 手段区分「配错了」和「这个书库确实没书」。
  Future<void> _probe(_OpdsDraft draft) async {
    final OpdsServerConfig? config = draft.toConfig();
    if (config == null) return;
    setState(() => _probes[draft.id] = const _ProbeState.running());
    final http.Client client = http.Client();
    final OpdsDiscoverySource source =
        OpdsDiscoverySource(config: config, client: client);
    _ProbeState result;
    try {
      final ProviderBatchResult<DiscoveryResultPage> page = await source.browse(
        const DiscoveryRequest(kind: DiscoveryMediaKind.novel),
      );
      final int count =
          page.items.isEmpty ? 0 : page.items.single.entries.length;
      result = _ProbeState.done(
        ok: true,
        message: t.discovery_opds_test_ok(count: count),
      );
    } on ExternalProviderFailure catch (failure) {
      // failure.message 已经是脱敏文案（不含地址/凭据），直接透出。
      result = _ProbeState.done(
        ok: false,
        message: t.discovery_opds_test_failed(reason: failure.message),
      );
    } catch (_) {
      result = _ProbeState.done(
        ok: false,
        message: t.discovery_opds_test_failed(reason: ''),
      );
    } finally {
      source.close();
    }
    if (!mounted) return;
    setState(() => _probes[draft.id] = result);
  }
}

/// 一条服务器的编辑中状态。URL 以**原始字符串**保存：`Uri` 解析不了的中间态
/// （用户刚打到 `htt`）也必须能停在输入框里，转成 `Uri` 只发生在落盘时。
class _OpdsDraft {
  const _OpdsDraft({
    required this.id,
    required this.name,
    required this.url,
    required this.username,
    required this.password,
    required this.enabled,
    required this.allowInsecureHttp,
  });

  factory _OpdsDraft.empty(String id) => _OpdsDraft(
        id: id,
        name: '',
        url: '',
        username: '',
        password: '',
        enabled: true,
        allowInsecureHttp: false,
      );

  factory _OpdsDraft.fromConfig(OpdsServerConfig config) => _OpdsDraft(
        id: config.id,
        name: config.name,
        url: config.catalogUrl.toString(),
        username: config.username,
        password: config.password,
        enabled: config.enabled,
        allowInsecureHttp: config.allowInsecureHttp,
      );

  final String id;
  final String name;
  final String url;
  final String username;
  final String password;
  final bool enabled;
  final bool allowInsecureHttp;

  _OpdsDraft copyWith({
    String? name,
    String? url,
    String? username,
    String? password,
    bool? enabled,
    bool? allowInsecureHttp,
  }) =>
      _OpdsDraft(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        username: username ?? this.username,
        password: password ?? this.password,
        enabled: enabled ?? this.enabled,
        allowInsecureHttp: allowInsecureHttp ?? this.allowInsecureHttp,
      );

  /// 有效即返回配置，否则 null。
  ///
  /// 校验完全交给 [OpdsServerConfig] 的构造器——那里是 URL 合法性与
  /// 明文 HTTP 放行的唯一真相源。在 UI 再抄一份判据必然与它漂移，
  /// 而漂移的结果是「界面说没问题、保存后条目却消失了」。
  OpdsServerConfig? toConfig() {
    final Uri? parsed = Uri.tryParse(url.trim());
    if (parsed == null) return null;
    try {
      return OpdsServerConfig(
        id: id,
        name: name,
        catalogUrl: parsed,
        username: username.trim(),
        password: password,
        enabled: enabled,
        allowInsecureHttp: allowInsecureHttp,
      );
    } on ArgumentError {
      return null;
    }
  }

  /// 输入框下方的错误提示；空 URL 不报错（还没开始填）。
  String? get urlError {
    if (url.trim().isEmpty) return null;
    if (toConfig() != null) return null;
    final Uri? parsed = Uri.tryParse(url.trim());
    final bool plainHttpBlocked = parsed != null &&
        parsed.scheme == 'http' &&
        !allowInsecureHttp &&
        parsed.host.isNotEmpty;
    // 明文 HTTP 被挡是最常见的一种「地址看着没错却存不下」，单独给一句话，
    // 否则用户会反复检查地址本身。
    return plainHttpBlocked
        ? t.discovery_opds_url_needs_http_optin
        : t.discovery_opds_url_invalid;
  }
}

/// 自检状态：进行中 / 有结论。
class _ProbeState {
  const _ProbeState.running()
      : running = true,
        ok = false,
        message = '';

  const _ProbeState.done({required this.ok, required this.message})
      : running = false;

  final bool running;
  final bool ok;
  final String message;
}
