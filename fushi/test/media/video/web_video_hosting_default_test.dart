import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/web_video_bridge.dart';
import 'package:fushi/src/media/video/web_video_hosting.dart';
import 'package:fushi/src/media/video/web_video_hosting_default.dart';

WebVideoPlaybackState _state({
  required int pos,
  int height = 1080,
  bool encrypted = true,
  bool paused = false,
  bool ad = false,
  String videoKey = 'v1',
}) => WebVideoPlaybackState(
  href: 'https://www.netflix.com/watch/1',
  videoKey: videoKey,
  hasVideo: true,
  positionMs: pos,
  paused: paused,
  durationMs: 3600000,
  videoWidth: height * 16 ~/ 9,
  videoHeight: height,
  rate: 1,
  fullscreen: false,
  title: 't',
  ad: ad,
  encrypted: encrypted,
);

WebVideoHosting _resolve(
  String site, {
  Object? manual,
  Object? legacy,
  Object? learned,
  bool underlay = true,
  double display = 2160,
}) => resolveWebVideoHosting(
  siteKey: site,
  manualBySite: manual,
  legacyGlobal: legacy,
  learnedBySite: learned,
  underlaySupported: underlay,
  displayHeightPx: display,
);

/// 以 1 秒一拍喂 [seconds] 秒正常播放，返回途中报出的结论。
List<WebVideoHostingVerdict> _play(
  WebVideoHostingProbe probe,
  int seconds, {
  int height = 1080,
  bool encrypted = true,
  int startMs = 0,
}) => <WebVideoHostingVerdict>[
  for (int i = 0; i <= seconds; i++)
    ?probe.observe(
      _state(pos: startMs + i * 1000, height: height, encrypted: encrypted),
    ),
];

void main() {
  group('站点键与 DRM 判据', () {
    test('去 www、小写；子域命中 DRM 表', () {
      expect(
        webVideoSiteKey(Uri.parse('https://WWW.Netflix.com/x')),
        'netflix.com',
      );
      expect(isKnownDrmWebVideoSite('netflix.com'), isTrue);
      expect(isKnownDrmWebVideoSite('video.amazon.co.jp'), isTrue);
      expect(isKnownDrmWebVideoSite('youtube.com'), isFalse);
      expect(isKnownDrmWebVideoSite('notnetflix.com'), isFalse);
    });
  });

  group('默认播放方式', () {
    test('没有任何记录：非 DRM 站默认 Fushi 播放', () {
      expect(_resolve('youtube.com'), WebVideoHosting.builtin);
    });

    test('预判：DRM ∧ 能底层合成 ∧ 显示器高于 1080 才默认原生', () {
      expect(_resolve('netflix.com'), WebVideoHosting.windowed);
      expect(_resolve('netflix.com', display: 1080), WebVideoHosting.builtin);
      expect(_resolve('netflix.com', display: 0), WebVideoHosting.builtin);
      expect(_resolve('netflix.com', underlay: false), WebVideoHosting.builtin);
    });

    test('实测结论优先于预判', () {
      expect(
        _resolve('netflix.com', learned: '{"netflix.com":"builtin"}'),
        WebVideoHosting.builtin,
      );
      expect(
        _resolve(
          'netflix.com',
          display: 1080,
          learned: '{"netflix.com":"windowed"}',
        ),
        WebVideoHosting.windowed,
      );
    });

    test('Fushi 播放里见过加密的未知站点按 DRM 预判', () {
      expect(
        _resolve('tver.jp', learned: '{"tver.jp":"drm"}'),
        WebVideoHosting.windowed,
      );
      expect(_resolve('tver.jp'), WebVideoHosting.builtin);
    });

    test('手动选择（按站点）最优先，其次旧全局偏好', () {
      expect(
        _resolve(
          'netflix.com',
          manual: '{"netflix.com":"builtin"}',
          legacy: 'windowed',
          learned: '{"netflix.com":"windowed"}',
        ),
        WebVideoHosting.builtin,
      );
      expect(
        _resolve('youtube.com', legacy: 'windowed'),
        WebVideoHosting.windowed,
      );
      expect(
        _resolve('netflix.com', legacy: 'builtin'),
        WebVideoHosting.builtin,
      );
    });

    test('坏偏好值忽略、不抛', () {
      expect(
        _resolve('netflix.com', manual: '{bad', learned: 42),
        WebVideoHosting.windowed,
      );
      expect(
        _resolve('netflix.com', manual: '{"netflix.com":1}'),
        WebVideoHosting.windowed,
      );
    });
  });

  group('实测结论合并', () {
    test('drm 不覆盖已有的原生 / Fushi 结论；相同结论不重写', () {
      const String learned = '{"netflix.com":"builtin"}';
      expect(
        mergeWebVideoHostingVerdict(
          learned,
          'netflix.com',
          WebVideoHostingVerdict.drm,
        ),
        isNull,
      );
      expect(
        mergeWebVideoHostingVerdict(
          learned,
          'netflix.com',
          WebVideoHostingVerdict.builtin,
        ),
        isNull,
      );
      expect(
        mergeWebVideoHostingVerdict(
          learned,
          'netflix.com',
          WebVideoHostingVerdict.windowed,
        ),
        '{"netflix.com":"windowed"}',
      );
      expect(
        mergeWebVideoHostingVerdict(
          null,
          'tver.jp',
          WebVideoHostingVerdict.drm,
        ),
        '{"tver.jp":"drm"}',
      );
    });

    test('手动选择按站点记、不动别的站', () {
      final String next = recordManualWebVideoHosting(
        '{"youtube.com":"windowed"}',
        'netflix.com',
        WebVideoHosting.builtin,
      );
      expect(decodeWebVideoSiteMap(next), <String, String>{
        'youtube.com': 'windowed',
        'netflix.com': 'builtin',
      });
    });
  });

  group('站点原生播放探针', () {
    test('加密流高于 1080 立即记原生，之后回落不改口', () {
      final WebVideoHostingProbe probe = WebVideoHostingProbe(
        hosting: WebVideoHosting.windowed,
      );
      expect(_play(probe, 5, height: 720), isEmpty);
      expect(
        probe.observe(_state(pos: 6000, height: 2160)),
        WebVideoHostingVerdict.windowed,
      );
      expect(_play(probe, 200, height: 1080, startMs: 7000), isEmpty);
    });

    test('稳定播够 90 秒仍 ≤1080 → 记 Fushi 播放（只报一次）', () {
      final WebVideoHostingProbe probe = WebVideoHostingProbe(
        hosting: WebVideoHosting.windowed,
      );
      expect(_play(probe, 89), isEmpty);
      expect(_play(probe, 5, startMs: 89000), <WebVideoHostingVerdict>[
        WebVideoHostingVerdict.builtin,
      ]);
      expect(_play(probe, 20, startMs: 95000), isEmpty);
    });

    test('没加密的站点播够也记 Fushi 播放', () {
      final WebVideoHostingProbe probe = WebVideoHostingProbe(
        hosting: WebVideoHosting.windowed,
      );
      expect(
        _play(probe, 95, height: 2160, encrypted: false),
        <WebVideoHostingVerdict>[WebVideoHostingVerdict.builtin],
      );
    });

    test('暂停 / 广告 / 跳转不算播放时长', () {
      final WebVideoHostingProbe probe = WebVideoHostingProbe(
        hosting: WebVideoHosting.windowed,
      );
      for (int i = 0; i < 200; i++) {
        probe.observe(_state(pos: i * 1000, paused: true));
        probe.observe(_state(pos: i * 1000 + 500, ad: true));
      }
      // 每拍跳 30 秒 = 跳转
      for (int i = 0; i < 50; i++) {
        probe.observe(_state(pos: i * 30000));
      }
      expect(probe.played, Duration.zero);
    });
  });

  group('Fushi 播放探针', () {
    test('见到加密流只记 drm；没加密什么都不记', () {
      final WebVideoHostingProbe enc = WebVideoHostingProbe(
        hosting: WebVideoHosting.builtin,
      );
      expect(_play(enc, 3), <WebVideoHostingVerdict>[
        WebVideoHostingVerdict.drm,
      ]);
      final WebVideoHostingProbe plain = WebVideoHostingProbe(
        hosting: WebVideoHosting.builtin,
      );
      expect(_play(plain, 200, encrypted: false), isEmpty);
    });
  });
}
