import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/youtube_source_resolver.dart';

/// TODO-1314（C7）：多分辨率缩略图候选回退的守卫。
///
/// - [youtubeThumbnailCandidates]：降序 maxres→sd→hq，末位恒 hqdefault；
/// - [resolveBestThumbnailUrl]：注入假 probe，断言取首个可用者、全失败退 hqdefault。
/// 真实 HEAD 探测（[resolveYoutubeMetadata] 内）依赖真网络，属外部契约，此处不联网测。
void main() {
  group('youtubeThumbnailCandidates', () {
    test('descending resolution, hqdefault last (always exists)', () {
      final List<String> c = youtubeThumbnailCandidates('vid123');
      expect(c.length, 3);
      expect(c[0], 'https://i.ytimg.com/vi/vid123/maxresdefault.jpg');
      expect(c[1], 'https://i.ytimg.com/vi/vid123/sddefault.jpg');
      expect(c[2], youtubeThumbnailUrl('vid123'));
      expect(c[2].contains('hqdefault'), isTrue);
    });
  });

  group('resolveBestThumbnailUrl', () {
    test('returns maxres when it exists (high wins)', () async {
      final List<String> probed = <String>[];
      final String best = await resolveBestThumbnailUrl(
        'v',
        probe: (String u) async {
          probed.add(u);
          return u.contains('maxresdefault');
        },
      );
      expect(best, 'https://i.ytimg.com/vi/v/maxresdefault.jpg');
      // 首个候选即命中 → 只探测一次，不多打网络。
      expect(probed.length, 1);
    });

    test('falls back to sd when maxres is missing', () async {
      final String best = await resolveBestThumbnailUrl(
        'v',
        probe: (String u) async => !u.contains('maxresdefault'),
      );
      expect(best, 'https://i.ytimg.com/vi/v/sddefault.jpg');
    });

    test('falls back to hqdefault when maxres and sd are missing', () async {
      final String best = await resolveBestThumbnailUrl(
        'v',
        probe: (String u) async => u.contains('hqdefault'),
      );
      expect(best, youtubeThumbnailUrl('v'));
    });

    test('all probes false -> still returns hqdefault (never no-cover)',
        () async {
      final String best = await resolveBestThumbnailUrl(
        'v',
        probe: (String u) async => false,
      );
      expect(best, youtubeThumbnailUrl('v'));
    });

    test('probe throwing is treated as missing, continues to next candidate',
        () async {
      final String best = await resolveBestThumbnailUrl(
        'v',
        probe: (String u) async {
          if (u.contains('maxresdefault')) throw Exception('network');
          return u.contains('sddefault');
        },
      );
      expect(best, 'https://i.ytimg.com/vi/v/sddefault.jpg');
    });
  });
}
