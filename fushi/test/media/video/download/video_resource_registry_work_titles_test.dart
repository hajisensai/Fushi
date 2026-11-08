import 'package:test/test.dart';

import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

/// BUG-4243：AniList 上《BanG Dream! Ave Mujica》的英文名是副标题
/// `Ave Mujica - The Die is Cast -`，它被选成首选查询词后，registry 只拿这一个词算
/// 标题贴合度，写正式名的高种 BD / SubsPlease 发布全沉到低种逐集发布后面。作品自己
/// 的任一已知标题都该算贴合。
class _FixedProvider implements VideoResourceProvider {
  _FixedProvider(this.items);

  final List<VideoResourceCandidate> items;

  @override
  String get id => 'nyaa';

  @override
  Set<VideoDiscoveryCategory> get categories =>
      VideoDiscoveryCategory.values.toSet();

  @override
  int get priority => 0;

  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async => ProviderBatchResult<VideoResourceCandidate>.success(items);

  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) async =>
      throw UnimplementedError();

  @override
  void close() {}
}

class _Candidate extends VideoResourceCandidate {
  _Candidate(String title, {required int seeders})
    : super(
        providerId: 'nyaa',
        providerInstanceId: 'nyaa',
        remoteId: title,
        title: title,
        providerPriority: 100,
        seeders: seeders,
      );
}

/// AniList 169295 的实际形状：title = native = romaji，英文副标题与日文名进别名。
VideoMediaReference _aveMujica() => VideoMediaReference(
  providerId: 'anilist',
  mediaId: '169295',
  mediaKind: VideoMetadataMediaKind.tv,
  discoveryCategory: VideoDiscoveryCategory.anime,
  title: 'BanG Dream! Ave Mujica',
  originalTitle: 'BanG Dream! Ave Mujica',
  aliases: const <String>['Ave Mujica - The Die is Cast -', 'バンドリ！アヴェムジカ'],
  year: 2025,
);

final List<VideoResourceCandidate> _results = <VideoResourceCandidate>[
  _Candidate(
    '[ToonsHub] BanG Dream! Ave Mujica S01E13 1080p UNEXT WEB-DL AAC2.0 '
    'H.264 (Ave Mujica - The Die is Cast -)',
    seeders: 2,
  ),
  _Candidate(
    '[cappybara] BanG Dream! Ave Mujica (2025) - S01 (BD 1080p HEVC x265 '
    'Opus 2.0) | Ave Mujica: The Die is Cast',
    seeders: 54,
  ),
  _Candidate(
    '[SubsPlease] BanG Dream! Ave Mujica (01-13) (1080p) [Batch]',
    seeders: 19,
  ),
  _Candidate(
    '[SubsPlease] BanG Dream! Ave Mujica - 13 (1080p) [05B83F4C].mkv',
    seeders: 38,
  ),
];

void main() {
  test('首选词是英文副标题时，写正式名的高种发布仍按做种数排在前面', () async {
    final VideoResourceRegistry registry = VideoResourceRegistry(
      <VideoResourceProvider>[_FixedProvider(_results)],
    );
    addTearDown(registry.close);

    final VideoResourceSearchResult result = await registry.search(
      VideoResourceSearchRequest(
        media: _aveMujica(),
        query: 'Ave Mujica - The Die is Cast -',
      ),
    );

    expect(
      result.items.map((VideoResourceCandidate c) => c.seeders).toList(),
      <int>[54, 38, 19, 2],
      reason: '同一作品的已知标题都算贴合，同分回到做种数次序',
    );
  });
}
