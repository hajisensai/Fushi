import 'package:test/test.dart';
import 'package:fushi_engine/media/video/youtube_source_resolver.dart';

/// TODO-1314（C7）/ BUG-5614：多分辨率缩略图候选回退的守卫。
///
/// - [youtubeThumbnailCandidates]：maxres→mq，末位恒 mqdefault，不含 4:3 带黑边的 sd / hq；
/// - [resolveBestThumbnailUrl]：注入假 probe，断言取首个可用者、全失败退 mqdefault；
/// - [youtubeHdThumbnailUrl] / [youtubeThumbnailFallbackUrl]：音乐封面同步给高清 URL，
///   取字节层遇 404 按回退规则换到恒存在的 mqdefault。
/// 真实 HEAD 探测（[resolveYoutubeMetadata] 内）依赖真网络，属外部契约，此处不联网测。
void main() {
  group('youtubeThumbnailCandidates', () {
    test('maxres first, mqdefault last (always exists), no 4:3 variants', () {
      final List<String> c = youtubeThumbnailCandidates('vid123');
      expect(c, <String>[
        'https://i.ytimg.com/vi/vid123/maxresdefault.jpg',
        'https://i.ytimg.com/vi/vid123/mqdefault.jpg',
      ]);
      expect(c.last, youtubeThumbnailUrl('vid123'));
      expect(c.any((String u) => u.contains('hqdefault')), isFalse);
      expect(c.any((String u) => u.contains('sddefault')), isFalse);
    });
  });

  group('youtubeHdThumbnailUrl', () {
    test('builds maxresdefault url', () {
      expect(
        youtubeHdThumbnailUrl('S7S4gUjXKjo'),
        'https://i.ytimg.com/vi/S7S4gUjXKjo/maxresdefault.jpg',
      );
    });
  });

  group('youtubeThumbnailFallbackUrl', () {
    test('HD / 4:3 variants fall back to mqdefault of the same video', () {
      for (final String name in <String>[
        'maxresdefault.jpg',
        'hq720.jpg',
        'sddefault.jpg',
        'hqdefault.jpg',
      ]) {
        expect(
          youtubeThumbnailFallbackUrl(
            'https://i.ytimg.com/vi/S7S4gUjXKjo/$name',
          ),
          'https://i.ytimg.com/vi/S7S4gUjXKjo/mqdefault.jpg',
          reason: name,
        );
      }
      expect(
        youtubeThumbnailFallbackUrl(
          'https://i.ytimg.com/vi_webp/S7S4gUjXKjo/maxresdefault.webp',
        ),
        'https://i.ytimg.com/vi/S7S4gUjXKjo/mqdefault.jpg',
      );
      expect(
        youtubeThumbnailFallbackUrl(youtubeHdThumbnailUrl('S7S4gUjXKjo')),
        youtubeThumbnailUrl('S7S4gUjXKjo'),
      );
    });

    test('mqdefault itself has nothing lower to fall back to', () {
      expect(
        youtubeThumbnailFallbackUrl(youtubeThumbnailUrl('S7S4gUjXKjo')),
        isNull,
      );
    });

    test('non-YouTube or malformed urls are not touched', () {
      expect(
        youtubeThumbnailFallbackUrl('https://example.com/vi/S7S4gUjXKjo/a.jpg'),
        isNull,
      );
      expect(
        youtubeThumbnailFallbackUrl('https://i.ytimg.com/vi/short/a.jpg'),
        isNull,
      );
      expect(
        youtubeThumbnailFallbackUrl('https://i.ytimg.com/an/channel.jpg'),
        isNull,
      );
      expect(youtubeThumbnailFallbackUrl('not a url'), isNull);
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

    test('falls back to mqdefault when maxres is missing', () async {
      final String best = await resolveBestThumbnailUrl(
        'v',
        probe: (String u) async => !u.contains('maxresdefault'),
      );
      expect(best, 'https://i.ytimg.com/vi/v/mqdefault.jpg');
    });

    test(
      'all probes false -> still returns mqdefault (never no-cover)',
      () async {
        final String best = await resolveBestThumbnailUrl(
          'v',
          probe: (String u) async => false,
        );
        expect(best, youtubeThumbnailUrl('v'));
      },
    );

    test(
      'probe throwing is treated as missing, continues to next candidate',
      () async {
        final String best = await resolveBestThumbnailUrl(
          'v',
          probe: (String u) async {
            if (u.contains('maxresdefault')) throw Exception('network');
            return u.contains('mqdefault');
          },
        );
        expect(best, 'https://i.ytimg.com/vi/v/mqdefault.jpg');
      },
    );
  });
}
