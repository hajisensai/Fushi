/// `fushi_server.yaml` 的 `srs:` 与 `ankiconnect:` 段（docs/specs/2026-11-05-server-srs-design.md §4.1 / §4.5 / §4.8）。
///
/// ```yaml
/// srs:
///   profiles: [<uid>, ...]       # 服务端提供的复习库（空 = 复习关）
///   default_profile: <uid>       # 客户端不点名时用哪份（空 = 第一份）
///   rollover_hour: 4             # profile 设置里没有翻日时刻时的兜底
///   mining_target: auto          # auto | anki | review：互联制卡默认落到哪
///   mining_decks: {<uid>: <deckId>}
/// ankiconnect:
///   enabled: false
///   bind: 127.0.0.1              # 非回环必须配 key（启动时拒绝裸开到局域网）
///   port: 8765
///   api_key: ""                  # 共用 key：落到默认 profile
///   profile_keys: {<uid>: <key>} # 按 key 选 profile（Yomitan 一门语言一个 key）
///   cors_origins: []
/// ```
library;

/// 互联制卡默认落到哪：[auto] = 选了复习库且没配 Anki 落地时进复习，否则进 Anki（老的 Anki 落地用户不变）。
enum ServerMiningTarget {
  auto('auto'),
  anki('anki'),
  review('review');

  const ServerMiningTarget(this.wire);

  final String wire;

  static ServerMiningTarget parse(String? raw) {
    for (final ServerMiningTarget t in values) {
      if (t.wire == raw) return t;
    }
    if (raw == null || raw.isEmpty) return auto;
    throw FormatException(
      'srs.mining_target 只能是 auto / anki / review，实际 "$raw"',
    );
  }
}

class ServerSrsConfig {
  const ServerSrsConfig({
    this.profiles = const <String>[],
    this.defaultProfile = '',
    this.rolloverHour = 4,
    this.miningTarget = ServerMiningTarget.auto,
    this.miningDecks = const <String, String>{},
  });

  factory ServerSrsConfig.fromYaml(Object? raw) {
    if (raw is! Map) return const ServerSrsConfig();
    final int hour = int.tryParse('${raw['rollover_hour'] ?? ''}') ?? 4;
    if (hour < 0 || hour > 23) {
      throw FormatException('srs.rollover_hour 必须在 0–23，实际 $hour');
    }
    return ServerSrsConfig(
      profiles: _strings(raw['profiles']),
      defaultProfile: _text(raw['default_profile']),
      rolloverHour: hour,
      miningTarget: ServerMiningTarget.parse(_text(raw['mining_target'])),
      miningDecks: _stringMap(raw['mining_decks']),
    );
  }

  /// 提供的复习库 profile uid（顺序 = WebUI 显示顺序）。空 = 复习关（今天的行为）。
  final List<String> profiles;

  /// 客户端不点名时用的 profile；不在 [profiles] 里（或空）时取第一份，见 [effectiveDefault]。
  final String defaultProfile;
  final int rolloverHour;
  final ServerMiningTarget miningTarget;

  /// 每份 profile 的制卡牌组 id；没有 = 那份的内置默认牌组。
  final Map<String, String> miningDecks;

  bool get enabled => profiles.isNotEmpty;

  /// 实际的默认 profile；复习关时 null。
  String? get effectiveDefault {
    if (profiles.isEmpty) return null;
    return profiles.contains(defaultProfile) ? defaultProfile : profiles.first;
  }

  ServerSrsConfig copyWith({
    List<String>? profiles,
    String? defaultProfile,
    int? rolloverHour,
    ServerMiningTarget? miningTarget,
    Map<String, String>? miningDecks,
  }) => ServerSrsConfig(
    profiles: profiles ?? this.profiles,
    defaultProfile: defaultProfile ?? this.defaultProfile,
    rolloverHour: rolloverHour ?? this.rolloverHour,
    miningTarget: miningTarget ?? this.miningTarget,
    miningDecks: miningDecks ?? this.miningDecks,
  );

  void writeYaml(StringBuffer b, String Function(String) q) {
    b.writeln('srs:');
    b.writeln('  profiles:${profiles.isEmpty ? ' []' : ''}');
    for (final String uid in profiles) {
      b.writeln('    - ${q(uid)}');
    }
    b.writeln('  default_profile: ${q(defaultProfile)}');
    b.writeln('  rollover_hour: $rolloverHour');
    b.writeln('  mining_target: ${q(miningTarget.wire)}');
    _writeMap(b, 'mining_decks', miningDecks, q);
  }
}

class ServerAnkiConnectConfig {
  const ServerAnkiConnectConfig({
    this.enabled = false,
    this.bind = '127.0.0.1',
    this.port = 8765,
    this.apiKey = '',
    this.profileKeys = const <String, String>{},
    this.corsOrigins = const <String>[],
  });

  factory ServerAnkiConnectConfig.fromYaml(Object? raw) {
    if (raw is! Map) return const ServerAnkiConnectConfig();
    final int port = int.tryParse('${raw['port'] ?? ''}') ?? 8765;
    if (port <= 0 || port > 65535) {
      throw FormatException('ankiconnect.port 不合法：$port');
    }
    final Object? enabled = raw['enabled'];
    return ServerAnkiConnectConfig(
      enabled: enabled == true || '$enabled'.toLowerCase() == 'true',
      bind: _text(raw['bind']).isEmpty ? '127.0.0.1' : _text(raw['bind']),
      port: port,
      apiKey: _text(raw['api_key']),
      profileKeys: _stringMap(raw['profile_keys']),
      corsOrigins: _strings(raw['cors_origins']),
    );
  }

  /// 默认关（所有者 2026-11-06）。
  final bool enabled;

  /// 默认只听本机；非回环地址必须配了 key 才起（[startProblem]）。
  final String bind;
  final int port;

  /// 共用 key：带它的请求落到默认 profile。
  final String apiKey;

  /// profile uid → 它专用的 key（AnkiConnect 没有 profile 字段，按 key 选）。
  final Map<String, String> profileKeys;

  /// 额外允许的浏览器来源；空 = 引擎默认清单。
  final List<String> corsOrigins;

  bool get hasAnyKey =>
      apiKey.isNotEmpty || profileKeys.values.any((String k) => k.isNotEmpty);

  static bool isLoopback(String bind) =>
      bind == '127.0.0.1' || bind == 'localhost' || bind == '::1';

  /// 不能起监听的原因（null = 可以起）：非回环却没有 key / key 重复。
  String? get startProblem {
    if (!isLoopback(bind) && !hasAnyKey) {
      return 'ankiconnect.bind=$bind 不是本机地址，必须先设 api_key 或 profile_keys，'
          '否则局域网里谁都能往复习库里加卡';
    }
    final List<String> keys = <String>[
      if (apiKey.isNotEmpty) apiKey,
      for (final String k in profileKeys.values)
        if (k.isNotEmpty) k,
    ];
    if (keys.toSet().length != keys.length) {
      return 'ankiconnect 的 api_key / profile_keys 有重复的 key，没法分出是哪份 profile';
    }
    return null;
  }

  ServerAnkiConnectConfig copyWith({
    bool? enabled,
    String? bind,
    int? port,
    String? apiKey,
    Map<String, String>? profileKeys,
    List<String>? corsOrigins,
  }) => ServerAnkiConnectConfig(
    enabled: enabled ?? this.enabled,
    bind: bind ?? this.bind,
    port: port ?? this.port,
    apiKey: apiKey ?? this.apiKey,
    profileKeys: profileKeys ?? this.profileKeys,
    corsOrigins: corsOrigins ?? this.corsOrigins,
  );

  void writeYaml(StringBuffer b, String Function(String) q) {
    b.writeln('ankiconnect:');
    b.writeln('  enabled: $enabled');
    b.writeln('  bind: ${q(bind)}');
    b.writeln('  port: $port');
    b.writeln('  api_key: ${q(apiKey)}');
    _writeMap(b, 'profile_keys', profileKeys, q);
    b.writeln('  cors_origins:${corsOrigins.isEmpty ? ' []' : ''}');
    for (final String o in corsOrigins) {
      b.writeln('    - ${q(o)}');
    }
  }
}

String _text(Object? v) => v == null ? '' : '$v'.trim();

List<String> _strings(Object? v) => <String>[
  if (v is List)
    for (final Object? e in v)
      if (e != null && '$e'.trim().isNotEmpty) '$e'.trim(),
];

Map<String, String> _stringMap(Object? v) => <String, String>{
  if (v is Map)
    for (final MapEntry<dynamic, dynamic> e in v.entries)
      if (e.key != null && e.value != null)
        '${e.key}'.trim(): '${e.value}'.trim(),
};

void _writeMap(
  StringBuffer b,
  String key,
  Map<String, String> m,
  String Function(String) q,
) {
  b.writeln('  $key:${m.isEmpty ? ' {}' : ''}');
  for (final MapEntry<String, String> e in m.entries) {
    b.writeln('    ${q(e.key)}: ${q(e.value)}');
  }
}
