import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/remote_online_subtitle_search.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_search_seed.dart';
import 'package:fushi/src/sync/video_remote_host.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi_engine/sync/video_remote_service.dart';

/// 手机遥控「在线搜索字幕」在电脑上的执行体：默认值（身份种子 / 集号 / 季号）只在
/// 检索词没被手机改过时生效；候选按不透明 id 记住、下载落进字幕目录。
void main() {
  late Directory dir;
  late _FakeProvider provider;
  late List<(String, String)> aligned;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('vr_online_subs');
    provider = _FakeProvider();
    aligned = <(String, String)>[];
  });
  tearDown(() => dir.delete(recursive: true));

  RemoteOnlineSubtitleSearch create({bool configured = true}) =>
      RemoteOnlineSubtitleSearch(
        registry: () async => configured
            ? VideoSubtitleRegistry(<VideoSubtitleProvider>[provider])
            : null,
        preferredLanguageFor: (String key) => key == 'frieren' ? 'en' : null,
        saveDirectory: () async => dir,
        aligner: (Uint8List bytes, String videoPath) async {
          aligned.add((String.fromCharCodes(bytes), videoPath));
          return Uint8List.fromList('aligned'.codeUnits);
        },
      );

  const RemoteOnlineSubtitleContext context = RemoteOnlineSubtitleContext(
    seriesQuery: 'Frieren',
    seed: SubtitleSearchSeed(
      anilistId: 154587,
      queries: <String>['葬送のフリーレン', 'Frieren'],
    ),
    episode: 3,
    season: 1,
  );

  Matcher remoteError(int status, String code) => isA<VideoRemoteException>()
      .having((VideoRemoteException e) => e.status, 'status', status)
      .having((VideoRemoteException e) => e.code, 'code', code);

  test(
    'defaults search with the scraped identity, episode and season',
    () async {
      final VideoRemoteOnlineSubtitleSearch result = await create().search(
        context,
      );
      expect(result.query, '葬送のフリーレン');
      expect(result.episode, 3);
      final VideoSubtitleSearchRequest request = provider.requests.single;
      expect(request.query, '葬送のフリーレン');
      expect(request.media?.anilistId, 154587);
      expect(request.alternateTitles, <String>['Frieren']);
      expect(request.season, 1);
      expect(request.episode, 3);
      // 系列记住的语言（en）排在前面。
      expect(
        result.candidates.map((VideoRemoteOnlineSubtitle c) => c.fileName),
        <String>['frieren_03.en.srt', 'frieren_03.ja.srt'],
      );
      expect(result.candidates.first.provider, 'fake');
      expect(result.candidates.first.language, 'en');
    },
  );

  test(
    'an edited query drops the identity and keeps the phone episode',
    () async {
      final VideoRemoteOnlineSubtitleSearch result = await create().search(
        context,
        query: 'Sousou no Frieren',
      );
      expect(result.query, 'Sousou no Frieren');
      expect(result.episode, isNull);
      final VideoSubtitleSearchRequest request = provider.requests.single;
      expect(request.media?.anilistId, isNull);
      expect(request.alternateTitles, isEmpty);
      expect(request.season, isNull);
      expect(request.episode, isNull);

      await create().search(context, query: 'Sousou no Frieren', episode: 5);
      expect(provider.requests.last.episode, 5);
    },
  );

  test('without a title nothing is searched', () async {
    final VideoRemoteOnlineSubtitleSearch result = await create().search(
      const RemoteOnlineSubtitleContext(
        seriesQuery: '',
        seed: SubtitleSearchSeed(),
      ),
    );
    expect(result.query, '');
    expect(result.candidates, isEmpty);
    expect(provider.requests, isEmpty);
  });

  test('missing sources and failed sources are reported as such', () async {
    await expectLater(
      create(configured: false).search(context),
      throwsA(remoteError(409, 'subtitle_source_missing')),
    );
    provider.fail = true;
    await expectLater(
      create().search(context),
      throwsA(remoteError(502, 'subtitle_search_failed')),
    );
  });

  test('download saves a safe file name and aligns local videos', () async {
    final RemoteOnlineSubtitleSearch search = create();
    final VideoRemoteOnlineSubtitleSearch result = await search.search(context);
    final String id = result.candidates.last.id;

    final String path = await search.download(id, videoPath: 'D:/v/ep3.mkv');
    expect(p(path), dir.path);
    expect(path.endsWith('ep3.ja.srt'), isTrue, reason: path);
    expect(File(path).readAsStringSync(), 'aligned');
    expect(aligned, <(String, String)>[('1\n00:00 ja', 'D:/v/ep3.mkv')]);

    // 远端流不对齐；同名文件不覆盖。
    final String second = await search.download(id);
    expect(second, isNot(path));
    expect(File(second).readAsStringSync(), '1\n00:00 ja');
    expect(aligned, hasLength(1));
  });

  test('ids die with the next search, failures are download errors', () async {
    final RemoteOnlineSubtitleSearch search = create();
    final String old = (await search.search(context)).candidates.first.id;
    await search.search(context);
    await expectLater(
      search.download(old),
      throwsA(remoteError(404, 'subtitle_candidate_missing')),
    );
    final String id = (await search.search(context)).candidates.first.id;
    provider.failDownload = true;
    await expectLater(
      search.download(id),
      throwsA(remoteError(502, 'subtitle_download_failed')),
    );
  });
}

String p(String path) => File(path).parent.path;

final class _FakeCandidate extends VideoSubtitleCandidate {
  _FakeCandidate(String fileName, String language)
    : super(
        providerId: 'fake',
        remoteId: fileName,
        fileName: fileName,
        language: language,
        providerPriority: 0,
        episode: 3,
      );
}

final class _FakeProvider implements VideoSubtitleProvider {
  final List<VideoSubtitleSearchRequest> requests =
      <VideoSubtitleSearchRequest>[];
  bool fail = false;
  bool failDownload = false;

  @override
  String get id => 'fake';

  @override
  int get priority => 0;

  @override
  bool get allowsFreeProbeDownload => false;

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) async {
    requests.add(request);
    if (fail) {
      return ProviderBatchResult<VideoSubtitleCandidate>(
        failures: <ExternalProviderFailure>[
          ExternalProviderFailure.fromException(
            providerId: id,
            operation: 'search',
            error: const SocketException('down'),
          ),
        ],
      );
    }
    return ProviderBatchResult<VideoSubtitleCandidate>.success(
      <VideoSubtitleCandidate>[
        _FakeCandidate('frieren_03.ja.srt', 'ja'),
        _FakeCandidate('frieren_03.en.srt', 'en'),
      ],
    );
  }

  @override
  Future<VideoSubtitleDownload> download(
    VideoSubtitleCandidate candidate,
  ) async {
    if (failDownload) throw StateError('gone');
    return VideoSubtitleDownload(
      bytes: Uint8List.fromList('1\n00:00 ${candidate.language}'.codeUnits),
      fileName: '../ep3.${candidate.language}.srt',
      language: candidate.language,
    );
  }

  @override
  void close() {}
}
