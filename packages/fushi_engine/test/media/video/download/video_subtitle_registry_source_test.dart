import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry_source.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:test/test.dart';

void main() {
  group('PerUseVideoSubtitleRegistrySource', () {
    test('每次借都现建一份，归还即关；重复归还只关一次', () {
      final List<_CountingProvider> built = <_CountingProvider>[];
      final PerUseVideoSubtitleRegistrySource source =
          PerUseVideoSubtitleRegistrySource(() {
            final _CountingProvider provider = _CountingProvider();
            built.add(provider);
            return VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]);
          });

      final VideoSubtitleRegistryLease first = source.acquire()!;
      final VideoSubtitleRegistryLease second = source.acquire()!;
      expect(built, hasLength(2));
      expect(identical(first.registry, second.registry), isFalse);

      first.release();
      first.release();
      expect(built.first.closeCalls, 1);
      expect(built.last.closeCalls, 0, reason: '另一份还借着，不受影响');
      second.release();
      expect(built.last.closeCalls, 1);
    });

    test('装出空 registry = 没配字幕：返回 null', () {
      int builds = 0;
      final PerUseVideoSubtitleRegistrySource source =
          PerUseVideoSubtitleRegistrySource(() {
            builds++;
            return VideoSubtitleRegistry(const <VideoSubtitleProvider>[]);
          });
      expect(source.acquire(), isNull);
      expect(builds, 1);
    });
  });

  test('FixedVideoSubtitleRegistrySource：总借同一份，归还不关（生命周期归构造方）', () {
    final _CountingProvider provider = _CountingProvider();
    final VideoSubtitleRegistry registry = VideoSubtitleRegistry(
      <VideoSubtitleProvider>[provider],
    );
    final FixedVideoSubtitleRegistrySource source =
        FixedVideoSubtitleRegistrySource(registry);
    final VideoSubtitleRegistryLease lease = source.acquire()!;
    expect(identical(lease.registry, registry), isTrue);
    lease.release();
    expect(provider.closeCalls, 0);
  });
}

class _CountingProvider implements VideoSubtitleProvider {
  int closeCalls = 0;

  @override
  String get id => 'counting';

  @override
  int get priority => 0;

  @override
  bool get allowsFreeProbeDownload => false;

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) async => ProviderBatchResult<VideoSubtitleCandidate>.success(
    const <VideoSubtitleCandidate>[],
  );

  @override
  Future<VideoSubtitleDownload> download(VideoSubtitleCandidate candidate) =>
      throw UnimplementedError();

  @override
  void close() => closeCalls++;
}
