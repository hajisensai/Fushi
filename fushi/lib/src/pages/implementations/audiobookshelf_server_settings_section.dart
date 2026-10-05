/// 「Audiobookshelf 服务器」设置区：用户自配 ABS 服务器增删改 + 登录 / 退出 / 测试。
///
/// 结构照抄 `alist_site_settings_section.dart`（草稿态 + 600ms 防抖落盘 + dispose 时
/// flush）。不同在凭据：密码 / API key 只是**输入框里的临时值**，点「登录」换成
/// 令牌后立即丢弃，持久化的只有令牌（见 `AudiobookshelfServerConfig`）。
///
/// 令牌有两个写入方：本设置区（登录 / 退出 / 改地址）与正在跑的发现源（refresh
/// token 轮换后经 `AppModel.persistAudiobookshelfTokens` 写回）。落盘时只有本区
/// **自己动过**令牌的草稿（[_AbsDraft.tokensDirty]）才用草稿里的令牌，其余一律取
/// 偏好里的当前值——否则设置页开着期间发生的一次轮换，会被草稿里打开页面时读到的
/// 旧令牌覆盖回去，下次刷新必然 401。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/media/discovery/audiobookshelf_server_config.dart';
import 'package:fushi/src/media/discovery/sources/audiobookshelf_discovery_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/source_toggle_section.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_api.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';
import 'package:fushi_engine/media/external_provider.dart';

const Duration _kSaveDebounce = Duration(milliseconds: 600);

class AudiobookshelfServerSettingsSection extends ConsumerStatefulWidget {
  const AudiobookshelfServerSettingsSection({super.key});

  @override
  ConsumerState<AudiobookshelfServerSettingsSection> createState() =>
      _AudiobookshelfServerSettingsSectionState();
}

class _AudiobookshelfServerSettingsSectionState
    extends ConsumerState<AudiobookshelfServerSettingsSection> {
  List<_AbsDraft> _drafts = <_AbsDraft>[];
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
      _drafts = <_AbsDraft>[
        for (final AudiobookshelfServerConfig config
            in appModel.prefsRepo.discoveryAudiobookshelfServers)
          _AbsDraft.fromConfig(config),
      ];
    }

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: FushiDesignTokens.of(context).spacing.rowHorizontal,
      ),
      child: Column(
        key: const ValueKey<String>('abs-server-settings'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SourceSectionHeading(
            title: t.discovery_audiobookshelf_settings_title,
            hint: t.discovery_audiobookshelf_settings_hint,
            icon: Icons.headphones_outlined,
          ),
          for (int index = 0; index < _drafts.length; index++) _card(index),
          Align(
            alignment: Alignment.centerLeft,
            child: FushiOutlinedButton.icon(
              key: const ValueKey<String>('abs-server-add'),
              onPressed: () => setState(
                () => _drafts.add(
                  _AbsDraft.empty(
                    'server-${DateTime.now().microsecondsSinceEpoch}',
                  ),
                ),
              ),
              icon: const Icon(Icons.add),
              label: Text(t.discovery_audiobookshelf_server_add),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(int index) {
    final _AbsDraft draft = _drafts[index];
    final _ProbeState? probe = _probes[draft.id];
    final bool signedIn = draft.tokens != null;
    return FushiCard(
      key: ValueKey<String>('abs-server-${draft.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: FushiSwitchListTile.adaptive(
                  key: ValueKey<String>('abs-server-$index-enabled'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(t.discovery_audiobookshelf_server_enabled),
                  value: draft.enabled,
                  onChanged: (bool value) =>
                      _update(index, draft.copyWith(enabled: value)),
                ),
              ),
              FushiIconButtonControl(
                key: ValueKey<String>('abs-server-$index-remove'),
                tooltip: t.discovery_audiobookshelf_server_remove,
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
            key: ValueKey<String>('abs-server-$index-name'),
            label: t.discovery_audiobookshelf_name_label,
            initialValue: draft.name,
            hintText: t.discovery_audiobookshelf_name_hint,
            onChanged: (String value) =>
                _update(index, draft.copyWith(name: value)),
          ),
          SettingsFormField(
            key: ValueKey<String>('abs-server-$index-url'),
            label: t.discovery_audiobookshelf_url_label,
            initialValue: draft.url,
            helperText: t.discovery_audiobookshelf_url_hint,
            keyboardType: TextInputType.url,
            errorText: draft.urlError,
            // 换了服务器地址，旧令牌属于另一台服务器：一律退出登录，免得把它
            // 发给新地址。
            onChanged: (String value) =>
                _update(index, draft.copyWith(url: value).signedOut()),
          ),
          FushiSwitchListTile.adaptive(
            key: ValueKey<String>('abs-server-$index-allow-http'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(t.discovery_audiobookshelf_http_allow),
            subtitle: Text(t.discovery_audiobookshelf_http_allow_hint),
            value: draft.allowInsecureHttp,
            onChanged: (bool value) =>
                _update(index, draft.copyWith(allowInsecureHttp: value)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              signedIn
                  ? t.discovery_audiobookshelf_session_signed_in(
                      name: draft.username.isEmpty ? 'API key' : draft.username,
                    )
                  : t.discovery_audiobookshelf_session_signed_out,
              key: ValueKey<String>('abs-server-$index-status'),
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          // 已登录时不显示凭据输入框：密码 / API key 只在换令牌那一下有用，
          // 登录成功后从树里拿掉，输入框里的明文也就跟着消失。
          if (!signedIn) ..._credentialFields(index, draft),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              FushiOutlinedButton.icon(
                key: ValueKey<String>('abs-server-$index-connect'),
                onPressed: !draft.canConnect || probe?.running == true
                    ? null
                    : () => unawaited(_connect(draft.id)),
                icon: probe?.running == true
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: FushiCircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        signedIn
                            ? Icons.network_check_outlined
                            : Icons.login_outlined,
                      ),
                label: Text(
                  signedIn
                      ? t.discovery_audiobookshelf_session_test
                      : t.discovery_audiobookshelf_session_sign_in,
                ),
              ),
              if (signedIn)
                FushiTextButton.icon(
                  key: ValueKey<String>('abs-server-$index-sign-out'),
                  onPressed: () {
                    setState(() => _probes.remove(draft.id));
                    _update(index, draft.signedOut());
                  },
                  icon: const Icon(Icons.logout_outlined),
                  label: Text(t.discovery_audiobookshelf_session_sign_out),
                ),
            ],
          ),
          if (probe != null && !probe.running)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                probe.message,
                key: ValueKey<String>('abs-server-$index-probe-result'),
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

  List<Widget> _credentialFields(int index, _AbsDraft draft) => <Widget>[
    SettingsFormField(
      key: ValueKey<String>('abs-server-$index-username'),
      label: t.discovery_audiobookshelf_username_label,
      initialValue: draft.username,
      onChanged: (String value) =>
          _updateTransient(index, draft.copyWith(username: value)),
    ),
    SettingsFormField(
      key: ValueKey<String>('abs-server-$index-password'),
      label: t.discovery_audiobookshelf_password_label,
      initialValue: draft.password,
      obscureText: true,
      onChanged: (String value) =>
          _updateTransient(index, draft.copyWith(password: value)),
    ),
    SettingsFormField(
      key: ValueKey<String>('abs-server-$index-api-key'),
      label: t.discovery_audiobookshelf_api_key_label,
      initialValue: draft.apiKey,
      helperText: t.discovery_audiobookshelf_api_key_hint,
      obscureText: true,
      onChanged: (String value) =>
          _updateTransient(index, draft.copyWith(apiKey: value)),
    ),
  ];

  void _update(int index, _AbsDraft next) {
    setState(() {
      _drafts[index] = next;
      _probes.remove(next.id);
    });
    _saveDebounce?.cancel();
    _saveDebounce = Timer(_kSaveDebounce, () => unawaited(_saveValidDrafts()));
  }

  /// 只改输入框临时值（用户名 / 密码 / API key）：不落盘，只刷新按钮可用态。
  void _updateTransient(int index, _AbsDraft next) {
    setState(() => _drafts[index] = next);
  }

  /// 落盘当前有效的草稿；无效草稿（地址没填完）留在 UI 里等下次。
  Future<void> _saveValidDrafts() async {
    final AppModel? appModel = _appModel;
    if (appModel == null) return;
    final Map<String, AudiobookshelfServerConfig> stored = _storedConfigs();
    final List<AudiobookshelfServerConfig> configs =
        <AudiobookshelfServerConfig>[
          for (final _AbsDraft draft in _drafts)
            if (draft.toConfig(stored[draft.id])
                case final AudiobookshelfServerConfig config)
              config,
        ];
    // 落盘之后本区的令牌改动已经成为偏好里的当前值，此后以偏好为准。
    _drafts = <_AbsDraft>[
      for (final _AbsDraft draft in _drafts) draft.copyWith(tokensDirty: false),
    ];
    await appModel.setDiscoveryAudiobookshelfServers(configs);
  }

  /// 偏好里当前的服务器配置（按 id）。令牌以它为准，除非本区刚改过令牌。
  Map<String, AudiobookshelfServerConfig> _storedConfigs() {
    final AppModel? appModel = _appModel;
    if (appModel == null) return const <String, AudiobookshelfServerConfig>{};
    return <String, AudiobookshelfServerConfig>{
      for (final AudiobookshelfServerConfig config
          in appModel.prefsRepo.discoveryAudiobookshelfServers)
        config.id: config,
    };
  }

  /// 未登录：用 API key 或账号密码换令牌；已登录：用现有令牌列一次库（顺带验证
  /// 令牌还活着）。两条路径都以「列出有声书库」收尾，报回库数或失败原因。
  Future<void> _connect(String draftId) async {
    final _AbsDraft? draft = _draftById(draftId);
    // 与落盘同一个令牌真相源：本区没动过令牌时以偏好里的为准——发现源刷新时会
    // 轮换 refresh token，草稿里那份可能已经作废，拿它探测会误报「会话失效」。
    final AudiobookshelfServerConfig? config =
        draft?.toConfig(_storedConfigs()[draftId]);
    if (draft == null || config == null) return;
    setState(() => _probes[draftId] = const _ProbeState.running());

    final AudiobookshelfTokens? currentTokens = config.tokens;
    final bool useApiKey =
        currentTokens == null && draft.apiKey.trim().isNotEmpty;
    // 统一出站装配点（代理 / 超时），也是 outbound_http_discipline 守卫的要求。
    final AudiobookshelfApi api = AudiobookshelfApi(
      serverUrl: config.serverUrl,
      providerId: audiobookshelfSourceIdFor(config.id),
      tokens: useApiKey
          ? AudiobookshelfTokens(accessToken: draft.apiKey.trim())
          : currentTokens,
      client: createAppHttpIoClient(),
    );
    _ProbeState result;
    AudiobookshelfTokens? tokens;
    String username = draft.username;
    try {
      if (useApiKey) {
        username = (await api.me()).username;
      } else if (currentTokens == null) {
        username = (await api.login(
          draft.username.trim(),
          draft.password,
        )).user.username;
      }
      final int books = (await api.libraries())
          .where((AudiobookshelfLibrary library) => library.isBookLibrary)
          .length;
      tokens = api.tokens;
      result = _ProbeState.done(
        ok: true,
        message: t.discovery_audiobookshelf_session_sign_in_ok(count: books),
      );
    } on ExternalProviderFailure catch (failure) {
      result = _ProbeState.done(
        ok: false,
        message: t.discovery_audiobookshelf_session_sign_in_failed(
          reason: failure.message,
        ),
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'AudiobookshelfServerSettings.connect',
        error,
        stack,
      );
      result = _ProbeState.done(
        ok: false,
        message: t.discovery_audiobookshelf_session_sign_in_failed(reason: ''),
      );
    } finally {
      api.close();
    }
    if (!mounted) return;
    final int index = _drafts.indexWhere((_AbsDraft d) => d.id == draftId);
    if (index < 0) return; // 连接期间用户删掉了这台服务器
    final _AbsDraft current = _drafts[index];
    // 只有这次探测自己换来/刷新了令牌才写回；没变就别把偏好里的值再抄一遍。
    final bool tokensChanged = tokens != null && tokens != currentTokens;
    setState(() {
      if (tokensChanged) {
        _drafts[index] = current.copyWith(
          username: username,
          password: '',
          apiKey: '',
          tokens: tokens,
          tokensDirty: true,
        );
      }
      _probes[draftId] = result;
    });
    if (tokensChanged) await _saveValidDrafts();
  }

  _AbsDraft? _draftById(String id) {
    for (final _AbsDraft draft in _drafts) {
      if (draft.id == id) return draft;
    }
    return null;
  }
}

/// 一台服务器的编辑中状态；URL 以原始字符串保存，转 `Uri` 只在落盘时。
class _AbsDraft {
  const _AbsDraft({
    required this.id,
    required this.name,
    required this.url,
    required this.username,
    required this.password,
    required this.apiKey,
    required this.tokens,
    required this.tokensDirty,
    required this.enabled,
    required this.allowInsecureHttp,
  });

  factory _AbsDraft.empty(String id) => _AbsDraft(
    id: id,
    name: '',
    url: '',
    username: '',
    password: '',
    apiKey: '',
    tokens: null,
    tokensDirty: false,
    enabled: true,
    allowInsecureHttp: false,
  );

  factory _AbsDraft.fromConfig(AudiobookshelfServerConfig config) => _AbsDraft(
    id: config.id,
    name: config.name,
    url: config.serverUrl.toString(),
    username: config.username,
    password: '',
    apiKey: '',
    tokens: config.tokens,
    tokensDirty: false,
    enabled: config.enabled,
    allowInsecureHttp: config.allowInsecureHttp,
  );

  final String id;
  final String name;
  final String url;
  final String username;

  /// 临时值：只在「登录」那一下用，永不落盘。
  final String password;
  final String apiKey;

  final AudiobookshelfTokens? tokens;

  /// 本区动过令牌（登录 / 退出 / 改地址）且尚未落盘。
  final bool tokensDirty;

  final bool enabled;
  final bool allowInsecureHttp;

  _AbsDraft copyWith({
    String? name,
    String? url,
    String? username,
    String? password,
    String? apiKey,
    AudiobookshelfTokens? tokens,
    bool? tokensDirty,
    bool? enabled,
    bool? allowInsecureHttp,
  }) => _AbsDraft(
    id: id,
    name: name ?? this.name,
    url: url ?? this.url,
    username: username ?? this.username,
    password: password ?? this.password,
    apiKey: apiKey ?? this.apiKey,
    tokens: tokens ?? this.tokens,
    tokensDirty: tokensDirty ?? this.tokensDirty,
    enabled: enabled ?? this.enabled,
    allowInsecureHttp: allowInsecureHttp ?? this.allowInsecureHttp,
  );

  /// 退出登录（令牌置空并标记为本区改动）。
  _AbsDraft signedOut() => _AbsDraft(
    id: id,
    name: name,
    url: url,
    username: '',
    password: '',
    apiKey: '',
    tokens: null,
    tokensDirty: true,
    enabled: enabled,
    allowInsecureHttp: allowInsecureHttp,
  );

  /// 「登录 / 测试」按钮可用：地址有效，且已登录或填了 API key / 账号。
  bool get canConnect {
    if (toConfig(null) == null) return false;
    if (tokens != null) return true;
    return apiKey.trim().isNotEmpty || username.trim().isNotEmpty;
  }

  /// 有效即返回配置，否则 null；校验全交给 [AudiobookshelfServerConfig] 构造器。
  ///
  /// [stored] 是偏好里同 id 的当前配置：本区没动过令牌时以它的令牌为准（见库注释）。
  AudiobookshelfServerConfig? toConfig(AudiobookshelfServerConfig? stored) {
    final Uri? parsed = AudiobookshelfApi.normalizeServerUrl(url);
    if (parsed == null) return null;
    final AudiobookshelfTokens? effectiveTokens = tokensDirty || stored == null
        ? tokens
        : stored.tokens;
    try {
      return AudiobookshelfServerConfig(
        id: id,
        name: name,
        serverUrl: parsed,
        username: username.trim(),
        tokens: effectiveTokens,
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
    if (toConfig(null) != null) return null;
    final Uri? parsed = AudiobookshelfApi.normalizeServerUrl(url);
    final bool plainHttpBlocked =
        parsed != null && parsed.scheme == 'http' && !allowInsecureHttp;
    return plainHttpBlocked
        ? t.discovery_audiobookshelf_url_http_optin_required
        : t.discovery_audiobookshelf_url_invalid;
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
