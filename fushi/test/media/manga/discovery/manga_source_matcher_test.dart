import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/discovery/manga_discovery_models.dart';
import 'package:fushi/src/media/manga/discovery/manga_source_matcher.dart';

/// 跨来源自动匹配编排：每源取最佳、低分丢弃、单源失败不拖累、按分排序、
/// 查询词按来源语言排序（日文源先原文）。
void main() {
  const MangaDiscoveryEntry entry = MangaDiscoveryEntry(
    anilistId: 1,
    titleNative: '葬送のフリーレン',
    titleRomaji: 'Sousou no Frieren',
    titleEnglish: "Frieren: Beyond Journey's End",
  );

  MangaMatchSource source(
    String id,
    String language,
    Future<List<MangaMatchHit>> Function(String query) search,
  ) =>
      MangaMatchSource(id: id, name: id, language: language, search: search);

  test('mangaMatchQueriesFor：日文源先原文，英文源先英文', () {
    expect(
      mangaMatchQueriesFor(entry, 'ja'),
      <String>[
        '葬送のフリーレン',
        'Sousou no Frieren',
        "Frieren: Beyond Journey's End",
      ],
    );
    expect(mangaMatchQueriesFor(entry, 'en').first,
        "Frieren: Beyond Journey's End");
  });

  test('每源留最佳命中，低于阈值的来源被整个丢弃，结果按分降序', () async {
    final List<MangaSourceMatch> matches = await matchMangaAcrossSources(
      entry: entry,
      sources: <MangaMatchSource>[
        source(
            'close',
            'ja',
            (String query) async => <MangaMatchHit>[
                  const MangaMatchHit(title: '葬送のフリーレン 第1巻', payload: 'a'),
                  const MangaMatchHit(title: 'ワンピース', payload: 'noise'),
                ]),
        source(
            'exact',
            'ja',
            (String query) async => <MangaMatchHit>[
                  const MangaMatchHit(title: '葬送のフリーレン', payload: 'b'),
                ]),
        source(
            'unrelated',
            'ja',
            (String query) async => <MangaMatchHit>[
                  const MangaMatchHit(title: 'ベルセルク', payload: 'c'),
                ]),
      ],
    );
    expect(matches, hasLength(2));
    expect(matches.first.source.id, 'exact');
    expect(matches.first.score, 1.0);
    expect(matches.last.source.id, 'close');
    expect(matches.last.hit.payload, 'a');
  });

  test('单源抛错静默跳过，不拖累其余来源', () async {
    final List<MangaSourceMatch> matches = await matchMangaAcrossSources(
      entry: entry,
      sources: <MangaMatchSource>[
        source('broken', 'ja', (String query) async {
          throw StateError('Cloudflare');
        }),
        source(
            'ok',
            'ja',
            (String query) async => <MangaMatchHit>[
                  const MangaMatchHit(title: '葬送のフリーレン', payload: 'x'),
                ]),
      ],
    );
    expect(matches, hasLength(1));
    expect(matches.single.source.id, 'ok');
  });

  test('首个查询空结果时换下一个标题重试，有结果但不像则不再叠加查询', () async {
    final List<String> queries = <String>[];
    final List<MangaSourceMatch> matches = await matchMangaAcrossSources(
      entry: entry,
      sources: <MangaMatchSource>[
        source('en-only', 'en', (String query) async {
          queries.add(query);
          if (query == "Frieren: Beyond Journey's End") {
            return const <MangaMatchHit>[];
          }
          return const <MangaMatchHit>[
            MangaMatchHit(title: 'Sousou no Frieren', payload: 'hit'),
          ];
        }),
      ],
    );
    expect(queries.first, "Frieren: Beyond Journey's End");
    expect(matches.single.hit.payload, 'hit');
  });

  test('无标题或无来源返回空表', () async {
    expect(
      await matchMangaAcrossSources(
        entry: const MangaDiscoveryEntry(anilistId: 2),
        sources: <MangaMatchSource>[
          source('any', 'ja', (String query) async {
            fail('无标题不应发起搜索');
          }),
        ],
      ),
      isEmpty,
    );
    expect(
      await matchMangaAcrossSources(
        entry: entry,
        sources: const <MangaMatchSource>[],
      ),
      isEmpty,
    );
  });
}
