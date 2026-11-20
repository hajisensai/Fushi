// 作品图谱 AI 裁决缓存（v163）。表语义见 media_link_ai_verdict_tables.dart。
part of 'database.dart';

mixin _FushiDbMediaLinkAiVerdicts on _$FushiDatabase {
  /// 裁决时刻不早于 [notBefore]（毫秒）的全部缓存行。表受过期清理约束、行很短，
  /// 一次推断整表读一遍比按候选逐对查省往返。
  Future<List<MediaLinkAiVerdictRow>> mediaLinkAiVerdictsSince(int notBefore) =>
      (select(mediaLinkAiVerdicts)..where(
            (MediaLinkAiVerdicts t) =>
                t.judgedAt.isBiggerOrEqualValue(notBefore),
          ))
          .get();

  /// 写入 / 覆盖一批结论（同一对端点只留最新的一条）。
  Future<void> upsertMediaLinkAiVerdicts(
    List<MediaLinkAiVerdictsCompanion> rows,
  ) async {
    if (rows.isEmpty) return;
    await batch((Batch b) {
      b.insertAllOnConflictUpdate(mediaLinkAiVerdicts, rows);
    });
  }

  /// 清掉裁决时刻早于 [before]（毫秒）的行，返回删掉的行数。
  Future<int> pruneMediaLinkAiVerdicts(int before) =>
      (delete(mediaLinkAiVerdicts)..where(
            (MediaLinkAiVerdicts t) => t.judgedAt.isSmallerThanValue(before),
          ))
          .go();
}
