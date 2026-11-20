import 'package:drift/drift.dart';

// ── media_link_ai_verdicts（schema v163，作品图谱 AI 裁决缓存）────────────────
//
// docs/specs/2026-10-24-cross-media-links.md「系列关系与省额度」：AI 对一对条目的
// 结论按「这一对 + AI 当时看到的内容」记下来，同样的问题不再问第二遍。
//
// 为什么需要：AI 判「不相关」或置信度不够而被丢弃的候选在 `media_links` 里不留任何
// 行，下一次推断（整库重跑、用户对同一条目再点一次「查找相关作品」、同一对从另一端
// 再出一次）又会原样发给 AI。判「相关」并落库的那些由 `media_links` 的行挡住，不靠
// 这张表，但也照记——自动路径丢弃的低置信结论，手动触发时可以直接拿来写成建议。
//
// 身份是无序的一对端点：[aKind] / [aKey] 是按 `<kind>\u0000<key>` 字典序较小的一端，
// [bKind] / [bKey] 是较大的一端（与 `mediaLinkPairKey` 同序）。方向相关的结论
// （[aIsOriginal]）相对这个固定顺序存，候选两端怎么摆都能读回来。
//
// [fingerprint] = AI 当时看到的全部输入（两端各自的种类 / 标题 / 年份 / 外部 id）+
// 提示词版本 + 模型名的摘要。条目重新刮削换了标题、换了模型、改了提示词，摘要对不上
// 就当没缓存、重新问并覆盖。
//
// **纯缓存、设备本地**（不进备份 / 同步）：AI 配置本来就是设备本地的，另一台设备可能
// 配的是另一个模型。没有外键：条目被删后留下的行按 [judgedAt] 过期清掉
// （`pruneMediaLinkAiVerdicts`），覆盖恢复后原样回灌也不会被外键打断。
@DataClassName('MediaLinkAiVerdictRow')
class MediaLinkAiVerdicts extends Table {
  TextColumn get aKind => text()();
  TextColumn get aKey => text()();
  TextColumn get bKind => text()();
  TextColumn get bKey => text()();

  /// AI 输入 + 提示词版本 + 模型名的摘要（十六进制）。
  TextColumn get fingerprint => text()();

  /// AI 是否判两端相关。
  BoolColumn get related => boolean()();

  /// 相关时的关系（`MediaLinkRelation.dbValue`）；不相关为 NULL。
  TextColumn get relation => text().nullable()();

  /// 有方向的关系里 a 一端是否是原作 / 前作 / 本篇；NULL = AI 说不清或无方向。
  BoolColumn get aIsOriginal => boolean().nullable()();

  RealColumn get confidence => real()();

  /// AI 给的一句理由（不相关时为空串）。
  TextColumn get reason => text().withDefault(const Constant(''))();

  /// 裁决时刻（毫秒）：过期判据。
  IntColumn get judgedAt => integer()();

  @override
  Set<Column> get primaryKey => <Column>{aKind, aKey, bKind, bKey};
}
