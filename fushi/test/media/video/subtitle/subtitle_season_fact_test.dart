import 'dart:convert';
import 'dart:io';

import 'package:fushi/src/media/video/subtitle/subtitle_batch.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/jimaku_client.dart';
import 'package:fushi_engine/media/video/jimaku_subtitle_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_source_season.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// HBK-AUDIT-049：字幕候选的季号是**来源事实**，不是检索请求的**意图**。
///
/// 旧实现里 Jimaku 把请求季号原样抄成每个候选的季号：只点第二季时，文本回退搜到的
/// 第一季条目、文件名写着 `S01E02` 的字幕全被标成第二季，批量又优先信这份标签，
/// 第一季字幕就写进了第二季。面板只传选中那一季的成员，执行器还把多季合集当成单季，
/// 继续接收未标季的字幕。

const String _base = 'https://jimaku.cc';

/// 伪 Jimaku：AniList id 只挂在第一季条目上（第二季条目没人挂 id），文本搜索也只
/// 命中第一季条目——正是「请求第二季、拿回第一季条目」的真实回退路径。
class _FakeJimaku {
  _FakeJimaku({required this.entry, required this.files});

  final Map<String, Object?> entry;
  final List<String> files;
  final List<String> downloaded = <String>[];

  MockClient get client => MockClient((http.Request req) async {
    final String path = req.url.path;
    if (path == '/api/entries/search') {
      final String? byId = req.url.queryParameters['anilist_id'];
      if (byId != null && byId != '${entry['anilist_id']}') {
        return http.Response('[]', 200);
      }
      return http.Response(jsonEncode(<Object?>[entry]), 200);
    }
    if (path == '/api/entries/${entry['id']}/files') {
      return http.Response(
        jsonEncode(<Object?>[
          for (final String name in files)
            <String, Object?>{
              'url': '$_base/entry/${entry['id']}/download/$name',
              'name': name,
              'size': 100,
              'last_modified': '2023-05-06T07:08:09.000Z',
            },
        ]),
        200,
      );
    }
    if (path.startsWith('/entry/${entry['id']}/download/')) {
      final String name = Uri.decodeComponent(path.split('/').last);
      downloaded.add(name);
      return http.Response(
        '1\n00:00:01,000 --> 00:00:02,000\n$name\n',
        200,
        headers: <String, String>{'content-type': 'text/plain; charset=utf-8'},
      );
    }
    return http.Response('not found', 404);
  });
}

Map<String, Object?> _entry({
  required int id,
  required String name,
  int? anilistId,
}) => <String, Object?>{
  'id': id,
  'name': name,
  'anilist_id': anilistId,
  'flags': <String, Object?>{'anime': true},
  'last_modified': '2023-05-06T07:08:09.000Z',
};

VideoSubtitleSearchRequest _request({required int anilistId, int? season}) =>
    VideoSubtitleSearchRequest(
      media: VideoMediaReference(
        providerId: 'anilist',
        mediaId: '$anilistId',
        mediaKind: VideoMetadataMediaKind.tv,
        discoveryCategory: VideoDiscoveryCategory.anime,
        title: 'Show',
        anilistId: anilistId,
      ),
      query: 'Show',
      season: season,
      languages: const <String>['ja'],
    );

SubtitleBatchTarget _target(int index, String title) => SubtitleBatchTarget(
  bookUid: 'video/$index',
  title: title,
  videoPath: 'C:/video/$title.mkv',
  sortIndex: index,
  isStream: false,
);

class _Labelled extends VideoSubtitleCandidate {
  _Labelled(String name, {int? season, int? episode})
    : super(
        providerId: 'fake',
        remoteId: name,
        fileName: name,
        language: 'ja',
        providerPriority: 1,
        season: season,
        episode: episode,
      );
}

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('subtitle_season_fact_');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('Jimaku 候选季号 = 来源事实', () {
    test('请求第二季、文本回退拿回第一季条目：候选不再被标成第二季', () async {
      final _FakeJimaku fake = _FakeJimaku(
        entry: _entry(id: 1, name: 'Show', anilistId: 21355),
        files: const <String>['Show - 01.ja.srt', 'Show S01E02.ja.srt'],
      );
      final ProviderBatchResult<VideoSubtitleCandidate> result =
          await JimakuVideoSubtitleProvider(
            client: JimakuClient(apiKey: 'k', client: fake.client),
          ).search(_request(anilistId: 108632, season: 2));

      expect(
        <String, int?>{
          for (final VideoSubtitleCandidate c in result.items)
            c.fileName: c.season,
        },
        <String, int?>{'Show - 01.ja.srt': null, 'Show S01E02.ja.srt': 1},
      );
    });

    test('条目 AniList id 与请求作品对上：未写季号的文件才算请求的那一季，文件名仍优先', () async {
      final _FakeJimaku fake = _FakeJimaku(
        entry: _entry(id: 2, name: 'Show', anilistId: 108632),
        files: const <String>['Show - 01.ja.srt', 'Show S01E02.ja.srt'],
      );
      final ProviderBatchResult<VideoSubtitleCandidate> result =
          await JimakuVideoSubtitleProvider(
            client: JimakuClient(apiKey: 'k', client: fake.client),
          ).search(_request(anilistId: 108632, season: 2));

      expect(
        <String, int?>{
          for (final VideoSubtitleCandidate c in result.items)
            c.fileName: c.season,
        },
        <String, int?>{'Show - 01.ja.srt': 2, 'Show S01E02.ja.srt': 1},
      );
    });

    test('未确认身份的条目只认条目名里唯一的季度记号', () {
      expect(
        jimakuEntrySeason(
          const JimakuEntry(id: 3, name: 'Show 2nd Season'),
          _request(anilistId: 108632, season: 3),
        ),
        2,
      );
      expect(
        jimakuEntrySeason(
          const JimakuEntry(id: 4, name: 'Show'),
          _request(anilistId: 108632, season: 3),
        ),
        isNull,
      );
      expect(
        subtitleSourceEntrySeason(
          identityConfirmed: false,
          requestedSeason: 2,
          entryNames: const <String?>['Show 2nd Season Part 3'],
        ),
        isNull,
        reason: '多个记号不猜',
      );
    });
  });

  group('批量按真实季号过滤', () {
    test('来源标签与文件名冲突时信文件名', () {
      expect(
        subtitleCandidateSeason(_Labelled('Show S01E01.ja.srt', season: 2)),
        1,
      );
      expect(
        subtitleCandidateSeason(_Labelled('Show - 01.ja.srt', season: 2)),
        2,
      );
      expect(subtitleCandidateSeason(_Labelled('Show - 01.ja.srt')), isNull);
    });

    test('合集跨季、只点第二季：第一季条目的字幕一个都写不进去', () async {
      final _FakeJimaku fake = _FakeJimaku(
        entry: _entry(id: 1, name: 'Show', anilistId: 21355),
        files: const <String>['Show - 01.ja.srt', 'Show S01E02.ja.srt'],
      );
      final JimakuVideoSubtitleProvider provider = JimakuVideoSubtitleProvider(
        client: JimakuClient(apiKey: 'k', client: fake.client),
      );
      final List<VideoSubtitleCandidate> candidates = (await provider.search(
        _request(anilistId: 108632, season: 2),
      )).items;
      expect(candidates, hasLength(2));

      final List<SubtitleBatchItem> results = await runSubtitleBatch(
        registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
        candidates: candidates,
        targets: <SubtitleBatchTarget>[
          _target(0, 'Show S02E01'),
          _target(1, 'Show S02E02'),
        ],
        saveDirectory: tmp.path,
        collectionSpansSeasons: true,
      );

      expect(
        results.map((SubtitleBatchItem r) => r.status),
        <SubtitleBatchStatus>[
          SubtitleBatchStatus.noMatch,
          SubtitleBatchStatus.noMatch,
        ],
      );
      for (final SubtitleBatchItem item in results) {
        expect(item.message, 'subtitle season does not match target season');
        expect(item.subtitlePath, isNull);
      }
      expect(fake.downloaded, isEmpty);
      expect(tmp.listSync(), isEmpty);
    });

    test('单季合集：未标季的字幕照常配上，标了第一季的仍不配给第二季', () async {
      final _FakeJimaku fake = _FakeJimaku(
        entry: _entry(id: 1, name: 'Show', anilistId: 21355),
        files: const <String>['Show - 01.ja.srt', 'Show S01E02.ja.srt'],
      );
      final JimakuVideoSubtitleProvider provider = JimakuVideoSubtitleProvider(
        client: JimakuClient(apiKey: 'k', client: fake.client),
      );
      final List<VideoSubtitleCandidate> candidates = (await provider.search(
        _request(anilistId: 108632, season: 2),
      )).items;

      final List<SubtitleBatchItem> results = await runSubtitleBatch(
        registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
        candidates: candidates,
        targets: <SubtitleBatchTarget>[
          _target(0, 'Show S02E01'),
          _target(1, 'Show S02E02'),
        ],
        saveDirectory: tmp.path,
      );

      expect(results[0].status, SubtitleBatchStatus.done);
      expect(results[1].status, SubtitleBatchStatus.noMatch);
      expect(fake.downloaded, <String>['Show - 01.ja.srt']);
    });

    test('合集跨季的 PV·特典节（目标没有季号）不受影响', () {
      expect(
        subtitleSeasonAllowsUnseasoned(
          season: null,
          collectionSpansSeasons: true,
        ),
        isTrue,
      );
      expect(
        subtitleSeasonAllowsUnseasoned(season: 2, collectionSpansSeasons: true),
        isFalse,
      );
      expect(
        subtitleSeasonAllowsUnseasoned(
          season: 2,
          collectionSpansSeasons: false,
        ),
        isTrue,
      );
    });
  });
}
