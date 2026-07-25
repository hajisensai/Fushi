import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/scraper/match_scorer.dart';
import 'package:hibiki/src/media/video/scraper/scraper_types.dart';

/// 快速构造候选（测试辅助）。
ScrapeCandidate candidateOf({
  required String title,
  List<String> aliases = const <String>[],
  int? year,
  ScrapeEntryType type = ScrapeEntryType.unknown,
  int? episodeCount,
}) {
  return ScrapeCandidate(
    source: ScrapeSource.offlineDb,
    entryId: 'test/$title',
    title: title,
    aliases: aliases,
    year: year,
    type: type,
    episodeCount: episodeCount,
    posterUrl: 'https://example.invalid/poster.jpg',
  );
}

void main() {
  group('MatchScorer.score 单项信号', () {
    test('标题全同 + 年份相等 → high', () {
      final MatchDecision decision = MatchScorer.score(
        parsed: const ParsedMediaName(title: 'bocchi the rock', year: 2022),
        candidate: candidateOf(title: 'Bocchi the Rock!', year: 2022),
      );
      expect(decision.titleScore, 1.0);
      expect(decision.yearMatched, isTrue);
      expect(decision.confidence, MatchConfidence.high);
    });

    test('年份冲突（差≥2）降级出 high', () {
      final MatchDecision decision = MatchScorer.score(
        parsed: const ParsedMediaName(title: 'bocchi the rock', year: 2010),
        candidate: candidateOf(title: 'Bocchi the Rock!', year: 2022),
      );
      expect(decision.titleScore, 1.0);
      expect(decision.yearMatched, isFalse);
      expect(decision.confidence, MatchConfidence.medium);
    });

    test('年份差 1 容忍，任一缺失时 yearMatched 为 null', () {
      final MatchDecision near = MatchScorer.score(
        parsed: const ParsedMediaName(title: 'bocchi the rock', year: 2021),
        candidate: candidateOf(title: 'Bocchi the Rock!', year: 2022),
      );
      expect(near.yearMatched, isTrue);
      final MatchDecision missing = MatchScorer.score(
        parsed: const ParsedMediaName(title: 'bocchi the rock'),
        candidate: candidateOf(title: 'Bocchi the Rock!', year: 2022),
      );
      expect(missing.yearMatched, isNull);
      expect(missing.confidence, MatchConfidence.high);
    });

    test('电影提示 vs TV 条目冲突降级出 high', () {
      final MatchDecision decision = MatchScorer.score(
        parsed: const ParsedMediaName(
            title: 'violet evergarden', isMovieHint: true),
        candidate: candidateOf(
          title: 'Violet Evergarden',
          type: ScrapeEntryType.tv,
        ),
      );
      expect(decision.typeMatched, isFalse);
      expect(decision.confidence, MatchConfidence.medium);
    });

    test('集数超出总集数记不一致并减分', () {
      final MatchDecision decision = MatchScorer.score(
        parsed: const ParsedMediaName(title: 'bocchi the rock', episode: 24),
        candidate: candidateOf(
          title: 'Bocchi the Rock!',
          episodeCount: 12,
        ),
      );
      expect(decision.episodeCountConsistent, isFalse);
      final MatchDecision ok = MatchScorer.score(
        parsed: const ParsedMediaName(title: 'bocchi the rock', episode: 5),
        candidate: candidateOf(
          title: 'Bocchi the Rock!',
          episodeCount: 12,
        ),
      );
      expect(ok.episodeCountConsistent, isTrue);
    });

    test('宁缺勿错：标题相似度 < 0.55 时加分项再多也不给 high', () {
      // titleScore = 0.5，year+season+episode+type 全加分后综合分已过高线，
      // 但硬规则封顶 medium。
      final MatchDecision decision = MatchScorer.score(
        parsed: const ParsedMediaName(
          title: '孤独',
          season: 2,
          year: 2022,
          episode: 5,
        ),
        candidate: candidateOf(
          title: '孤独摇滚',
          aliases: <String>['孤独摇滚 第二季'],
          year: 2022,
          type: ScrapeEntryType.tv,
          episodeCount: 12,
        ),
      );
      expect(decision.titleScore, lessThan(0.55));
      expect(decision.yearMatched, isTrue);
      expect(decision.seasonMatched, isTrue);
      expect(decision.confidence, MatchConfidence.medium);
    });

    test('完全无关标题 → low', () {
      final MatchDecision decision = MatchScorer.score(
        parsed: const ParsedMediaName(title: 'totally different', year: 2022),
        candidate: candidateOf(title: '孤独摇滚', year: 2022),
      );
      expect(decision.confidence, MatchConfidence.low);
    });
  });

  group('MatchScorer.best 多候选选优', () {
    test('正确季度条目胜出（第一季条目被季度冲突压下去）', () {
      final ScrapeCandidate seasonOne = candidateOf(
        title: 'Mushoku Tensei: Isekai Ittara Honki Dasu',
        aliases: <String>[
          '無職転生～異世界行ったら本気だす～',
          '无职转生～到了异世界就拿出真本事～',
        ],
        year: 2021,
        type: ScrapeEntryType.tv,
        episodeCount: 11,
      );
      final ScrapeCandidate seasonTwo = candidateOf(
        title: 'Mushoku Tensei II: Isekai Ittara Honki Dasu',
        aliases: <String>[
          '無職転生 Ⅱ ～異世界行ったら本気だす～',
          '无职转生 第二季',
        ],
        year: 2023,
        type: ScrapeEntryType.tv,
        episodeCount: 12,
      );
      final MatchDecision? best = MatchScorer.best(
        parsed: const ParsedMediaName(
          title: '无职转生',
          season: 2,
          year: 2023,
          episode: 5,
        ),
        candidates: <ScrapeCandidate>[seasonOne, seasonTwo],
      );
      expect(best, isNotNull);
      expect(best!.candidate.title, seasonTwo.title);
      expect(best.seasonMatched, isTrue);
      expect(best.confidence, MatchConfidence.high);
      // 第一季单独打分：季度冲突。
      final MatchDecision one = MatchScorer.score(
        parsed: const ParsedMediaName(title: '无职转生', season: 2, year: 2023),
        candidate: seasonOne,
      );
      expect(one.seasonMatched, isFalse);
    });

    test('电影提示时 movie 条目胜出 TV 条目', () {
      final ScrapeCandidate tv = candidateOf(
        title: 'Violet Evergarden',
        aliases: <String>['紫罗兰永恒花园'],
        year: 2018,
        type: ScrapeEntryType.tv,
        episodeCount: 13,
      );
      final ScrapeCandidate movie = candidateOf(
        title: 'Violet Evergarden Movie',
        aliases: <String>['剧场版 紫罗兰永恒花园'],
        year: 2020,
        type: ScrapeEntryType.movie,
        episodeCount: 1,
      );
      final MatchDecision? best = MatchScorer.best(
        parsed: const ParsedMediaName(
          title: 'violet evergarden',
          isMovieHint: true,
        ),
        candidates: <ScrapeCandidate>[tv, movie],
      );
      expect(best, isNotNull);
      expect(best!.candidate.title, movie.title);
      expect(best.typeMatched, isTrue);
    });

    test('无电影提示时类型加权中性，正片不被联动 CM 徽标反超（BUG-1080）', () {
      // 文件名没写「剧场版」时，候选是不是电影从文件名根本推不出来，不得据此奖惩。
      // 旧实现给「无 hint + movie 候选」−0.10、给「无 hint + 非 movie 候选」+0.05，这
      // 0.15 摆动会把正片压成 medium、把靠借来别名蹭到同样 titleScore 的联动 CM 顶成 high。
      const ParsedMediaName parsed =
          ParsedMediaName(title: 'kimi no na wa'); // 无 isMovieHint
      final MatchDecision movie = MatchScorer.score(
        parsed: parsed,
        candidate:
            candidateOf(title: 'Kimi no Na wa.', type: ScrapeEntryType.movie),
      );
      final MatchDecision cm = MatchScorer.score(
        parsed: parsed,
        candidate: candidateOf(
          title: 'Suntory Minami Alps no Tennensui',
          aliases: <String>['Kimi no Na wa'], // 借来的别名蹭 titleScore
          type: ScrapeEntryType.special,
        ),
      );
      // 修后：无 hint 时类型加权恒为 0，typeMatched 不可判定；两者 titleScore 同为 1.0
      // → 同级，正片不再被 CM 的类型加权反超。
      expect(movie.typeMatched, isNull);
      expect(cm.typeMatched, isNull);
      expect(movie.titleScore, 1.0);
      expect(cm.titleScore, 1.0);
      expect(movie.confidence, cm.confidence,
          reason: '标题同分时类型不再制造偏差，正片不再被联动 CM 徽标反超');
      expect(movie.confidence, MatchConfidence.high);
    });

    test('罗马数字季度记号（Ⅱ/ii）也能对上', () {
      final ScrapeCandidate romanTwo = candidateOf(
        title: 'Mushoku Tensei II',
        aliases: <String>['無職転生 Ⅱ'],
        type: ScrapeEntryType.tv,
      );
      final MatchDecision decision = MatchScorer.score(
        parsed: const ParsedMediaName(title: 'mushoku tensei', season: 2),
        candidate: romanTwo,
      );
      expect(decision.seasonMatched, isTrue);
    });

    test('空候选列表返回 null', () {
      expect(
        MatchScorer.best(
          parsed: const ParsedMediaName(title: 'anything'),
          candidates: const <ScrapeCandidate>[],
        ),
        isNull,
      );
    });
  });
}
