/// 作品图谱推断（L1，spec `docs/specs/2026-10-24-cross-media-links.md`「推断」与
/// 「AI 辅助判断」两节）。
///
/// 只用各模块已在用的身份，不为联动新增元数据主源；**一律不用 Bangumi**（所有者
/// 2026-10-24 拍板）。推断结果只写成**建议**（`is_user_confirmed = false`），用户
/// 确认后才在「同一作品」区块里显示成事实；用户否决过的同一对条目不再提议
/// （`FushiDatabase.proposeMediaLink` 的去重）。
///
/// 规则（纯函数，离线可测）：
/// - [matchMalSourceMaterial]：MAL（Jikan）给出动画的原作（Adaptation，manga 条目）→
///   按**标题**对本地书。Jikan 关联条目不带 ISBN，所以是中等判据，只作建议。
/// - [matchSubjectsByTitle]：两个条目没有共享 id 但规范化标题相同（游戏 ↔ 动画等）→
///   低置信候选，交 AI 裁决；没配 AI 时作为低置信建议。
///
/// AI 裁决（[MediaLinkJudge]）只在已缩小的候选上给结构化结论（是否相关、关系、方向、
/// 置信度、理由），**不让 AI 编 id**：结论按候选下标回填，端点永远来自本地数据。
library;

import 'package:fushi_core/fushi_core.dart';

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
  });

  final MediaLinkEndpoint endpoint;

  /// 显示名 / 原名 / 刮削别名…（任一命中即算）。
  final List<String> titles;
  final int? year;

  /// provider → id（`mal` / `anidb` / `vndb` …，Bangumi 不收）。
  final Map<String, String> externalIds;

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
  });

  final MediaLinkSubject from;
  final MediaLinkSubject to;
  final MediaLinkRelation relation;
  final String source;
  final double confidence;
  final String reason;

  /// 是否有共享外部 id 佐证（而不只是标题像）。只有它为 true 且 AI 高置信时，
  /// 「高置信自动确认」才会直接确认。
  final bool idEvidence;

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
  );
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

/// 推断一轮的落库结果。
class MediaLinkInferenceOutcome {
  const MediaLinkInferenceOutcome({
    required this.proposed,
    required this.autoConfirmed,
    required this.rejectedByAi,
  });

  /// 新写入的建议数（含被自动确认的）。
  final int proposed;
  final int autoConfirmed;

  /// AI 判为不相关、没有写入的候选数。
  final int rejectedByAi;
}

/// 「高置信自动确认」的门槛（且必须有共享 id 佐证）。
const double kMediaLinkAutoConfirmConfidence = 0.9;

/// 把候选（可选经 AI 裁决）写成建议。同一对条目已有任何行（含否决墓碑）的候选在
/// 进 AI 之前就筛掉——否决过的不重复提议，也不为它白花一次 AI 请求。
///
/// AI 结论：不相关 → 不写；相关 → `source = ai`，关系 / 方向 / 置信度 / 理由取 AI
/// 的（理由前缀保留确定性证据）。[autoConfirm] 打开且候选有共享 id 佐证、AI 置信度
/// ≥ [kMediaLinkAutoConfirmConfidence] 时直接确认。AI 失败照常抛给调用方（由它决定
/// 提示用户并退回只跑确定性规则），这里不吞。
Future<MediaLinkInferenceOutcome> applyMediaLinkCandidates({
  required FushiDatabase db,
  required List<MediaLinkCandidate> candidates,
  MediaLinkJudge? judge,
  bool autoConfirm = false,
}) async {
  final List<MediaLinkCandidate> fresh = <MediaLinkCandidate>[];
  final Set<String> seen = <String>{};
  for (final MediaLinkCandidate c in candidates) {
    final MediaLinkEndpoint a = c.from.endpoint;
    final MediaLinkEndpoint b = c.to.endpoint;
    if (a.kind == b.kind && a.key == b.key) continue;
    final List<String> pair = <String>[
      '${a.kind.dbValue}\u0000${a.key}',
      '${b.kind.dbValue}\u0000${b.key}',
    ]..sort();
    if (!seen.add(pair.join('\u0001'))) continue;
    if (await db.mediaLinkPairExists(a, b)) continue;
    fresh.add(c);
  }
  if (fresh.isEmpty) {
    return const MediaLinkInferenceOutcome(
      proposed: 0,
      autoConfirmed: 0,
      rejectedByAi: 0,
    );
  }
  List<MediaLinkVerdict?> verdicts = List<MediaLinkVerdict?>.filled(
    fresh.length,
    null,
  );
  if (judge != null) {
    final List<MediaLinkVerdict?> got = await judge.judge(fresh);
    if (got.length == fresh.length) verdicts = got;
  }
  int proposed = 0;
  int autoConfirmed = 0;
  int rejected = 0;
  for (int i = 0; i < fresh.length; i++) {
    MediaLinkCandidate c = fresh[i];
    final MediaLinkVerdict? v = verdicts[i];
    if (v != null) {
      if (!v.related) {
        rejected++;
        continue;
      }
      final bool swap = v.relation.directed && v.fromIsOriginal == false;
      c = c.copyWith(
        from: swap ? c.to : c.from,
        to: swap ? c.from : c.to,
        relation: v.relation.directed && v.fromIsOriginal == null
            ? MediaLinkRelation.sameWork
            : v.relation,
        source: MediaLinkSource.ai,
        confidence: v.confidence,
        reason: '${v.reason}\n— ${c.reason}',
      );
    }
    final bool wrote = await db.proposeMediaLink(
      relation: c.relation,
      from: c.from.endpoint,
      to: c.to.endpoint,
      source: c.source,
      confidence: c.confidence,
      reason: c.reason,
    );
    if (!wrote) continue;
    proposed++;
    if (autoConfirm &&
        v != null &&
        c.idEvidence &&
        v.confidence >= kMediaLinkAutoConfirmConfidence) {
      await db.confirmMediaLink(
        mediaLinkIdFor(c.relation, c.from.endpoint, c.to.endpoint),
      );
      autoConfirmed++;
    }
  }
  return MediaLinkInferenceOutcome(
    proposed: proposed,
    autoConfirmed: autoConfirmed,
    rejectedByAi: rejected,
  );
}
