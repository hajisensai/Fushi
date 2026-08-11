import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/torrent/video_resource_relevance.dart';

/// BUG-1548：资源搜索搜 `Hibike! Euphonium 2` 返回 S1/S3/剧场版/OVA 混排，且因为
/// 唯一排序是 seeders 降序，老季必然压在正确季之前。
void main() {
  group('parseVideoResourceIdentity', () {
    test('番剧标题后的裸数字按季号读，基础标题剥掉它', () {
      final VideoResourceTitleIdentity identity =
          parseVideoResourceIdentity('Hibike! Euphonium 2');

      expect(identity.season, 2);
      expect(identity.titles, contains('hibike euphonium'));
    });

    test('S3 / Season 3 与裸数字三种写法读出同一个季号', () {
      expect(
        parseVideoResourceIdentity(
          '[SubsPlease] Hibike! Euphonium S3 - 13 (1080p) [230618C3].mkv',
        ).season,
        3,
      );
      expect(
        parseVideoResourceIdentity(
          '[Judas] Hibike! Euphonium (Sound! Euphonium) (Season 3) '
          '[1080p][HEVC x265 10bit][Multi-Subs] (Batch)',
        ).season,
        3,
      );
      expect(
        parseVideoResourceIdentity(
          '[Maoam] Hibike! Euphonium 3 - BD Specials [1080p x264 FLAC]',
        ).season,
        3,
      );
    });

    test('并列的中/日/英标题各自入集合，季号一致时才认', () {
      final VideoResourceTitleIdentity identity = parseVideoResourceIdentity(
        '[VCB-Studio] Hibike! Euphonium 2 / 響け！ユーフォニアム 2 '
        '10-bit 1080p HEVC BDRip [Fin]',
      );

      expect(identity.season, 2);
      expect(identity.titles, contains('hibike euphonium'));
    });

    test('没有任何季号标记时是 null，不能当成第一季', () {
      expect(
        parseVideoResourceIdentity(
          '[Okay-Subs] Hibike! Euphonium Ensemble Contest (2023) (BD 1080p) '
          '| Tokubetsu-hen OVA | Sound! Euphonium',
        ).season,
        isNull,
      );
    });
  });

  group('rankVideoResourcesByRelevance', () {
    test('搜第 2 季时正确季排前，明确的其它季沉到底部', () {
      // 顺序与做种数刻意照抄用户截图：错季的做种数更高，旧排序下必然在前。
      final List<VideoResourceCandidate> input = <VideoResourceCandidate>[
        _candidate(
          '[Okay-Subs] Hibike! Euphonium Ensemble Contest (2023) (BD 1080p) '
          '| Tokubetsu-hen OVA | Sound! Euphonium',
          seeders: 62,
        ),
        _candidate(
          '[Judas] Hibike! Euphonium (Sound! Euphonium) (Season 3) '
          '[1080p][HEVC x265 10bit][Multi-Subs] (Batch)',
          seeders: 59,
        ),
        _candidate(
          '[SubsPlease] Hibike! Euphonium S3 - 13 (1080p) [230618C3].mkv',
          seeders: 43,
        ),
        _candidate(
          '[VCB-Studio] Hibike! Euphonium 2 / 響け！ユーフォニアム 2 '
          '10-bit 1080p HEVC BDRip [Fin]',
          seeders: 32,
        ),
        _candidate(
          '[Maoam] Hibike! Euphonium 3 - BD Specials [1080p x264 FLAC]',
          seeders: 19,
        ),
        _candidate(
          '[DBD-Raws][吹响吧！上低音号2/Hibike! Euphonium 2/響け！ユーフォニアム 2]'
          '[01-13TV全集+特典映像][1080P][BDRip]',
          seeders: 8,
        ),
      ];

      final List<VideoResourceCandidate> ranked = rankVideoResourcesByRelevance(
        input,
        query: 'Hibike! Euphonium 2',
      );

      // 第 2 季的两条（做种数最低的两条）必须冒到最前。
      expect(
        ranked.take(2).map((VideoResourceCandidate c) => c.title).toList(),
        containsAll(<Matcher>[contains('VCB-Studio'), contains('DBD-Raws')]),
      );
      // S3 / Season 3 / 3 的三条必须落到最后。
      expect(
        ranked.skip(3).map((VideoResourceCandidate c) => c.title).join('\n'),
        allOf(contains('Judas'), contains('SubsPlease'), contains('Maoam')),
      );
      // 只重排不丢弃：一条都不能少。
      expect(ranked, hasLength(input.length));
    });

    test('季号未知的条目不被惩罚到错季之下', () {
      final List<VideoResourceCandidate> ranked = rankVideoResourcesByRelevance(
        <VideoResourceCandidate>[
          _candidate('[Judas] Hibike! Euphonium (Season 3) (Batch)',
              seeders: 900),
          _candidate('[Okay-Subs] Hibike! Euphonium Ensemble Contest OVA',
              seeders: 1),
        ],
        query: 'Hibike! Euphonium 2',
      );

      expect(ranked.first.title, contains('Okay-Subs'));
    });

    test('调用方显式给季号时以它为准，忽略查询串里的数字', () {
      final List<VideoResourceCandidate> ranked = rankVideoResourcesByRelevance(
        <VideoResourceCandidate>[
          _candidate('[Group] Show 2 [1080p]', seeders: 900),
          _candidate('[Group] Show S03 [1080p]', seeders: 1),
        ],
        query: 'Show 2',
        season: 3,
      );

      expect(ranked.first.title, contains('S03'));
    });

    test('查询词不带季号时保持上游次序（providerPriority → seeders）', () {
      final List<VideoResourceCandidate> input = <VideoResourceCandidate>[
        _candidate('[Group] Show S03 [1080p]', seeders: 900),
        _candidate('[Group] Show 2 [1080p]', seeders: 100),
        _candidate('[Group] Show [1080p]', seeders: 10),
      ];

      final List<VideoResourceCandidate> ranked = rankVideoResourcesByRelevance(
        input,
        query: 'Show',
      );

      expect(
        ranked.map((VideoResourceCandidate c) => c.title).toList(),
        input.map((VideoResourceCandidate c) => c.title).toList(),
      );
    });
  });
}

int _instance = 0;

VideoResourceCandidate _candidate(String title, {required int seeders}) =>
    _RelevanceCandidate(title: title, seeders: seeders);

class _RelevanceCandidate extends VideoResourceCandidate {
  _RelevanceCandidate({required String title, required int seeders})
      : super(
          providerId: 'nyaa',
          providerInstanceId: 'nyaa',
          remoteId: '${_instance++}',
          title: title,
          providerPriority: 100,
          seeders: seeders,
        );
}
