import 'package:test/test.dart';

import 'package:fushi/src/media/metadata/scrape_title_matcher.dart';
import 'package:fushi/src/mining/galgame_scrape_controller.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_adapter.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:fushi_engine/mining/metadata/galgame_metadata_source.dart';

/// 游戏库「全部刮削」的自动采用判据，走真实的多源合并路径
/// （[GalgameScrapeController.search] 把各源候选拼成一条列表）再交给
/// [uniqueExactScrapeTitleMatch]，参数与 `games_library_page.dart` 的
/// `_scrapeAllGames` 一致（守卫见 scrape_all_entry_guard_test）。
///
/// 回归：Bangumi 与 VNDB 都收录的作品（ATRI、STEINS;GATE 一类），两个源各回一条
/// 精确同名，旧判据把它当成歧义，整库这类作品全部「需确认」、刮不出封面。
SourceCandidate? _batchPick(String query, List<SourceCandidate> candidates) =>
    uniqueExactScrapeTitleMatch<SourceCandidate>(
      query: query,
      candidates: candidates,
      titles: (SourceCandidate candidate) => <String>[
        if (candidate.nameCn != null) candidate.nameCn!,
        if (candidate.name != null) candidate.name!,
      ],
      sourceOf: (SourceCandidate candidate) => candidate.source,
    );

SourceCandidate _candidate(
  GalgameMetadataSource source,
  String id,
  String name, {
  String? nameCn,
}) =>
    SourceCandidate(source: source, externalId: id, name: name, nameCn: nameCn);

void main() {
  test('Bangumi 与 VNDB 各一条精确同名：自动采用第一个源（Bangumi）的命中', () async {
    final GalgameScrapeController controller = GalgameScrapeController(
      adapters: <GalgameMetadataAdapter>[
        _FakeAdapter(GalgameMetadataSource.bgm, <SourceCandidate>[
          _candidate(
            GalgameMetadataSource.bgm,
            '250000',
            'ATRI -My Dear Moments-',
            nameCn: 'ATRI -我亲爱的时光-',
          ),
          _candidate(GalgameMetadataSource.bgm, '250001', 'ATRI 设定集'),
        ]),
        _FakeAdapter(GalgameMetadataSource.vndb, <SourceCandidate>[
          _candidate(
            GalgameMetadataSource.vndb,
            'v22758',
            'ATRI -My Dear Moments-',
          ),
        ]),
        _FakeAdapter(GalgameMetadataSource.dlsite, const <SourceCandidate>[]),
      ],
    );

    const String query = 'ATRI -My Dear Moments-';
    final List<SourceCandidate> candidates = (await controller.search(
      query,
    )).candidates;
    final SourceCandidate? picked = _batchPick(query, candidates);

    expect(picked, isNotNull);
    expect(picked!.source, GalgameMetadataSource.bgm);
    expect(picked.externalId, '250000');
  });

  test('只有一个源命中时照常采用', () async {
    final GalgameScrapeController controller = GalgameScrapeController(
      adapters: <GalgameMetadataAdapter>[
        _FakeAdapter(GalgameMetadataSource.bgm, const <SourceCandidate>[]),
        _FakeAdapter(GalgameMetadataSource.vndb, <SourceCandidate>[
          _candidate(GalgameMetadataSource.vndb, 'v2002', 'STEINS;GATE'),
        ]),
      ],
    );

    final SourceCandidate? picked = _batchPick(
      'STEINS;GATE',
      (await controller.search('STEINS;GATE')).candidates,
    );

    expect(picked?.externalId, 'v2002');
  });

  test('同一个源收录两条同名作品是真歧义：即使别的源唯一也留给单卡确认', () async {
    final GalgameScrapeController controller = GalgameScrapeController(
      adapters: <GalgameMetadataAdapter>[
        _FakeAdapter(GalgameMetadataSource.bgm, <SourceCandidate>[
          _candidate(GalgameMetadataSource.bgm, '1', 'Start'),
          _candidate(GalgameMetadataSource.bgm, '2', 'Start'),
        ]),
        _FakeAdapter(GalgameMetadataSource.vndb, <SourceCandidate>[
          _candidate(GalgameMetadataSource.vndb, 'v1', 'Start'),
        ]),
      ],
    );

    final SourceCandidate? picked = _batchPick(
      'Start',
      (await controller.search('Start')).candidates,
    );

    expect(picked, isNull);
  });
}

/// 假 adapter：searchByName 固定回给定候选。
class _FakeAdapter implements GalgameMetadataAdapter {
  _FakeAdapter(this.source, this.results);

  @override
  final GalgameMetadataSource source;

  final List<SourceCandidate> results;

  @override
  bool validateId(String id) => false;

  @override
  String externalUrl(String id) => 'https://example.com/$id';

  @override
  Future<GalgameMetadataDraft?> fetchById(String id) async => null;

  @override
  Future<List<SourceCandidate>> searchByName(String name, {int? limit}) async =>
      results;

  @override
  void close() {}
}
