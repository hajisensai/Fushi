/// 游戏的 VNDB 配音表（作品图谱 L5，spec `docs/specs/2026-10-24-cross-media-links.md`
/// §5）：`POST /kana/vn` 的 `va` 字段——角色 + 声优 + 声优的外部链接。
///
/// 只读游戏侧**已绑定的** VNDB id（`galgame_sources` 的 vndb 行），不为人物页另起
/// 刮削：一部游戏一次请求，结果落 `game_voice_casts` 缓存。
///
/// 2026-10-24 实测（`v17`）：`va.staff.extlinks` 直接给出声优的 `anidb`（AniDB
/// creator id）、`wikidata`（数字，不带 Q）、`musicbrainz_artist`（MBID），这就是
/// 视频 / 游戏 / 音乐三域人物合并的主桥，不必每个声优都去问 Wikidata。
///
/// 角色图按 `image.sexual` 过滤：均值 > 0.5（不是明确的「安全」）就不保留 URL——
/// 人物页是普通浏览面，不在这里展示可能露骨的图。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:fushi_engine/media/people/person_identity.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_engine/utils/net/app_user_agent.dart';

/// 请求 `va` 时要的字段（逐字，2026-10-24 对 kana API 实测可用）。
const String kVndbVoiceCastFields =
    'va.note,va.character.id,va.character.name,va.character.original,'
    'va.character.image.url,va.character.image.sexual,'
    'va.staff.id,va.staff.name,va.staff.original,'
    'va.staff.extlinks.name,va.staff.extlinks.id';

/// 角色图 `sexual` 均值超过它就丢掉 URL（0 = 安全，1 = 暗示，2 = 露骨）。
const double kVndbCharacterImageMaxSexual = 0.5;

/// 一条配音：一个角色由一位声优出演。
class GameVoiceCredit {
  GameVoiceCredit({
    required this.characterId,
    required this.characterName,
    required this.staffId,
    required this.staffName,
    this.characterOriginal,
    this.characterImageUrl,
    this.staffOriginal,
    this.note,
    Iterable<String> staffIdNodes = const <String>[],
  }) : staffIdNodes = Set<String>.unmodifiable(staffIdNodes);

  /// VNDB 角色 id（`c32`）。
  final String characterId;
  final String characterName;
  final String? characterOriginal;
  final String? characterImageUrl;

  /// VNDB staff id（`s566`）。
  final String staffId;
  final String staffName;
  final String? staffOriginal;

  /// VNDB 的配音备注（「幼少期」等）。
  final String? note;

  /// 声优的外部 id 节点（[personIdNode]）：至少有 `id:vndb:<staffId>`，外加 extlinks
  /// 里的 AniDB / Wikidata / MusicBrainz。
  final Set<String> staffIdNodes;

  Map<String, Object?> toJson() => <String, Object?>{
    'cid': characterId,
    'cn': characterName,
    if (characterOriginal != null) 'co': characterOriginal,
    if (characterImageUrl != null) 'ci': characterImageUrl,
    'sid': staffId,
    'sn': staffName,
    if (staffOriginal != null) 'so': staffOriginal,
    if (note != null) 'note': note,
    'ids': staffIdNodes.toList()..sort(),
  };

  static GameVoiceCredit? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? cid = json['cid'];
    final Object? cn = json['cn'];
    final Object? sid = json['sid'];
    final Object? sn = json['sn'];
    if (cid is! String || cn is! String || sid is! String || sn is! String) {
      return null;
    }
    final Object? ids = json['ids'];
    return GameVoiceCredit(
      characterId: cid,
      characterName: cn,
      characterOriginal: _str(json['co']),
      characterImageUrl: _str(json['ci']),
      staffId: sid,
      staffName: sn,
      staffOriginal: _str(json['so']),
      note: _str(json['note']),
      staffIdNodes: <String>[
        if (ids is List)
          for (final Object? n in ids)
            if (n is String) n,
      ],
    );
  }
}

String? _str(Object? v) {
  if (v is! String) return null;
  final String t = v.trim();
  return t.isEmpty ? null : t;
}

/// 缓存编码（`game_voice_casts.cast_json`）。
String encodeGameVoiceCast(List<GameVoiceCredit> cast) =>
    jsonEncode(<Object?>[for (final GameVoiceCredit c in cast) c.toJson()]);

/// 缓存解码；坏 JSON 返回空表（缓存坏了等同没取过之外的「没有配音」，调用方按
/// fetchedAt 过期重取）。
List<GameVoiceCredit> decodeGameVoiceCast(String raw) {
  final Object? json;
  try {
    json = jsonDecode(raw);
  } on FormatException {
    return const <GameVoiceCredit>[];
  }
  if (json is! List) return const <GameVoiceCredit>[];
  return <GameVoiceCredit>[
    for (final Object? e in json)
      if (GameVoiceCredit.fromJson(e) case final GameVoiceCredit c) c,
  ];
}

/// VNDB extlinks 名 → 人物外部 id scheme（只收这三类）。
String? _schemeOfVndbExtlink(String name) => switch (name) {
  'anidb' => PersonIdScheme.anidb,
  'wikidata' => PersonIdScheme.wikidata,
  'musicbrainz_artist' => PersonIdScheme.musicbrainz,
  _ => null,
};

/// 解析一条 `/vn` 结果的 `va` 字段（纯函数）。缺角色 / 缺声优的条目跳过；同一
/// （角色, 声优）只留一条。
List<GameVoiceCredit> parseVndbVoiceCast(Object? vn) {
  if (vn is! Map) return const <GameVoiceCredit>[];
  final Object? va = vn['va'];
  if (va is! List) return const <GameVoiceCredit>[];
  final List<GameVoiceCredit> out = <GameVoiceCredit>[];
  final Set<String> seen = <String>{};
  for (final Object? entry in va) {
    if (entry is! Map) continue;
    final Object? character = entry['character'];
    final Object? staff = entry['staff'];
    if (character is! Map || staff is! Map) continue;
    final String? cid = _str(character['id']);
    final String? cname = _str(character['name']);
    final String? sid = normalizePersonExternalId(
      PersonIdScheme.vndb,
      staff['id']?.toString() ?? '',
    );
    final String? sname = _str(staff['name']);
    if (cid == null || cname == null || sid == null || sname == null) continue;
    if (!seen.add('$cid|$sid')) continue;
    String? image;
    final Object? img = character['image'];
    if (img is Map) {
      final Object? sexual = img['sexual'];
      final double s = sexual is num ? sexual.toDouble() : 2;
      if (s <= kVndbCharacterImageMaxSexual) image = _str(img['url']);
    }
    final Set<String> ids = <String>{
      if (personIdNode(PersonIdScheme.vndb, sid) case final String n) n,
    };
    final Object? links = staff['extlinks'];
    if (links is List) {
      for (final Object? l in links) {
        if (l is! Map) continue;
        final Object? name = l['name'];
        final Object? id = l['id'];
        if (name is! String || id == null) continue;
        final String? scheme = _schemeOfVndbExtlink(name);
        if (scheme == null) continue;
        if (personIdNode(scheme, id.toString()) case final String n) ids.add(n);
      }
    }
    out.add(
      GameVoiceCredit(
        characterId: cid,
        characterName: cname,
        characterOriginal: _str(character['original']),
        characterImageUrl: image,
        staffId: sid,
        staffName: sname,
        staffOriginal: _str(staff['original']),
        note: _str(entry['note']),
        staffIdNodes: ids,
      ),
    );
  }
  return out;
}

/// VNDB 配音表请求失败（非 2xx / 回复不是合法 JSON / 超时）。不缓存失败。
class VndbVoiceCastException implements Exception {
  const VndbVoiceCastException(this.message);

  final String message;

  @override
  String toString() => 'VndbVoiceCastException: $message';
}

/// 取一部 VN 的配音表。应用内用 [shared]（进程级串行 + 最小间隔，VNDB 官方限流约
/// 200 次 / 5 分钟，这里取远比它保守的 1.1 s）；测试注入 `client`。
class VndbVoiceCastClient {
  VndbVoiceCastClient({
    http.Client? client,
    this.endpoint = 'https://api.vndb.org/kana/vn',
    this.minInterval = const Duration(milliseconds: 1100),
    this.timeout = const Duration(seconds: 20),
  }) : _client = client;

  static final VndbVoiceCastClient shared = VndbVoiceCastClient();

  final http.Client? _client;
  final String endpoint;
  final Duration minInterval;
  final Duration timeout;

  Future<void> _tail = Future<void>.value();
  DateTime? _lastRequestAt;

  /// [vnId] 不合法或 VNDB 上不存在 → null；存在但没有配音 → 空表。
  Future<List<GameVoiceCredit>?> fetch(String vnId) {
    final String id = vnId.trim().toLowerCase();
    if (!RegExp(r'^v[1-9][0-9]{0,8}$').hasMatch(id)) {
      return Future<List<GameVoiceCredit>?>.value();
    }
    final Completer<List<GameVoiceCredit>?> done =
        Completer<List<GameVoiceCredit>?>();
    _tail = _tail.then((_) async {
      final DateTime? last = _lastRequestAt;
      if (last != null) {
        final Duration wait = minInterval - DateTime.now().difference(last);
        if (wait > Duration.zero) await Future<void>.delayed(wait);
      }
      _lastRequestAt = DateTime.now();
      try {
        done.complete(await _query(id));
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  Future<List<GameVoiceCredit>?> _query(String id) async {
    final http.Client client = _client ?? createAppHttpIoClient();
    try {
      final http.Response res = await client
          .post(
            Uri.parse(endpoint),
            headers: <String, String>{
              'User-Agent': fushiUserAgent('people-vndb-cast'),
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(<String, Object?>{
              'filters': <Object?>['id', '=', id],
              'fields': kVndbVoiceCastFields,
              'results': 1,
            }),
          )
          .timeout(timeout);
      if (res.statusCode == 404) return null;
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw VndbVoiceCastException('HTTP ${res.statusCode}');
      }
      final Object? json;
      try {
        json = jsonDecode(utf8.decode(res.bodyBytes));
      } on FormatException catch (e) {
        throw VndbVoiceCastException('bad JSON: ${e.message}');
      }
      final Object? results = json is Map ? json['results'] : null;
      if (results is! List) throw const VndbVoiceCastException('no results');
      if (results.isEmpty) return null;
      return parseVndbVoiceCast(results.first);
    } on TimeoutException {
      throw const VndbVoiceCastException('timeout');
    } on http.ClientException catch (e) {
      throw VndbVoiceCastException(e.message);
    } finally {
      if (_client == null) client.close();
    }
  }
}
