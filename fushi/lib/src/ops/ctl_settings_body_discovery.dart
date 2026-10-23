import 'package:flutter/widgets.dart';
import 'package:fushi/src/media/discovery/alist_site_config.dart';
import 'package:fushi/src/media/discovery/audiobookshelf_server_config.dart';
import 'package:fushi/src/media/discovery/discovery_server_probes.dart';
import 'package:fushi/src/media/discovery/media_discovery_source.dart';
import 'package:fushi/src/media/discovery/opds_server_config.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_api.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';

/// 「在线服务 › 资源」下四个逃生口页面（发现来源开关、OPDS 书目服务器、AList /
/// OpenList 站点、Audiobookshelf 服务器）在控制通道上的条目。
///
/// 读写走页面同一组 `AppModel` 写回口（`setDiscoverySourceEnabled` /
/// `setDiscoveryOpdsServers` / `setDiscoveryAListSites` /
/// `setDiscoveryAudiobookshelfServers`，落偏好后重建发现源注册表）；记录合法性
/// 全交给各 `*Config` 构造器（与页面草稿 `toConfig()` 同一真相源）；连接测试 /
/// 登录走 `discovery_server_probes.dart` 里与页面共用的执行体。
///
/// 凭据（OPDS / AList 密码、ABS 密码 / API key）只收 secret 参数，列表输出只给
/// `hasPassword` / `signedIn`，不回显。
List<CtlBodyPage> buildCtlDiscoveryBodyPages() => <CtlBodyPage>[
  CtlBodyPage(
    breadcrumb: _crumb(t.discovery_sources_settings_title),
    visible: _discoveryAvailable,
    items: <SettingsItem>[_builtinSourcesList()],
  ),
  CtlBodyPage(
    breadcrumb: _crumb(t.discovery_opds_settings_title),
    visible: _discoveryAvailable,
    items: <SettingsItem>[_opdsList(), _opdsTest()],
  ),
  CtlBodyPage(
    breadcrumb: _crumb(t.discovery_alist_settings_title),
    visible: _discoveryAvailable,
    items: <SettingsItem>[_alistList(), _alistTest()],
  ),
  CtlBodyPage(
    breadcrumb: _mediaServersCrumb(t.discovery_audiobookshelf_settings_title),
    // 与 schema 一致：ABS 住在「媒体服务器」节，不受发现源的 iOS 合规门影响。
    visible: _always,
    items: <SettingsItem>[_absList(), _absSignIn(), _absSignOut(), _absTest()],
  ),
];

/// 条目 id。schema 里 `services.discovery_sources` 等是导航行，`.cli.` 段避开它们。
const String kCtlDiscoverySourcesListId =
    'services.discovery_sources.cli.sources';
const String kCtlOpdsListId = 'services.opds_servers.cli.servers';
const String kCtlOpdsTestId = 'services.opds_servers.cli.test';
const String kCtlAListListId = 'services.alist_sites.cli.sites';
const String kCtlAListTestId = 'services.alist_sites.cli.test';
const String kCtlAbsListId = 'services.audiobookshelf_servers.cli.servers';
const String kCtlAbsSignInId = 'services.audiobookshelf_servers.cli.sign_in';
const String kCtlAbsSignOutId = 'services.audiobookshelf_servers.cli.sign_out';
const String kCtlAbsTestId = 'services.audiobookshelf_servers.cli.test';

String _crumb(String leaf) =>
    '${t.settings_destination_services} › ${t.section_services_resources} › $leaf';

String _mediaServersCrumb(String leaf) =>
    '${t.settings_destination_services} › ${t.video_library_media_servers} › $leaf';

bool _always(SettingsContext _) => true;

/// 与 schema 里「资源」分组同一判据：iOS 合规版不登记任何发现源。
bool _discoveryAvailable(SettingsContext _) =>
    StoreRestrictedCapability.externalDiscovery.isAvailable;

// ── 通用 ────────────────────────────────────────────────────────────────────

bool _parseBool(String raw, String what) {
  switch (raw.trim().toLowerCase()) {
    case 'true' || 'on' || 'yes' || '1':
      return true;
    case 'false' || 'off' || 'no' || '0':
      return false;
  }
  throw ArgumentError('$what 要布尔值（true / false），收到「$raw」');
}

bool? _optBool(Map<String, String> fields, String name) {
  final String? raw = fields[name];
  return raw == null ? null : _parseBool(raw, name);
}

Uri _parseUrl(String raw) {
  final Uri? parsed = Uri.tryParse(raw.trim());
  if (parsed == null || raw.trim().isEmpty) {
    throw ArgumentError('url 不是合法地址：「$raw」');
  }
  return parsed;
}

/// 新记录 id：与页面「添加」按钮同一形状（前缀 + 微秒时间戳）。
String _newId(String prefix) =>
    '$prefix-${DateTime.now().microsecondsSinceEpoch}';

SettingsCustomItem _listItem({
  required String id,
  required String title,
  required SettingsCliList cli,
}) => SettingsCustomItem(
  id: id,
  builder: (SettingsContext _) => const SizedBox.shrink(),
  searchTitle: title,
  cliList: cli,
);

SettingsActionItem _action({
  required String id,
  required String title,
  required SettingsCliAction cli,
  String? subtitle,
  bool destructive = false,
}) {
  final SettingsCliRun run = cli.run!;
  return SettingsActionItem(
    id: id,
    title: title,
    subtitle: subtitle,
    destructive: destructive,
    cli: cli,
    onTap: (SettingsContext c) async {
      await run(c, const <String, String>{});
    },
  );
}

const SettingsCliParam _idParam = SettingsCliParam(
  'id',
  help: '记录 id（config items <列表键> ls 查看）',
);

String _kindsWire(Iterable<DiscoveryMediaKind> kinds) => DiscoveryMediaKind
    .values
    .where(kinds.contains)
    .map((DiscoveryMediaKind k) => k.name)
    .join(',');

Set<DiscoveryMediaKind> _parseKinds(String raw) {
  final Set<DiscoveryMediaKind> kinds = <DiscoveryMediaKind>{};
  for (final String part in raw.split(',')) {
    final String name = part.trim().toLowerCase();
    if (name.isEmpty) continue;
    final DiscoveryMediaKind? kind = DiscoveryMediaKind.values
        .where((DiscoveryMediaKind k) => k.name == name)
        .firstOrNull;
    if (kind == null) {
      throw ArgumentError(
        'kinds 里的「$part」不认识；可用：'
        '${DiscoveryMediaKind.values.map((DiscoveryMediaKind k) => k.name).join(' | ')}',
      );
    }
    kinds.add(kind);
  }
  if (kinds.isEmpty) throw ArgumentError('kinds 至少要一个');
  return kinds;
}

// ── 发现来源（内置源开关）──────────────────────────────────────────────────

/// 内置源（不含用户自配服务器——它们的开关是自己记录上的 `enabled`）。
List<MediaDiscoverySource> _builtinSources(SettingsContext c) => c
    .appModel
    .mediaDiscoveryService
    .sources
    .where((MediaDiscoverySource s) => !s.isUserConfigured)
    .toList(growable: false);

Map<String, Object?> _sourceRecord(
  MediaDiscoverySource source,
  Set<String> disabled,
) => <String, Object?>{
  'id': source.id,
  'name': source.displayName,
  'kinds': _kindsWire(source.capabilities.kinds),
  'enabled': !disabled.contains(source.id),
};

SettingsCustomItem _builtinSourcesList() => _listItem(
  id: kCtlDiscoverySourcesListId,
  title: t.discovery_sources_settings_title,
  cli: SettingsCliList(
    list: (SettingsContext c) async {
      final Set<String> disabled = c.appModel.discoveryDisabledSourceIds;
      return <Map<String, Object?>>[
        for (final MediaDiscoverySource s in _builtinSources(c))
          _sourceRecord(s, disabled),
      ];
    },
    update: (SettingsContext c, String id, Map<String, String> fields) async {
      final bool? enabled = _optBool(fields, 'enabled');
      if (enabled == null) throw ArgumentError('缺少字段 enabled');
      final MediaDiscoverySource source = _builtinSources(c).firstWhere(
        (MediaDiscoverySource s) => s.id == id,
        orElse: () => throw ArgumentError('没有内置发现源「$id」'),
      );
      await c.appModel.setDiscoverySourceEnabled(id, enabled);
      return _sourceRecord(source, c.appModel.discoveryDisabledSourceIds);
    },
    fields: const <SettingsCliParam>[
      SettingsCliParam('enabled', help: 'true/false：是否进「全部源」聚合'),
    ],
  ),
);

// ── OPDS ────────────────────────────────────────────────────────────────────

List<OpdsServerConfig> _opdsServers(SettingsContext c) =>
    c.appModel.prefsRepo.discoveryOpdsServers;

Map<String, Object?> _opdsRecord(OpdsServerConfig s) => <String, Object?>{
  'id': s.id,
  'name': s.name,
  'url': s.catalogUrl.toString(),
  'username': s.username,
  'hasPassword': s.password.isNotEmpty,
  'hasApiKey': s.apiKey.isNotEmpty,
  'enabled': s.enabled,
  'allowInsecureHttp': s.allowInsecureHttp,
};

OpdsServerConfig _requireOpds(SettingsContext c, String id) =>
    _opdsServers(c).firstWhere(
      (OpdsServerConfig s) => s.id == id,
      orElse: () => throw ArgumentError('没有 OPDS 服务器「$id」'),
    );

/// 按字段（只改给出的）拼出一条配置；校验交给 [OpdsServerConfig] 构造器。
OpdsServerConfig _opdsFrom(
  String id,
  Map<String, String> f, {
  OpdsServerConfig? base,
}) => OpdsServerConfig(
  id: id,
  name: f['name']?.trim() ?? base?.name ?? '',
  catalogUrl: f.containsKey('url') ? _parseUrl(f['url']!) : base!.catalogUrl,
  username: f['username']?.trim() ?? base?.username ?? '',
  password: f['password'] ?? base?.password ?? '',
  apiKey: f['api_key']?.trim() ?? base?.apiKey ?? '',
  enabled: _optBool(f, 'enabled') ?? base?.enabled ?? true,
  allowInsecureHttp:
      _optBool(f, 'allow_http') ?? base?.allowInsecureHttp ?? false,
);

const List<SettingsCliParam> _opdsFields = <SettingsCliParam>[
  SettingsCliParam('url', help: '目录地址（如 https://host/opds）'),
  SettingsCliParam('name', help: '显示名；省略 = 用主机名', required: false),
  SettingsCliParam(
    'username',
    help: '账号（HTTP Basic；Komga 填登录邮箱）',
    required: false,
  ),
  SettingsCliParam(
    'password',
    help: '密码；空串 = 清除',
    required: false,
    secret: true,
  ),
  SettingsCliParam(
    'api_key',
    help: 'API key（经 X-API-Key 头发送，Komga 用）；空串 = 清除',
    required: false,
    secret: true,
  ),
  SettingsCliParam('enabled', help: 'true/false，默认 true', required: false),
  SettingsCliParam(
    'allow_http',
    help: 'true/false：放行明文 HTTP（局域网自建），默认 false',
    required: false,
  ),
];

SettingsCustomItem _opdsList() => _listItem(
  id: kCtlOpdsListId,
  title: t.discovery_opds_settings_title,
  cli: SettingsCliList(
    list: (SettingsContext c) async => <Map<String, Object?>>[
      for (final OpdsServerConfig s in _opdsServers(c)) _opdsRecord(s),
    ],
    add: (SettingsContext c, Map<String, String> f) async {
      final OpdsServerConfig created = _opdsFrom(_newId('opds'), f);
      await c.appModel.setDiscoveryOpdsServers(<OpdsServerConfig>[
        ..._opdsServers(c),
        created,
      ]);
      return _opdsRecord(created);
    },
    update: (SettingsContext c, String id, Map<String, String> f) async {
      final OpdsServerConfig next = _opdsFrom(id, f, base: _requireOpds(c, id));
      await c.appModel.setDiscoveryOpdsServers(<OpdsServerConfig>[
        for (final OpdsServerConfig s in _opdsServers(c)) s.id == id ? next : s,
      ]);
      return _opdsRecord(next);
    },
    remove: (SettingsContext c, String id) async {
      _requireOpds(c, id);
      await c.appModel.setDiscoveryOpdsServers(<OpdsServerConfig>[
        for (final OpdsServerConfig s in _opdsServers(c))
          if (s.id != id) s,
      ]);
    },
    fields: _opdsFields,
  ),
);

SettingsActionItem _opdsTest() => _action(
  id: kCtlOpdsTestId,
  title: t.discovery_opds_test,
  cli: SettingsCliAction(
    params: const <SettingsCliParam>[_idParam],
    run: (SettingsContext c, Map<String, String> args) async {
      final DiscoveryProbeOutcome outcome = await probeOpdsServer(
        _requireOpds(c, args['id']!),
      );
      // 探测打通了另一条地址（用户填的是服务端根 / 网页地址）：与设置页同样
      // 写回配置，下次不必再探测（BUG-3526）。
      final Uri? resolved = outcome.resolvedUrl;
      if (resolved != null) {
        await c.appModel.persistOpdsCatalogUrl(args['id']!, resolved);
      }
      return outcome.toJson();
    },
  ),
);

// ── AList / OpenList ────────────────────────────────────────────────────────

List<AListSiteConfig> _alistSites(SettingsContext c) =>
    c.appModel.prefsRepo.discoveryAListSites;

Map<String, Object?> _alistRecord(AListSiteConfig s) => <String, Object?>{
  'id': s.id,
  'name': s.name,
  'url': s.baseUrl.toString(),
  'kinds': _kindsWire(s.kinds),
  'username': s.username,
  'hasPassword': s.password.isNotEmpty,
  'enabled': s.enabled,
  'allowInsecureHttp': s.allowInsecureHttp,
};

AListSiteConfig _requireAList(SettingsContext c, String id) =>
    _alistSites(c).firstWhere(
      (AListSiteConfig s) => s.id == id,
      orElse: () => throw ArgumentError('没有 AList 站点「$id」'),
    );

AListSiteConfig _alistFrom(
  String id,
  Map<String, String> f, {
  AListSiteConfig? base,
}) => AListSiteConfig(
  id: id,
  name: f['name']?.trim() ?? base?.name ?? '',
  baseUrl: f.containsKey('url') ? _parseUrl(f['url']!) : base!.baseUrl,
  kinds: f.containsKey('kinds')
      ? _parseKinds(f['kinds']!)
      : base?.kinds ?? kDefaultAListSiteKinds,
  username: f['username']?.trim() ?? base?.username ?? '',
  password: f['password'] ?? base?.password ?? '',
  enabled: _optBool(f, 'enabled') ?? base?.enabled ?? true,
  allowInsecureHttp:
      _optBool(f, 'allow_http') ?? base?.allowInsecureHttp ?? false,
);

final List<SettingsCliParam> _alistFields = <SettingsCliParam>[
  const SettingsCliParam('url', help: '站点根地址（如 https://alist.example.com）'),
  const SettingsCliParam('name', help: '显示名；省略 = 用主机名', required: false),
  SettingsCliParam(
    'kinds',
    help:
        '显示在哪些库，逗号分隔：'
        '${DiscoveryMediaKind.values.map((DiscoveryMediaKind k) => k.name).join(',')}'
        '；省略 = 默认',
    required: false,
  ),
  const SettingsCliParam('username', help: '账号；空 = 游客', required: false),
  const SettingsCliParam(
    'password',
    help: '密码；空串 = 清除',
    required: false,
    secret: true,
  ),
  const SettingsCliParam(
    'enabled',
    help: 'true/false，默认 true',
    required: false,
  ),
  const SettingsCliParam(
    'allow_http',
    help: 'true/false：放行明文 HTTP，默认 false',
    required: false,
  ),
];

SettingsCustomItem _alistList() => _listItem(
  id: kCtlAListListId,
  title: t.discovery_alist_settings_title,
  cli: SettingsCliList(
    list: (SettingsContext c) async => <Map<String, Object?>>[
      for (final AListSiteConfig s in _alistSites(c)) _alistRecord(s),
    ],
    add: (SettingsContext c, Map<String, String> f) async {
      final AListSiteConfig created = _alistFrom(_newId('alist'), f);
      await c.appModel.setDiscoveryAListSites(<AListSiteConfig>[
        ..._alistSites(c),
        created,
      ]);
      return _alistRecord(created);
    },
    update: (SettingsContext c, String id, Map<String, String> f) async {
      final AListSiteConfig next = _alistFrom(
        id,
        f,
        base: _requireAList(c, id),
      );
      await c.appModel.setDiscoveryAListSites(<AListSiteConfig>[
        for (final AListSiteConfig s in _alistSites(c)) s.id == id ? next : s,
      ]);
      return _alistRecord(next);
    },
    remove: (SettingsContext c, String id) async {
      _requireAList(c, id);
      await c.appModel.setDiscoveryAListSites(<AListSiteConfig>[
        for (final AListSiteConfig s in _alistSites(c))
          if (s.id != id) s,
      ]);
    },
    fields: _alistFields,
  ),
);

SettingsActionItem _alistTest() => _action(
  id: kCtlAListTestId,
  title: t.discovery_alist_test,
  cli: SettingsCliAction(
    params: const <SettingsCliParam>[_idParam],
    run: (SettingsContext c, Map<String, String> args) async =>
        (await probeAListSite(_requireAList(c, args['id']!))).toJson(),
  ),
);

// ── Audiobookshelf ──────────────────────────────────────────────────────────

List<AudiobookshelfServerConfig> _absServers(SettingsContext c) =>
    c.appModel.prefsRepo.discoveryAudiobookshelfServers;

Map<String, Object?> _absRecord(AudiobookshelfServerConfig s) =>
    <String, Object?>{
      'id': s.id,
      'name': s.name,
      'url': s.serverUrl.toString(),
      'username': s.username,
      'signedIn': s.isSignedIn,
      'enabled': s.enabled,
      'allowInsecureHttp': s.allowInsecureHttp,
    };

AudiobookshelfServerConfig _requireAbs(SettingsContext c, String id) =>
    _absServers(c).firstWhere(
      (AudiobookshelfServerConfig s) => s.id == id,
      orElse: () => throw ArgumentError('没有 Audiobookshelf 服务器「$id」'),
    );

Uri _absUrl(String raw) {
  final Uri? parsed = AudiobookshelfApi.normalizeServerUrl(raw);
  if (parsed == null) throw ArgumentError('url 不是合法地址：「$raw」');
  return parsed;
}

/// 拼一条 ABS 配置。改了地址就退出登录（旧令牌属于另一台服务器，同页面
/// 「改地址 → signedOut()」）。
AudiobookshelfServerConfig _absFrom(
  String id,
  Map<String, String> f, {
  AudiobookshelfServerConfig? base,
}) {
  final Uri url = f.containsKey('url') ? _absUrl(f['url']!) : base!.serverUrl;
  final bool urlChanged = base == null || url != base.serverUrl;
  return AudiobookshelfServerConfig(
    id: id,
    name: f['name']?.trim() ?? base?.name ?? '',
    serverUrl: url,
    username: urlChanged ? '' : base.username,
    tokens: urlChanged ? null : base.tokens,
    enabled: _optBool(f, 'enabled') ?? base?.enabled ?? true,
    allowInsecureHttp:
        _optBool(f, 'allow_http') ?? base?.allowInsecureHttp ?? false,
  );
}

Future<void> _saveAbs(SettingsContext c, AudiobookshelfServerConfig next) =>
    c.appModel.setDiscoveryAudiobookshelfServers(<AudiobookshelfServerConfig>[
      for (final AudiobookshelfServerConfig s in _absServers(c))
        s.id == next.id ? next : s,
    ]);

SettingsCustomItem _absList() => _listItem(
  id: kCtlAbsListId,
  title: t.discovery_audiobookshelf_settings_title,
  cli: SettingsCliList(
    list: (SettingsContext c) async => <Map<String, Object?>>[
      for (final AudiobookshelfServerConfig s in _absServers(c)) _absRecord(s),
    ],
    add: (SettingsContext c, Map<String, String> f) async {
      final AudiobookshelfServerConfig created = _absFrom(_newId('server'), f);
      await c.appModel.setDiscoveryAudiobookshelfServers(
        <AudiobookshelfServerConfig>[..._absServers(c), created],
      );
      return _absRecord(created);
    },
    update: (SettingsContext c, String id, Map<String, String> f) async {
      final AudiobookshelfServerConfig next = _absFrom(
        id,
        f,
        base: _requireAbs(c, id),
      );
      await _saveAbs(c, next);
      return _absRecord(next);
    },
    remove: (SettingsContext c, String id) async {
      _requireAbs(c, id);
      await c.appModel.setDiscoveryAudiobookshelfServers(
        <AudiobookshelfServerConfig>[
          for (final AudiobookshelfServerConfig s in _absServers(c))
            if (s.id != id) s,
        ],
      );
    },
    fields: const <SettingsCliParam>[
      SettingsCliParam('url', help: '服务器根地址（可带子路径，如 http://nas:13378）'),
      SettingsCliParam('name', help: '显示名；省略 = 用主机名', required: false),
      SettingsCliParam('enabled', help: 'true/false，默认 true', required: false),
      SettingsCliParam(
        'allow_http',
        help: 'true/false：放行明文 HTTP，默认 false；改地址会退出登录',
        required: false,
      ),
    ],
  ),
);

SettingsActionItem _absSignIn() => _action(
  id: kCtlAbsSignInId,
  title: t.discovery_audiobookshelf_session_sign_in,
  subtitle: t.discovery_audiobookshelf_api_key_hint,
  cli: SettingsCliAction(
    params: const <SettingsCliParam>[
      _idParam,
      SettingsCliParam('username', help: '账号（与 password 一起用）', required: false),
      SettingsCliParam(
        'password',
        help: '密码（只用来换令牌，不落盘）',
        required: false,
        secret: true,
      ),
      SettingsCliParam(
        'api_key',
        help: 'API key（与账号密码二选一）',
        required: false,
        secret: true,
      ),
    ],
    run: _absSignInRun,
  ),
);

/// 用 API key 或账号密码换令牌并落盘。已登录的服务器先退出再登，免得「现有令牌
/// 还活着」时把新给的凭据当成没看见（[connectAudiobookshelfServer] 有令牌就只测）。
Future<Object?> _absSignInRun(
  SettingsContext c,
  Map<String, String> args,
) async {
  final AudiobookshelfServerConfig base = _requireAbs(c, args['id']!);
  final String apiKey = (args['api_key'] ?? '').trim();
  final String username = (args['username'] ?? '').trim();
  final String password = args['password'] ?? '';
  if (apiKey.isEmpty && username.isEmpty) {
    throw ArgumentError('要么给 api_key，要么给 username + password');
  }
  final AudiobookshelfConnectOutcome outcome =
      await connectAudiobookshelfServer(
        base.withTokens(null, username: ''),
        username: username,
        password: password,
        apiKey: apiKey,
      );
  if (outcome.ok && outcome.tokens != null) {
    await _saveAbs(
      c,
      _requireAbs(
        c,
        base.id,
      ).withTokens(outcome.tokens, username: outcome.username),
    );
  }
  return <String, Object?>{
    ...outcome.toJson(),
    'server': _absRecord(_requireAbs(c, base.id)),
  };
}

SettingsActionItem _absSignOut() => _action(
  id: kCtlAbsSignOutId,
  title: t.discovery_audiobookshelf_session_sign_out,
  destructive: true,
  cli: SettingsCliAction(
    confirm: true,
    params: const <SettingsCliParam>[_idParam],
    run: (SettingsContext c, Map<String, String> args) async {
      final AudiobookshelfServerConfig base = _requireAbs(c, args['id']!);
      final AudiobookshelfServerConfig next = base.withTokens(
        null,
        username: '',
      );
      await _saveAbs(c, next);
      return _absRecord(next);
    },
  ),
);

SettingsActionItem _absTest() => _action(
  id: kCtlAbsTestId,
  title: t.discovery_audiobookshelf_session_test,
  cli: SettingsCliAction(
    params: const <SettingsCliParam>[_idParam],
    run: (SettingsContext c, Map<String, String> args) async {
      final AudiobookshelfServerConfig base = _requireAbs(c, args['id']!);
      if (!base.isSignedIn) {
        throw ArgumentError('服务器「${base.id}」未登录，先 config run $kCtlAbsSignInId');
      }
      final AudiobookshelfConnectOutcome outcome =
          await connectAudiobookshelfServer(base);
      // 测试途中协议层可能刷新并轮换了令牌：与页面同样写回，否则下次必 401。
      if (outcome.ok &&
          outcome.tokens != null &&
          outcome.tokens != base.tokens) {
        await _saveAbs(c, _requireAbs(c, base.id).withTokens(outcome.tokens));
      }
      return outcome.toJson();
    },
  ),
);
