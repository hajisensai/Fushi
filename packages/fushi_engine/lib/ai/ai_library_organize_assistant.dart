/// AI 整理库的提示词与回复解析（spec `docs/specs/2026-10-20-ai-library-organize-design.md` §7）。
///
/// 模型只看到**局部下标**（条目 `#i`、合集 `C<n>`），不接触任何 uid / bookKey；回复也只认
/// 这些下标。本文件只做两件纯事：把一批事实写成提示词、把回复解析成**形状合法**的
/// 建议（越界 / 重复 / 不认识的字段一律剔除，坏回复返回 null）。语义层的裁决（墓碑、
/// 拒绝、所有权、跨域、刮削 id 冲突、置信度门槛）在 `library_organize_plan.dart`。
library;

import 'dart:convert';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_reply_json.dart';
import 'package:fushi_engine/ai/ai_settings.dart';

/// 一次请求最多带多少条目 / 多少已有合集（超过由调用方分块）。
const int kAiOrganizeMaxItemsPerRequest = 200;
const int kAiOrganizeMaxCollectionsPerRequest = 150;

/// 回复的输出上限：200 条目分成几十组，每组几十 token。
const int kAiOrganizeMaxReplyTokens = 6000;

/// 发给模型的一个条目（散条目，或某个整理器合集里的成员——[inCollection] 非空）。
class AiOrganizeItem {
  const AiOrganizeItem({
    required this.title,
    this.creator,
    this.year,
    this.folder,
    this.inCollection,
    this.season,
    this.episode,
  });

  final String title;

  /// 作者 / 出版社 / 品牌。
  final String? creator;
  final int? year;

  /// 视频所在文件夹的末级名（所有者 2026-10-20 同意发送）。
  final String? folder;

  /// 已在哪个整理器合集里（`C<n>`）；null = 散条目。
  final String? inCollection;
  final int? season;
  final int? episode;

  Map<String, Object?> toPromptJson(int index) => <String, Object?>{
        'i': index,
        'title': title,
        if (creator != null && creator!.isNotEmpty) 'by': creator,
        if (year != null) 'year': year,
        if (folder != null && folder!.isNotEmpty) 'folder': folder,
        if (season != null) 'season': season,
        if (episode != null) 'episode': episode,
        if (inCollection != null) 'in': inCollection,
      };
}

/// 发给模型的一个已有合集。
class AiOrganizeCollection {
  const AiOrganizeCollection({
    required this.id,
    required this.name,
    required this.memberCount,
    required this.sampleTitles,
    required this.userOwned,
    this.organizeKey,
  });

  /// `C<n>`。
  final String id;
  final String name;
  final int memberCount;
  final List<String> sampleTitles;

  /// 用户的合集：只能当 `into` 目标，不能被合并掉、不能被移出成员。
  final bool userOwned;
  final String? organizeKey;

  Map<String, Object?> toPromptJson() => <String, Object?>{
        'id': id,
        'name': name,
        'members': memberCount,
        if (sampleTitles.isNotEmpty) 'sample': sampleTitles,
        if (organizeKey != null) 'key': organizeKey,
        if (userOwned) 'user_owned': true,
      };
}

/// 一次请求的全部输入。
class AiLibraryOrganizeRequest {
  const AiLibraryOrganizeRequest({
    required this.domain,
    required this.items,
    required this.collections,
    required this.nameLanguage,
    this.knownKeys = const <String>[],
    this.rejected = const <({String key, String name})>[],
  });

  /// `books` / `manga` / `video` / `games`。
  final String domain;
  final List<AiOrganizeItem> items;
  final List<AiOrganizeCollection> collections;

  /// 新合集展示名用的语言（BCP-47，如 `zh-Hans`）。
  final String nameLanguage;

  /// 已知的分组键（必须原样复用）。
  final List<String> knownKeys;

  /// 用户拒绝过的分组（绝不再提）。
  final List<({String key, String name})> rejected;
}

enum AiOrganizeLevel { work, franchise }

enum AiOrganizeConfidence {
  high,
  medium,
  low;

  static AiOrganizeConfidence? parse(Object? raw) {
    for (final AiOrganizeConfidence c in AiOrganizeConfidence.values) {
      if (c.name == raw) return c;
    }
    return null;
  }
}

/// 「这些条目是一组」。
class AiOrganizeGroupProposal {
  const AiOrganizeGroupProposal({
    required this.members,
    required this.name,
    required this.level,
    required this.confidence,
    this.into,
    this.originalTitle,
    this.key,
  });

  /// 条目下标（去重、在范围内）。
  final List<int> members;

  /// 并进哪个已有合集（`C<n>`）；null = 新建。
  final String? into;
  final String name;
  final String? originalTitle;

  /// AI 声称复用的已知键（本地会核对它确实已知）。
  final String? key;
  final AiOrganizeLevel level;
  final AiOrganizeConfidence confidence;
}

/// 「这几个已有合集是同一个系列」。
class AiOrganizeMergeProposal {
  const AiOrganizeMergeProposal({
    required this.collections,
    required this.confidence,
  });

  final List<String> collections;
  final AiOrganizeConfidence confidence;
}

/// 「这些条目不属于它现在所在的整理器合集」。
class AiOrganizeEvictionProposal {
  const AiOrganizeEvictionProposal({
    required this.collection,
    required this.members,
    required this.confidence,
  });

  final String collection;
  final List<int> members;
  final AiOrganizeConfidence confidence;
}

class AiOrganizeReply {
  const AiOrganizeReply({
    this.groups = const <AiOrganizeGroupProposal>[],
    this.merges = const <AiOrganizeMergeProposal>[],
    this.evictions = const <AiOrganizeEvictionProposal>[],
  });

  final List<AiOrganizeGroupProposal> groups;
  final List<AiOrganizeMergeProposal> merges;
  final List<AiOrganizeEvictionProposal> evictions;

  bool get isEmpty => groups.isEmpty && merges.isEmpty && evictions.isEmpty;
}

AiProviderConfig? resolveLibraryOrganizeAiProvider(AiSettingsSource settings) =>
    settings.aiFeatureAssignments.resolve(
      AiFeature.libraryOrganize,
      settings.aiProviders,
    );

String buildAiLibraryOrganizeSystemPrompt(String domain) {
  final String what = switch (domain) {
    'video' => 'a video library (anime, drama, movies)',
    'games' => 'a visual novel / game library',
    'manga' => 'a manga library',
    _ => 'a book library (light novels, novels, audiobooks)',
  };
  return '''
You organize $what into collections: groups of items that belong together.

You get loose items ("i" indexes) and the existing collections ("C" ids). Some
items are already members of a machine-made collection ("in"). Propose only
groupings you actually know to be right from your knowledge of these works:
- the same work written differently (original title, romanization,
  translation), volumes without volume numbers, side stories and sequels of the
  same series, scattered episodes, OVAs and specials of one show;
- an item that belongs to an existing collection goes "into" that collection;
- two existing collections that are the same series can be merged;
- an item wrongly placed in a machine-made collection can be evicted.

Answer with a single JSON object and nothing else:
{"groups": [{"members": [i, ...], "into": "C3" or null, "name": "...",
             "originalTitle": "...", "key": "<known key>" or null,
             "level": "work" or "franchise", "confidence": "high"|"medium"|"low"}],
 "merges": [{"collections": ["C1", "C4"], "confidence": "..."}],
 "evictions": [{"collection": "C2", "members": [i, ...], "confidence": "..."}]}

Rules:
- "level": "work" = the volumes / episodes of one single work (one season of a
  show, one novel series). "franchise" = different works of one franchise
  (several seasons, movies, spin-offs). Use "work" whenever it is one work.
- "originalTitle" is the series' official title in its original language
  (Japanese works: the Japanese title), not a translation. Required for new groups.
- "name" is the display name for a new collection, written in the
  "name_language" given below. Keep it short: the series name, no volume range.
- When the group is a series listed in "known_keys", put that key in "key"
  exactly as given. Never invent keys.
- Never propose a group listed in "rejected".
- A collection with "user_owned": true can only receive items ("into"); never
  list it in "merges" or "evictions".
- New groups need at least two items. "into" groups need at least one item.
- Each item index at most once in the whole answer. Use only the indexes and
  ids you were given.
- If you are not sure, leave it out. An empty answer is fine:
  {"groups": [], "merges": [], "evictions": []}
''';
}

String buildAiLibraryOrganizeUserPrompt(AiLibraryOrganizeRequest request) {
  final StringBuffer buffer = StringBuffer()
    ..writeln('library: ${request.domain}')
    ..writeln('name_language: ${request.nameLanguage}')
    ..writeln('known_keys: ${jsonEncode(request.knownKeys)}')
    ..writeln(
      'rejected: ${jsonEncode(<Map<String, String>>[
            for (final ({String key, String name}) r in request.rejected)
              <String, String>{'key': r.key, 'name': r.name},
          ])}',
    )
    ..writeln('collections:');
  for (final AiOrganizeCollection c in request.collections) {
    buffer.writeln(jsonEncode(c.toPromptJson()));
  }
  buffer.writeln('items:');
  for (int i = 0; i < request.items.length; i++) {
    buffer.writeln(jsonEncode(request.items[i].toPromptJson(i)));
  }
  return buffer.toString();
}

/// 解析回复。形状不对（不是 JSON 对象、三个列表都不是列表）返回 null；单条坏的
/// 只丢那一条。下标越界 / 重复、合集 id 不认识的一律剔除。
AiOrganizeReply? parseAiLibraryOrganizeReply(
  String reply, {
  required int itemCount,
  required Set<String> collectionIds,
}) {
  final Map<String, Object?>? decoded = decodeAiJsonObject(reply);
  if (decoded == null) return null;
  final Object? rawGroups = decoded['groups'];
  final Object? rawMerges = decoded['merges'];
  final Object? rawEvictions = decoded['evictions'];
  if (rawGroups is! List && rawMerges is! List && rawEvictions is! List) {
    return null;
  }
  List<int> indexes(Object? raw) {
    if (raw is! List) return const <int>[];
    final List<int> out = <int>[];
    for (final Object? e in raw) {
      final int? i = _readIndex(e);
      if (i == null || i < 0 || i >= itemCount || out.contains(i)) continue;
      out.add(i);
    }
    return out;
  }

  String? collectionId(Object? raw) =>
      raw is String && collectionIds.contains(raw) ? raw : null;
  String? text(Object? raw) {
    if (raw is! String) return null;
    final String t = raw.trim();
    return t.isEmpty ? null : t;
  }

  final List<AiOrganizeGroupProposal> groups = <AiOrganizeGroupProposal>[
    if (rawGroups is List)
      for (final Object? g in rawGroups)
        if (g is Map)
          if (_group(g, indexes, collectionId, text)
              case final AiOrganizeGroupProposal p)
            p,
  ];
  final List<AiOrganizeMergeProposal> merges = <AiOrganizeMergeProposal>[
    if (rawMerges is List)
      for (final Object? m in rawMerges)
        if (m is Map)
          if (_merge(m, collectionId) case final AiOrganizeMergeProposal p) p,
  ];
  final List<AiOrganizeEvictionProposal> evictions =
      <AiOrganizeEvictionProposal>[
    if (rawEvictions is List)
      for (final Object? e in rawEvictions)
        if (e is Map)
          if (_eviction(e, indexes, collectionId)
              case final AiOrganizeEvictionProposal p)
            p,
  ];
  return AiOrganizeReply(groups: groups, merges: merges, evictions: evictions);
}

AiOrganizeGroupProposal? _group(
  Map<Object?, Object?> g,
  List<int> Function(Object?) indexes,
  String? Function(Object?) collectionId,
  String? Function(Object?) text,
) {
  final AiOrganizeConfidence? confidence =
      AiOrganizeConfidence.parse(g['confidence']);
  final List<int> members = indexes(g['members']);
  final String? into = collectionId(g['into']);
  final String? name = text(g['name']);
  if (confidence == null || members.isEmpty) return null;
  if (g['into'] != null && into == null) return null; // 引用了不存在的合集。
  if (into == null && (members.length < 2 || name == null)) return null;
  return AiOrganizeGroupProposal(
    members: members,
    into: into,
    name: name ?? '',
    originalTitle: text(g['originalTitle']),
    key: text(g['key']),
    level: g['level'] == 'franchise'
        ? AiOrganizeLevel.franchise
        : AiOrganizeLevel.work,
    confidence: confidence,
  );
}

AiOrganizeMergeProposal? _merge(
  Map<Object?, Object?> m,
  String? Function(Object?) collectionId,
) {
  final AiOrganizeConfidence? confidence =
      AiOrganizeConfidence.parse(m['confidence']);
  final Object? raw = m['collections'];
  if (confidence == null || raw is! List) return null;
  final List<String> ids = <String>[];
  for (final Object? c in raw) {
    final String? id = collectionId(c);
    if (id != null && !ids.contains(id)) ids.add(id);
  }
  if (ids.length < 2) return null;
  return AiOrganizeMergeProposal(collections: ids, confidence: confidence);
}

AiOrganizeEvictionProposal? _eviction(
  Map<Object?, Object?> e,
  List<int> Function(Object?) indexes,
  String? Function(Object?) collectionId,
) {
  final AiOrganizeConfidence? confidence =
      AiOrganizeConfidence.parse(e['confidence']);
  final String? collection = collectionId(e['collection']);
  final List<int> members = indexes(e['members']);
  if (confidence == null || collection == null || members.isEmpty) return null;
  return AiOrganizeEvictionProposal(
    collection: collection,
    members: members,
    confidence: confidence,
  );
}

int? _readIndex(Object? raw) {
  if (raw is int) return raw;
  if (raw is double && raw == raw.roundToDouble()) return raw.round();
  if (raw is String) return int.tryParse(raw.trim().replaceFirst('#', ''));
  return null;
}

/// 一次请求的结果：解析后的回复（null = 坏回复）+ 用量。
class AiLibraryOrganizeResponse {
  const AiLibraryOrganizeResponse({required this.reply, this.usage});

  final AiOrganizeReply? reply;
  final AiChatUsage? usage;
}

/// 发一次请求。失败照常抛 [AiChatFailure]（脱敏短码），由调用方记进整理记录。
Future<AiLibraryOrganizeResponse> requestAiLibraryOrganize({
  required AiChatClient client,
  required AiProviderConfig provider,
  required AiLibraryOrganizeRequest request,
}) async {
  final AiChatCompletion completion = await client.completeWithUsage(
    provider: provider,
    messages: <AiChatMessage>[
      AiChatMessage.system(
        buildAiLibraryOrganizeSystemPrompt(request.domain),
        cacheable: true,
      ),
      AiChatMessage.user(buildAiLibraryOrganizeUserPrompt(request)),
    ],
    maxTokens: kAiOrganizeMaxReplyTokens,
  );
  return AiLibraryOrganizeResponse(
    reply: parseAiLibraryOrganizeReply(
      completion.text,
      itemCount: request.items.length,
      collectionIds: <String>{
        for (final AiOrganizeCollection c in request.collections) c.id,
      },
    ),
    usage: completion.usage,
  );
}
