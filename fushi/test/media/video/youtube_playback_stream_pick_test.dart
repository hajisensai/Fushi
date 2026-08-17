import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/youtube_source_resolver.dart';

/// 最小选流候选（TODO-1159）：pickPlaybackVideoStream 只依赖 height/codec/throttled，
/// 免构造重量级 youtube_explode 的 VideoOnlyStreamInfo。
class _FakeStream {
  const _FakeStream(this.height, this.codec, {this.throttled = false});
  final int height;
  final String codec;
  final bool throttled;
}

_FakeStream _pick(List<_FakeStream> streams, {int maxHeight = 1080}) {
  return pickPlaybackVideoStream<_FakeStream>(
    streams,
    heightOf: (_FakeStream s) => s.height,
    codecOf: (_FakeStream s) => s.codec,
    throttledOf: (_FakeStream s) => s.throttled,
    maxHeight: maxHeight,
  );
}

List<_FakeStream> _dedupe(List<_FakeStream> streams) {
  return dedupeVideoStreamsByHeight<_FakeStream>(
    streams,
    heightOf: (_FakeStream s) => s.height,
    codecOf: (_FakeStream s) => s.codec,
    throttledOf: (_FakeStream s) => s.throttled,
  );
}

void main() {
  group('youtubeVideoCodecPriority', () {
    test('avc1/H.264 最高优先(0)，前缀匹配', () {
      expect(youtubeVideoCodecPriority('avc1.640028'), 0);
      expect(youtubeVideoCodecPriority('AVC1.4D401F'), 0);
      expect(youtubeVideoCodecPriority('avc3.640028'), 0);
      expect(youtubeVideoCodecPriority('h264'), 0);
    });
    test('vp9=1, av01=2, 未知=3', () {
      expect(youtubeVideoCodecPriority('vp9'), 1);
      expect(youtubeVideoCodecPriority('vp09.00.10.08'), 1);
      expect(youtubeVideoCodecPriority('av01.0.08M.08'), 2);
      expect(youtubeVideoCodecPriority('av1'), 2);
      expect(youtubeVideoCodecPriority('theora'), 3);
      expect(youtubeVideoCodecPriority(''), 3);
    });
    test('avc1 严格优于 vp9 优于 av01', () {
      expect(
        youtubeVideoCodecPriority('avc1.640028') <
            youtubeVideoCodecPriority('vp9'),
        isTrue,
      );
      expect(
        youtubeVideoCodecPriority('vp9') <
            youtubeVideoCodecPriority('av01.0.08M.08'),
        isTrue,
      );
    });
  });

  group('pickPlaybackVideoStream', () {
    test('同 1080p 的 avc1/vp9/av01 → 选 avc1（编码优先修卡顿）', () {
      final List<_FakeStream> streams = <_FakeStream>[
        const _FakeStream(1080, 'av01.0.08M.08'),
        const _FakeStream(1080, 'vp9'),
        const _FakeStream(1080, 'avc1.640028'),
      ];
      // 打乱顺序也应稳定选 avc1（不依赖列表次序 / List.sort 稳定性）。
      expect(_pick(streams).codec, 'avc1.640028');
      expect(_pick(streams.reversed.toList()).codec, 'avc1.640028');
    });

    test('maxHeight cap：有 1080p 时不选更高（1440/2160）', () {
      final List<_FakeStream> streams = <_FakeStream>[
        const _FakeStream(2160, 'avc1.640028'),
        const _FakeStream(1440, 'avc1.640028'),
        const _FakeStream(1080, 'avc1.640028'),
        const _FakeStream(720, 'avc1.640028'),
      ];
      final _FakeStream chosen = _pick(streams);
      // 编码相同 → 取 cap 内最高清 = 1080（不越过 cap，也不顺带降到 720）。
      expect(chosen.height, 1080);
    });

    test('编码优先高于分辨率：avc1@720 胜过 av01@1080', () {
      final List<_FakeStream> streams = <_FakeStream>[
        const _FakeStream(1080, 'av01.0.08M.08'),
        const _FakeStream(720, 'avc1.640028'),
      ];
      final _FakeStream chosen = _pick(streams);
      expect(chosen.codec, 'avc1.640028');
      expect(chosen.height, 720);
    });

    test('无 avc1 时回落 vp9（优于 av01）', () {
      final List<_FakeStream> streams = <_FakeStream>[
        const _FakeStream(1080, 'av01.0.08M.08'),
        const _FakeStream(1080, 'vp9'),
        const _FakeStream(720, 'vp9'),
      ];
      final _FakeStream chosen = _pick(streams);
      expect(chosen.codec, 'vp9');
      expect(chosen.height, 1080);
    });

    test('同编码同分辨率 → 优先非 throttled', () {
      final List<_FakeStream> streams = <_FakeStream>[
        const _FakeStream(1080, 'avc1.640028', throttled: true),
        const _FakeStream(1080, 'avc1.640028', throttled: false),
      ];
      expect(_pick(streams).throttled, isFalse);
    });

    test('全部 > maxHeight（罕见）→ 退最低清', () {
      final List<_FakeStream> streams = <_FakeStream>[
        const _FakeStream(4320, 'avc1.640028'),
        const _FakeStream(2160, 'av01.0.08M.08'),
      ];
      final _FakeStream chosen = _pick(streams, maxHeight: 1080);
      expect(chosen.height, 2160);
    });

    test('空列表抛 StateError', () {
      expect(() => _pick(<_FakeStream>[]), throwsStateError);
    });
  });

  group('pickVideoStreamForTargetHeight (显式画质目标 = 画质菜单语义)', () {
    _FakeStream pickTarget(List<_FakeStream> streams, int target) {
      return pickVideoStreamForTargetHeight<_FakeStream>(
        streams,
        heightOf: (_FakeStream s) => s.height,
        codecOf: (_FakeStream s) => s.codec,
        throttledOf: (_FakeStream s) => s.throttled,
        targetHeight: target,
      );
    }

    test('目标 2160：分辨率优先越过编码（vp9@2160 胜 avc1@1080）', () {
      final List<_FakeStream> streams = <_FakeStream>[
        const _FakeStream(1080, 'avc1.640028'),
        const _FakeStream(2160, 'vp9'),
        const _FakeStream(1440, 'vp9'),
      ];
      final _FakeStream chosen = pickTarget(streams, 2160);
      expect(chosen.height, 2160);
      expect(chosen.codec, 'vp9');
    });

    test('同一目标高度内编码偏好仍生效（avc1 胜 vp9）', () {
      final List<_FakeStream> streams = <_FakeStream>[
        const _FakeStream(1080, 'vp9'),
        const _FakeStream(1080, 'avc1.640028'),
        const _FakeStream(720, 'avc1.640028'),
      ];
      final _FakeStream chosen = pickTarget(streams, 1080);
      expect(chosen.height, 1080);
      expect(chosen.codec, 'avc1.640028');
    });

    test('无恰好目标档：取 ≤目标 的最高档（目标 1440，只有 1080/720 → 1080）', () {
      final List<_FakeStream> streams = <_FakeStream>[
        const _FakeStream(1080, 'vp9'),
        const _FakeStream(720, 'avc1.640028'),
      ];
      expect(pickTarget(streams, 1440).height, 1080);
    });

    test('目标 480 降档省流：不选更高档', () {
      final List<_FakeStream> streams = <_FakeStream>[
        const _FakeStream(1080, 'avc1.640028'),
        const _FakeStream(480, 'avc1.640028'),
        const _FakeStream(360, 'avc1.640028'),
      ];
      expect(pickTarget(streams, 480).height, 480);
    });

    test('全部高于目标 → 退最低档（宁流畅勿卡死）', () {
      final List<_FakeStream> streams = <_FakeStream>[
        const _FakeStream(2160, 'vp9'),
        const _FakeStream(1440, 'vp9'),
      ];
      expect(pickTarget(streams, 480).height, 1440);
    });

    test('空列表抛 StateError', () {
      expect(() => pickTarget(<_FakeStream>[], 1080), throwsStateError);
    });
  });

  group('dedupeVideoStreamsByHeight (YouTube 画质档去重)', () {
    test('每个高度只留一条，按高度降序', () {
      final List<_FakeStream> streams = <_FakeStream>[
        const _FakeStream(720, 'avc1.640028'),
        const _FakeStream(1080, 'avc1.640028'),
        const _FakeStream(360, 'avc1.640028'),
        const _FakeStream(480, 'avc1.640028'),
      ];
      final List<_FakeStream> out = _dedupe(streams);
      expect(out.map((_FakeStream s) => s.height).toList(),
          <int>[1080, 720, 480, 360]);
    });

    test('同高度多编码 → 每档取编码最优（avc1 胜 vp9/av01）', () {
      final List<_FakeStream> streams = <_FakeStream>[
        const _FakeStream(1080, 'av01.0.08M.08'),
        const _FakeStream(1080, 'vp9'),
        const _FakeStream(1080, 'avc1.640028'),
        const _FakeStream(720, 'vp9'),
        const _FakeStream(720, 'av01.0.08M.08'),
      ];
      final List<_FakeStream> out = _dedupe(streams);
      expect(out.length, 2);
      expect(out[0].height, 1080);
      expect(out[0].codec, 'avc1.640028');
      expect(out[1].height, 720);
      expect(out[1].codec, 'vp9'); // 无 avc1 时 vp9 胜 av01
    });

    test('同高度同编码 → 非 throttled 胜出', () {
      final List<_FakeStream> streams = <_FakeStream>[
        const _FakeStream(1080, 'avc1.640028', throttled: true),
        const _FakeStream(1080, 'avc1.640028', throttled: false),
      ];
      final List<_FakeStream> out = _dedupe(streams);
      expect(out.length, 1);
      expect(out.single.throttled, isFalse);
    });

    test('空列表 → 空结果', () {
      expect(_dedupe(<_FakeStream>[]), isEmpty);
    });
  });
}
