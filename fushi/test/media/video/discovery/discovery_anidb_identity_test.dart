import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/discovery/discovery_anidb_identity.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_resolver.dart';

/// 刮削重设计 P1：下载/订阅确认时的 AniDB 身份就地解析。
class _FakeAniDbProvider implements VideoMetadataProvider {
  _FakeAniDbProvider(this.results);

  final List<VideoMetadataWork> results;
  int searchCount = 0;
  final List<String> queries = <String>[];

  @override
  VideoMetadataProviderKind get providerKind => VideoMetadataProviderKind.anidb;

  @override
  bool get isAvailable => true;

  @override
  Future<List<VideoMetadataWork>> search(
    VideoMetadataSearchRequest request,
  ) async {
    searchCount++;
    queries.add(request.title);
    return results;
  }

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async =>
      results
          .where((VideoMetadataWork work) => work.ids
              .any((VideoMetadataId id) => id.value == lookup.externalId))
          .firstOrNull;

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
    VideoMetadataLookup lookup,
  ) async =>
      const <VideoMetadataSeason>[];

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  }) async =>
      const <VideoMetadataEpisode>[];

  @override
  void close() {}
}

VideoMetadataWork _work(String id, String title) => VideoMetadataWork(
      provider: VideoMetadataProviderKind.anidb,
      kind: VideoMetadataMediaKind.tv,
      title: title,
      ids: <VideoMetadataId>[
        VideoMetadataId(type: 'anidb', value: id, isDefault: true),
      ],
    );

VideoMediaReference _reference({
  VideoDiscoveryCategory category = VideoDiscoveryCategory.anime,
  int? anidbId,
}) =>
    VideoMediaReference(
      providerId: 'anilist',
      mediaId: '100',
      mediaKind: VideoMetadataMediaKind.tv,
      discoveryCategory: category,
      title: '某番剧中文名',
      originalTitle: 'ショー',
      aliases: const <String>['Show Romaji'],
      anidbId: anidbId,
    );

void main() {
  VideoMetadataProviderRegistry registryOf(_FakeAniDbProvider provider) =>
      VideoMetadataProviderRegistry(<VideoMetadataProvider>[provider]);

  test('已带 anidbId：直接 confirmed，不做任何搜索', () async {
    final _FakeAniDbProvider provider =
        _FakeAniDbProvider(<VideoMetadataWork>[_work('42', 'ショー')]);
    final AniDbDiscoveryIdentityResult result =
        await resolveAniDbDiscoveryIdentity(
      reference: _reference(anidbId: 7),
      registry: registryOf(provider),
    );
    expect(result.status, AniDbDiscoveryIdentityStatus.confirmed);
    expect(result.reference.anidbId, 7);
    expect(provider.searchCount, 0);
  });

  test('非 anime 条目不适用：AniDB 不收真人影视，不解析不打扰', () async {
    final _FakeAniDbProvider provider =
        _FakeAniDbProvider(<VideoMetadataWork>[_work('42', 'ショー')]);
    final AniDbDiscoveryIdentityResult result =
        await resolveAniDbDiscoveryIdentity(
      reference: _reference(category: VideoDiscoveryCategory.tv),
      registry: registryOf(provider),
    );
    expect(result.status, AniDbDiscoveryIdentityStatus.notApplicable);
    expect(provider.searchCount, 0);
  });

  test(
      '唯一严格命中：anidbId 与 externalIds 一起写进 reference；'
      '日文原名优先于本地化显示名', () async {
    final _FakeAniDbProvider provider =
        _FakeAniDbProvider(<VideoMetadataWork>[_work('42', 'ショー')]);
    final AniDbDiscoveryIdentityResult result =
        await resolveAniDbDiscoveryIdentity(
      reference: _reference(),
      registry: registryOf(provider),
    );
    expect(result.status, AniDbDiscoveryIdentityStatus.confirmed);
    expect(result.reference.anidbId, 42);
    expect(result.reference.externalIds['anidb'], '42');
    expect(result.reference.originalTitle, 'ショー', reason: '解析不许改写名字面，只补身份');
    expect(provider.queries.first, 'ショー', reason: '候选顺序 = 原名 → 别名 → 显示名');
  });

  test('多个候选通过严格门：ambiguous + 候选带 anidb lookup', () async {
    final _FakeAniDbProvider provider = _FakeAniDbProvider(<VideoMetadataWork>[
      _work('42', 'ショー'),
      _work('43', 'ショー'),
    ]);
    final AniDbDiscoveryIdentityResult result =
        await resolveAniDbDiscoveryIdentity(
      reference: _reference(),
      registry: registryOf(provider),
    );
    expect(result.status, AniDbDiscoveryIdentityStatus.ambiguous);
    expect(
      result.candidates.map((c) => c.lookup.externalId),
      containsAll(<String>['42', '43']),
    );
    expect(result.reference.anidbId, isNull, reason: '歧义绝不自动挑一个');
  });

  test('查无：notFound，reference 原样返回', () async {
    final _FakeAniDbProvider provider =
        _FakeAniDbProvider(const <VideoMetadataWork>[]);
    final AniDbDiscoveryIdentityResult result =
        await resolveAniDbDiscoveryIdentity(
      reference: _reference(),
      registry: registryOf(provider),
    );
    expect(result.status, AniDbDiscoveryIdentityStatus.notFound);
    expect(result.reference.anidbId, isNull);
  });
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final Iterator<T> iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
