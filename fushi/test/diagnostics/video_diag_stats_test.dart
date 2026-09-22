import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/diagnostics/video_diag_stats.dart';

/// 两个纯聚合器的契约。这些断言是「卡顿结论」的地基：速率算错、把读不到当成 0、
/// 或者把换片的计数器归零当成负增量，都会让日志指向完全相反的原因。
void main() {
  group('VideoMpvStatsSnapshot 解析', () {
    test('从字符串属性解析（libmpv 经 FFI 回来的常是字符串）', () {
      final VideoMpvStatsSnapshot s =
          VideoMpvStatsSnapshot.fromProperties(<String, Object?>{
            'vo-delayed-frame-count': '12',
            'frame-drop-count': '3',
            'decoder-frame-drop-count': '0',
            'avsync': '-0.004',
            'demuxer-cache-duration': '18.5',
            'hwdec-current': 'd3d11va',
            'current-vo': 'gpu',
            'width': '1920',
            'height': '1080',
            'paused-for-cache': 'no',
          });
      expect(s.voDelayedFrames, 12);
      expect(s.voDroppedFrames, 3);
      expect(s.decoderDroppedFrames, 0);
      expect(s.avsync, closeTo(-0.004, 1e-9));
      expect(s.demuxerCacheSeconds, closeTo(18.5, 1e-9));
      expect(s.hwdec, 'd3d11va');
      expect(s.currentVo, 'gpu');
      expect(s.videoWidth, 1920);
      expect(s.videoHeight, 1080);
      expect(s.pausedForCache, isFalse);
    });

    test('缺失 / 不可解析的属性落 null，绝不拿 0 冒充', () {
      final VideoMpvStatsSnapshot s = VideoMpvStatsSnapshot.fromProperties(
        <String, Object?>{
          'frame-drop-count': '',
          'avsync': 'nonsense',
          'hwdec-current': 'null',
        },
      );
      expect(s.voDelayedFrames, isNull, reason: '键根本没给');
      expect(s.voDroppedFrames, isNull, reason: '空串不是 0');
      expect(s.avsync, isNull);
      expect(s.hwdec, isNull, reason: '字面 "null" 当作没有');
      // 输出里以 `-` 呈现，读日志的人能区分「读不到」与「真是 0」。
      expect(s.describeSince(null, 1000), contains('late=-'));
      expect(s.describeSince(null, 1000), contains('vo-drop=-'));
    });

    test('properties 清单覆盖 fromProperties 用到的每个键', () {
      // 两处各写一份字符串是漂移的温床：清单漏一个，那个字段就永远是 null，
      // 而且没有任何报错。
      const List<String> used = <String>[
        'vo-delayed-frame-count',
        'frame-drop-count',
        'decoder-frame-drop-count',
        'avsync',
        'demuxer-cache-duration',
        'cache-speed',
        'video-bitrate',
        'audio-bitrate',
        'estimated-vf-fps',
        'container-fps',
        'estimated-display-fps',
        'hwdec-current',
        'current-vo',
        'width',
        'height',
        'video-params/pixelformat',
        'paused-for-cache',
      ];
      for (final String key in used) {
        expect(VideoMpvStatsSnapshot.properties, contains(key));
      }
      expect(VideoMpvStatsSnapshot.properties.length, used.length);
    });
  });

  group('describeSince 增量与速率', () {
    test('首个窗口（无基线）只给瞬时值，不编造速率', () {
      const VideoMpvStatsSnapshot cur = VideoMpvStatsSnapshot(
        voDelayedFrames: 10,
        voDroppedFrames: 2,
      );
      final String line = cur.describeSince(null, 1000);
      expect(line, contains('late=10'));
      expect(line.contains('/s'), isFalse);
    });

    test('给出本窗增量与每秒速率', () {
      const VideoMpvStatsSnapshot prev = VideoMpvStatsSnapshot(
        voDelayedFrames: 10,
        voDroppedFrames: 2,
      );
      const VideoMpvStatsSnapshot cur = VideoMpvStatsSnapshot(
        voDelayedFrames: 28,
        voDroppedFrames: 2,
      );
      final String line = cur.describeSince(prev, 2000);
      // 18 帧 / 2 秒 = 9.0/s
      expect(line, contains('late=+18(9.0/s,tot=28)'));
      expect(line, contains('vo-drop=+0(0.0/s,tot=2)'));
    });

    test('换片导致计数器回绕时负增量按 0（与黑闪判据同口径）', () {
      const VideoMpvStatsSnapshot prev = VideoMpvStatsSnapshot(
        voDelayedFrames: 900,
      );
      const VideoMpvStatsSnapshot cur = VideoMpvStatsSnapshot(
        voDelayedFrames: 3,
      );
      final String line = cur.describeSince(prev, 1000);
      expect(line, contains('late=+0('), reason: '换片重置不得被读成一瞬间的负数/巨量迟帧');
    });
  });

  group('isDegradedSince（提级 warn 的判据）', () {
    test('三个计数器合计超过阈值即降级', () {
      const VideoMpvStatsSnapshot prev = VideoMpvStatsSnapshot(
        voDelayedFrames: 0,
        voDroppedFrames: 0,
        decoderDroppedFrames: 0,
      );
      const VideoMpvStatsSnapshot bad = VideoMpvStatsSnapshot(
        voDelayedFrames: 4,
        voDroppedFrames: 3,
        decoderDroppedFrames: 2,
      );
      expect(bad.isDegradedSince(prev, 1000), isTrue, reason: '合计 9/s >= 8');
      const VideoMpvStatsSnapshot ok = VideoMpvStatsSnapshot(
        voDelayedFrames: 1,
        voDroppedFrames: 1,
        decoderDroppedFrames: 0,
      );
      expect(ok.isDegradedSince(prev, 1000), isFalse);
    });

    test('无基线不判降级（首窗不误报）', () {
      const VideoMpvStatsSnapshot cur = VideoMpvStatsSnapshot(
        voDelayedFrames: 9999,
      );
      expect(cur.isDegradedSince(null, 1000), isFalse);
    });
  });

  group('静态部分', () {
    test('静态字段变了才认为需要重打一行', () {
      const VideoMpvStatsSnapshot a = VideoMpvStatsSnapshot(
        hwdec: 'd3d11va',
        currentVo: 'gpu',
      );
      const VideoMpvStatsSnapshot sameStatic = VideoMpvStatsSnapshot(
        hwdec: 'd3d11va',
        currentVo: 'gpu',
        voDelayedFrames: 42, // 动态量变化不算静态变化
      );
      const VideoMpvStatsSnapshot hwdecLost = VideoMpvStatsSnapshot(
        hwdec: 'no',
        currentVo: 'gpu',
      );
      expect(a.staticDiffersFrom(null), isTrue, reason: '第一次必须打');
      expect(sameStatic.staticDiffersFrom(a), isFalse);
      expect(hwdecLost.staticDiffersFrom(a), isTrue, reason: '硬解掉回软解是要看到的事件');
    });
  });

  group('VideoFrameTimingAggregator', () {
    // 一个数 = 关键路径耗时（全放 build、raster 为 0）。判据是 max(build, raster)：
    // 之前按 t/2 均分成 build/raster 构造，正好掩盖了「求和判据」的误报。
    List<VideoFrameSample> framesOf(List<int> criticalMicros) {
      return criticalMicros
          .map((int t) => VideoFrameSample(buildMicros: t, rasterMicros: 0))
          .toList();
    }

    test('build 与 raster 流水线并行：各自在预算内就不是 jank（不求和）', () {
      // 9ms + 9ms 求和 18ms 会误判成超预算，实际每条线都赶得上。
      const VideoFrameSample smooth = VideoFrameSample(
        buildMicros: 9000,
        rasterMicros: 9000,
      );
      expect(smooth.criticalMicros, 9000);
      final VideoFrameTimingAggregator agg = VideoFrameTimingAggregator()
        ..addAll(List<VideoFrameSample>.filled(4, smooth));
      expect(
        agg.isJankyWindow(),
        isFalse,
        reason: 'DevTools 口径：build / raster 各自 ≤ 16.7ms 即流畅',
      );
      final String line = VideoFrameTimingAggregator.summarise(
        List<VideoFrameSample>.filled(4, smooth),
        1000,
      );
      expect(line, contains('jank=0'));
      expect(line, contains('severe=0'));
      // 反例：单条线超预算才算。
      const VideoFrameSample slowRaster = VideoFrameSample(
        buildMicros: 2000,
        rasterMicros: 20000,
      );
      expect(slowRaster.criticalMicros, 20000);
      expect(
        VideoFrameTimingAggregator.summarise(<VideoFrameSample>[
          slowRaster,
        ], 1000),
        contains('jank=1'),
      );
    });

    test('percentile 用最近秩，空表为 0', () {
      expect(VideoFrameTimingAggregator.percentile(<int>[], 0.5), 0);
      expect(VideoFrameTimingAggregator.percentile(<int>[7], 0.95), 7);
      final List<int> sorted = <int>[1, 2, 3, 4, 5];
      expect(VideoFrameTimingAggregator.percentile(sorted, 0.5), 3);
      expect(VideoFrameTimingAggregator.percentile(sorted, 0.95), 5);
    });

    test('汇总行给出帧数、fps、jank / severe 计数与 build/raster 分位', () {
      final String line = VideoFrameTimingAggregator.summarise(
        framesOf(<int>[8000, 10000, 20000, 60000]),
        1000,
      );
      expect(line, contains('frames=4'));
      expect(line, contains('fps=4.0'));
      // 超 16.667ms 的两帧；其中 60ms 那帧 >= 3 倍预算。
      expect(line, contains('jank=2'));
      expect(line, contains('severe=1'));
      expect(line, contains('build(p50/p95/max)='));
      expect(line, contains('raster(p50/p95/max)='));
      expect(line, contains('budget=16.7'));
    });

    test('空窗返回 null（暂停时不每秒刷一行 frames=0）', () {
      final VideoFrameTimingAggregator agg = VideoFrameTimingAggregator();
      expect(agg.summariseAndReset(1000), isNull);
    });

    test('summariseAndReset 会清空窗口', () {
      final VideoFrameTimingAggregator agg = VideoFrameTimingAggregator()
        ..addAll(framesOf(<int>[8000, 9000]));
      expect(agg.frameCount, 2);
      expect(agg.summariseAndReset(1000), isNotNull);
      expect(agg.frameCount, 0);
      expect(agg.summariseAndReset(1000), isNull);
    });

    test('isJankyWindow：一帧严重即算卡，或超预算过半', () {
      final VideoFrameTimingAggregator severe = VideoFrameTimingAggregator()
        ..addAll(framesOf(<int>[8000, 8000, 8000, 60000]));
      expect(severe.isJankyWindow(), isTrue, reason: '单帧 60ms 已是可感知的顿');

      final VideoFrameTimingAggregator mild = VideoFrameTimingAggregator()
        ..addAll(framesOf(<int>[8000, 8000, 8000, 18000]));
      expect(mild.isJankyWindow(), isFalse, reason: '偶发一帧略超不该刷 warn');

      final VideoFrameTimingAggregator sustained = VideoFrameTimingAggregator()
        ..addAll(framesOf(<int>[18000, 18000, 8000, 8000]));
      expect(sustained.isJankyWindow(), isTrue, reason: '半数超预算＝持续掉帧');

      expect(VideoFrameTimingAggregator().isJankyWindow(), isFalse);
    });
  });
}
