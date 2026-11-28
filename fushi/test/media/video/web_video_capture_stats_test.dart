import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/web_video_capture_stats.dart';

import '../../helpers/source_guard.dart';

/// BUG-5611：「制卡优先」档截取链路的只读体检（fork 纹理桥 → Dart）。
void main() {
  Map<String, Object?> raw({
    int frames = 120,
    int width = 3840,
    int height = 2160,
    List<List<int>>? samples,
  }) => <String, Object?>{
    'frames': frames,
    'width': width,
    'height': height,
    'samples':
        samples ??
        <List<int>>[
          <int>[10, 20, 30, 255],
          <int>[200, 180, 160, 255],
          <int>[0, 0, 0, 255],
          <int>[90, 100, 110, 255],
          <int>[255, 255, 255, 255],
        ],
  };

  test('解析 fork 回的 map', () {
    final WebVideoCaptureStats? s = parseWebVideoCaptureStats(raw());
    expect(s, isNotNull);
    expect(s!.frames, 120);
    expect(s.width, 3840);
    expect(s.samples, hasLength(5));
    expect(s.hasNonWhiteContent, isTrue);
    expect(s.hasVariedContent, isTrue);
  });

  test('一片白 = BUG-5611 症状', () {
    final WebVideoCaptureStats s = parseWebVideoCaptureStats(
      raw(
        samples: List<List<int>>.generate(5, (_) => <int>[255, 255, 255, 255]),
      ),
    )!;
    expect(s.hasNonWhiteContent, isFalse);
    expect(s.hasVariedContent, isFalse);
  });

  test('还没有帧：尺寸 0、无采样', () {
    final WebVideoCaptureStats s = parseWebVideoCaptureStats(
      raw(frames: 0, width: 0, height: 0, samples: <List<int>>[]),
    )!;
    expect(s.hasNonWhiteContent, isFalse);
  });

  test('纯色底（黑）不算有画面变化', () {
    final WebVideoCaptureStats s = parseWebVideoCaptureStats(
      raw(samples: List<List<int>>.generate(5, (_) => <int>[0, 0, 0, 255])),
    )!;
    expect(s.hasNonWhiteContent, isTrue);
    expect(s.hasVariedContent, isFalse);
  });

  test('形状不对返回 null', () {
    expect(parseWebVideoCaptureStats(null), isNull);
    expect(parseWebVideoCaptureStats(<String, Object?>{'frames': 1}), isNull);
    expect(
      parseWebVideoCaptureStats(
        raw(
          samples: <List<int>>[
            <int>[1, 2, 3],
          ],
        ),
      ),
      isNull,
    );
  });

  test('通道：方法名与前缀 + viewId；窗口宿主档 / 没有 viewId 回 null', () async {
    String? seenChannel;
    String? seenMethod;
    final WebVideoCaptureStats? s = await readWebVideoCaptureStats(
      42,
      invoke: (String channel, String method) async {
        seenChannel = channel;
        seenMethod = method;
        return raw();
      },
    );
    expect(s, isNotNull);
    expect(seenChannel, 'com.pichillilorenzo/custom_platform_view_42');
    expect(seenMethod, kWebVideoGetCaptureStatsMethod);
    expect(
      await readWebVideoCaptureStats(
        42,
        invoke: (String channel, String method) async => null,
      ),
      isNull,
    );
    expect(await readWebVideoCaptureStats(null), isNull);
  });

  test('fork 侧方法名与 Dart 一致，且回的字段齐全', () {
    final String cc = maskComments(
      File(
        '../packages/flutter_inappwebview_windows/windows/custom_platform_view/'
        'custom_platform_view.cc',
      ).readAsStringSync(),
    );
    expect(
      cc,
      contains(
        'constexpr auto kMethodGetCaptureStats = '
        '"$kWebVideoGetCaptureStatsMethod";',
      ),
    );
    for (final String key in <String>['frames', 'width', 'height', 'samples']) {
      expect(cc, contains('flutter::EncodableValue("$key")'));
    }
  });
}
