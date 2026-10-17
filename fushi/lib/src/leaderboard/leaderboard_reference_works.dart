// 排行榜总字数卡片的「≈ 读完 N 卷某作品」：参照作品模型与挑选逻辑（纯 Dart，可测）。
// 数据是随包 const 表 [kLeaderboardReferenceWorks]（jiten.moe 生成，运行时不联网）。

import 'dart:math' as math;

/// 参照作品的种类（决定动词：读 / 看 / 玩）。
enum LeaderboardReferenceKind { novel, manga, anime, visualNovel }

/// 一部参照作品。[parts] = 卷 / 集数（单本 / 单部 / 剧场版为 1）。
class LeaderboardReferenceWork {
  const LeaderboardReferenceWork({
    required this.jitenId,
    required this.kind,
    required this.title,
    required this.totalChars,
    required this.parts,
  });

  /// jiten.moe deckId（出处，`https://jiten.moe/decks/media/<id>/detail`）。
  final int jitenId;
  final LeaderboardReferenceKind kind;
  final String title;
  final int totalChars;
  final int parts;

  /// 换算单位的字数：多卷 / 多集按每卷 / 每集，否则按整部。
  int get unitChars => (totalChars / parts).round();

  /// 是否按卷 / 集换算（false = 按「整部 N 遍」）。
  bool get countsParts => parts > 1;
}

/// 一次换算结果。
class LeaderboardReferenceEquivalent {
  const LeaderboardReferenceEquivalent({
    required this.work,
    required this.amount,
  });

  final LeaderboardReferenceWork work;

  /// 相当于多少卷 / 集 / 遍。
  final double amount;
}

/// 从 [works] 里挑一部给 [chars] 做参照：优先换算后 ≥ 1 的（「读完 0.03 卷」没有
/// 意义），[random] 决定轮换（每次打开页面换一部）。[chars] ≤ 0 或表为空时 null。
LeaderboardReferenceEquivalent? pickLeaderboardReference(
  int chars,
  List<LeaderboardReferenceWork> works,
  math.Random random,
) {
  if (chars <= 0 || works.isEmpty) return null;
  final List<LeaderboardReferenceWork> fitting = <LeaderboardReferenceWork>[
    for (final LeaderboardReferenceWork w in works)
      if (w.unitChars > 0 && chars >= w.unitChars) w,
  ];
  final List<LeaderboardReferenceWork> pool;
  if (fitting.isNotEmpty) {
    pool = fitting;
  } else {
    // 都比总字数大：取单位字数最小的那部（最接近 1）。
    final int smallest = works
        .map((LeaderboardReferenceWork w) => w.unitChars)
        .where((int c) => c > 0)
        .fold<int>(1 << 62, math.min);
    pool = <LeaderboardReferenceWork>[
      for (final LeaderboardReferenceWork w in works)
        if (w.unitChars == smallest) w,
    ];
  }
  if (pool.isEmpty) return null;
  final LeaderboardReferenceWork work = pool[random.nextInt(pool.length)];
  return LeaderboardReferenceEquivalent(
    work: work,
    amount: chars / work.unitChars,
  );
}

/// 下一个整百万里程碑（恰好整百万时取再下一个）。
int leaderboardNextMillion(int chars) =>
    ((math.max(chars, 0) ~/ 1000000) + 1) * 1000000;
