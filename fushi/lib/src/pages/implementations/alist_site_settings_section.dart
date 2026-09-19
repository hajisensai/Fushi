/// 「AList / OpenList 站点」设置区：用户自配站点增删改 + 连接自检。
///
/// 结构照抄 `opds_server_settings_section.dart`（草稿态 + 600ms 防抖落盘 +
/// dispose 时 flush），多出一组「显示在哪些库」的多选：AList 是裸文件树，站里
/// 放的是书还是游戏协议上看不出来，只能由用户声明。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/alist_site_config.dart';
import 'package:fushi/src/media/discovery/discovery_labels.dart';
import 'package:fushi/src/media/discovery/sources/alist_discovery_source.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/source_toggle_section.dart';
import 'package:fushi/utils.dart';

const Duration _kSaveDebounce = Duration(milliseconds: 600);

class AListSiteSettingsSection extends ConsumerStatefulWidget {
  const AListSiteSettingsSection({super.key});

  @override
  ConsumerState<AListSiteSettingsSection> createState() =>
      _AListSiteSettingsSectionState();
}

class _AListSiteSettingsSectionState
    extends ConsumerState<AListSiteSettingsSection> {
  List<_AListDraft> _drafts = <_AListDraft>[];
  bool _loaded = false;
  Timer? _saveDebounce;

  /// build 期抓住的 AppModel；dispose 里不能 `ref.read`（同 OPDS 段）。
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
      _drafts = <_AListDraft>[
        for (final AListSiteConfig config
            in appModel.prefsRepo.discoveryAListSites)
          _AListDraft.fromConfig(config),
      ];
    }

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: FushiDesignTokens.of(context).spacing.rowHorizontal,
      ),
      child: Column(
        key: const ValueKey<String>('alist-site-settings'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SourceSectionHeading(
            title: t.discovery_alist_settings_title,
            hint: t.discovery_alist_settings_hint,
            icon: Icons.folder_shared_outlined,
          ),
          for (int index = 0; index < _drafts.length; index++) _card(index),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey<String>('alist-site-add'),
              onPressed: () => setState(
                () => _drafts.add(
                  _AListDraft.empty(
                    'site-${DateTime.now().microsecondsSinceEpoch}',
                  ),
                ),
              ),
              icon: const Icon(Icons.add),
              label: Text(t.discovery_alist_add),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(int index) {
    final _AListDraft draft = _drafts[index];
    final _ProbeState? probe = _probes[draft.id];
    return FushiCard(
      key: ValueKey<String>('alist-site-${draft.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: SwitchListTile.adaptive(
                  key: ValueKey<String>('alist-site-$index-enabled'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(t.discovery_alist_enabled),
                  value: draft.enabled,
                  onChanged: (bool value) =>
                      _update(index, draft.copyWith(enabled: value)),
                ),
              ),
              IconButton(
                key: ValueKey<String>('alist-site-$index-remove'),
                tooltip: t.discovery_alist_remove,
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
            key: ValueKey<String>('alist-site-$index-name'),
            label: t.discovery_alist_name,
            initialValue: draft.name,
            hintText: t.discovery_alist_name_hint,
            onChanged: (String value) =>
                _update(index, draft.copyWith(name: value)),
          ),
          SettingsFormField(
            key: ValueKey<String>('alist-site-$index-url'),
            label: t.discovery_alist_url,
            initialValue: draft.url,
            helperText: t.discovery_alist_url_hint,
            keyboardType: TextInputType.url,
            errorText: draft.urlError,
            onChanged: (String value) =>
                _update(index, draft.copyWith(url: value)),
          ),
          SettingsFormField(
            key: ValueKey<String>('alist-site-$index-username'),
            label: t.discovery_alist_username,
            initialValue: draft.username,
            helperText: t.discovery_alist_username_hint,
            onChanged: (String value) =>
                _update(index, draft.copyWith(username: value)),
          ),
          SettingsFormField(
            key: ValueKey<String>('alist-site-$index-password'),
            label: t.discovery_alist_password,
            initialValue: draft.password,
            obscureText: true,
            onChanged: (String value) =>
                _update(index, draft.copyWith(password: value)),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Text(
              t.discovery_alist_kinds,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              for (final DiscoveryMediaKind kind in DiscoveryMediaKind.values)
                FilterChip(
                  key: ValueKey<String>('alist-site-$index-kind-${kind.name}'),
                  label: Text(discoveryMediaKindLabel(kind)),
                  selected: draft.kinds.contains(kind),
                  onSelected: (bool selected) {
                    final Set<DiscoveryMediaKind> next =
                        Set<DiscoveryMediaKind>.of(draft.kinds);
                    if (selected) {
                      next.add(kind);
                    } else {
                      next.remove(kind);
                    }
                    // 至少留一个：全取消会让整条配置无效而从偏好里消失，
                    // 用户看到的却是「我只是点了一下 chip，站点没了」。
                    if (next.isEmpty) return;
                    _update(index, draft.copyWith(kinds: next));
                  },
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              t.discovery_alist_kinds_hint,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          SwitchListTile.adaptive(
            key: ValueKey<String>('alist-site-$index-allow-http'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(t.discovery_alist_allow_http),
            subtitle: Text(t.discovery_alist_allow_http_hint),
            value: draft.allowInsecureHttp,
            onChanged: (bool value) =>
                _update(index, draft.copyWith(allowInsecureHttp: value)),
          ),
          Row(
            children: <Widget>[
              OutlinedButton.icon(
                key: ValueKey<String>('alist-site-$index-test'),
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
                label: Text(t.discovery_alist_test),
              ),
              if (probe != null && !probe.running) ...<Widget>[
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    probe.message,
                    key: ValueKey<String>('alist-site-$index-probe-result'),
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

  void _update(int index, _AListDraft next) {
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
    final List<AListSiteConfig> configs = <AListSiteConfig>[
      for (final _AListDraft draft in _drafts)
        if (draft.toConfig() case final AListSiteConfig config) config,
    ];
    await appModel.setDiscoveryAListSites(configs);
  }

  /// 连接自检：真列一次根目录（游客/账号都走同一条 `fs/list`），报回条目数或
  /// 脱敏后的失败原因。站点关了游客、账号错、地址带了多余路径，表现全都是
  /// 「发现页里这个源是空的」，没有自检用户无从分辨。
  Future<void> _probe(_AListDraft draft) async {
    final AListSiteConfig? config = draft.toConfig();
    if (config == null) return;
    setState(() => _probes[draft.id] = const _ProbeState.running());
    // 统一出站装配点（代理/超时），也是 outbound_http_discipline 守卫的要求。
    final AListDiscoverySource source = AListDiscoverySource.fromConfig(
      config,
      client: createAppHttpIoClient(),
    );
    _ProbeState result;
    try {
      final ProviderBatchResult<DiscoveryResultPage> page = await source.browse(
        DiscoveryRequest(kind: config.kinds.first),
      );
      final int count =
          page.items.isEmpty ? 0 : page.items.single.entries.length;
      result = _ProbeState.done(
        ok: true,
        message: t.discovery_alist_test_ok(count: count),
      );
    } on ExternalProviderFailure catch (failure) {
      result = _ProbeState.done(
        ok: false,
        message: t.discovery_alist_test_failed(reason: failure.message),
      );
    } catch (_) {
      result = _ProbeState.done(
        ok: false,
        message: t.discovery_alist_test_failed(reason: ''),
      );
    } finally {
      source.close();
    }
    if (!mounted) return;
    setState(() => _probes[draft.id] = result);
  }
}

/// 一个站点的编辑中状态；URL 以原始字符串保存，转 `Uri` 只在落盘时。
class _AListDraft {
  const _AListDraft({
    required this.id,
    required this.name,
    required this.url,
    required this.kinds,
    required this.username,
    required this.password,
    required this.enabled,
    required this.allowInsecureHttp,
  });

  factory _AListDraft.empty(String id) => _AListDraft(
        id: id,
        name: '',
        url: '',
        kinds: kDefaultAListSiteKinds,
        username: '',
        password: '',
        enabled: true,
        allowInsecureHttp: false,
      );

  factory _AListDraft.fromConfig(AListSiteConfig config) => _AListDraft(
        id: config.id,
        name: config.name,
        url: config.baseUrl.toString(),
        kinds: config.kinds,
        username: config.username,
        password: config.password,
        enabled: config.enabled,
        allowInsecureHttp: config.allowInsecureHttp,
      );

  final String id;
  final String name;
  final String url;
  final Set<DiscoveryMediaKind> kinds;
  final String username;
  final String password;
  final bool enabled;
  final bool allowInsecureHttp;

  _AListDraft copyWith({
    String? name,
    String? url,
    Set<DiscoveryMediaKind>? kinds,
    String? username,
    String? password,
    bool? enabled,
    bool? allowInsecureHttp,
  }) =>
      _AListDraft(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        kinds: kinds ?? this.kinds,
        username: username ?? this.username,
        password: password ?? this.password,
        enabled: enabled ?? this.enabled,
        allowInsecureHttp: allowInsecureHttp ?? this.allowInsecureHttp,
      );

  /// 有效即返回配置，否则 null；校验全交给 [AListSiteConfig] 构造器。
  AListSiteConfig? toConfig() {
    final Uri? parsed = Uri.tryParse(url.trim());
    if (parsed == null) return null;
    try {
      return AListSiteConfig(
        id: id,
        name: name,
        baseUrl: parsed,
        kinds: kinds,
        username: username.trim(),
        password: password,
        enabled: enabled,
        allowInsecureHttp: allowInsecureHttp,
      );
    } on ArgumentError {
      return null;
    }
  }

  /// 输入框下方的错误提示；空 URL 不报错。只判地址本身——没勾库另有一行
  /// 提示，不该混进地址错误里。
  String? get urlError {
    if (url.trim().isEmpty) return null;
    final Uri? parsed = Uri.tryParse(url.trim());
    if (parsed != null && _urlOnlyValid(parsed)) return null;
    final bool plainHttpBlocked = parsed != null &&
        parsed.scheme == 'http' &&
        !allowInsecureHttp &&
        parsed.host.isNotEmpty;
    return plainHttpBlocked
        ? t.discovery_alist_url_needs_http_optin
        : t.discovery_alist_url_invalid;
  }

  bool _urlOnlyValid(Uri parsed) {
    try {
      AListSiteConfig(
        id: id,
        name: name,
        baseUrl: parsed,
        kinds: kDefaultAListSiteKinds,
        allowInsecureHttp: allowInsecureHttp,
      );
      return true;
    } on ArgumentError {
      return false;
    }
  }
}

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
