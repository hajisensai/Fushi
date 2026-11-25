// 作品图谱 AI 裁决缓存（v163）。表语义见 media_link_ai_verdict_tables.dart。
part of 'database.dart';

/// `media_link_ai_verdicts` 的主键：一对端点，[aKind] / [aKey] 是按
/// `<kind>\u0000<key>` 字典序较小的一端（与 `mediaLinkPairKey` 同序）。
typedef MediaLinkAiVerdictPair = ({
  String aKind,
  String aKey,
  String bKind,
  String bKey,
});

/// [_FushiDbMediaLinkAiVerdicts.mediaLinkAiVerdictsForPairs] 一条 SELECT 最多带几对：
/// 每对 4 个绑定参数 + 1 个时刻参数，200 对 = 801，留在 SQLite 旧版 999 的上限内。
const int _kMediaLinkAiVerdictPairsPerSelect = 200;

mixin _FushiDbMediaLinkAiVerdicts on _$FushiDatabase {
  /// 裁决时刻不早于 [notBefore]（毫秒）的全部缓存行（诊断 / 测试用；推断路径按
  /// 候选查 [mediaLinkAiVerdictsForPairs]，不整表读）。
  Future<List<MediaLinkAiVerdictRow>> mediaLinkAiVerdictsSince(int notBefore) =>
      (select(mediaLinkAiVerdicts)..where(
            (MediaLinkAiVerdicts t) =>
                t.judgedAt.isBiggerOrEqualValue(notBefore),
          ))
          .get();

  /// [pairs] 里各对端点裁决时刻不早于 [notBefore]（毫秒）的缓存行：按主键
  /// （a_kind, a_key, b_kind, b_key）逐对命中，读回的行数不超过本次去重后的对数，
  /// 与表里攒了多少别的组合无关。重复的对只查一次；超过
  /// [_kMediaLinkAiVerdictPairsPerSelect] 对时分几条 SELECT。
  Future<List<MediaLinkAiVerdictRow>> mediaLinkAiVerdictsForPairs(
    Iterable<MediaLinkAiVerdictPair> pairs,
    int notBefore,
  ) async {
    final List<MediaLinkAiVerdictPair> unique = pairs.toSet().toList();
    final List<MediaLinkAiVerdictRow> out = <MediaLinkAiVerdictRow>[];
    for (
      int start = 0;
      start < unique.length;
      start += _kMediaLinkAiVerdictPairsPerSelect
    ) {
      final int end = start + _kMediaLinkAiVerdictPairsPerSelect < unique.length
          ? start + _kMediaLinkAiVerdictPairsPerSelect
          : unique.length;
      final List<MediaLinkAiVerdictPair> chunk = unique.sublist(start, end);
      out.addAll(
        await (select(mediaLinkAiVerdicts)..where(
              (MediaLinkAiVerdicts t) =>
                  Expression.or(<Expression<bool>>[
                    for (final MediaLinkAiVerdictPair p in chunk)
                      t.aKind.equals(p.aKind) &
                          t.aKey.equals(p.aKey) &
                          t.bKind.equals(p.bKind) &
                          t.bKey.equals(p.bKey),
                  ]) &
                  t.judgedAt.isBiggerOrEqualValue(notBefore),
            ))
            .get(),
      );
    }
    return out;
  }

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
