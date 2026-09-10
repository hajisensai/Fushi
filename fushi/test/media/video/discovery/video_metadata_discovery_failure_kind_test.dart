// BUG-2430：同一个发现域里曾有两条 failure 翻译路径。TMDB / AniList 走认得
// [VideoMetadataNetworkException] 的那条（429 → rateLimited，带 statusCode /
// retryAfter），MAL 走裸的 [ExternalProviderFailure.fromException]，它只认
// TimeoutException / ClientException / FormatException，于是限流、5xx、鉴权失败
// 被一律压成 unknown 并丢掉状态码——UI 只能把「被限流，等一会儿再搜」统一显示成
// 「来源暂不可用」。MAL 走 Jikan 公共接口、1 秒一发且不重试，429 是常态。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/discovery/video_metadata_discovery_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_transport.dart';

class _ThrowingMetadataProvider implements VideoMetadataProvider {
  _ThrowingMetadataProvider(this.error);

  final Exception error;

  @override
  VideoMetadataProviderKind get providerKind => VideoMetadataProviderKind.mal;

  @override
  bool get isAvailable => true;

  @override
  Future<List<VideoMetadataWork>> search(
    VideoMetadataSearchRequest request,
  ) async =>
      throw error;

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async =>
      null;

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

VideoMetadataSearchDiscoveryProvider _provider(Exception error) =>
    VideoMetadataSearchDiscoveryProvider(
      provider: _ThrowingMetadataProvider(error),
      categories: const <VideoDiscoveryCategory>{VideoDiscoveryCategory.anime},
    );

Future<ExternalProviderFailure> _searchFailure(Exception error) async {
  final result = await _provider(
    error,
  ).search(const VideoDiscoveryRequest(query: '别当欧尼酱了'));
  expect(result.failures, isNotEmpty);
  return result.failures.first;
}

void main() {
  test('Jikan 429 记为限流而不是 unknown，并带上 status/retryAfter', () async {
    final ExternalProviderFailure failure = await _searchFailure(
      const VideoMetadataNetworkException(
        'rate limited',
        statusCode: 429,
        retryAfter: Duration(seconds: 5),
      ),
    );
    expect(failure.providerId, 'mal');
    expect(failure.kind, ExternalProviderFailureKind.rateLimited);
    expect(failure.statusCode, 429);
    expect(failure.retryAfter, const Duration(seconds: 5));
    expect(failure.retryable, isTrue);
    // 消息里不得出现 URL / 凭据，只留状态码。
    expect(failure.message, isNot(contains('http')));
  });

  test('鉴权与服务端错误各归其类', () async {
    expect(
      (await _searchFailure(
        const VideoMetadataNetworkException('nope', statusCode: 401),
      ))
          .kind,
      ExternalProviderFailureKind.unauthorized,
    );
    expect(
      (await _searchFailure(
        const VideoMetadataNetworkException('boom', statusCode: 503),
      ))
          .kind,
      ExternalProviderFailureKind.network,
    );
    expect(
      (await _searchFailure(
        const VideoMetadataNetworkException('gone', statusCode: 404),
      ))
          .kind,
      ExternalProviderFailureKind.notFound,
    );
  });

  test('非传输异常仍走通用分类', () async {
    expect(
      (await _searchFailure(const FormatException('bad json'))).kind,
      ExternalProviderFailureKind.invalidResponse,
    );
  });

  test('搜索来源带用户可见名，横幅不必印原始 id', () {
    expect(_provider(const FormatException('x')).id, 'mal');
    expect(
      _provider(const FormatException('x')).displayName,
      isNot('mal'),
      reason: 'displayName 必须是品牌名，不是接线标识',
    );
  });
}
