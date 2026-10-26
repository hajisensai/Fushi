/// 「Kavita 服务器」设置区：用户自配 Kavita 服务器增删改 + 连接测试。
///
/// 结构照抄 `audiobookshelf_server_settings_section.dart`（草稿态 + 600ms 防抖落盘
/// + dispose 时 flush），但凭据更简单：只有一把长期 API key，没有令牌轮换，所以
/// 草稿里的 key 就是要持久化的值，不需要「令牌脏位」。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/discovery/discovery_server_probes.dart'
    show DiscoveryProbeOutcome;
import 'package:fushi/src/media/kavita/kavita_api_registry.dart';
import 'package:fushi/src/media/kavita/kavita_connect_probe.dart';
import 'package:fushi/src/media/kavita/kavita_server_config.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/source_toggle_section.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/kavita/kavita_api.dart';

const Duration _kSaveDebounce = Duration(milliseconds: 600);

class KavitaServerSettingsSection extends ConsumerStatefulWidget {
  const KavitaServerSettingsSection({super.key});

  @override
  ConsumerState<KavitaServerSettingsSection> createState() =>
      _KavitaServerSettingsSectionState();
}

class _KavitaServerSettingsSectionState
    extends ConsumerState<KavitaServerSettingsSection> {
  List<KavitaDraft> _drafts = <KavitaDraft>[];
  bool _loaded = false;
  Timer? _saveDebounce;

  /// build 期抓住的 AppModel；dispose 里不能 `ref.read`（同 OPDS / AList 段）。
  AppModel? _appModel;

  final Map<String, _ProbeState> _probes = <String, _ProbeState>{};

  @override
  void dispose() {
    final bool pending = _saveDebounce?.isActive ?? false;
    _saveDebounce?.cancel();
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
      _drafts = <KavitaDraft>[
        for (final KavitaServerConfig config
            in appModel.prefsRepo.kavitaServers)
          KavitaDraft.fromConfig(config),
      ];
    }

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: FushiDesignTokens.of(context).spacing.rowHorizontal,
      ),
      child: Column(
        key: const ValueKey<String>('kavita-server-settings'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SourceSectionHeading(
            title: t.kavita_settings_title,
            hint: t.kavita_settings_hint,
            icon: Icons.auto_stories_outlined,
          ),
          for (int index = 0; index < _drafts.length; index++) _card(index),
          Align(
            alignment: Alignment.centerLeft,
            child: FushiOutlinedButton.icon(
              key: const ValueKey<String>('kavita-server-add'),
              onPressed: () => setState(
                () => _drafts.add(
                  KavitaDraft.empty(
                    'server-${DateTime.now().microsecondsSinceEpoch}',
                  ),
                ),
              ),
              icon: const Icon(Icons.add),
              label: Text(t.kavita_server_add),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(int index) {
    final KavitaDraft draft = _drafts[index];
    final _ProbeState? probe = _probes[draft.id];
    return FushiCard(
      key: ValueKey<String>('kavita-server-${draft.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: FushiSwitchListTile.adaptive(
                  key: ValueKey<String>('kavita-server-$index-enabled'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(t.kavita_server_enabled),
                  value: draft.enabled,
                  onChanged: (bool value) =>
                      _update(index, draft.copyWith(enabled: value)),
                ),
              ),
              FushiIconButtonControl(
                key: ValueKey<String>('kavita-server-$index-remove'),
                tooltip: t.kavita_server_remove,
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
            key: ValueKey<String>('kavita-server-$index-name'),
            label: t.kavita_name_label,
            initialValue: draft.name,
            hintText: t.kavita_name_hint,
            onChanged: (String value) =>
                _update(index, draft.copyWith(name: value)),
          ),
          SettingsFormField(
            key: ValueKey<String>('kavita-server-$index-url'),
            label: t.kavita_url_label,
            initialValue: draft.url,
            helperText: t.kavita_url_hint,
            keyboardType: TextInputType.url,
            errorText: draft.urlError,
            onChanged: (String value) =>
                _update(index, draft.copyWith(url: value)),
          ),
          FushiSwitchListTile.adaptive(
            key: ValueKey<String>('kavita-server-$index-allow-http'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(t.kavita_http_allow),
            subtitle: Text(t.kavita_http_allow_hint),
            value: draft.allowInsecureHttp,
            onChanged: (bool value) =>
                _update(index, draft.copyWith(allowInsecureHttp: value)),
          ),
          SettingsFormField(
            key: ValueKey<String>('kavita-server-$index-api-key'),
            label: t.kavita_api_key_label,
            initialValue: draft.apiKey,
            helperText: t.kavita_api_key_hint,
            obscureText: true,
            onChanged: (String value) =>
                _update(index, draft.copyWith(apiKey: value)),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: FushiOutlinedButton.icon(
              key: ValueKey<String>('kavita-server-$index-connect'),
              onPressed: !draft.canConnect || probe?.running == true
                  ? null
                  : () => unawaited(_connect(draft.id)),
              icon: probe?.running == true
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: FushiCircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.network_check_outlined),
              label: Text(t.kavita_connect_test),
            ),
          ),
          if (probe != null && !probe.running)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                probe.message,
                key: ValueKey<String>('kavita-server-$index-probe-result'),
                style: TextStyle(
                  color: probe.ok
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _update(int index, KavitaDraft next) {
    setState(() {
      _drafts[index] = next;
      _probes.remove(next.id);
    });
    _saveDebounce?.cancel();
    _saveDebounce = Timer(_kSaveDebounce, () => unawaited(_saveValidDrafts()));
  }

  /// 落盘当前有效的草稿；无效草稿（地址没填完）留在 UI 里等下次。
  Future<void> _saveValidDrafts() async {
    final AppModel? appModel = _appModel;
    if (appModel == null) return;
    final List<KavitaServerConfig> configs = <KavitaServerConfig>[
      for (final KavitaDraft draft in _drafts)
        if (draft.toConfig() case final KavitaServerConfig config) config,
    ];
    await appModel.prefsRepo.setKavitaServers(configs);
    KavitaApiRegistry.instance.retainOnly(configs);
  }

  Future<void> _connect(String draftId) async {
    KavitaDraft? draft;
    for (final KavitaDraft d in _drafts) {
      if (d.id == draftId) draft = d;
    }
    final KavitaServerConfig? config = draft?.toConfig();
    if (config == null) return;
    setState(() => _probes[draftId] = const _ProbeState.running());
    _ProbeState result;
    try {
      final DiscoveryProbeOutcome outcome = await connectKavitaServer(config);
      result = _ProbeState.done(ok: outcome.ok, message: outcome.message);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'KavitaServerSettings.connect',
        error,
        stack,
      );
      result = _ProbeState.done(
        ok: false,
        message: t.kavita_connect_failed(reason: ''),
      );
    }
    if (!mounted) return;
    if (!_drafts.any((KavitaDraft d) => d.id == draftId)) return;
    setState(() => _probes[draftId] = result);
  }
}

/// 一台服务器的编辑中状态；URL 以原始字符串保存，转 `Uri` 只在落盘时。
class KavitaDraft {
  const KavitaDraft({
    required this.id,
    required this.name,
    required this.url,
    required this.apiKey,
    required this.enabled,
    required this.allowInsecureHttp,
  });

  factory KavitaDraft.empty(String id) => KavitaDraft(
    id: id,
    name: '',
    url: '',
    apiKey: '',
    enabled: true,
    allowInsecureHttp: false,
  );

  factory KavitaDraft.fromConfig(KavitaServerConfig config) => KavitaDraft(
    id: config.id,
    name: config.name,
    url: config.serverUrl.toString(),
    apiKey: config.apiKey,
    enabled: config.enabled,
    allowInsecureHttp: config.allowInsecureHttp,
  );

  final String id;
  final String name;
  final String url;
  final String apiKey;
  final bool enabled;
  final bool allowInsecureHttp;

  KavitaDraft copyWith({
    String? name,
    String? url,
    String? apiKey,
    bool? enabled,
    bool? allowInsecureHttp,
  }) => KavitaDraft(
    id: id,
    name: name ?? this.name,
    url: url ?? this.url,
    apiKey: apiKey ?? this.apiKey,
    enabled: enabled ?? this.enabled,
    allowInsecureHttp: allowInsecureHttp ?? this.allowInsecureHttp,
  );

  /// 「测试连接」可用：地址有效且填了 API key。
  bool get canConnect => toConfig() != null && apiKey.trim().isNotEmpty;

  /// 有效即返回配置，否则 null；校验全交给 [KavitaServerConfig] 构造器。
  KavitaServerConfig? toConfig() {
    if (url.trim().isEmpty) return null;
    final Uri? parsed = Uri.tryParse(KavitaApi.normalizeServerUrl(url));
    if (parsed == null) return null;
    try {
      return KavitaServerConfig(
        id: id,
        name: name,
        serverUrl: parsed,
        apiKey: apiKey.trim(),
        enabled: enabled,
        allowInsecureHttp: allowInsecureHttp,
      );
    } on ArgumentError {
      return null;
    }
  }

  /// 输入框下方的错误提示；空 URL 不报错。
  String? get urlError {
    if (url.trim().isEmpty) return null;
    if (toConfig() != null) return null;
    final Uri? parsed = Uri.tryParse(KavitaApi.normalizeServerUrl(url));
    final bool plainHttpBlocked =
        parsed != null && parsed.scheme == 'http' && !allowInsecureHttp;
    return plainHttpBlocked
        ? t.kavita_url_http_optin_required
        : t.kavita_url_invalid;
  }
}

class _ProbeState {
  const _ProbeState.running() : running = true, ok = false, message = '';

  const _ProbeState.done({required this.ok, required this.message})
    : running = false;

  final bool running;
  final bool ok;
  final String message;
}
