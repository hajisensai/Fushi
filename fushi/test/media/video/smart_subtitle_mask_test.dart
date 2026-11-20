import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/video/raw_video_frame.dart';
import 'package:fushi/src/media/video/smart_subtitle_mask_sampler.dart';
import 'package:fushi/src/media/video/smart_subtitle_mask_tracker.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_mask.dart';
import 'package:fushi/src/media/video/video_subtitle_mask_config.dart';

const Rect _region = Rect.fromLTWH(0.1, 0.75, 0.8, 0.22);

/// 一行底部字幕（画面比例坐标）。
const Rect _line = Rect.fromLTWH(0.3, 0.85, 0.4, 0.05);

RawVideoFrame _rawFrame({
  required int width,
  required int height,
  required int stride,
  int Function(int x, int y, int c)? pixel,
}) {
  final Uint8List bgra = Uint8List(height * stride);
  if (pixel != null) {
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        for (int c = 0; c < 4; c++) {
          bgra[y * stride + x * 4 + c] = pixel(x, y, c);
        }
      }
    }
  }
  return RawVideoFrame(
    width: width,
    height: height,
    stride: stride,
    bgra: bgra,
  );
}

VideoPlayerController _controller({required bool playing, int position = 0}) {
  final VideoPlayerController c = VideoPlayerController()
    ..debugVideoWidthOverride = 1920
    ..debugVideoHeightOverride = 1080;
  c.debugSetPositionForTesting(position);
  c.debugSetIsPlayingForTesting(playing);
  return c;
}

/// 16x9 整帧里按 [region] 截出的一块（代替真播放器的截帧）。
RawVideoFrameCrop? _capture(Rect region) => cropRawVideoFrame(
  RawVideoFrame(width: 16, height: 9, stride: 64, bgra: Uint8List(9 * 64)),
  region,
);

class _FakeDetector implements SmartSubtitleMaskDetector {
  _FakeDetector(this.results);

  /// 每次识别依次返回；用完后一直返回最后一个。
  final List<List<Rect>> results;
  int calls = 0;
  bool disposed = false;
  bool unavailable = false;

  @override
  Future<List<Rect>> detect(RawVideoFrameCrop crop) async {
    if (unavailable) throw const SmartSubtitleMaskDetectorUnavailable();
    final List<Rect> r = results[calls.clamp(0, results.length - 1)];
    calls++;
    return r;
  }

  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  group('raw video frame', () {
    test('crop bytes round-trip; bad frames and bad headers are rejected', () {
      final RawVideoFrame f = _rawFrame(width: 4, height: 2, stride: 20);
      final Uint8List? bytes = cropRawVideoFrameBytes(
        f,
        const Rect.fromLTRB(0, 0, 1, 1),
      );
      expect(bytes, hasLength(kRawVideoFrameCropHeaderBytes + 4 * 2 * 4));
      final RawVideoFrameCrop? crop = parseRawVideoFrameCrop(bytes);
      expect(crop, isNotNull);
      expect(
        (crop!.frameWidth, crop.frameHeight, crop.width, crop.height),
        (4, 2, 4, 2),
      );
      expect(parseRawVideoFrameCrop(null), isNull);
      expect(parseRawVideoFrameCrop(Uint8List(8)), isNull);
      // 数据比头部声明的短。
      expect(
        parseRawVideoFrameCrop(Uint8List.sublistView(bytes!, 0, 30)),
        isNull,
      );
      // stride 小于 width * 4 / 缓冲比 height * stride 短：不裁。
      const Rect all = Rect.fromLTRB(0, 0, 1, 1);
      expect(
        cropRawVideoFrameBytes(
          RawVideoFrame(width: 4, height: 2, stride: 8, bgra: Uint8List(16)),
          all,
        ),
        isNull,
      );
      expect(
        cropRawVideoFrameBytes(
          RawVideoFrame(width: 4, height: 2, stride: 16, bgra: Uint8List(20)),
          all,
        ),
        isNull,
      );
    });

    // 补丁在截帧 isolate 上调用这个变换：只把裁剪传回主 isolate。
    test('the capture transform crops on the capture side', () {
      final RawVideoFrame f = _rawFrame(
        width: 10,
        height: 10,
        stride: 48,
        pixel: (int x, int y, int c) => c == 0 ? x : 0,
      );
      final RawVideoFrameTransform transform = rawVideoFrameCropTransform(
        const Rect.fromLTRB(0.5, 0.8, 1, 1),
      );
      final RawVideoFrameCrop crop = parseRawVideoFrameCrop(
        transform(f.width, f.height, f.stride, f.bgra),
      )!;
      expect((crop.left, crop.top, crop.width, crop.height), (5, 8, 5, 2));
      expect(crop.rgba.length, 5 * 2 * 4);
      // 裁剪内 (0, 0) = 整帧 (5, 8)：B=5 → RGBA 的第三个字节。
      expect(crop.rgba.sublist(0, 4), <int>[0, 0, 5, 255]);
    });

    test('crops a fraction, swaps BGRA to opaque RGBA, honours stride', () {
      // B = x, G = y, R = 200；stride 带 8 字节填充。
      final RawVideoFrame f = _rawFrame(
        width: 10,
        height: 10,
        stride: 48,
        pixel: (int x, int y, int c) => switch (c) {
          0 => x,
          1 => y,
          2 => 200,
          _ => 0,
        },
      );
      final RawVideoFrameCrop crop = cropRawVideoFrame(
        f,
        const Rect.fromLTRB(0.2, 0.5, 0.6, 0.8),
      )!;
      expect((crop.left, crop.top, crop.width, crop.height), (2, 5, 4, 3));
      expect(crop.rgba.length, 4 * 3 * 4);
      // 裁剪内 (1, 2) = 整帧 (3, 7)：R=200, G=7, B=3, A=255。
      const int i = (2 * 4 + 1) * 4;
      expect(crop.rgba.sublist(i, i + 4), <int>[200, 7, 3, 255]);
      expect(
        crop.toFrameFraction(const Rect.fromLTRB(0, 0, 4, 3)),
        const Rect.fromLTRB(0.2, 0.5, 0.6, 0.8),
      );
      expect(
        cropRawVideoFrame(f, const Rect.fromLTRB(0.5, 0.5, 0.5, 0.9)),
        isNull,
      );
    });
  });

  group('smartSubtitleMaskRectForLines', () {
    test('pads each line by its height and unions them', () {
      const Rect a = Rect.fromLTWH(0.3, 0.80, 0.4, 0.05);
      const Rect b = Rect.fromLTWH(0.35, 0.87, 0.3, 0.05);
      final Rect r = smartSubtitleMaskRectForLines(<Rect>[a, b], _region)!;
      expect(r.left, closeTo(0.3 - 0.05 * kSmartSubtitleMaskPadX, 1e-9));
      expect(r.right, closeTo(0.7 + 0.05 * kSmartSubtitleMaskPadX, 1e-9));
      expect(r.top, closeTo(0.80 - 0.05 * kSmartSubtitleMaskPadY, 1e-9));
      expect(r.bottom, closeTo(0.92 + 0.05 * kSmartSubtitleMaskPadY, 1e-9));
    });

    test('ignores lines outside the region and tiny noise; clamps', () {
      // 画面顶部的字（招牌）不在搜索区域里。
      const Rect sign = Rect.fromLTWH(0.4, 0.1, 0.2, 0.05);
      const Rect noise = Rect.fromLTWH(0.5, 0.9, 0.01, 0.005);
      expect(
        smartSubtitleMaskRectForLines(<Rect>[sign, noise], _region),
        isNull,
      );
      // 贴着区域右下角的行：留边后被钳回区域内。
      const Rect edge = Rect.fromLTWH(0.7, 0.92, 0.19, 0.04);
      final Rect r = smartSubtitleMaskRectForLines(<Rect>[edge], _region)!;
      expect(r.right, closeTo(_region.right, 1e-9));
      expect(r.bottom, closeTo(_region.bottom, 1e-9));
    });
  });

  group('SmartSubtitleMaskTracker', () {
    test('shows at once, holds through short gaps, hides after holdEmpty', () {
      final SmartSubtitleMaskTracker t = SmartSubtitleMaskTracker(
        holdEmpty: const Duration(milliseconds: 1000),
      );
      Rect? at(int ms, List<Rect> lines) => t.addSample(
        lines: lines,
        region: _region,
        at: Duration(milliseconds: ms),
      );
      expect(at(0, const <Rect>[]), isNull);
      final Rect? shown = at(100, const <Rect>[_line]);
      expect(shown, isNotNull);
      // 句间空档 600 ms：不闪。
      expect(at(700, const <Rect>[]), shown);
      expect(at(1099, const <Rect>[]), shown);
      expect(at(1100, const <Rect>[]), isNull);
      // 重新出字后再次计时。
      expect(at(1200, const <Rect>[_line]), isNotNull);
      t.reset();
      expect(t.rect, isNull);
    });
  });

  group('SmartSubtitleMaskSampler', () {
    test('samples while playing, publishes the tracked rect', () async {
      final VideoPlayerController c = _controller(playing: true);
      final _FakeDetector d = _FakeDetector(<List<Rect>>[
        const <Rect>[_line],
      ]);
      final SmartSubtitleMaskSampler s = SmartSubtitleMaskSampler(
        controller: c,
        region: _region,
        detect: d.detect,
        capture: (Rect r) async => _capture(r),
        minInterval: Duration.zero,
      );
      await pumpEventQueue();
      expect(d.calls, greaterThan(0));
      expect(
        s.rect.value,
        smartSubtitleMaskRectForLines(const <Rect>[_line], _region),
      );
      s.dispose();
    });

    test('paused on an unchanged frame samples once, then stops', () async {
      final VideoPlayerController c = _controller(
        playing: false,
        position: 5000,
      );
      final _FakeDetector d = _FakeDetector(<List<Rect>>[const <Rect>[]]);
      final SmartSubtitleMaskSampler s = SmartSubtitleMaskSampler(
        controller: c,
        region: _region,
        detect: d.detect,
        capture: (Rect r) async => _capture(r),
        minInterval: Duration.zero,
      );
      await pumpEventQueue();
      expect(d.calls, 1);
      await pumpEventQueue();
      expect(d.calls, 1);
      // 暂停态步进到新帧：再识别一次。
      c.debugSetPositionForTesting(5040);
      await pumpEventQueue();
      expect(d.calls, 2);
      s.dispose();
    });

    test('seek clears the mask until the next detection', () async {
      final VideoPlayerController c = _controller(
        playing: false,
        position: 1000,
      );
      final _FakeDetector d = _FakeDetector(<List<Rect>>[
        const <Rect>[_line],
        const <Rect>[],
      ]);
      final SmartSubtitleMaskSampler s = SmartSubtitleMaskSampler(
        controller: c,
        region: _region,
        detect: d.detect,
        capture: (Rect r) async => _capture(r),
        minInterval: Duration.zero,
      );
      await pumpEventQueue();
      expect(s.rect.value, isNotNull);
      c.debugSetPositionForTesting(60000);
      expect(s.rect.value, isNull);
      await pumpEventQueue();
      expect(s.rect.value, isNull);
      s.dispose();
    });

    test(
      'detector unavailable -> covers the whole region, reports once',
      () async {
        final VideoPlayerController c = _controller(playing: true);
        final _FakeDetector d = _FakeDetector(<List<Rect>>[const <Rect>[]])
          ..unavailable = true;
        int reports = 0;
        final SmartSubtitleMaskSampler s = SmartSubtitleMaskSampler(
          controller: c,
          region: _region,
          detect: d.detect,
          capture: (Rect r) async => _capture(r),
          minInterval: Duration.zero,
          onUnavailable: () => reports++,
        );
        await pumpEventQueue();
        expect(s.unavailable, isTrue);
        expect(s.rect.value, _region);
        expect(reports, 1);
        expect(d.calls, 0);
        // 拖了搜索区域：整块常显跟着走。
        const Rect moved = Rect.fromLTWH(0.1, 0.05, 0.8, 0.15);
        s.region = moved;
        expect(s.rect.value, moved);
        s.dispose();
      },
    );

    test('persistent errors are reported once per streak', () async {
      final VideoPlayerController c = _controller(playing: true);
      int errors = 0;
      int captures = 0;
      final SmartSubtitleMaskSampler s = SmartSubtitleMaskSampler(
        controller: c,
        region: _region,
        detect: (_) async => const <Rect>[],
        capture: (Rect r) async {
          captures++;
          throw StateError('boom');
        },
        minInterval: Duration.zero,
        onError: (Object e, StackTrace st) => errors++,
      );
      for (int i = 0; i < 5; i++) {
        await pumpEventQueue();
      }
      expect(captures, greaterThan(2));
      expect(errors, 1);
      s.dispose();
    });
  });

  group('VideoSubtitleMaskLayer smart mode', () {
    Widget host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      home: SizedBox(width: 800, height: 450, child: child),
    );

    testWidgets('owns a detector only while enabled + smart', (
      WidgetTester tester,
    ) async {
      final VideoPlayerController c = _controller(playing: false);
      final List<_FakeDetector> created = <_FakeDetector>[];
      final ValueNotifier<Rect?> draft = ValueNotifier<Rect?>(null);
      Widget layer(VideoSubtitleMaskConfig config) => host(
        VideoSubtitleMaskLayer(
          controller: c,
          fit: BoxFit.contain,
          config: config,
          draftRect: draft,
          createSmartDetector: () {
            final _FakeDetector d = _FakeDetector(<List<Rect>>[const <Rect>[]]);
            created.add(d);
            return d;
          },
        ),
      );
      const VideoSubtitleMaskConfig manual = VideoSubtitleMaskConfig(
        enabled: true,
      );
      await tester.pumpWidget(layer(manual));
      expect(created, isEmpty);
      final VideoSubtitleMaskConfig smart = manual.copyWith(
        mode: VideoSubtitleMaskMode.smart,
      );
      await tester.pumpWidget(layer(smart));
      expect(created, hasLength(1));
      // 智能模式、还没识别到字：遮布从原位置淡出到全透明。
      await tester.pump(const Duration(seconds: 1));
      final AnimatedOpacity fade = tester.widget<AnimatedOpacity>(
        find.descendant(
          of: find.byType(VideoSubtitleMaskLayer),
          matching: find.byType(AnimatedOpacity),
        ),
      );
      expect(fade.opacity, 0);
      await tester.pumpWidget(layer(smart.copyWith(enabled: false)));
      await tester.pump();
      expect(created.single.disposed, isTrue);
      await tester.pumpWidget(const SizedBox());
      draft.dispose();
      c.dispose();
    });
    // 模型刚下载好 / 换了模型：之前判成不可用的识别器要按新身份重建，不必切模式。
    testWidgets('detector identity change rebuilds the detector', (
      WidgetTester tester,
    ) async {
      final VideoPlayerController c = _controller(playing: false);
      final List<_FakeDetector> created = <_FakeDetector>[];
      final ValueNotifier<Rect?> draft = ValueNotifier<Rect?>(null);
      final ValueNotifier<Object?> identity = ValueNotifier<Object?>('m|true');
      int unavailableReports = 0;
      await tester.pumpWidget(
        host(
          VideoSubtitleMaskLayer(
            controller: c,
            fit: BoxFit.contain,
            config: const VideoSubtitleMaskConfig(
              enabled: true,
              mode: VideoSubtitleMaskMode.smart,
            ),
            draftRect: draft,
            smartDetectorIdentity: identity,
            onSmartUnavailable: () => unavailableReports++,
            createSmartDetector: () {
              final _FakeDetector d = _FakeDetector(<List<Rect>>[
                const <Rect>[],
              ])..unavailable = created.isEmpty;
              created.add(d);
              return d;
            },
          ),
        ),
      );
      expect(created, hasLength(1));
      identity.value = 'm|false';
      await tester.pump();
      expect(created, hasLength(2));
      expect(created.first.disposed, isTrue);
      expect(created.last.disposed, isFalse);
      await tester.pumpWidget(const SizedBox());
      expect(created.last.disposed, isTrue);
      identity.dispose();
      draft.dispose();
      c.dispose();
    });
  });

  group('VideoSubtitleMaskConfig mode', () {
    test('round-trips; missing / unknown mode falls back to manual', () {
      const VideoSubtitleMaskConfig c = VideoSubtitleMaskConfig(
        enabled: true,
        mode: VideoSubtitleMaskMode.smart,
      );
      expect(VideoSubtitleMaskConfig.fromJson(c.toJson()), c);
      expect(
        VideoSubtitleMaskConfig.fromJson('{"enabled":true}').mode,
        VideoSubtitleMaskMode.manual,
      );
      expect(
        VideoSubtitleMaskConfig.fromJson('{"mode":"bogus"}').mode,
        VideoSubtitleMaskMode.manual,
      );
    });
  });
}
