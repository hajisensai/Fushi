/// 作品图谱 AI 裁决（[AiFeature.mediaLinks]，spec
/// `docs/specs/2026-10-24-cross-media-links.md`「AI 辅助判断」）。
///
/// 输入是确定性规则已缩小的候选（两端各自的标题写法、年份、种类、已知外部 id、
/// 是哪条规则提的、规则猜的关系），输出按候选下标回填的结构化结论：关系
/// （adaptation / same_work / sequel / side_story / 音乐两种 / none）、方向、置信度、
/// 理由。**不让 AI 自由检索或编造 id**：回复里只有下标与枚举值，端点永远来自本地
/// 数据；下标越界、关系不认识、置信度非法的条目一律丢弃（该条视为「判不了」，保留
/// 确定性结果）。
///
/// 省额度（都不降判断质量）：
/// - 一个条目在一次请求里只发一遍（`items` 表 + `pairs` 引用下标）——以某个条目为
///   中心的十几条候选不再把它的全部标题重复十几遍；
/// - 每个条目最多 [kAiMediaLinkMaxTitlesPerItem] 个写法、规范化后相同的只留一个
///   （VNDB 别名能有十几个）；
/// - 不再发规则的英文证据句（它只是把两边标题又抄一遍），改发规则名与猜测关系；
/// - 回复用短键，不相关的不写理由；
/// - 回复被截断时逐条抢救已写完的结论，不整批作废重问；
/// - 后面的批次失败时保留前面已拿到的结论（[AiMediaLinkJudge.partialFailure]）；
/// - 问过的一对记进本机缓存（[MediaLinkVerdictCache]，`media_link_ai_verdicts`）：
///   AI 看到的内容、模型、提示词版本都没变就直接用上次的结论，不再发请求。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' show sha1;
import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_reply_json.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/media/links/media_link_inference.dart';

/// 一次请求最多送几条候选（再多拆批）。
const int kAiMediaLinkMaxCandidatesPerRequest = 20;

/// 一个条目最多发几个标题写法。
const int kAiMediaLinkMaxTitlesPerItem = 4;

/// 单个标题最多发几个字符（超长的文件名式标题截断）。
const int kAiMediaLinkMaxTitleChars = 80;

/// 提示词 / 回复格式的版本：改了系统提示词或发给 AI 的条目形状就加一，旧缓存的摘要
/// 自然对不上、全部重问。
const int kAiMediaLinkPromptVersion = 2;

/// 缓存的结论保留多久：过期后重新问一次（模型在进步，条目也可能早就删了）。
const Duration kAiMediaLinkVerdictCacheTtl = Duration(days: 180);

/// 解析「作品图谱裁决」当前可用的提供商；null = 未指派 / 已删 / 没配全（跳过 AI，
/// 只剩确定性推断）。
AiProviderConfig? resolveMediaLinkAiProvider(AiSettingsSource settings) =>
    settings.aiFeatureAssignments.resolve(
      AiFeature.mediaLinks,
      settings.aiProviders,
    );

const String kAiMediaLinkSystemPrompt = '''
You judge pairs of items from one person's media library (anime / video
series, single videos, books including manga and light novels, visual novels
and other games, music): do they belong to the same creative work or series?

Input JSON: "items" are library items (k = kind, t = known title spellings,
y = year, ids = known external ids). "pairs" is what to judge: i = pair
number, a / b = positions in "items", src = the local rule that proposed the
pair, guess = that rule's relation guess (it may be wrong).

Judge every pair on its own. "r" is one of:
- "adaptation": one side adapts the other (novel -> anime, game -> anime,
  manga -> game ...).
- "same_work": two versions or copies of the same work and no side is clearly
  the original.
- "sequel": different installments of one series (season 2, sequel novel,
  sequel game).
- "side_story": one is a side story, spin-off, movie or fan disc of the
  other's main story.
- "soundtrack" / "theme_song": only when side a is music (kind music_album or
  music_track) made for side b; "soundtrack" for a score / OST album,
  "theme_song" for opening / ending / insert / character songs and drama CDs.
  A compilation or a cover that merely contains the title is "none".
- "none": not related. A same or similar title alone is not enough when
  years, kinds or creators contradict it.
"o": "a" or "b" for the original of an adaptation, the earlier installment of
a sequel, or the main story of a side story; "?" when you cannot tell. Always
"a" for music.
"c": confidence from 0 to 1.
"why": at most 12 words the user will read; leave it out when r is "none".

Never invent identifiers and never add pairs. Reply with one JSON object only,
no prose, one entry per pair:
{"v":[{"i":0,"r":"adaptation","o":"a","c":0.8,"why":"..."},{"i":1,"r":"none","c":0.9}]}
''';

/// 发给 AI 的标题：规范化后相同的只留第一个，最多
/// [kAiMediaLinkMaxTitlesPerItem] 个，超长截断。
List<String> aiMediaLinkTitles(List<String> titles) {
  final Set<String> seen = <String>{};
  final List<String> out = <String>[];
  for (final String raw in titles) {
    final String title = raw.trim();
    if (title.isEmpty || !seen.add(foldMediaTitle(title))) continue;
    out.add(
      title.length > kAiMediaLinkMaxTitleChars
          ? title.substring(0, kAiMediaLinkMaxTitleChars)
          : title,
    );
    if (out.length >= kAiMediaLinkMaxTitlesPerItem) break;
  }
  return out;
}

Map<String, Object?> _item(MediaLinkSubject s) => <String, Object?>{
  'k': s.endpoint.kind.dbValue,
  't': aiMediaLinkTitles(s.titles),
  if (s.year != null) 'y': s.year,
  if (s.externalIds.isNotEmpty) 'ids': s.externalIds,
};

/// 用户消息：条目表（每个条目只出现一次）+ 候选对（a = 候选 from，b = 候选 to）。
String buildAiMediaLinkUserPrompt(List<MediaLinkCandidate> candidates) {
  final Map<String, int> indexOf = <String, int>{};
  final List<Map<String, Object?>> items = <Map<String, Object?>>[];
  int item(MediaLinkSubject s) => indexOf.putIfAbsent(
    '${s.endpoint.kind.dbValue}\u0000${s.endpoint.key}',
    () {
      items.add(_item(s));
      return items.length - 1;
    },
  );

  final List<Map<String, Object?>> pairs = <Map<String, Object?>>[
    for (int i = 0; i < candidates.length; i++)
      <String, Object?>{
        'i': i,
        'a': item(candidates[i].from),
        'b': item(candidates[i].to),
        'src': candidates[i].source,
        'guess': candidates[i].relation.dbValue,
      },
  ];
  return jsonEncode(<String, Object?>{'items': items, 'pairs': pairs});
}

int? _asIndex(Object? raw) => switch (raw) {
  final int v => v,
  final double v when v == v.roundToDouble() => v.toInt(),
  final String v => int.tryParse(v.trim()),
  _ => null,
};

double? _asConfidence(Object? raw) {
  final double? c = switch (raw) {
    final num v => v.toDouble(),
    final String v => double.tryParse(v.trim()),
    _ => null,
  };
  return c == null || c.isNaN || c < 0 || c > 1 ? null : c;
}

const Set<String> _unrelatedWords = <String>{
  'none',
  'unrelated',
  'not_related',
  'no',
  'null',
};

/// 回复里的关系词 → 关系 + 是否要把方向反过来（`prequel` = 反向的 sequel）。
({MediaLinkRelation relation, bool flip})? _relationOf(String word) =>
    switch (word) {
      'adaptation' => (relation: MediaLinkRelation.adaptation, flip: false),
      'same_work' => (relation: MediaLinkRelation.sameWork, flip: false),
      'theme_song' => (relation: MediaLinkRelation.themeSong, flip: false),
      'soundtrack' => (relation: MediaLinkRelation.soundtrack, flip: false),
      'sequel' => (relation: MediaLinkRelation.sequel, flip: false),
      'prequel' => (relation: MediaLinkRelation.sequel, flip: true),
      'side_story' ||
      'spin_off' ||
      'spinoff' => (relation: MediaLinkRelation.sideStory, flip: false),
      _ => null,
    };

/// 回复整体不是合法 JSON（多半是输出被截断）时，把已经写完整的结论对象逐个抠出来。
List<Object?> _salvageVerdictNodes(String reply) {
  final List<Object?> out = <Object?>[];
  // 跳过最外层的 `{`：从它后面开始找各条结论自己的对象。
  int from = reply.indexOf('{') + 1;
  while (from > 0 && from < reply.length) {
    final int open = reply.indexOf('{', from);
    if (open < 0) break;
    final String? text = extractAiJsonObject(reply.substring(open));
    if (text == null) break; // 剩下的是没写完的那一条。
    try {
      out.add(jsonDecode(text));
    } on FormatException {
      // 这一条本身坏了，跳过它继续。
    }
    from = open + text.length;
  }
  return out;
}

/// 解析 AI 回复成与 [count] 条候选同序的结论；形状不对的条目为 null。
/// 新旧两种键名都认（`v` / `verdicts`、`i` / `index`、`r` / `relation`、
/// `o` / `original`、`c` / `confidence`、`why` / `reason`）。
List<MediaLinkVerdict?> parseAiMediaLinkVerdicts(String reply, int count) {
  final List<MediaLinkVerdict?> out = List<MediaLinkVerdict?>.filled(
    count,
    null,
  );
  final Map<String, Object?>? json = decodeAiJsonObject(reply);
  final Object? listed = json?['v'] ?? json?['verdicts'];
  final List<Object?> raw = listed is List
      ? listed.cast<Object?>()
      : _salvageVerdictNodes(reply);
  for (final Object? node in raw) {
    if (node is! Map) continue;
    final int? index = _asIndex(node['i'] ?? node['index']);
    if (index == null || index < 0 || index >= count) continue;
    final Object? relationRaw = node['r'] ?? node['relation'];
    final String word = relationRaw is String
        ? relationRaw.trim().toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_')
        : '';
    final Object? relatedRaw = node['related'];
    final bool related = relatedRaw is bool
        ? relatedRaw
        : word.isNotEmpty && !_unrelatedWords.contains(word);
    final double? confidence = _asConfidence(node['c'] ?? node['confidence']);
    if (!related) {
      // 不相关的结论只用来丢弃候选，置信度缺省也认。
      if (relatedRaw is! bool && word.isEmpty) continue;
      out[index] = MediaLinkVerdict(
        related: false,
        relation: MediaLinkRelation.sameWork,
        fromIsOriginal: null,
        confidence: confidence ?? 0,
        reason: 'AI verdict',
      );
      continue;
    }
    final ({MediaLinkRelation relation, bool flip})? relation = _relationOf(
      word,
    );
    if (relation == null || confidence == null) continue;
    final bool? fromIsOriginal = switch (node['o'] ?? node['original']) {
      'a' => true,
      'b' => false,
      _ => null,
    };
    final Object? reason = node['why'] ?? node['reason'];
    out[index] = MediaLinkVerdict(
      related: true,
      relation: relation.relation,
      fromIsOriginal: fromIsOriginal == null
          ? null
          : fromIsOriginal != relation.flip,
      confidence: confidence,
      reason: reason is String && reason.trim().isNotEmpty
          ? reason.trim()
          : 'AI verdict',
    );
  }
  return out;
}

/// 一批 [count] 条候选的输出上限：每条结论约 60 token（含一句理由），留一倍余量。
int aiMediaLinkMaxTokens(int count) => 256 + 110 * count;

/// 一条候选在缓存里的位置：无序的一对端点（[aFirst] = 候选的 from 就是字典序较小的
/// 一端）+ AI 输入的摘要。
typedef _CacheSlot = ({
  MediaLinkEndpoint a,
  MediaLinkEndpoint b,
  bool aFirst,
  String fingerprint,
});

String _endpointSortKey(MediaLinkEndpoint e) =>
    '${e.kind.dbValue}\u0000${e.key}';

/// 作品图谱 AI 裁决的本机缓存（`media_link_ai_verdicts`，设备本地、纯缓存）。
class MediaLinkVerdictCache {
  MediaLinkVerdictCache(this.db, {int Function()? now})
    : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final FushiDatabase db;
  final int Function() _now;

  int get _notBefore => _now() - kAiMediaLinkVerdictCacheTtl.inMilliseconds;

  _CacheSlot _slot(MediaLinkCandidate c, String model) {
    final bool aFirst =
        _endpointSortKey(
          c.from.endpoint,
        ).compareTo(_endpointSortKey(c.to.endpoint)) <=
        0;
    final MediaLinkSubject a = aFirst ? c.from : c.to;
    final MediaLinkSubject b = aFirst ? c.to : c.from;
    return (
      a: a.endpoint,
      b: b.endpoint,
      aFirst: aFirst,
      fingerprint: sha1
          .convert(
            utf8.encode(
              jsonEncode(<Object?>[
                kAiMediaLinkPromptVersion,
                model,
                _item(a),
                _item(b),
              ]),
            ),
          )
          .toString(),
    );
  }

  /// [candidates] 各自缓存的结论（同序同长）；没缓存 / 已过期 / AI 输入变了为 null。
  Future<List<MediaLinkVerdict?>> lookup(
    List<MediaLinkCandidate> candidates,
    String model,
  ) async {
    final Map<String, MediaLinkAiVerdictRow> rows =
        <String, MediaLinkAiVerdictRow>{
          for (final MediaLinkAiVerdictRow r
              in await db.mediaLinkAiVerdictsSince(_notBefore))
            '${r.aKind}\u0000${r.aKey}\u0001${r.bKind}\u0000${r.bKey}': r,
        };
    return <MediaLinkVerdict?>[
      for (final MediaLinkCandidate c in candidates) _read(c, model, rows),
    ];
  }

  MediaLinkVerdict? _read(
    MediaLinkCandidate c,
    String model,
    Map<String, MediaLinkAiVerdictRow> rows,
  ) {
    final _CacheSlot slot = _slot(c, model);
    final MediaLinkAiVerdictRow? row =
        rows['${_endpointSortKey(slot.a)}\u0001${_endpointSortKey(slot.b)}'];
    if (row == null || row.fingerprint != slot.fingerprint) return null;
    final MediaLinkRelation? relation = row.relation == null
        ? null
        : MediaLinkRelation.tryParse(row.relation!);
    if (row.related && relation == null) return null;
    final bool? aIsOriginal = row.aIsOriginal;
    return MediaLinkVerdict(
      related: row.related,
      relation: relation ?? MediaLinkRelation.sameWork,
      fromIsOriginal: aIsOriginal == null ? null : aIsOriginal == slot.aFirst,
      confidence: row.confidence,
      reason: row.reason.isEmpty ? 'AI verdict' : row.reason,
    );
  }

  /// 记下 [candidates] 各自刚拿到的结论（[verdicts] 同序；null = 没判出来，不记），
  /// 顺带清掉过期行。
  Future<void> store(
    List<MediaLinkCandidate> candidates,
    List<MediaLinkVerdict?> verdicts,
    String model,
  ) async {
    final int at = _now();
    final List<MediaLinkAiVerdictsCompanion> rows =
        <MediaLinkAiVerdictsCompanion>[];
    for (int i = 0; i < candidates.length; i++) {
      final MediaLinkVerdict? v = verdicts[i];
      if (v == null) continue;
      final _CacheSlot slot = _slot(candidates[i], model);
      final bool? fromIsOriginal = v.fromIsOriginal;
      rows.add(
        MediaLinkAiVerdictsCompanion.insert(
          aKind: slot.a.kind.dbValue,
          aKey: slot.a.key,
          bKind: slot.b.kind.dbValue,
          bKey: slot.b.key,
          fingerprint: slot.fingerprint,
          related: v.related,
          relation: Value<String?>(v.related ? v.relation.dbValue : null),
          aIsOriginal: Value<bool?>(
            !v.related || fromIsOriginal == null
                ? null
                : fromIsOriginal == slot.aFirst,
          ),
          confidence: v.confidence,
          reason: Value<String>(v.related ? v.reason : ''),
          judgedAt: at,
        ),
      );
    }
    if (rows.isEmpty) return;
    await db.upsertMediaLinkAiVerdicts(rows);
    await db.pruneMediaLinkAiVerdicts(_notBefore);
  }
}

/// [MediaLinkJudge] 的 AI 实现：按 [kAiMediaLinkMaxCandidatesPerRequest] 分批请求。
/// 给了 [cache] 时先查缓存，只把没问过（或 AI 输入变了）的候选发出去，拿到结论即记。
///
/// 第一批就失败 = 提供商不可用，照常抛 [AiChatFailure]（调用方退回只跑确定性规则）；
/// 后面的批次失败时不再继续请求，已拿到的结论照常返回、没问到的为 null（等同
/// 「没经 AI」），失败记在 [partialFailure]——已付费的结论不作废。
class AiMediaLinkJudge implements MediaLinkJudge {
  AiMediaLinkJudge({required this.client, required this.provider, this.cache});

  final AiChatClient client;
  final AiProviderConfig provider;

  /// null = 不用缓存（每条候选都问）。
  final MediaLinkVerdictCache? cache;

  /// 累计从缓存直接取到结论的候选数。
  int cacheHits = 0;

  /// 累计发出的请求数（含失败的那次）。
  int requestCount = 0;

  /// 最近一次 [judge] 里中途失败的那次请求；null = 全部成功。
  AiChatFailure? partialFailure;

  @override
  Future<List<MediaLinkVerdict?>> judge(
    List<MediaLinkCandidate> candidates,
  ) async {
    partialFailure = null;
    final List<MediaLinkVerdict?> out =
        await cache?.lookup(candidates, provider.model) ??
        List<MediaLinkVerdict?>.filled(candidates.length, null);
    final List<int> ask = <int>[
      for (int i = 0; i < out.length; i++)
        if (out[i] == null) i,
    ];
    cacheHits += out.length - ask.length;
    for (
      int start = 0;
      start < ask.length;
      start += kAiMediaLinkMaxCandidatesPerRequest
    ) {
      final List<int> indexes = ask.sublist(
        start,
        (start + kAiMediaLinkMaxCandidatesPerRequest).clamp(0, ask.length),
      );
      final List<MediaLinkCandidate> batch = <MediaLinkCandidate>[
        for (final int i in indexes) candidates[i],
      ];
      final String reply;
      requestCount++;
      try {
        reply = await client.complete(
          provider: provider,
          messages: <AiChatMessage>[
            AiChatMessage.system(kAiMediaLinkSystemPrompt),
            AiChatMessage.user(buildAiMediaLinkUserPrompt(batch)),
          ],
          maxTokens: aiMediaLinkMaxTokens(batch.length),
        );
      } on AiChatFailure catch (e) {
        if (start == 0) rethrow;
        partialFailure = e;
        break;
      }
      final List<MediaLinkVerdict?> got = parseAiMediaLinkVerdicts(
        reply,
        batch.length,
      );
      for (int k = 0; k < indexes.length; k++) {
        out[indexes[k]] = got[k];
      }
      // 每批拿到就记：后面的批次失败也不丢。
      await cache?.store(batch, got, provider.model);
    }
    return out;
  }
}
