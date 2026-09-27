// 「整套下载」联网补全：AI 只能从正文列作品，列出的每一部都要回资料源核对。
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/ai/ai_video_franchise_assistant.dart';
import 'package:fushi/src/ai/web_knowledge.dart';
import 'package:fushi/src/media/video/discovery/video_franchise.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

class _FakeWeb extends WebKnowledgeClient {
  _FakeWeb(this.pages, {bool enabled = true})
    : super(
        sites: enabled
            ? <WebKnowledgeSite>[kBuiltinWebKnowledgeSites.first]
            : const <WebKnowledgeSite>[],
      );

  final List<WebKnowledgePage> pages;
  final List<String> queries = <String>[];

  @override
  Future<List<WebKnowledgePage>> search(
    String query, {
    int pagesPerSource = 1,
    int maxCharsPerPage = 12000,
  }) async {
    queries.add(query);
    return pages;
  }
}

WebKnowledgePage _page(
  String title,
  String text, {
  bool isList = false,
  String siteId = 'wikipedia_zh',
}) => WebKnowledgePage(
  site: kBuiltinWebKnowledgeSites.firstWhere(
    (WebKnowledgeSite site) => site.id == siteId,
  ),
  title: title,
  url: Uri.parse('https://example.org/$siteId/$title'),
  text: text,
  isList: isList,
);

VideoDiscoveryItem _item(
  String id,
  String title, {
  VideoMetadataMediaKind kind = VideoMetadataMediaKind.movie,
  int? year,
  String? originalTitle,
}) => VideoDiscoveryItem(
  reference: VideoMediaReference(
    providerId: 'mal',
    mediaId: id,
    mediaKind: kind,
    discoveryCategory: VideoDiscoveryCategory.anime,
    title: title,
    originalTitle: originalTitle,
    year: year,
  ),
);

void main() {
  group('parseAiFranchiseList', () {
    test('逐字段校验：坏一条丢一条', () {
      final List<AiFranchiseWork> works = parseAiFranchiseList('''
{"works": [
  {"title": "大雄的恐龙", "originalTitle": "のび太の恐竜", "year": 1980, "kind": "movie"},
  {"title": "哆啦A梦", "year": 2005, "kind": "tv"},
  {"title": "", "kind": "movie"},
  {"title": "游戏", "kind": "game"},
  {"title": "年份乱写", "year": 3000, "kind": "movie"}
]}''');
      expect(works.map((AiFranchiseWork w) => w.title), <String>[
        '大雄的恐龙',
        '哆啦A梦',
        '年份乱写',
      ]);
      expect(works.first.originalTitle, 'のび太の恐竜');
      expect(works.last.year, isNull);
    });

    test('抠不出 JSON → 空', () {
      expect(parseAiFranchiseList('sorry'), isEmpty);
    });
  });

  test('pickFranchisePages：列表类条目排前、每站一页、截断', () {
    final List<WebKnowledgePage> picked = pickFranchisePages(<WebKnowledgePage>[
      _page('哆啦A梦', 'x' * 20000, siteId: 'wikipedia_ja'),
      _page('哆啦A梦电影作品列表', 'list'),
      _page('哆啦A梦（系列）', 'other page of the same site'),
    ]);
    expect(picked.map((WebKnowledgePage p) => p.title), <String>[
      '哆啦A梦电影作品列表',
      '哆啦A梦',
    ]);
    expect(picked.last.text.length, kAiFranchiseMaxCharsPerPage);
  });

  test('pickFranchisePages：百科作品列表与 ANN 清单同档；TVmaze 降一档，不挤掉作品列表', () {
    final List<WebKnowledgePage> picked = pickFranchisePages(<WebKnowledgePage>[
      _page('哆啦A梦', 'plain', siteId: 'moegirl'),
      _page('TVmaze: 哆啦A梦', 'tvmaze', isList: true, siteId: 'tvmaze'),
      _page('哆啦A梦电影作品列表', 'list'),
      _page('Anime News Network: 哆啦A梦', 'ann', isList: true, siteId: 'ann'),
      _page('Anime News Network: ドラえもん', 'ann2', isList: true, siteId: 'ann'),
      _page('List of Doraemon films', 'en', siteId: 'wikipedia_en'),
    ]);
    expect(picked.map((WebKnowledgePage p) => p.title), <String>[
      '哆啦A梦电影作品列表',
      'Anime News Network: 哆啦A梦',
      'List of Doraemon films',
    ]);
  });

  group('aiFranchiseWorkMatches', () {
    const AiFranchiseWork work = AiFranchiseWork(
      title: '大雄的恐龙',
      originalTitle: 'のび太の恐竜',
      year: 1980,
      kind: VideoMetadataMediaKind.movie,
    );

    test('原名一致 + 年份 ±1 + 同类型', () {
      expect(
        aiFranchiseWorkMatches(
          work,
          _item('1', 'Nobita no Kyouryuu', originalTitle: 'のび太の恐竜', year: 1981),
        ),
        isTrue,
      );
    });

    test('同名重制版（年份差得远）、类型不同、标题对不上都不收', () {
      expect(
        aiFranchiseWorkMatches(
          work,
          _item('2', 'X', originalTitle: 'のび太の恐竜', year: 2006),
        ),
        isFalse,
      );
      expect(
        aiFranchiseWorkMatches(
          work,
          _item(
            '3',
            'X',
            originalTitle: 'のび太の恐竜',
            year: 1980,
            kind: VideoMetadataMediaKind.tv,
          ),
        ),
        isFalse,
      );
      expect(
        aiFranchiseWorkMatches(work, _item('4', '大雄的宇宙', year: 1980)),
        isFalse,
      );
    });
  });

  group('expandVideoFranchiseFromWeb', () {
    final VideoDiscoveryItem anchor = _item(
      'tv',
      '哆啦A梦',
      kind: VideoMetadataMediaKind.tv,
      year: 2005,
    );
    final VideoDiscoveryItem known1980 = _item(
      'm1',
      '大雄的恐龙',
      originalTitle: 'のび太の恐竜',
      year: 1980,
    );
    final VideoFranchise known = VideoFranchise(
      name: '哆啦A梦',
      series: <VideoDiscoveryItem>[anchor],
      movies: <VideoDiscoveryItem>[known1980],
    );

    test('只核对清单里没有的；核对不上的（AI 编的）不进清单', () async {
      final List<String> searched = <String>[];
      final VideoFranchise? result = await expandVideoFranchiseFromWeb(
        anchor: anchor,
        known: known,
        web: _FakeWeb(<WebKnowledgePage>[_page('哆啦A梦电影作品列表', '...')]),
        listWorks: (_, _) async => const <AiFranchiseWork>[
          AiFranchiseWork(
            title: '大雄的恐龙',
            originalTitle: 'のび太の恐竜',
            year: 1980,
            kind: VideoMetadataMediaKind.movie,
          ),
          AiFranchiseWork(
            title: '大雄的宇宙开拓史',
            originalTitle: 'のび太の宇宙開拓史',
            year: 1981,
            kind: VideoMetadataMediaKind.movie,
          ),
          AiFranchiseWork(
            title: '不存在的剧场版',
            year: 2099,
            kind: VideoMetadataMediaKind.movie,
          ),
        ],
        findCandidates: (AiFranchiseWork work) async {
          searched.add(work.title);
          if (work.year == 1981) {
            return <VideoDiscoveryItem>[
              _item(
                'm2',
                'Nobita no Uchuu Kaitakushi',
                originalTitle: 'のび太の宇宙開拓史',
                year: 1981,
              ),
            ];
          }
          return <VideoDiscoveryItem>[_item('zz', '别的作品', year: 2099)];
        },
      );
      expect(searched, <String>['大雄的宇宙开拓史', '不存在的剧场版']);
      expect(
        result!.movies.map((VideoDiscoveryItem e) => e.reference.mediaId),
        <String>['m1', 'm2'],
      );
      expect(result.series.single.reference.mediaId, 'tv');
    });

    test('没有年份的补全作品不收（泛名同名作品防线）', () async {
      final List<String> searched = <String>[];
      await expandVideoFranchiseFromWeb(
        anchor: anchor,
        known: known,
        web: _FakeWeb(<WebKnowledgePage>[_page('p', 't')]),
        listWorks: (_, _) async => const <AiFranchiseWork>[
          AiFranchiseWork(title: 'Air', kind: VideoMetadataMediaKind.movie),
        ],
        findCandidates: (AiFranchiseWork work) async {
          searched.add(work.title);
          return const <VideoDiscoveryItem>[];
        },
      );
      expect(searched, isEmpty);
    });

    test('来源全关 / AI 抛错 → 原样返回资料源结果', () async {
      final VideoFranchise? off = await expandVideoFranchiseFromWeb(
        anchor: anchor,
        known: known,
        web: _FakeWeb(const <WebKnowledgePage>[], enabled: false),
        listWorks: (_, _) async => fail('来源全关时不该问 AI'),
        findCandidates: (_) async => const <VideoDiscoveryItem>[],
      );
      expect(identical(off, known), isTrue);

      final VideoFranchise? failed = await expandVideoFranchiseFromWeb(
        anchor: anchor,
        known: known,
        web: _FakeWeb(<WebKnowledgePage>[_page('p', 't')]),
        listWorks: (_, _) async => throw StateError('ai down'),
        findCandidates: (_) async => const <VideoDiscoveryItem>[],
      );
      expect(identical(failed, known), isTrue);
    });

    test('资料源什么都没有时，联网补全也能从零建出系列', () async {
      final VideoFranchise? result = await expandVideoFranchiseFromWeb(
        anchor: anchor,
        known: null,
        web: _FakeWeb(<WebKnowledgePage>[_page('p', 't')]),
        listWorks: (_, _) async => const <AiFranchiseWork>[
          AiFranchiseWork(
            title: '大雄的恐龙',
            year: 1980,
            kind: VideoMetadataMediaKind.movie,
          ),
        ],
        findCandidates: (_) async => <VideoDiscoveryItem>[known1980],
      );
      expect(result!.series.single.reference.mediaId, 'tv');
      expect(result.movies.single.reference.mediaId, 'm1');
    });
  });
}
