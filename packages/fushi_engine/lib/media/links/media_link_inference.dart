/// 作品图谱推断（L1，spec `docs/specs/2026-10-24-cross-media-links.md`「推断」与
/// 「AI 辅助判断」两节）。
///
/// 只用各模块已在用的身份，不为联动新增元数据主源；**一律不用 Bangumi**（所有者
/// 2026-10-24 拍板）。推断结果按 AI 库管家设计稿 §5.2 的门槛
/// （[mediaLinkDispositionOf]）落库：强证据 / AI 高置信的直接**生效**
/// （`confirmed_by = ai`，可撤销），其余写成建议或丢弃；用户确认 / 否决过的同一对
/// 条目不再碰（`FushiDatabase.applyAiMediaLink` / `proposeMediaLink` 的去重）。
///
/// 规则（纯函数，离线可测）：
/// - [matchMalSourceMaterial]：MAL（Jikan）给出动画的原作（Adaptation，manga 条目）→
///   按**标题**对本地书。Jikan 关联条目不带 ISBN；标题完全相同算强匹配（生效），
///   包含关系只作建议。
/// - [matchSubjectsByTitle]：两个条目没有共享 id 但规范化标题相同（游戏 ↔ 动画等）→
///   低置信候选，交 AI 裁决；没配 AI 时作为低置信建议。
/// - [matchSeriesByTitle]：同类条目（视频 ↔ 视频、游戏 ↔ 游戏）标题沾边、刮削源又
///   没给出系列关系 → 续作候选，只交 AI 裁决，没有 AI 结论就不写。
///
/// AI 裁决（[MediaLinkJudge]）只在已缩小的候选上给结构化结论（是否相关、关系、方向、
/// 置信度、理由），**不让 AI 编 id**：结论按候选下标回填，端点永远来自本地数据。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/links/work_graph.dart'
    show workSeriesRelations;

import 'package:fushi_engine/media/video/metadata/mal_video_metadata_provider.dart'
    show MalSourceMaterial;

/// 来源名「按规范化标题对上」（无共享外部 id）。
const String kMediaLinkTitleMatchSource = 'title';

/// 参与推断的一个本地条目：端点 + 全部可比标题 + 年份 + 已知外部 id。
class MediaLinkSubject {
  const MediaLinkSubject({
    required this.endpoint,
    required this.titles,
    this.year,
    this.externalIds = const <String, String>{},
    this.seriesSources = const <String>{},
  });

  final MediaLinkEndpoint endpoint;

  /// 显示名 / 原名 / 刮削别名…（任一命中即算）。
  final List<String> titles;
  final int? year;

  /// provider → id（`mal` / `anidb` / `vndb` …，Bangumi 不收）。
  final Map<String, String> externalIds;

  /// 已经把这个条目的系列关系（续作 / 前传 / 外传…）刮进 `collection_relations` 的
  /// 资料源（`anidb` / `mal` / 是合集成员的 TMDB 电影的 `tmdb`）。只有身份、源不提供
  /// 系列关系的不算：VNDB（游戏关系不落库）、TMDB 剧集与不在合集里的电影。
  final Set<String> seriesSources;

  String get displayTitle => titles.isEmpty ? endpoint.key : titles.first;
}

/// 一条推断候选（尚未写库）。[from] → [to] 是连接方向（无方向关系无所谓顺序）。
class MediaLinkCandidate {
  const MediaLinkCandidate({
    required this.from,
    required this.to,
    required this.relation,
    required this.source,
    required this.confidence,
    required this.reason,
    this.idEvidence = false,
    this.aiOnly = false,
  });

  final MediaLinkSubject from;
  final MediaLinkSubject to;
  final MediaLinkRelation relation;
  final String source;
  final double confidence;
  final String reason;

  /// 是否有共享外部 id 佐证（而不只是标题像）。为 true 时两条路径都直接生效
  /// （除非 AI 判不相关），见 [mediaLinkDispositionOf]。
  final bool idEvidence;

  /// 只有 AI 给了结论才落库的候选（[matchSeriesByTitle]：同类条目标题沾边，规则
  /// 自己分不出是续作、外传、重复入库还是碰巧同名）。没有 AI 结论（没配 AI / 请求
  /// 失败 / 这一条没判出来）时直接丢弃，不写成建议——否则每个「标题包含」都会变成
  /// 一条要用户手动否决的噪音。
  final bool aiOnly;

  MediaLinkCandidate copyWith({
    MediaLinkSubject? from,
    MediaLinkSubject? to,
    MediaLinkRelation? relation,
    String? source,
    double? confidence,
    String? reason,
  }) => MediaLinkCandidate(
    from: from ?? this.from,
    to: to ?? this.to,
    relation: relation ?? this.relation,
    source: source ?? this.source,
    confidence: confidence ?? this.confidence,
    reason: reason ?? this.reason,
    idEvidence: idEvidence,
    aiOnly: aiOnly,
  );
}

/// 一对端点的无序键（不分关系与方向）：候选去重、「已有系列关系」集合共用。
String mediaLinkPairKey(MediaLinkEndpoint a, MediaLinkEndpoint b) {
  final List<String> pair = <String>[
    '${a.kind.dbValue}\u0000${a.key}',
    '${b.kind.dbValue}\u0000${b.key}',
  ]..sort();
  return pair.join('\u0001');
}

/// 标题比较口径：与库页搜索同一归一化（[foldMediaTitle]），丢掉空串。
Set<String> _foldedTitles(Iterable<String> titles) => <String>{
  for (final String t in titles)
    if (foldMediaTitle(t) case final String f when f.isNotEmpty) f,
};

/// 两组规范化标题的匹配强度：1 = 有一条完全相同；0.75 = 一方包含另一方且短的
/// 那条至少 4 个字符（「作品名」⊂「作品名 第1巻」）；0 = 对不上。
double titleMatchStrength(Iterable<String> a, Iterable<String> b) {
  final Set<String> fa = _foldedTitles(a);
  final Set<String> fb = _foldedTitles(b);
  if (fa.intersection(fb).isNotEmpty) return 1;
  for (final String x in fa) {
    for (final String y in fb) {
      final String shorter = x.length <= y.length ? x : y;
      final String longer = x.length <= y.length ? y : x;
      if (shorter.length >= 4 && longer.contains(shorter)) return 0.75;
    }
  }
  return 0;
}

/// 规则 R1：动画 [video] 的 MAL 原作 [sources] → 按标题对本地 [books]。
/// 方向：书（原作）→ 视频（改编）。置信度：标题完全相同 0.6，包含关系 0.45。
List<MediaLinkCandidate> matchMalSourceMaterial({
  required MediaLinkSubject video,
  required List<MalSourceMaterial> sources,
  required List<MediaLinkSubject> books,
}) {
  final List<MediaLinkCandidate> out = <MediaLinkCandidate>[];
  for (final MediaLinkSubject book in books) {
    MalSourceMaterial? best;
    double bestStrength = 0;
    for (final MalSourceMaterial s in sources) {
      final double strength = titleMatchStrength(<String>[s.name], book.titles);
      if (strength > bestStrength) {
        bestStrength = strength;
        best = s;
      }
    }
    if (best == null) continue;
    out.add(
      MediaLinkCandidate(
        from: book,
        to: video,
        relation: MediaLinkRelation.adaptation,
        source: MediaLinkSource.mal,
        confidence: bestStrength >= 1 ? 0.6 : 0.45,
        reason:
            'MAL lists "${best.name}" (manga #${best.malId}) as the source '
            'of "${video.displayTitle}"; local book title '
            '"${book.displayTitle}" matches by title only.',
      ),
    );
  }
  return out;
}

/// 规则 R0（强判据）：游戏 [game] 的 VNDB id 经 Wikidata 桥出的改编动画 AniDB id
/// [anidbIds]，对上本地视频的 AniDB id。方向确定（VN 是原作）；`source = wikidata`、
/// 置信度 0.9、有共享 id 佐证（按 §5.2 直接生效）。
List<MediaLinkCandidate> matchWikidataAnime({
  required MediaLinkSubject game,
  required Set<String> anidbIds,
  required List<MediaLinkSubject> videos,
}) {
  if (anidbIds.isEmpty) return const <MediaLinkCandidate>[];
  return <MediaLinkCandidate>[
    for (final MediaLinkSubject v in videos)
      if (v.externalIds['anidb'] case final String aid
          when anidbIds.contains(aid.trim()))
        MediaLinkCandidate(
          from: game,
          to: v,
          relation: MediaLinkRelation.adaptation,
          source: MediaLinkSource.wikidata,
          confidence: 0.9,
          reason:
              'Wikidata: anime with AniDB #${aid.trim()} is based on '
              'VNDB ${game.externalIds['vndb']} ("${game.displayTitle}").',
          idEvidence: true,
        ),
  ];
}

/// 规则 R2：[subject] 与 [others] 之间没有共享 id、但规范化标题对得上的 →
/// 低置信「同一作品」候选（0.35 / 0.25），交 AI 裁决方向与真假。
List<MediaLinkCandidate> matchSubjectsByTitle({
  required MediaLinkSubject subject,
  required List<MediaLinkSubject> others,
}) {
  final List<MediaLinkCandidate> out = <MediaLinkCandidate>[];
  for (final MediaLinkSubject other in others) {
    if (other.endpoint.kind == subject.endpoint.kind) continue;
    final double strength = titleMatchStrength(subject.titles, other.titles);
    if (strength <= 0) continue;
    out.add(
      MediaLinkCandidate(
        from: subject,
        to: other,
        relation: MediaLinkRelation.sameWork,
        source: kMediaLinkTitleMatchSource,
        confidence: strength >= 1 ? 0.35 : 0.25,
        reason:
            'Titles match: "${subject.displayTitle}" / '
            '"${other.displayTitle}" (no shared external id).',
      ),
    );
  }
  return out;
}

/// 一个端点最多出几条同类系列候选（[matchSeriesByTitle]）。
const int kMediaLinkSeriesCandidateLimit = 6;

/// 同类系列候选只在这两族里出：视频（合集 / 散装电影）之间、游戏之间。书不出——
/// 同一系列的各卷标题互相包含，N 卷就是 N² 对，而「第 3 卷是第 2 卷的续作」对用户
/// 没有信息量（卷的归属由系列合集管）。
String? _seriesFamily(MediaLinkKind kind) => switch (kind) {
  MediaLinkKind.videoCollection || MediaLinkKind.videoEpisode => 'video',
  MediaLinkKind.game => 'game',
  _ => null,
};

/// 两个条目的系列关系是否都已由同一个资料源刮进 `collection_relations`
/// （[MediaLinkSubject.seriesSources]）。是 = 那个源对这一对是权威的：源里没写它们
/// 有关系，就不拿去问 AI。只是两端在同一个源都有 id 不够——VNDB 的游戏关系、TMDB
/// 剧集与剧场版之间的关系从不落库，按 id 跳过会让这两类最常见的系列一条候选都出不来。
bool _shareSeriesSource(MediaLinkSubject a, MediaLinkSubject b) =>
    a.seriesSources.any(b.seriesSources.contains);

int _shortestTitle(MediaLinkSubject s) {
  int best = 1 << 30;
  for (final String t in s.titles) {
    final int n = foldMediaTitle(t).length;
    if (n > 0 && n < best) best = n;
  }
  return best;
}

/// 规则 R3：[subject] 与**同类**的 [others]（视频 ↔ 视频、游戏 ↔ 游戏）标题沾边
/// （相同或一方包含另一方）→ 「续作」候选，**只交 AI 裁决**（[MediaLinkCandidate.aiOnly]）：
/// 第二季、剧场版、外传、Fan Disc 在刮削源拿不到关系时（没刮过的合集、两端不在同一个
/// 资料源）由 AI 判是续作 / 外传 / 同一作品 / 不相关。
///
/// - [alreadyLinked] 为 true 的对（刮削的系列关系已经把它们连上）不出；
/// - 两端的系列关系都已由同一个资料源刮过的不出（[_shareSeriesSource]）；
/// - 方向先按年份（早的是前作），没有年份按标题短的在前（本篇标题通常是续作标题的
///   前缀）——只是给 AI 的初始猜测，AI 说不清方向时落库前还会再判一次；
/// - 标题相同的排在包含关系前面，最多 [kMediaLinkSeriesCandidateLimit] 条。
List<MediaLinkCandidate> matchSeriesByTitle({
  required MediaLinkSubject subject,
  required List<MediaLinkSubject> others,
  bool Function(MediaLinkEndpoint a, MediaLinkEndpoint b)? alreadyLinked,
}) {
  final String? family = _seriesFamily(subject.endpoint.kind);
  if (family == null) return const <MediaLinkCandidate>[];
  final List<({MediaLinkSubject other, double strength})> hits =
      <({MediaLinkSubject other, double strength})>[];
  for (final MediaLinkSubject other in others) {
    if (_seriesFamily(other.endpoint.kind) != family) continue;
    if (other.endpoint == subject.endpoint) continue;
    if (_shareSeriesSource(subject, other)) continue;
    if (alreadyLinked?.call(subject.endpoint, other.endpoint) ?? false) {
      continue;
    }
    final double strength = titleMatchStrength(subject.titles, other.titles);
    if (strength <= 0) continue;
    hits.add((other: other, strength: strength));
  }
  // List.sort 不稳定：强度相同的按原顺序（下标）排，结果确定。
  final List<int> order = <int>[for (int i = 0; i < hits.length; i++) i]
    ..sort((int x, int y) {
      final int byStrength = hits[y].strength.compareTo(hits[x].strength);
      return byStrength != 0 ? byStrength : x.compareTo(y);
    });
  final List<MediaLinkCandidate> out = <MediaLinkCandidate>[];
  for (final int i in order.take(kMediaLinkSeriesCandidateLimit)) {
    final MediaLinkSubject other = hits[i].other;
    final int? sy = subject.year;
    final int? oy = other.year;
    final bool subjectFirst = sy != null && oy != null && sy != oy
        ? sy < oy
        : _shortestTitle(subject) <= _shortestTitle(other);
    final MediaLinkSubject from = subjectFirst ? subject : other;
    final MediaLinkSubject to = subjectFirst ? other : subject;
    out.add(
      MediaLinkCandidate(
        from: from,
        to: to,
        relation: MediaLinkRelation.sequel,
        source: kMediaLinkTitleMatchSource,
        confidence: hits[i].strength >= 1 ? 0.25 : 0.2,
        reason:
            'Titles overlap: "${from.displayTitle}" / "${to.displayTitle}" '
            '(same kind, no series relation from a metadata source).',
        aiOnly: true,
      ),
    );
  }
  return out;
}

/// AI 对一条候选的结构化结论。
class MediaLinkVerdict {
  const MediaLinkVerdict({
    required this.related,
    required this.relation,
    required this.fromIsOriginal,
    required this.confidence,
    required this.reason,
  });

  final bool related;
  final MediaLinkRelation relation;

  /// adaptation 时：true = 候选的 `from` 一端是原作；false = `to` 是原作；null =
  /// 判不出方向（退回无方向的「同一作品」）。
  final bool? fromIsOriginal;
  final double confidence;
  final String reason;
}

/// AI 裁决器：对 [candidates] 逐条给结论（与输入同序、同长；某条判不了给 null）。
abstract interface class MediaLinkJudge {
  Future<List<MediaLinkVerdict?>> judge(List<MediaLinkCandidate> candidates);
}

//// 推断是谁触发的（AI 库管家设计稿 §5.2：同一证据在两条路径上的门槛不同）。
enum MediaLinkInferenceTrigger {
  /// 自动路径（库管家自动跑，没有人看着）：只落高置信。
  automatic,

  /// 用户手动点「查找相关作品」/ ops `links.infer`：中置信也直接生效。
  manual,
}

/// 一条候选的落库去向。
enum MediaLinkDisposition {
  /// 直接生效（`confirmed_by = ai`，可撤销）。
  apply,

  /// 写成建议，等用户确认。
  suggest,

  /// 不写。
  discard,
}

/// 推断一轮的落库结果。
class MediaLinkInferenceOutcome {
  const MediaLinkInferenceOutcome({
    required this.applied,
    required this.suggested,
    required this.discarded,
    this.appliedWrites = const <MediaLinkAiWrite>[],
    this.suggestedIds = const <MediaLinkId>[],
  });

  /// 直接生效的条数（= [appliedWrites] 的长度）。
  final int applied;

  /// 新写入的建议数。
  final int suggested;

  /// 丢弃的候选数（AI 判不相关，或自动路径下 AI 低置信）。
  final int discarded;

  /// 生效连接的写入回执（id + 写入前的行），撤销用
  /// （`FushiDatabase.revertAiMediaLink`）。
  final List<MediaLinkAiWrite> appliedWrites;

  /// 本轮新写入的建议行（= [suggested] 条）。建议只在这一对条目之间原本没有任何行时
  /// 才写，撤销 = `FushiDatabase.discardMediaLinkSuggestion`。
  final List<MediaLinkId> suggestedIds;

  /// 本轮新写入（生效 + 建议）的条数。
  int get written => applied + suggested;
}

/// AI「高置信」门槛：只有标题匹配时，AI 置信度达到它两条路径都直接生效。
const double kMediaLinkAiHighConfidence = 0.9;

/// AI「中置信」门槛：达到它（但不到高置信）时，手动触发生效、自动路径写建议；
/// 不到它算低置信：手动触发写建议、自动路径丢弃。口径同 AI 整理库 §7.7。
const double kMediaLinkAiMediumConfidence = 0.6;

/// MAL 原作关系里「标题强匹配」的置信度（[matchMalSourceMaterial] 标题完全相同时
/// 给 0.6，包含关系 0.45 不算强匹配）。
const double kMediaLinkMalStrongTitleConfidence = 0.6;

/// 一条连接的两端各自所在作品（作品图谱连通分量）的身份与规模，由调用方提供
/// （§5.4 第二条兜底用）。返回 null = 端点不在作品图里（还没有任何连接），按只有
/// 自己一个成员的作品记账。
typedef MediaLinkWorkOf =
    ({Object id, int size})? Function(MediaLinkEndpoint endpoint);

/// 按 AI 库管家设计稿 §5.2 的表决定一条候选的去向（不含 §5.4 兜底）。
/// [original] 是 AI 改写前的候选（证据类别看它），[verdict] 为 null = 没经 AI。
///
/// | 证据 | 自动路径 | 手动触发 |
/// |---|---|---|
/// | 共享外部 id（[MediaLinkCandidate.idEvidence]） | 生效 | 生效 |
/// | MAL 原作关系 + 标题强匹配 | 生效 | 生效 |
/// | 只有标题，AI 高置信 | 生效 | 生效 |
/// | AI 中置信 | 建议 | 生效 |
/// | AI 低置信 | 丢弃 | 建议 |
///
/// AI 判「不相关」一律丢弃（强证据也不例外：宁可漏连）。没经 AI、又没有强证据的
/// 候选照旧写成建议（表里没有这一格，保持现状）。
MediaLinkDisposition mediaLinkDispositionOf({
  required MediaLinkCandidate original,
  required MediaLinkVerdict? verdict,
  required MediaLinkInferenceTrigger trigger,
}) {
  if (verdict != null && !verdict.related) return MediaLinkDisposition.discard;
  if (original.idEvidence) return MediaLinkDisposition.apply;
  if (original.source == MediaLinkSource.mal &&
      original.confidence >= kMediaLinkMalStrongTitleConfidence) {
    return MediaLinkDisposition.apply;
  }
  if (verdict == null) return MediaLinkDisposition.suggest;
  final bool manual = trigger == MediaLinkInferenceTrigger.manual;
  if (verdict.confidence >= kMediaLinkAiHighConfidence) {
    return MediaLinkDisposition.apply;
  }
  if (verdict.confidence >= kMediaLinkAiMediumConfidence) {
    return manual ? MediaLinkDisposition.apply : MediaLinkDisposition.suggest;
  }
  return manual ? MediaLinkDisposition.suggest : MediaLinkDisposition.discard;
}

/// §5.4 第一条兜底：两端都是带外部 id 的视频合集、而外部 id 对不上（没有任何一个
/// 来源的 id 相同）→ 不是同一部作品的硬证据，`same_work` 不生效。口径同 AI 整理库
/// §7.8 第 6 条。只管 `same_work`：续作 / 外传之间外部 id 本来就不同。
bool mediaLinkExternalIdsConflict(MediaLinkCandidate c) {
  if (c.relation != MediaLinkRelation.sameWork) return false;
  if (c.from.endpoint.kind != MediaLinkKind.videoCollection ||
      c.to.endpoint.kind != MediaLinkKind.videoCollection) {
    return false;
  }
  final Map<String, String> a = c.from.externalIds;
  final Map<String, String> b = c.to.externalIds;
  if (a.isEmpty || b.isEmpty) return false;
  for (final MapEntry<String, String> e in a.entries) {
    final String? other = b[e.key];
    if (other != null && other.trim() == e.value.trim()) return false;
  }
  return true;
}

/// §5.4 第二条兜底：一条连接把两部**都已不止一个成员**的作品并成一部。按成员数
/// 字面的「较大一方规模翻倍以上」只在两边一样大时成立，挡不住 9 卷 + 10 卷这种错并，
/// 所以取更保守的读法：两边都已成形（≥ 2）就算，自动路径降为建议。同一作品内部
/// 补连（两端已在同一分量）不算。
bool mediaLinkFusesWorks(
  ({Object id, int size}) a,
  ({Object id, int size}) b,
) => a.id != b.id && a.size >= 2 && b.size >= 2;

/// 是否是「音乐 → 作品」的候选（[MediaLinkRelation.themeSong] /
/// [MediaLinkRelation.soundtrack] 的 from 一端是音乐）。
bool isMusicMediaLinkCandidate(MediaLinkCandidate c) =>
    c.from.endpoint.kind == MediaLinkKind.musicAlbum ||
    c.from.endpoint.kind == MediaLinkKind.musicTrack;

/// 不交 AI 裁决的候选：声纹命中是实测对齐出来的（AI 库管家设计稿 §4.4 第 3 条，
/// 最强证据），AI 只看得到标题，没有资格推翻它，也不为它白花一次请求。
bool mediaLinkSkipsJudge(MediaLinkCandidate c) =>
    c.source == MediaLinkSource.fingerprint;

/// 把 AI 结论约束到候选两端的种类允许的关系上（AI 只能判真假与置信度，不能给
/// 端点种类配不上的关系）：
/// - 音乐候选：关系只能是 [MediaLinkRelation.themeSong] /
///   [MediaLinkRelation.soundtrack]（AI 给了别的就沿用候选的），方向固定音乐 → 作品；
/// - 其余候选：AI 给了主题曲 / 原声 = 结论形状不对，当没裁决（null）。
MediaLinkVerdict? fitMediaLinkVerdict(
  MediaLinkCandidate c,
  MediaLinkVerdict? v,
) {
  if (v == null || !v.related) return v;
  final bool musicRelation =
      v.relation == MediaLinkRelation.themeSong ||
      v.relation == MediaLinkRelation.soundtrack;
  if (!isMusicMediaLinkCandidate(c)) return musicRelation ? null : v;
  return MediaLinkVerdict(
    related: true,
    relation: musicRelation ? v.relation : c.relation,
    fromIsOriginal: true,
    confidence: v.confidence,
    reason: v.reason,
  );
}

/// 同一对条目出现多条候选时谁留下：声纹实测 > 共享外部 id > MAL 原作强匹配 >
/// 普通标题匹配 > 只有 AI 能定的同类候选。
int mediaLinkEvidenceRank(MediaLinkCandidate c) {
  if (c.source == MediaLinkSource.fingerprint) return 4;
  if (c.idEvidence) return 3;
  if (c.source == MediaLinkSource.mal &&
      c.confidence >= kMediaLinkMalStrongTitleConfidence) {
    return 2;
  }
  return c.aiOnly ? 0 : 1;
}

/// 两端年份都有且不同时：true = [a] 更早，false = [b] 更早；否则 null。
bool? _earlierByYear(MediaLinkSubject a, MediaLinkSubject b) {
  final int? ya = a.year;
  final int? yb = b.year;
  if (ya == null || yb == null || ya == yb) return null;
  return ya < yb;
}

/// 把候选（可选经 AI 裁决）按 [mediaLinkDispositionOf] 的门槛落库：生效的写成
/// `confirmed_by = ai`（`FushiDatabase.applyAiMediaLink`），建议走
/// `FushiDatabase.proposeMediaLink`。同一对条目已有任何行（含否决墓碑、用户确认）的
/// 候选在进 AI 之前就筛掉——用户定过的一对 AI 不改，否决过的不重复提议，也不为它
/// 白花一次 AI 请求。
///
/// AI 结论：不相关 → 丢弃；相关 → `source = ai`，关系 / 方向 / 置信度 / 理由取 AI
/// 的（理由前缀保留确定性证据）。AI 失败照常抛给调用方（由它决定提示用户并退回只跑
/// 确定性规则），这里不吞。
///
/// §5.4 兜底：[mediaLinkExternalIdsConflict] 两条路径都降为建议；[workOf] 给出时，
/// 自动路径上 [mediaLinkFusesWorks] 的降为建议（本轮已生效的连接计入分量合并；
/// [workOf] 返回 null 的端点按单成员作品记账）。
Future<MediaLinkInferenceOutcome> applyMediaLinkCandidates({
  required FushiDatabase db,
  required List<MediaLinkCandidate> candidates,
  required MediaLinkInferenceTrigger trigger,
  MediaLinkJudge? judge,
  MediaLinkWorkOf? workOf,
}) async {
  // 同一对条目只留一条：证据强的顶掉弱的（一批端点一起推断时，同一对可能先从一端
  // 以「标题像」出现、再从另一端以 MAL 原作出现），同样强的先到先得。
  final List<MediaLinkCandidate> unique = <MediaLinkCandidate>[];
  final Map<String, int> slotOf = <String, int>{};
  for (final MediaLinkCandidate c in candidates) {
    final MediaLinkEndpoint a = c.from.endpoint;
    final MediaLinkEndpoint b = c.to.endpoint;
    if (a.kind == b.kind && a.key == b.key) continue;
    // 只有 AI 能定的候选：没有裁决器就不必留着。
    if (c.aiOnly && judge == null) continue;
    final String key = mediaLinkPairKey(a, b);
    final int? slot = slotOf[key];
    if (slot == null) {
      slotOf[key] = unique.length;
      unique.add(c);
    } else if (mediaLinkEvidenceRank(c) > mediaLinkEvidenceRank(unique[slot])) {
      unique[slot] = c;
    }
  }
  final List<MediaLinkCandidate> fresh = <MediaLinkCandidate>[];
  for (final MediaLinkCandidate c in unique) {
    if (await db.mediaLinkPairExists(c.from.endpoint, c.to.endpoint)) continue;
    fresh.add(c);
  }
  if (fresh.isEmpty) {
    return const MediaLinkInferenceOutcome(
      applied: 0,
      suggested: 0,
      discarded: 0,
    );
  }
  final List<MediaLinkVerdict?> verdicts = List<MediaLinkVerdict?>.filled(
    fresh.length,
    null,
  );
  final List<int> toJudge = <int>[
    for (int i = 0; i < fresh.length; i++)
      if (!mediaLinkSkipsJudge(fresh[i])) i,
  ];
  if (judge != null && toJudge.isNotEmpty) {
    final List<MediaLinkVerdict?> got = await judge.judge(<MediaLinkCandidate>[
      for (final int i in toJudge) fresh[i],
    ]);
    if (got.length == toJudge.length) {
      for (int k = 0; k < toJudge.length; k++) {
        verdicts[toJudge[k]] = fitMediaLinkVerdict(fresh[toJudge[k]], got[k]);
      }
    }
  }
  // 本轮生效连接造成的分量合并（§5.4 第二条在同一轮里也要成立）。
  final Map<Object, Object> parent = <Object, Object>{};
  final Map<Object, int> sizeOf = <Object, int>{};
  Object root(Object id) {
    Object r = id;
    while (parent[r] != null && parent[r] != r) {
      r = parent[r]!;
    }
    return r;
  }

  // 作品图里没有的端点（还没有任何连接、也不在系列合集里）就是只有自己一个成员的
  // 作品：照样进并查集，本轮先生效的连接把它并进别的作品后，后面的连接才看得到真实
  // 分量（否则孤立端点先连上 A 作品、再连上 B 作品会绕过 §5.4 第二条）。
  ({Object id, int size})? work(MediaLinkEndpoint e) {
    if (workOf == null) return null;
    final ({Object id, int size}) w = workOf(e) ?? (id: e, size: 1);
    sizeOf.putIfAbsent(w.id, () => w.size);
    final Object r = root(w.id);
    return (id: r, size: sizeOf[r]!);
  }

  final List<MediaLinkAiWrite> writes = <MediaLinkAiWrite>[];
  final List<MediaLinkId> suggestedIds = <MediaLinkId>[];
  int discarded = 0;
  for (int i = 0; i < fresh.length; i++) {
    final MediaLinkCandidate original = fresh[i];
    MediaLinkCandidate c = original;
    final MediaLinkVerdict? v = verdicts[i];
    // 只有 AI 能定的候选没拿到结论（请求失败 / 这一条没判出来）：不写。
    if (original.aiOnly && v == null) {
      discarded++;
      continue;
    }
    MediaLinkDisposition disposition = mediaLinkDispositionOf(
      original: original,
      verdict: v,
      trigger: trigger,
    );
    if (disposition == MediaLinkDisposition.discard) {
      discarded++;
      continue;
    }
    // 关系 / 方向拿不准、不该不经用户就生效的结论。
    bool needsReview = false;
    if (v != null) {
      final bool series = workSeriesRelations.contains(v.relation);
      bool? fromIsOriginal = v.fromIsOriginal;
      if (series) {
        final bool? byYear = _earlierByYear(c.from, c.to);
        if (fromIsOriginal == null) {
          // AI 说不清谁在前：两端年份不同就按年份定，否则沿用候选原方向但只作建议
          // （续作 / 外传两端是不同作品，退成 same_work 会把它们并成一部）。
          fromIsOriginal = byYear;
          needsReview = byYear == null;
        } else if (v.relation == MediaLinkRelation.sequel &&
            byYear != null &&
            byYear != fromIsOriginal) {
          // AI 说的「前作」比「续作」晚出：方向与年份矛盾，交用户看。
          needsReview = true;
        }
      }
      // 同类候选（视频 ↔ 视频 / 游戏 ↔ 游戏）被判成同一作品 / 改编 = 要把两个条目
      // 并成一部作品，多半是重复入库或版本差异，不自动并。
      if (original.aiOnly && !series) needsReview = true;
      final bool swap = v.relation.directed && fromIsOriginal == false;
      c = c.copyWith(
        from: swap ? c.to : c.from,
        to: swap ? c.from : c.to,
        // 方向不明的改编退成 same_work。
        relation: v.relation.directed && fromIsOriginal == null && !series
            ? MediaLinkRelation.sameWork
            : v.relation,
        source: MediaLinkSource.ai,
        confidence: v.confidence,
        reason: '${v.reason}\n— ${c.reason}',
      );
    }
    if (needsReview && disposition == MediaLinkDisposition.apply) {
      disposition = MediaLinkDisposition.suggest;
    }
    ({Object id, int size})? wa;
    ({Object id, int size})? wb;
    if (disposition == MediaLinkDisposition.apply) {
      if (mediaLinkExternalIdsConflict(c)) {
        disposition = MediaLinkDisposition.suggest;
      } else if (trigger == MediaLinkInferenceTrigger.automatic) {
        wa = work(c.from.endpoint);
        wb = work(c.to.endpoint);
        if (wa != null && wb != null && mediaLinkFusesWorks(wa, wb)) {
          disposition = MediaLinkDisposition.suggest;
        }
      }
    }
    if (disposition == MediaLinkDisposition.apply) {
      final MediaLinkAiWrite? w = await db.applyAiMediaLink(
        relation: c.relation,
        from: c.from.endpoint,
        to: c.to.endpoint,
        source: c.source,
        confidence: c.confidence,
        reason: c.reason,
      );
      if (w == null) continue;
      writes.add(w);
      if (wa != null && wb != null && wa.id != wb.id) {
        parent[wb.id] = wa.id;
        sizeOf[wa.id] = wa.size + wb.size;
      }
      continue;
    }
    final bool wrote = await db.proposeMediaLink(
      relation: c.relation,
      from: c.from.endpoint,
      to: c.to.endpoint,
      source: c.source,
      confidence: c.confidence,
      reason: c.reason,
    );
    if (wrote) {
      suggestedIds.add(
        mediaLinkIdFor(c.relation, c.from.endpoint, c.to.endpoint),
      );
    }
  }
  return MediaLinkInferenceOutcome(
    applied: writes.length,
    suggested: suggestedIds.length,
    discarded: discarded,
    appliedWrites: List<MediaLinkAiWrite>.unmodifiable(writes),
    suggestedIds: List<MediaLinkId>.unmodifiable(suggestedIds),
  );
}
