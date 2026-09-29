import 'dart:convert';

import 'package:fushi_core/fushi_core.dart';

/// 游戏跨设备身份索引（互联标签 / 合集同步用）。
///
/// `galgames.id` 是添加时刻的微秒时间戳，**只在本机有意义**：同一款游戏在两台
/// 电脑上各加一次，id 必然不同。跨端要对上号只能靠内容身份，按可信度排序：
///
/// 1. `vndb:<id>` / `bgm:<id>`——刮削源给出的外部条目 id（[GalgameSources].externalId）；
/// 2. `exe:<归一化 exe 路径>`——两台机器装在同一路径（常见于整盘迁移 / 同步盘）；
/// 3. `title:<归一化标题>`——用户改的名、刮削名 / 中文名、入库时手填的名。
///    未改名的默认名（= exe 文件名去扩展名，如 `game` / `start`）**不产 title 键**：
///    它描述的是启动器文件而不是作品，大量不同的游戏都叫这个名。
///
/// 外部 id 是硬身份：两边都有同一刮削源（vndb / bgm）的 id 却不相交时，即使 exe
/// 路径或标题撞上也**拒绝对号**（同名不同作 / 复刻与原版），不退到弱身份。
///
/// 此外裸 `galgames.id` 总作为最后一个别名发布：从备份恢复出来的库保留原 id，
/// 同 id 即同一款（与备份合并 `_buildGameIdMap` 的「同 id → 同刮削身份 → 同 exe
/// 路径」判据同序）。
///
/// 每个本机游戏产出一组候选键；发布时取**本机唯一**的第一个做主键、其余做别名，
/// 解析时按对端给的键序逐个查、命中本机唯一一款才算对上。一个键在本机映射到多款
/// 游戏（同名重复入库、两个 exe 都叫 `game`）就是歧义，宁可对不上也不猜——对错
/// 号会把标签 / 合集成员挂到另一款游戏上，比漏同步更糟。
///
/// 一个唯一键都没有的游戏退回裸 `galgames.id`（与本改动之前的 wire 形态相同，
/// 对端解析不到即静默忽略，行为不倒退）。
class GameIdentityIndex {
  GameIdentityIndex._(this._keysById, this._idsByKey);

  /// 本机游戏 id → 候选身份键（按可信度排序、去重）。
  final Map<String, List<String>> _keysById;

  /// 候选身份键 → 声明它的本机游戏 id 集合（>1 即歧义）。
  final Map<String, Set<String>> _idsByKey;

  static const GameIdentityIndex empty = GameIdentityIndex._const();

  const GameIdentityIndex._const()
    : _keysById = const <String, List<String>>{},
      _idsByKey = const <String, Set<String>>{};

  static Future<GameIdentityIndex> load(FushiDatabase db) async {
    final List<GalgameRow> games = await db.getAllGalgames();
    if (games.isEmpty) return empty;
    final Map<String, List<GalgameSourceRow>> sources = await db
        .getAllGalgameSources();
    return build(<({GalgameRow game, List<GalgameSourceRow> sources})>[
      for (final GalgameRow g in games)
        (game: g, sources: sources[g.id] ?? const <GalgameSourceRow>[]),
    ]);
  }

  /// 纯函数构建（测试直接喂行）。
  static GameIdentityIndex build(
    List<({GalgameRow game, List<GalgameSourceRow> sources})> rows,
  ) {
    final Map<String, List<String>> keysById = <String, List<String>>{};
    final Map<String, Set<String>> idsByKey = <String, Set<String>>{};
    for (final ({GalgameRow game, List<GalgameSourceRow> sources}) r in rows) {
      final List<String> keys = candidateKeys(r.game, r.sources);
      keysById[r.game.id] = keys;
      for (final String k in keys) {
        (idsByKey[k] ??= <String>{}).add(r.game.id);
      }
    }
    return GameIdentityIndex._(keysById, idsByKey);
  }

  /// 一款游戏的候选身份键（可信度降序、去重）。
  static List<String> candidateKeys(
    GalgameRow game,
    List<GalgameSourceRow> sources,
  ) {
    final List<String> out = <String>[];
    void add(String? key) {
      if (key != null && !out.contains(key)) out.add(key);
    }

    for (final String source in _externalSources) {
      for (final GalgameSourceRow s in sources) {
        final String id = (s.externalId ?? '').trim();
        if (s.source == source && id.isNotEmpty) add('$source:$id');
      }
    }
    final String exe = game.exePath.trim().replaceAll(r'\', '/').toLowerCase();
    if (exe.isNotEmpty) add('exe:$exe');
    add(_titleKey(_customName(game.customDataJson)));
    for (final GalgameSourceRow s in sources) {
      final Map<String, Object?> data = _decodeObject(s.dataJson);
      add(_titleKey(data['nameCn']));
      add(_titleKey(data['name']));
    }
    if (!_isDefaultExeName(game.name, game.exePath)) {
      add(_titleKey(game.name));
    }
    return out;
  }

  /// 本机游戏 [gameId] 的跨端身份：主键 = 第一个本机唯一的候选键，别名 = 其余
  /// 唯一候选键 + 裸 id。没有任何唯一键时主键就是裸 id。不是本机游戏的键（合集
  /// 清单替对端转发的透传键）原样返回。
  ({String key, List<String> aliases}) wireIdentity(String gameId) {
    final List<String> unique = <String>[
      for (final String k in _keysById[gameId] ?? const <String>[])
        if (_idsByKey[k]?.length == 1) k,
    ];
    if (unique.isEmpty || !_keysById.containsKey(gameId)) {
      return (key: gameId, aliases: const <String>[]);
    }
    return (key: unique.first, aliases: <String>[...unique.skip(1), gameId]);
  }

  /// 跨端身份 → 本机游戏 id。[keys] 按对端给出的可信度顺序；第一个在本机唯一
  /// 命中的键胜出。也认本机裸 id（同一台设备自己发出去又收回来）。对不上返回 null。
  ///
  /// 命中的本机游戏若与对端在同一刮削源上的外部 id 冲突（两边都有、互不相交），
  /// 整体拒绝对号返回 null——那是另一款作品，不能靠 exe / 标题等弱身份凑上。
  String? resolve(Iterable<String> keys) {
    final List<String> remote = keys.toList(growable: false);
    for (final String k in remote) {
      final String? hit;
      if (_keysById.containsKey(k)) {
        hit = k;
      } else {
        final Set<String>? ids = _idsByKey[k];
        hit = (ids != null && ids.length == 1) ? ids.first : null;
      }
      if (hit == null) continue;
      return _externalIdsConflict(remote, _keysById[hit]!) ? null : hit;
    }
    return null;
  }

  static const List<String> _externalSources = <String>['vndb', 'bgm'];

  /// 同一刮削源上两边都有 id 且互不相交 ⇒ 不是同一款游戏。
  static bool _externalIdsConflict(List<String> remote, List<String> local) {
    for (final String source in _externalSources) {
      final String prefix = '$source:';
      final Set<String> r = <String>{
        for (final String k in remote)
          if (k.startsWith(prefix)) k,
      };
      if (r.isEmpty) continue;
      final Set<String> l = <String>{
        for (final String k in local)
          if (k.startsWith(prefix)) k,
      };
      if (l.isNotEmpty && r.intersection(l).isEmpty) return true;
    }
    return false;
  }

  /// [name] 是否就是入库时由 exe 文件名推出的默认名（未改名、未刮削）。与 app 侧
  /// `galgameNameFromExe` 同口径：文件名去扩展名，比较时忽略大小写与首尾空白。
  static bool _isDefaultExeName(String name, String exePath) {
    final String exe = exePath.trim();
    final int slash = exe.lastIndexOf(RegExp(r'[\\/]'));
    final String base = slash < 0 ? exe : exe.substring(slash + 1);
    final int dot = base.lastIndexOf('.');
    final String stem = dot <= 0 ? base : base.substring(0, dot);
    final String n = name.trim().toLowerCase();
    return n.isNotEmpty &&
        (n == stem.toLowerCase() ||
            n == base.toLowerCase() ||
            n == exe.toLowerCase());
  }

  static String? _titleKey(Object? raw) {
    if (raw is! String) return null;
    final String norm = raw.trim().toLowerCase().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
    return norm.isEmpty ? null : 'title:$norm';
  }

  static Object? _customName(String? customDataJson) =>
      _decodeObject(customDataJson)['name'];

  static Map<String, Object?> _decodeObject(String? json) {
    if (json == null || json.isEmpty) return const <String, Object?>{};
    try {
      final Object? v = jsonDecode(json);
      if (v is Map<String, Object?>) return v;
    } on FormatException {
      // 坏 JSON：当作没有这部分身份，不影响其它候选键。
    }
    return const <String, Object?>{};
  }
}
