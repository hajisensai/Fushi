/// 匹配打分校验（刮削流水线第⑤层）。
///
/// 输入解析层的 [ParsedMediaName] 与匹配层的 [ScrapeCandidate]，
/// 输出带置信度的 [MatchDecision]。原则「宁缺勿错」：低置信度宁可
/// 保留抽帧封面，也不落一张错误海报。
library;

import 'package:fushi/src/media/video/scraper/scraper_types.dart';
import 'package:fushi/src/media/video/scraper/title_normalizer.dart';

// ---------------------------------------------------------------------------
// 权重与阈值（调参集中在此，均有注释说明取值理由）。
// ---------------------------------------------------------------------------

/// 标题相似度是主导信号，直接作为基准分（权重 1.0），其余都是修正项。
const double _kTitleWeight = 1.0;

/// 年份完全相等：强加分。年份是文件名里最可靠的辅助信号。
const double _kYearExactBonus = 0.15;

/// 年份差 1：容忍（跨年番/放送与制作年差异常见），不加不减。
const double _kYearNearDelta = 0.0;

/// 年份差 ≥2：强减分——大概率是同名不同作或错误季度条目。
const double _kYearFarPenalty = -0.20;

/// 电影提示与候选类型一致（剧场版 hint + movie 条目）：加分。
const double _kTypeMovieBonus = 0.10;

/// 显式电影提示但候选不是 movie：强冲突减分。
const double _kTypeConflictStrongPenalty = -0.20;

/// 季度记号对上（parsed.season≥2 且候选标题/别名含对应季度记号）：加分。
const double _kSeasonBonus = 0.15;

/// 季度冲突（要第 N 季却匹到第一季条目或别的季）：减分。
/// 同系列各季标题高度相似，季度记号是唯一区分器，罚必须足够狠。
const double _kSeasonPenalty = -0.15;

/// 集数落在候选总集数范围内：小幅加分（一致是弱证据）。
const double _kEpisodeBonus = 0.05;

/// 集数超出候选总集数：减分（多半是选错季）。
const double _kEpisodePenalty = -0.15;

/// 综合分 ≥ 此线 → high（批量匹配自动落封面）。
/// 取 0.85：要求「标题基本对得上 + 至少一个强佐证」或「标题近乎全同」。
const double _kHighThreshold = 0.85;

/// 综合分 ≥ 此线 → medium（进人工确认队列）；再低即 low。
const double _kMediumThreshold = 0.55;

/// 宁缺勿错硬规则：标题相似度本身低于此线时，无论加分项一律不给 high。
/// 年份/类型全对但标题对不上的，多为同档期不同作。
const double _kMinTitleScoreForHigh = 0.55;

/// 打分校验器（纯静态，无状态）。
class MatchScorer {
  const MatchScorer._();

  /// 对单个候选打分。
  static MatchDecision score({
    required ParsedMediaName parsed,
    required ScrapeCandidate candidate,
  }) {
    return _scoreInternal(parsed: parsed, candidate: candidate).$1;
  }

  /// 对全部候选打分取综合分最高者；空列表返回 null。
  static MatchDecision? best({
    required ParsedMediaName parsed,
    required List<ScrapeCandidate> candidates,
  }) {
    MatchDecision? bestDecision;
    double bestTotal = double.negativeInfinity;
    for (final ScrapeCandidate candidate in candidates) {
      final (MatchDecision decision, double total) =
          _scoreInternal(parsed: parsed, candidate: candidate);
      if (total > bestTotal) {
        bestTotal = total;
        bestDecision = decision;
      }
    }
    return bestDecision;
  }

  /// 打分主体：返回决策与内部综合分
  /// （契约 [MatchDecision] 不携带总分，best 选优需要内部值）。
  static (MatchDecision, double) _scoreInternal({
    required ParsedMediaName parsed,
    required ScrapeCandidate candidate,
  }) {
    // --- 标题相似度：parsed.title 对 candidate.title 与全部 aliases 取最大。---
    double titleScore =
        TitleNormalizer.similarity(parsed.title, candidate.title);
    for (final String alias in candidate.aliases) {
      if (titleScore >= 1.0) {
        break;
      }
      final double s = TitleNormalizer.similarity(parsed.title, alias);
      if (s > titleScore) {
        titleScore = s;
      }
    }
    double total = titleScore * _kTitleWeight;

    // --- 年份：双方都有才参与。---
    bool? yearMatched;
    if (parsed.year != null && candidate.year != null) {
      final int delta = (parsed.year! - candidate.year!).abs();
      if (delta == 0) {
        yearMatched = true;
        total += _kYearExactBonus;
      } else if (delta == 1) {
        yearMatched = true; // 容忍带。
        total += _kYearNearDelta;
      } else {
        yearMatched = false;
        total += _kYearFarPenalty;
      }
    }

    // --- 类型：只有文件名显式带电影标记（剧场版/Movie/映画）时类型才是可信信号。---
    // hint + movie → 一致加分；hint + 非 movie → 强冲突减分。
    // 文件名**没**电影标记时，候选是不是电影从文件名根本推不出来（剧集文件常省略、
    // 电影文件也常不写「剧场版」）——此时保持中性 0，不得据此奖惩任一方。旧实现给
    // 「无 hint + movie 候选」−0.10、给「无 hint + 剧集候选」+0.05，这 0.15 的系统性
    // 摆动会把无标记的正片压到联动 CM / 剧集条目之下（BUG-1080）。unknown 同样不参与。
    bool? typeMatched;
    if (candidate.type != ScrapeEntryType.unknown && parsed.isMovieHint) {
      final bool candidateIsMovie = candidate.type == ScrapeEntryType.movie;
      if (candidateIsMovie) {
        typeMatched = true;
        total += _kTypeMovieBonus;
      } else {
        typeMatched = false;
        total += _kTypeConflictStrongPenalty;
      }
    }

    // --- 季度：parsed.season 有值才参与。---
    bool? seasonMatched;
    final int? parsedSeason = parsed.season;
    if (parsedSeason != null) {
      final Set<int> candidateSeasons = _detectSeasons(candidate);
      if (parsedSeason >= 2) {
        if (candidateSeasons.contains(parsedSeason)) {
          seasonMatched = true;
          total += _kSeasonBonus;
        } else {
          // 候选无任何季度记号（明显是第一季条目）或记号是别的季：都算冲突。
          seasonMatched = false;
          total += _kSeasonPenalty;
        }
      } else {
        // 要第一季：无记号或标 1 都算一致（第一季通常不带记号，不给加分）；
        // 只带 ≥2 记号的候选算冲突。
        if (candidateSeasons.isEmpty || candidateSeasons.contains(1)) {
          seasonMatched = true;
        } else {
          seasonMatched = false;
          total += _kSeasonPenalty;
        }
      }
    }

    // --- 集数一致性：双方都有才参与，episode <= episodeCount 才一致。---
    bool? episodeCountConsistent;
    if (parsed.episode != null && candidate.episodeCount != null) {
      if (parsed.episode! <= candidate.episodeCount!) {
        episodeCountConsistent = true;
        total += _kEpisodeBonus;
      } else {
        episodeCountConsistent = false;
        total += _kEpisodePenalty;
      }
    }

    // --- 置信度分级（含宁缺勿错硬规则）。---
    MatchConfidence confidence;
    if (total >= _kHighThreshold && titleScore >= _kMinTitleScoreForHigh) {
      confidence = MatchConfidence.high;
    } else if (total >= _kMediumThreshold) {
      confidence = MatchConfidence.medium;
    } else {
      confidence = MatchConfidence.low;
    }

    return (
      MatchDecision(
        candidate: candidate,
        confidence: confidence,
        titleScore: titleScore,
        yearMatched: yearMatched,
        typeMatched: typeMatched,
        seasonMatched: seasonMatched,
        episodeCountConsistent: episodeCountConsistent,
      ),
      total,
    );
  }

  // -------------------------------------------------------------------------
  // 季度记号识别（简单规则，覆盖常见写法即可）。
  // -------------------------------------------------------------------------

  /// 从候选 title + aliases 中识别出全部季度号。
  static Set<int> _detectSeasons(ScrapeCandidate candidate) {
    final Set<int> seasons = <int>{};
    for (final String name in <String>[candidate.title, ...candidate.aliases]) {
      seasons.addAll(_detectSeasonsInText(name));
    }
    return seasons;
  }

  /// 中文数字 → 整数（季度用，只到十）。
  static const Map<String, int> _kCjkDigits = <String, int>{
    '一': 1,
    '二': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
    '十': 10,
  };

  /// 罗马数字 token（归一化后为小写）→ 季度号。
  /// 刻意不收单独的 i / v / x：单字母误报率太高（如 SPY×FAMILY 的 x）。
  static const Map<String, int> _kRomanTokens = <String, int>{
    'ⅱ': 2,
    'ⅲ': 3,
    'ⅳ': 4,
    'ⅵ': 6,
    'ⅶ': 7,
    'ⅷ': 8,
    'ⅸ': 9,
    'ii': 2,
    'iii': 3,
    'iv': 4,
    'vi': 6,
    'vii': 7,
    'viii': 8,
    'ix': 9,
  };

  /// 识别单个标题串里的季度记号：
  /// `第N季/第N期/第N部` / `2nd Season` / `Season 2` / `Part 2` /
  /// `S2` / 罗马数字 Ⅱ Ⅲ（独立 token）。
  static Set<int> _detectSeasonsInText(String rawName) {
    final String text = TitleNormalizer.normalize(rawName);
    final Set<int> seasons = <int>{};
    // 第N季 / 第N期 / 第N部（阿拉伯或中文数字）。
    for (final RegExpMatch m
        in RegExp('第\\s*([0-9]+|[一二三四五六七八九十])\\s*[季期部]').allMatches(text)) {
      final String digits = m.group(1)!;
      final int? n = int.tryParse(digits) ?? _kCjkDigits[digits];
      if (n != null && n >= 1 && n <= 20) {
        seasons.add(n);
      }
    }
    // 2nd season / season 2 / part 2。
    for (final RegExpMatch m in RegExp(
      r'(?:([0-9]+)\s*(?:st|nd|rd|th)\s+season)|(?:(?:season|part)\s*([0-9]+))',
    ).allMatches(text)) {
      final int? n = int.tryParse(m.group(1) ?? m.group(2) ?? '');
      if (n != null && n >= 1 && n <= 20) {
        seasons.add(n);
      }
    }
    // 独立 token：s2 / ii / ⅲ 等。
    for (final String token in TitleNormalizer.tokens(text)) {
      final int? roman = _kRomanTokens[token];
      if (roman != null) {
        seasons.add(roman);
        continue;
      }
      final RegExpMatch? sMatch = RegExp(r'^s([0-9]{1,2})$').firstMatch(token);
      if (sMatch != null) {
        final int? n = int.tryParse(sMatch.group(1)!);
        if (n != null && n >= 1 && n <= 20) {
          seasons.add(n);
        }
      }
    }
    return seasons;
  }
}
