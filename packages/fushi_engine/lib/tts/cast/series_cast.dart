/// 按系列记忆角色与声音：同一系列（漫画的各卷、小说的各卷）共用一份角色表和声音
/// 指派表，新的一卷开标注 / 生成时自动带上，不用每卷重新认人、重新选声音。
///
/// - 漫画演出稿（`MangaAudioScript`）与小说选角表（`TtsCast`）都挂在这上面，所以
///   「同一个角色在漫画里和小说里用同一个嗓子」也是同一份档案。
/// - 书自己的指派表叠在系列上面（[CastVoiceAssignment.resolveOver]）：书里没设的回落到
///   系列。用户在某一卷里给角色选声音时由界面决定写进系列还是只写这一卷；默认写系列。
/// - 角色表只增不减：每卷标注出来的新角色并进系列（同名合并别名、空特征补上），
///   下一卷的标注从系列角色表里选人，名字不会每卷漂移。
/// - 系列身份 [SeriesCastProfile.seriesKey] 由应用给（默认取书所在的合集，
///   `collection:<id>`；用户也可以手动指到别的系列），引擎只当不透明字符串。
/// - 一份档案一个 JSON（`<sha1(seriesKey)>.series-cast.json`），书 → 系列的关联在
///   同目录的 `series-links.json`。都是原子写。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';
import 'package:fushi_engine/tts/cast/cast_voice_assignment.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';

/// 并入角色：同名合并别名、空特征用新值补上（不覆盖已有值）。别名命中已有角色的
/// 新名字并进那个角色，避免同一人在系列里出现两次。
void mergeCastRoster(
  Map<String, TtsCastCharacter> roster,
  Iterable<TtsCastCharacter> found,
) {
  for (final TtsCastCharacter c in found) {
    if (c.name == kTtsNarrator || c.name == kTtsUnknown || c.name.isEmpty) {
      continue;
    }
    final String target = canonicalCastName(roster, c.name) ?? c.name;
    final TtsCastCharacter? old = roster[target];
    if (old == null) {
      roster[target] = c;
      continue;
    }
    roster[target] = TtsCastCharacter(
      name: old.name,
      aliases: <String>{
        ...old.aliases,
        if (c.name != old.name) c.name,
        ...c.aliases.where((String a) => a != old.name),
      }.toList(),
      gender: old.gender ?? c.gender,
      age: old.age ?? c.age,
      description: old.description ?? c.description,
    );
  }
}

/// [nameOrAlias] 在角色表里的规范名；不认识返回 null。
String? canonicalCastName(
  Map<String, TtsCastCharacter> roster,
  String nameOrAlias,
) {
  if (roster.containsKey(nameOrAlias)) return nameOrAlias;
  for (final TtsCastCharacter c in roster.values) {
    if (c.aliases.contains(nameOrAlias)) return c.name;
  }
  return null;
}

class SeriesCastProfile {
  SeriesCastProfile({
    required this.seriesKey,
    this.title = '',
    Map<String, TtsCastCharacter>? roster,
    CastVoiceAssignment? voices,
    this.defaultSeed,
    List<String>? members,
    List<CastTextSubstitution>? substitutions,
    this.updatedAt = 0,
  }) : substitutions = substitutions ?? <CastTextSubstitution>[],
       roster = roster ?? <String, TtsCastCharacter>{},
       voices = voices ?? CastVoiceAssignment(),
       members = members ?? <String>[];

  static const int schemaVersion = 1;

  final String seriesKey;

  /// 展示用的系列名（合集名的快照；改名不影响身份）。
  String title;

  /// 系列角色表：规范名 → 角色。
  final Map<String, TtsCastCharacter> roster;

  /// 系列级声音指派（各卷的指派表叠在它上面）。
  final CastVoiceAssignment voices;

  /// 系列默认种子；null = 各卷用自己的。
  int? defaultSeed;

  /// 关联到本系列的书（bookKey），按加入顺序；按系列跑标注 / 生成时就是这个顺序。
  final List<String> members;

  /// 用户填的用词替换表（见 `cast_text_substitution.dart`），各卷生成时共用。
  final List<CastTextSubstitution> substitutions;

  /// 最后修改时刻（毫秒）。
  int updatedAt;

  bool get isEmpty => roster.isEmpty && voices.isEmpty && substitutions.isEmpty;

  /// 生成时实际念的文字：按本系列替换表改写 [text]。
  String spokenText(String text) => applyCastSubstitutions(text, substitutions);

  /// 记住一卷里标注出的角色。
  void learnRoster(Iterable<TtsCastCharacter> found) =>
      mergeCastRoster(roster, found);

  /// 角色改名 / 合并：角色表与声音指派一起改，旧名留作别名。
  void renameCharacter(String from, String to) {
    if (from == to) return;
    voices.renameCharacter(from, to);
    final TtsCastCharacter? gone = roster.remove(from);
    if (gone != null && to != kTtsUnknown && to != kTtsNarrator) {
      mergeCastRoster(roster, <TtsCastCharacter>[
        TtsCastCharacter(
          name: to,
          aliases: <String>[from, ...gone.aliases],
          gender: gone.gender,
          age: gone.age,
          description: gone.description,
        ),
      ]);
    }
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'v': schemaVersion,
    'key': seriesKey,
    if (title.isNotEmpty) 'title': title,
    'roster': <Object?>[
      for (final TtsCastCharacter c in roster.values) c.toJson(),
    ],
    'voices': voices.toJson(),
    if (defaultSeed != null) 'seed': defaultSeed,
    'members': members,
    if (substitutions.isNotEmpty)
      'subs': <Object?>[
        for (final CastTextSubstitution s in substitutions) s.toJson(),
      ],
    'updated': updatedAt,
  };

  static SeriesCastProfile? fromJson(Object? raw) {
    if (raw is! Map || raw['key'] is! String) return null;
    final Object? roster = raw['roster'];
    final Object? members = raw['members'];
    final Object? seed = raw['seed'];
    final Object? updated = raw['updated'];
    final Object? title = raw['title'];
    final Object? subs = raw['subs'];
    return SeriesCastProfile(
      substitutions: <CastTextSubstitution>[
        if (subs is List)
          for (final Object? s in subs)
            if (CastTextSubstitution.fromJson(s)
                case final CastTextSubstitution e)
              e,
      ],
      seriesKey: raw['key'] as String,
      title: title is String ? title : '',
      roster: <String, TtsCastCharacter>{
        if (roster is List)
          for (final Object? r in roster)
            if (TtsCastCharacter.fromJson(r) case final TtsCastCharacter c)
              c.name: c,
      },
      voices: CastVoiceAssignment.fromJson(raw['voices']),
      defaultSeed: seed is int ? seed : null,
      members: <String>[
        if (members is List)
          for (final Object? m in members)
            if (m is String && m.isNotEmpty) m,
      ],
      updatedAt: updated is int ? updated : 0,
    );
  }
}

/// 系列档案与「书 → 系列」关联的存储。
class SeriesCastStore {
  SeriesCastStore(this.root);

  final Directory root;

  File _profileFile(String seriesKey) => File(
    p.join(
      root.path,
      '${sha1.convert(utf8.encode(seriesKey))}.series-cast.json',
    ),
  );

  File get _linksFile => File(p.join(root.path, 'series-links.json'));

  Future<SeriesCastProfile> load(String seriesKey) async {
    final File f = _profileFile(seriesKey);
    if (!await f.exists()) return SeriesCastProfile(seriesKey: seriesKey);
    try {
      final SeriesCastProfile? parsed = SeriesCastProfile.fromJson(
        jsonDecode(await f.readAsString()),
      );
      if (parsed != null && parsed.seriesKey == seriesKey) return parsed;
    } on FormatException {
      // 落到下面：坏文件挪开，返回空档案。
    }
    await f.rename('${f.path}.corrupt');
    return SeriesCastProfile(seriesKey: seriesKey);
  }

  Future<void> save(SeriesCastProfile profile, {DateTime? now}) async {
    profile.updatedAt = (now ?? DateTime.now()).millisecondsSinceEpoch;
    await _atomicWrite(
      _profileFile(profile.seriesKey),
      jsonEncode(profile.toJson()),
    );
  }

  Future<Map<String, String>> _readLinks() async {
    final File f = _linksFile;
    if (!await f.exists()) return <String, String>{};
    try {
      final Object? raw = jsonDecode(await f.readAsString());
      if (raw is! Map) return <String, String>{};
      return <String, String>{
        for (final MapEntry<Object?, Object?> e in raw.entries)
          if (e.key is String && e.value is String)
            e.key! as String: e.value! as String,
      };
    } on FormatException {
      await f.rename('${f.path}.corrupt');
      return <String, String>{};
    }
  }

  /// 书显式关联的系列；null = 没手动关联过（应用自己按合集推断）。
  Future<String?> linkOf(String bookKey) async => (await _readLinks())[bookKey];

  /// 把书关联到系列（同时登记进系列成员表）；[seriesKey] 为 null 解除关联。
  Future<void> link(String bookKey, String? seriesKey) async {
    final Map<String, String> links = await _readLinks();
    final String? previous = links[bookKey];
    if (previous == seriesKey) {
      if (seriesKey != null) await _ensureMember(seriesKey, bookKey);
      return;
    }
    if (seriesKey == null) {
      links.remove(bookKey);
    } else {
      links[bookKey] = seriesKey;
    }
    await _atomicWrite(_linksFile, jsonEncode(links));
    if (previous != null) {
      final SeriesCastProfile old = await load(previous);
      if (old.members.remove(bookKey)) await save(old);
    }
    if (seriesKey != null) await _ensureMember(seriesKey, bookKey);
  }

  Future<void> _ensureMember(String seriesKey, String bookKey) async {
    final SeriesCastProfile profile = await load(seriesKey);
    if (profile.members.contains(bookKey)) return;
    profile.members.add(bookKey);
    await save(profile);
  }

  /// 书改键（改标题）后把关联与成员表跟着改。
  Future<void> rekeyBook(String from, String to) async {
    final Map<String, String> links = await _readLinks();
    final String? series = links.remove(from);
    if (series == null) return;
    links[to] = series;
    await _atomicWrite(_linksFile, jsonEncode(links));
    final SeriesCastProfile profile = await load(series);
    final int at = profile.members.indexOf(from);
    if (at >= 0) {
      profile.members[at] = to;
      await save(profile);
    }
  }

  static Future<void> _atomicWrite(File f, String content) async {
    await f.parent.create(recursive: true);
    final File tmp = File('${f.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(f.path);
  }
}
