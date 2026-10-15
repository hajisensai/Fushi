/// 合集成员顺序：规则（集号 / 卷号）判不出的成员交 AI 定位。
///
/// 规则序（`VideoFolderGroupCoordinator` 的季 → 集 → 名称、`BookSeriesGrouper` 的
/// 卷号 → 名称）对绝大多数合集已经正确；它判不出的是**没有可用编号**的成员——
/// SP / OVA / 特别篇 / 总集篇 / 剧场版（解析器给 episode == null，一律殿后），以及
/// 汉字卷号、上 / 下卷、外传这类 `parseBookSeriesKey` 认不出的卷。本模块只处理这一类：
///
/// 1. [collectionOrderAmbiguousIndices] 判「有没有规则判不出的成员」（纯函数）——
///    没有就**不发请求**；
/// 2. 把整张合集（规则序 + 每个成员的编号与刮削事实）交给模型，要求它只给一个
///    下标排列；模型**不认识这部作品**时回 `{"known": false}`、对拿不准的成员可以
///    不排（留在规则位置）——不许按标题模式硬猜。回了不认识且用户启用了联网资料
///    站（[WebKnowledgeClient]，与「AI 下视频」同一套站点）时，用合集名抓条目正文，
///    带着资料再问一轮；仍不认识 → [AiCollectionOrderStatus.unknown]，顺序不改；
/// 3. [parseAiCollectionOrder] 本地校验：越界 / 重复剔除；规则排得出的成员
///    （锚点）**一律保持规则相对序**，模型只能决定判不出的成员插在哪两个锚点之间；
///    模型漏掉的判不出成员留在规则位置。返回值恒是完整排列，坏回复返回 null
///    （调用方据此「不改」）。
///
/// 边界同其它 AI 功能（`ai_feature.dart`）：未指派提供商不发请求；AI 只在已有
/// 成员里排序，不增删成员；失败不影响规则序。
library;

import 'dart:convert';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_reply_json.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';
import 'package:fushi_engine/media/collections/book_series_key.dart';
import 'package:fushi_engine/media/collections/shelf_sort.dart'
    show naturalCompare;
import 'package:fushi_engine/media/video/video_filename_parser.dart';

/// 喂给模型的成员上限。再大的合集（长篇连载几百集）提示词又贵又容易被截断，
/// 而且这种合集的 SP 通常也已有刮削编号——超过上限直接不问。
const int kAiCollectionOrderMaxMembers = 200;

/// 联网资料：最多喂几页、每页截多长（合集排序只需要剧集 / 卷目清单那一段）。
const int kAiCollectionOrderMaxReferencePages = 3;
const int kAiCollectionOrderMaxCharsPerPage = 6000;

/// 合集按哪套规则看：视频按季 / 集，书按卷。
enum AiCollectionOrderKind { video, book }

/// 合集里的一个排序单元（视频一个文件；书一卷——EPUB 与它配对的 SRT 合成一个
/// 单元，由调用方合并）。
class AiCollectionOrderMember {
  const AiCollectionOrderMember({
    required this.title,
    this.fileName,
    this.season,
    this.episode,
    this.volume,
    this.metadata = const <String, Object?>{},
  });

  /// 视频成员：季 / 集从文件名解析（与 `VideoFolderGroupCoordinator` 同一个
  /// [parseVideoFilename]），[metadata] 是可选的刮削事实（分集标题、播出日期、
  /// AniDB 集号等）。
  factory AiCollectionOrderMember.video({
    required String title,
    required String fileName,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    final VideoNameInfo info = parseVideoFilename(fileName);
    return AiCollectionOrderMember(
      title: title,
      fileName: fileName,
      season: info.season,
      episode: info.episode,
      metadata: metadata,
    );
  }

  /// 书成员：卷号从书名解析（与 `BookSeriesGrouper` 同一个 [parseBookSeriesKey]）。
  factory AiCollectionOrderMember.book({required String title}) =>
      AiCollectionOrderMember(
        title: title,
        volume: parseBookSeriesKey(title)?.volume,
      );

  final String title;
  final String? fileName;
  final int? season;
  final int? episode;
  final num? volume;
  final Map<String, Object?> metadata;
}

/// 书名里规则认不出、但明显带「卷位」语义的标记：上 / 中 / 下卷、前后编、外传、
/// 番外、特别篇、短篇集、汉字卷号（第三巻）。命中即视为规则判不出。
final RegExp _bookUnparsedVolumeMarker = RegExp(
  r'([上中下]巻|[上中下]卷|[上中下]冊|[上中下]册'
  r'|[(（\[［【<〈《]\s*[上中下]\s*[)）\]］】>〉》]'
  r'|(?:^|\s)[上中下]\s*$'
  r'|前編|後編|前篇|后篇|後篇|中編|中篇|完結編|完结篇'
  r'|外伝|外传|番外|特別編|特别篇|特別篇|短編集|短篇集|短編|短篇'
  r'|第[一二三四五六七八九十百千〇零壱弐参]+[巻卷冊册部集話话])',
);

/// 规则判不出位置的成员下标（相对 [members]）；空集 = 规则已能完整定序，不必问 AI。
///
/// - 视频：合集里**同时**有带集号与不带集号的成员时，不带集号的那些（SP / OVA /
///   特别篇 / 总集篇 / 剧场版……规则只会把它们堆到末尾）。全都没集号的合集
///   （手攒播放列表、电影系列）不算——那里没有「正片」可以当锚点。
/// - 书：卷号冲突的卷（两本不同书解析出同一卷号）、书名带规则认不出的卷位标记
///   （上 / 下卷、外传、汉字卷号）的卷，以及两本及以上都没有卷号的卷（规则只能
///   按书名硬排）。仅一本没卷号且无标记的视为第 1 卷，规则排得出。
Set<int> collectionOrderAmbiguousIndices(
  List<AiCollectionOrderMember> members,
  AiCollectionOrderKind kind,
) {
  if (members.length < 2) return const <int>{};
  switch (kind) {
    case AiCollectionOrderKind.video:
      final bool anyNumbered = members.any(
        (AiCollectionOrderMember m) => m.episode != null,
      );
      if (!anyNumbered) return const <int>{};
      return <int>{
        for (int i = 0; i < members.length; i++)
          if (members[i].episode == null) i,
      };
    case AiCollectionOrderKind.book:
      final Set<int> out = <int>{};
      final Map<num, List<int>> byVolume = <num, List<int>>{};
      final List<int> unnumbered = <int>[];
      for (int i = 0; i < members.length; i++) {
        final AiCollectionOrderMember m = members[i];
        if (_bookUnparsedVolumeMarker.hasMatch(m.title)) out.add(i);
        final num? volume = m.volume;
        if (volume == null) {
          unnumbered.add(i);
        } else {
          byVolume.putIfAbsent(volume, () => <int>[]).add(i);
        }
      }
      for (final List<int> same in byVolume.values) {
        if (same.length > 1) out.addAll(same);
      }
      if (unnumbered.length > 1) out.addAll(unnumbered);
      return out;
  }
}

/// 规则序（下标排列）：视频 季（缺省 1）→ 集（缺省殿后）→ 文件名 natural；书
/// 卷号（缺省第 0 卷）→ 书名 natural。平局按输入下标，结果确定。
List<int> ruleOrderCollectionMembers(
  List<AiCollectionOrderMember> members,
  AiCollectionOrderKind kind,
) {
  final List<int> order = List<int>.generate(members.length, (int i) => i);
  int compare(int a, int b) {
    final AiCollectionOrderMember ma = members[a];
    final AiCollectionOrderMember mb = members[b];
    int c;
    switch (kind) {
      case AiCollectionOrderKind.video:
        c = (ma.season ?? 1).compareTo(mb.season ?? 1);
        if (c != 0) return c;
        c = (ma.episode ?? (1 << 30)).compareTo(mb.episode ?? (1 << 30));
        if (c != 0) return c;
        c = naturalCompare(ma.fileName ?? ma.title, mb.fileName ?? mb.title);
      case AiCollectionOrderKind.book:
        c = (ma.volume ?? 0).compareTo(mb.volume ?? 0);
        if (c != 0) return c;
        c = naturalCompare(ma.title, mb.title);
    }
    return c != 0 ? c : a.compareTo(b);
  }

  order.sort(compare);
  return order;
}

/// 解析「合集排序」当前可用的提供商；null = 未指派 / 已删 / 没配全（不发请求）。
AiProviderConfig? resolveCollectionOrderAiProvider(AiSettingsSource settings) =>
    settings.aiFeatureAssignments.resolve(
      AiFeature.collectionOrder,
      settings.aiProviders,
    );

String buildAiCollectionOrderSystemPrompt(AiCollectionOrderKind kind) {
  final String task = switch (kind) {
    AiCollectionOrderKind.video =>
      '''
You order the members of one video collection (the episodes of a series, or a
franchise playlist) into the order a viewer should watch them.

Members with "needs_placement": false were already placed by their season and
episode numbers; keep their relative order. Members with "needs_placement": true
have no usable episode number: specials (SP), OVAs / OADs, recap or compilation
episodes, movies, extra episodes such as "13.5", PVs, creditless OP/ED and
trailers. Place each of them where it belongs in broadcast or story order:
- a special or OVA goes right after the episode it follows in the story or by
  air date (use "air_date" and "anidb_episode" from the metadata when present;
  AniDB numbers like "S1" are specials);
- a recap / compilation goes after the episodes it summarizes;
- a movie goes where it fits the story (after the season it continues, or
  between seasons);
- PVs, trailers, creditless OP/ED and other bonus clips go at the end unless
  the metadata clearly says otherwise.''',
    AiCollectionOrderKind.book =>
      '''
You order the volumes of one book or manga series into reading order.

Members with "needs_placement": false were already placed by their volume
numbers; keep their relative order. Members with "needs_placement": true could
not be placed by the parser: volume numbers written in kanji (第三巻), 上 / 中 / 下
(first / middle / last part) volumes, 前編 / 後編, side stories (外伝 / 番外 /
短編集), special editions, or two different books that parsed to the same
volume number. Place each of them in publication / reading order:
- 上 before 中 before 下, 前編 before 後編, and a split volume sits where its
  number puts it (e.g. "3 上" and "3 下" between volume 2 and volume 4);
- kanji numerals are ordinary volume numbers (一 = 1, 十二 = 12);
- side stories and short story collections go after the main volume they
  follow, or at the end when nothing says where they belong.''',
  };
  return '''
$task

Rules:
- Answer with a single JSON object and nothing else: {"order": [index, ...]}.
- "order" lists member indexes from first to last, each at most once. Keep
  every member with "needs_placement": false.
- Only place a "needs_placement" member when you actually know where it belongs
  in this specific work: from your own knowledge of it, or from the reference
  excerpts when given. Never guess from title patterns alone. Leave out of
  "order" any member you are not sure about; it keeps its current position.
- If you do not recognise this work and the excerpts (if any) do not tell you
  either, answer exactly {"known": false}.
- Use only the indexes you were given. Never invent members.
''';
}

String buildAiCollectionOrderUserPrompt({
  required String collectionName,
  required List<AiCollectionOrderMember> members,
  required Set<int> ambiguous,
  List<WebKnowledgePage> references = const <WebKnowledgePage>[],
}) {
  final StringBuffer buffer = StringBuffer()
    ..writeln('Collection: ${jsonEncode(collectionName)}')
    ..writeln('Members in the current order:');
  for (int i = 0; i < members.length; i++) {
    final AiCollectionOrderMember m = members[i];
    buffer.writeln(
      jsonEncode(<String, Object?>{
        'index': i,
        'title': m.title,
        if (m.fileName != null && m.fileName != m.title) 'file': m.fileName,
        if (m.season != null) 'season': m.season,
        if (m.episode != null) 'episode': m.episode,
        if (m.volume != null) 'volume': m.volume,
        if (m.metadata.isNotEmpty) 'metadata': m.metadata,
        'needs_placement': ambiguous.contains(i),
      }),
    );
  }
  if (references.isNotEmpty) {
    buffer.writeln('Reference excerpts (fetched for this collection):');
    for (final WebKnowledgePage page in references) {
      buffer.writeln(
        jsonEncode(<String, Object?>{
          'source': page.url.toString(),
          'title': page.title,
          'text': page.text,
        }),
      );
    }
  }
  return buffer.toString();
}

/// 模型明说「不认识这部作品」（`{"known": false}`）。
bool aiCollectionOrderReplyIsUnknown(String reply) =>
    decodeAiJsonObject(reply)?['known'] == false;

/// 解析并校验模型回复，返回 0..count-1 的完整排列；回复解析不出、或模型对
/// [floating]（规则判不出的成员）一个都没给位置时返回 null（调用方不改顺序）。
///
/// 锚点（不在 [floating] 里的下标）恒按输入序（= 规则序）排列，模型改不动；
/// 每个判不出的成员插在「模型排在它前面的锚点里规则序最靠后那个」之后，同一空隙
/// 里的多个按模型给的先后。模型漏掉的判不出成员当锚点留在原位。
List<int>? parseAiCollectionOrder(
  String reply, {
  required int count,
  required Set<int> floating,
}) {
  final Map<String, Object?>? decoded = decodeAiJsonObject(reply);
  final Object? rawOrder = decoded?['order'];
  if (rawOrder is! List) return null;
  final List<int> given = <int>[];
  final Set<int> seen = <int>{};
  for (final Object? entry in rawOrder) {
    final int? index = _readIndex(entry);
    if (index == null || index < 0 || index >= count) continue;
    if (seen.add(index)) given.add(index);
  }
  final Set<int> placed = <int>{
    for (final int i in given)
      if (floating.contains(i)) i,
  };
  if (placed.isEmpty) return null;
  final List<int> anchors = <int>[
    for (int i = 0; i < count; i++)
      if (!placed.contains(i)) i,
  ];
  final Map<int, int> rankOf = <int, int>{
    for (int r = 0; r < anchors.length; r++) anchors[r]: r,
  };
  final Map<int, List<int>> floatsBySlot = <int, List<int>>{};
  int maxRank = -1;
  for (final int index in given) {
    final int? rank = rankOf[index];
    if (rank != null) {
      if (rank > maxRank) maxRank = rank;
      continue;
    }
    floatsBySlot.putIfAbsent(maxRank + 1, () => <int>[]).add(index);
  }
  final List<int> out = <int>[];
  for (int slot = 0; slot <= anchors.length; slot++) {
    out.addAll(floatsBySlot[slot] ?? const <int>[]);
    if (slot < anchors.length) out.add(anchors[slot]);
  }
  return List<int>.unmodifiable(out);
}

/// 模型给下标时 int / "3" / 3.0 都见过，统一收成 int；认不出为 null。
int? _readIndex(Object? raw) {
  if (raw is int) return raw;
  if (raw is double && raw == raw.roundToDouble()) return raw.round();
  if (raw is String) return int.tryParse(raw.trim());
  return null;
}

/// 一次 AI 定序的结论。
enum AiCollectionOrderStatus {
  /// 规则已能完整定序（或成员不足两个），没有发请求。
  noAmbiguity,

  /// 合集太大（超过 [kAiCollectionOrderMaxMembers]），没有发请求。
  tooLarge,

  /// 模型回复没通过本地校验，顺序不改。
  invalidReply,

  /// 模型不认识这部作品（联网资料也没帮上），顺序不改。
  unknown,

  /// 拿到了通过校验的完整排列（可能与输入序相同）。
  proposed,
}

class AiCollectionOrderProposal {
  const AiCollectionOrderProposal({
    required this.status,
    required this.order,
    this.ambiguous = const <int>{},
  });

  final AiCollectionOrderStatus status;

  /// 下标排列（相对调用方传入的成员列表）；非 [AiCollectionOrderStatus.proposed]
  /// 时为恒等排列。
  final List<int> order;

  /// 规则判不出的成员下标。
  final Set<int> ambiguous;

  /// 排列与输入序不同。
  bool get changed {
    for (int i = 0; i < order.length; i++) {
      if (order[i] != i) return true;
    }
    return false;
  }
}

/// 对**已按规则排好**的 [members] 问 AI。没有判不出的成员 / 合集过大时不发
/// 请求；模型回「不认识」且 [web] 启用了资料站时，用合集名抓资料再问一轮。
/// 网络 / 提供商失败原样抛 [AiChatFailure]（文案已脱敏）；抓资料失败只记诊断
/// （[WebKnowledgeClient.search] 不抛），按没资料处理。
Future<AiCollectionOrderProposal> requestAiCollectionOrder({
  required AiChatClient client,
  required AiProviderConfig provider,
  required AiCollectionOrderKind kind,
  required String collectionName,
  required List<AiCollectionOrderMember> members,
  WebKnowledgeClient? web,
}) async {
  final List<int> identity = List<int>.unmodifiable(
    List<int>.generate(members.length, (int i) => i),
  );
  final Set<int> ambiguous = collectionOrderAmbiguousIndices(members, kind);
  if (ambiguous.isEmpty) {
    return AiCollectionOrderProposal(
      status: AiCollectionOrderStatus.noAmbiguity,
      order: identity,
    );
  }
  if (members.length > kAiCollectionOrderMaxMembers) {
    return AiCollectionOrderProposal(
      status: AiCollectionOrderStatus.tooLarge,
      order: identity,
      ambiguous: ambiguous,
    );
  }
  Future<String> ask(List<WebKnowledgePage> references) => client.complete(
    provider: provider,
    messages: <AiChatMessage>[
      AiChatMessage.system(buildAiCollectionOrderSystemPrompt(kind)),
      AiChatMessage.user(
        buildAiCollectionOrderUserPrompt(
          collectionName: collectionName,
          members: members,
          ambiguous: ambiguous,
          references: references,
        ),
      ),
    ],
    // 每个下标几个 token；200 成员的排列也远低于这个数，留给推理模型思考余量。
    maxTokens: 4096,
  );

  String reply = await ask(const <WebKnowledgePage>[]);
  if (aiCollectionOrderReplyIsUnknown(reply)) {
    // 模型不认识这部作品：先查资料再答，查不到就不动（不让它硬猜）。
    final List<WebKnowledgePage> references = web != null && web.isEnabled
        ? (await web.search(
            collectionName,
            maxCharsPerPage: kAiCollectionOrderMaxCharsPerPage,
          )).take(kAiCollectionOrderMaxReferencePages).toList()
        : const <WebKnowledgePage>[];
    if (references.isNotEmpty) reply = await ask(references);
    if (references.isEmpty || aiCollectionOrderReplyIsUnknown(reply)) {
      return AiCollectionOrderProposal(
        status: AiCollectionOrderStatus.unknown,
        order: identity,
        ambiguous: ambiguous,
      );
    }
  }
  final List<int>? order = parseAiCollectionOrder(
    reply,
    count: members.length,
    floating: ambiguous,
  );
  if (order == null) {
    // 合法的 order 但一个待定成员都没排 = 模型对它们都拿不准，按「不知道」不动，
    // 不算坏回复。
    final bool abstained = decodeAiJsonObject(reply)?['order'] is List;
    return AiCollectionOrderProposal(
      status: abstained
          ? AiCollectionOrderStatus.unknown
          : AiCollectionOrderStatus.invalidReply,
      order: identity,
      ambiguous: ambiguous,
    );
  }
  return AiCollectionOrderProposal(
    status: AiCollectionOrderStatus.proposed,
    order: order,
    ambiguous: ambiguous,
  );
}
