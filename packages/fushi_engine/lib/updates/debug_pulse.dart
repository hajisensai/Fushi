/// 调试版流水线（debug pulse）的数据模型与派生。
///
/// 数据由 CI（`tool/gen_debug_pulse.py`）算好推到 `update-manifest` 分支的
/// `debug-pulse-fushi.json`，契约见 `docs/specs/2026-11-10-debug-pulse.md`。这一层是纯的：
/// 只解析、只回答「相对本机装的那个调试版，哪些是新的」，不碰网络与 UI。
library;

import 'dart:convert';

/// 客户端认识的 schema 版本。不认识的版本整份当作没有数据（不猜字段）。
const int kDebugPulseSchemaVersion = 1;

/// 一个平台在某个调试版上的出包状态（生成器算好，客户端只映射）。
enum DebugPulsePlatformState {
  /// 滚动 release 上有这个平台的包。
  ok('ok'),

  /// 对应发布 run 排队 / 等待中。
  queued('queued'),

  /// 对应发布 run 正在跑。
  building('building'),

  /// run 成功，但包还不在 release 上。
  built('built'),

  /// run 失败 / 超时。
  failed('failed'),

  /// run 被后来的 push 取消（同分支发布互相顶掉）。
  superseded('superseded'),

  /// 没包，也没找到 run。
  none('none');

  const DebugPulsePlatformState(this.wire);

  final String wire;

  static DebugPulsePlatformState fromWire(Object? value) {
    for (final DebugPulsePlatformState s in values) {
      if (s.wire == value) return s;
    }
    return none;
  }

  /// 还在路上（会变成 [ok] 或失败）。
  bool get inFlight => this == queued || this == building || this == built;
}

/// 出包平台键。与资产名、生成器输出同形。
enum DebugPulsePlatform {
  android('android'),
  windows('windows'),
  macos('macos'),
  ios('ios');

  const DebugPulsePlatform(this.wire);

  final String wire;

  /// `Platform.operatingSystem` → 平台键；没有调试包的系统（linux 等）返回 null。
  static DebugPulsePlatform? fromOperatingSystem(String os) {
    for (final DebugPulsePlatform p in values) {
      if (p.wire == os) return p;
    }
    return null;
  }
}

class DebugPulsePlatformStatus {
  const DebugPulsePlatformStatus({required this.state, this.url});

  final DebugPulsePlatformState state;

  /// 对应发布 run 的网页。
  final String? url;

  static const DebugPulsePlatformStatus unknown = DebugPulsePlatformStatus(
    state: DebugPulsePlatformState.none,
  );
}

/// PR 的类别：取自 conventional-commit 标题前缀。
enum DebugPulsePrKind { feature, fix, perf, other }

class DebugPulsePr {
  const DebugPulsePr({
    required this.number,
    required this.title,
    required this.author,
    required this.mergedAt,
    required this.additions,
    required this.deletions,
    required this.labels,
  });

  final int number;

  /// 原始标题（含 `feat(scope):` 前缀）。显示用 [displayTitle]。
  final String title;
  final String author;
  final DateTime? mergedAt;
  final int additions;
  final int deletions;
  final List<String> labels;

  static final RegExp _conventional = RegExp(
    r'^(feat|fix|perf|refactor|docs|test|tests|chore|style|ci|build|revert)'
    r'(?:\(([^)]*)\))?!?:\s*',
    caseSensitive: false,
  );

  RegExpMatch? get _prefix => _conventional.firstMatch(title);

  DebugPulsePrKind get kind {
    final String? type = _prefix?.group(1)?.toLowerCase();
    return switch (type) {
      'feat' => DebugPulsePrKind.feature,
      'fix' => DebugPulsePrKind.fix,
      'perf' => DebugPulsePrKind.perf,
      _ => DebugPulsePrKind.other,
    };
  }

  /// `feat(server): xxx` 里的 `server`；没有则 null。
  String? get scope {
    final String? s = _prefix?.group(2)?.trim();
    return (s == null || s.isEmpty) ? null : s;
  }

  /// 去掉前缀后的标题。
  String get displayTitle {
    final RegExpMatch? m = _prefix;
    if (m == null) return title;
    final String rest = title.substring(m.end).trim();
    return rest.isEmpty ? title : rest;
  }
}

class DebugPulseCommit {
  const DebugPulseCommit({required this.sha, required this.subject});

  final String sha;
  final String subject;
}

/// 一组「多出来的提交」：一个调试版的内容，或 develop 上还没进包的部分。
abstract class DebugPulseChangeSet {
  List<int> get prNumbers;
  List<DebugPulseCommit> get direct;
  bool get truncated;
  Map<DebugPulsePlatform, DebugPulsePlatformStatus> get platforms;

  DebugPulsePlatformStatus platform(DebugPulsePlatform p) =>
      platforms[p] ?? DebugPulsePlatformStatus.unknown;
}

class DebugPulseBuild extends DebugPulseChangeSet {
  DebugPulseBuild({
    required this.seq,
    required this.version,
    required this.sha,
    required this.unknown,
    required this.publishedAt,
    required this.testflight,
    required this.baseSeq,
    required this.prNumbers,
    required this.direct,
    required this.truncated,
    required this.platforms,
  });

  final int seq;
  final String version;
  final String? sha;

  /// sha 解析不出，内容未知。
  final bool unknown;
  final DateTime? publishedAt;
  final bool testflight;
  final int? baseSeq;
  @override
  final List<int> prNumbers;
  @override
  final List<DebugPulseCommit> direct;
  @override
  final bool truncated;
  @override
  final Map<DebugPulsePlatform, DebugPulsePlatformStatus> platforms;

  /// 与更新器版本串同形的显示名：`debug.25034`。
  String get label => 'debug.$seq';
}

class DebugPulsePending extends DebugPulseChangeSet {
  DebugPulsePending({
    required this.headSha,
    required this.headSeq,
    required this.prNumbers,
    required this.direct,
    required this.truncated,
    required this.platforms,
  });

  final String headSha;

  /// 下一个包会叫 `debug.<headSeq>`；算不出时 null。
  final int? headSeq;
  @override
  final List<int> prNumbers;
  @override
  final List<DebugPulseCommit> direct;
  @override
  final bool truncated;
  @override
  final Map<DebugPulsePlatform, DebugPulsePlatformStatus> platforms;

  bool get isEmpty => prNumbers.isEmpty && direct.isEmpty;
}

class DebugPulseReport {
  DebugPulseReport({
    required this.generatedAt,
    required this.repo,
    required this.builds,
    required this.pending,
    required this.prs,
  });

  final DateTime? generatedAt;
  final String repo;

  /// seq 降序。
  final List<DebugPulseBuild> builds;
  final DebugPulsePending? pending;
  final Map<int, DebugPulsePr> prs;

  DebugPulseBuild? get latest => builds.isEmpty ? null : builds.first;

  /// 编号对应的 PR；生成器漏了元数据时给一个只有编号的占位，不丢条目。
  DebugPulsePr pr(int number) =>
      prs[number] ??
      DebugPulsePr(
        number: number,
        title: '#$number',
        author: '',
        mergedAt: null,
        additions: 0,
        deletions: 0,
        labels: const <String>[],
      );

  String prUrl(int number) => 'https://github.com/$repo/pull/$number';

  /// 比本机 [installedSeq] 新的调试版（seq 降序）。本机 seq 未知时为空——
  /// 不知道装的是哪个，就不敢说哪些是「新的」。
  List<DebugPulseBuild> newerThan(int? installedSeq) => installedSeq == null
      ? const <DebugPulseBuild>[]
      : builds.where((DebugPulseBuild b) => b.seq > installedSeq).toList();

  /// 比本机新的包里一共多了几个 PR（去重）。
  int newPrCount(int? installedSeq) => <int>{
    for (final DebugPulseBuild b in newerThan(installedSeq)) ...b.prNumbers,
  }.length;

  /// 本机平台最新一个**真出了包**的调试版：能更新到的就是它。
  DebugPulseBuild? latestAvailableFor(DebugPulsePlatform? platform) {
    for (final DebugPulseBuild b in builds) {
      if (platform == null ||
          b.platform(platform).state == DebugPulsePlatformState.ok) {
        return b;
      }
    }
    return null;
  }

  /// 解析 CI 产出的 JSON。结构不对 / schema 不认识返回 null（当作没有数据）。
  static DebugPulseReport? tryParse(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    if (decoded['schema'] != kDebugPulseSchemaVersion) return null;
    final String repo = _str(decoded['repo']) ?? 'hajisensai/Fushi';

    final Map<int, DebugPulsePr> prs = <int, DebugPulsePr>{};
    final Object? rawPrs = decoded['prs'];
    if (rawPrs is Map<String, Object?>) {
      for (final MapEntry<String, Object?> e in rawPrs.entries) {
        final Object? v = e.value;
        final int? n =
            int.tryParse(e.key) ?? (v is Map ? _int(v['number']) : null);
        if (n == null || v is! Map<String, Object?>) continue;
        prs[n] = DebugPulsePr(
          number: n,
          title: _str(v['title']) ?? '#$n',
          author: _str(v['author']) ?? '',
          mergedAt: _date(v['mergedAt']),
          additions: _int(v['additions']) ?? 0,
          deletions: _int(v['deletions']) ?? 0,
          labels: _list(v['labels']).whereType<String>().toList(),
        );
      }
    }

    final List<DebugPulseBuild> builds = <DebugPulseBuild>[];
    for (final Object? raw in _list(decoded['builds'])) {
      if (raw is! Map<String, Object?>) continue;
      final int? seq = _int(raw['seq']);
      if (seq == null) continue;
      builds.add(
        DebugPulseBuild(
          seq: seq,
          version: _str(raw['version']) ?? '',
          sha: _str(raw['sha']),
          unknown: raw['unknown'] == true || _str(raw['sha']) == null,
          publishedAt: _date(raw['publishedAt']),
          testflight: raw['testflight'] == true,
          baseSeq: _int(raw['baseSeq']),
          prNumbers: _ints(raw['prs']),
          direct: _commits(raw['direct']),
          truncated: raw['truncated'] == true,
          platforms: _platforms(raw['platforms']),
        ),
      );
    }
    builds.sort((DebugPulseBuild a, DebugPulseBuild b) => b.seq - a.seq);

    DebugPulsePending? pending;
    final Object? rawPending = decoded['pending'];
    if (rawPending is Map<String, Object?>) {
      pending = DebugPulsePending(
        headSha: _str(rawPending['headSha']) ?? '',
        headSeq: _int(rawPending['headSeq']),
        prNumbers: _ints(rawPending['prs']),
        direct: _commits(rawPending['direct']),
        truncated: rawPending['truncated'] == true,
        platforms: _platforms(rawPending['platforms']),
      );
    }

    return DebugPulseReport(
      generatedAt: _date(decoded['generatedAt']),
      repo: repo,
      builds: builds,
      pending: pending,
      prs: prs,
    );
  }
}

String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

int? _int(Object? v) => switch (v) {
  final int i => i,
  final num n => n.toInt(),
  final String s => int.tryParse(s),
  _ => null,
};

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;

List<Object?> _list(Object? v) =>
    v is List ? v.cast<Object?>() : const <Object?>[];

List<int> _ints(Object? v) => <int>[for (final Object? e in _list(v)) ?_int(e)];

List<DebugPulseCommit> _commits(Object? v) => <DebugPulseCommit>[
  for (final Object? e in _list(v))
    if (e is Map<String, Object?>)
      DebugPulseCommit(
        sha: _str(e['sha']) ?? '',
        subject: _str(e['subject']) ?? '',
      ),
];

Map<DebugPulsePlatform, DebugPulsePlatformStatus> _platforms(Object? v) {
  final Map<DebugPulsePlatform, DebugPulsePlatformStatus> out =
      <DebugPulsePlatform, DebugPulsePlatformStatus>{};
  if (v is! Map<String, Object?>) return out;
  for (final DebugPulsePlatform p in DebugPulsePlatform.values) {
    final Object? s = v[p.wire];
    if (s is! Map<String, Object?>) continue;
    out[p] = DebugPulsePlatformStatus(
      state: DebugPulsePlatformState.fromWire(s['state']),
      url: _str(s['url']),
    );
  }
  return out;
}
