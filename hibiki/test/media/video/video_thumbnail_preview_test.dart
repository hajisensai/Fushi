import 'dart:async';
import 'dart:ui' as ui;

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_thumbnail_preview_controller.dart';
import 'package:hibiki/src/media/video/video_thumbnail_preview_overlay.dart';

/// 造一个 1x1 的真 [ui.Image]（取帧 fake 返回值）。
Future<ui.Image> _makeImage() async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 1, 1),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  final ui.Picture picture = recorder.endRecording();
  return picture.toImage(1, 1);
}

void main() {
  group('thumbnailTargetMs (纯函数)', () {
    test('线性映射中段', () {
      expect(thumbnailTargetMs(0.5, 100000), 50000);
    });

    test('0 / 1 边界', () {
      expect(thumbnailTargetMs(0.0, 100000), 0);
      expect(thumbnailTargetMs(1.0, 100000), 100000);
    });

    test('超界 fraction 被 clamp', () {
      expect(thumbnailTargetMs(-0.5, 100000), 0);
      expect(thumbnailTargetMs(1.5, 100000), 100000);
    });

    test('无时长返回 null', () {
      expect(thumbnailTargetMs(0.5, 0), isNull);
      expect(thumbnailTargetMs(0.5, -1), isNull);
    });
  });

  group('thumbnailPreviewLeft (纯函数)', () {
    test('中段居中对准 hover 点', () {
      // center = 0.5*1000 = 500, left = 500 - 80 = 420
      expect(thumbnailPreviewLeft(0.5, 1000, 160), 420);
    });

    test('左缘 clamp 到 0', () {
      expect(thumbnailPreviewLeft(0.0, 1000, 160), 0);
    });

    test('右缘 clamp 到 trackWidth - bubbleWidth', () {
      expect(thumbnailPreviewLeft(1.0, 1000, 160), 840);
    });

    test('轨道比浮层窄时居中（左缘可负）', () {
      // maxLeft = 100 - 160 = -60 <= 0 → 居中 = -30
      expect(thumbnailPreviewLeft(0.5, 100, 160), -30);
    });
  });

  group('formatThumbnailTimestamp (纯函数)', () {
    test('mm:ss（<1小时）', () {
      expect(formatThumbnailTimestamp(0), '00:00');
      expect(formatThumbnailTimestamp(65000), '01:05');
      expect(formatThumbnailTimestamp(3599000), '59:59');
    });

    test('h:mm:ss（>=1小时）', () {
      expect(formatThumbnailTimestamp(3600000), '1:00:00');
      expect(formatThumbnailTimestamp(3661000), '1:01:01');
    });

    test('负值 clamp 到 0', () {
      expect(formatThumbnailTimestamp(-5000), '00:00');
    });
  });

  group('VideoThumbnailPreviewController 防抖/单飞/软取消', () {
    test('hidden 初态', () {
      final VideoThumbnailPreviewController c = VideoThumbnailPreviewController(
        grabber: (int _) async => null,
        durationMsProvider: () => 100000,
      );
      expect(c.state.phase, ThumbnailPreviewPhase.hidden);
      c.dispose();
    });

    test('fraction==null → 隐藏', () {
      final VideoThumbnailPreviewController c = VideoThumbnailPreviewController(
        grabber: (int _) async => null,
        durationMsProvider: () => 100000,
      );
      c.request(0.5, desktop: true);
      expect(c.state.phase, ThumbnailPreviewPhase.loading);
      c.request(null, desktop: true);
      expect(c.state.phase, ThumbnailPreviewPhase.hidden);
      c.dispose();
    });

    test('非桌面 → 立即 timestampOnly，不取帧', () {
      int grabs = 0;
      final VideoThumbnailPreviewController c = VideoThumbnailPreviewController(
        grabber: (int _) async {
          grabs++;
          return null;
        },
        durationMsProvider: () => 100000,
      );
      fakeAsync((FakeAsync async) {
        c.request(0.5, desktop: false);
        expect(c.state.phase, ThumbnailPreviewPhase.timestampOnly);
        expect(c.state.targetMs, 50000);
        async.elapse(const Duration(seconds: 1));
        expect(grabs, 0, reason: '移动端/timestampOnly 绝不取帧');
      });
      c.dispose();
    });

    test('无时长 → timestampOnly（targetMs null）', () {
      final VideoThumbnailPreviewController c = VideoThumbnailPreviewController(
        grabber: (int _) async => null,
        durationMsProvider: () => 0,
      );
      c.request(0.5, desktop: true);
      expect(c.state.phase, ThumbnailPreviewPhase.timestampOnly);
      expect(c.state.targetMs, isNull);
      c.dispose();
    });

    test('防抖窗内多次 request 只触发一次取帧', () {
      int grabs = 0;
      final VideoThumbnailPreviewController c = VideoThumbnailPreviewController(
        grabber: (int _) async {
          grabs++;
          return null;
        },
        durationMsProvider: () => 100000,
        debounce: const Duration(milliseconds: 120),
      );
      fakeAsync((FakeAsync async) {
        c.request(0.1, desktop: true);
        async.elapse(const Duration(milliseconds: 40));
        c.request(0.2, desktop: true);
        async.elapse(const Duration(milliseconds: 40));
        c.request(0.3, desktop: true);
        // 还没到 120ms → 一次都没发
        async.elapse(const Duration(milliseconds: 40));
        // 最后一次 request 后 120ms 到 → 只发最后一个
        async.elapse(const Duration(milliseconds: 120));
        async.flushMicrotasks();
        expect(grabs, 1, reason: '连续移动只在停下后取一次');
      });
      c.dispose();
    });

    test('单飞：in-flight 期间多 request 只起一个，完成后补发最新 pending', () {
      final List<int> grabbed = <int>[];
      late void Function() complete;
      final VideoThumbnailPreviewController c = VideoThumbnailPreviewController(
        grabber: (int targetMs) {
          grabbed.add(targetMs);
          final Completer<ui.Image?> completer = Completer<ui.Image?>();
          complete = () => completer.complete(null);
          return completer.future;
        },
        durationMsProvider: () => 100000,
        debounce: const Duration(milliseconds: 120),
      );
      fakeAsync((FakeAsync async) {
        c.request(0.1, desktop: true); // target 10000
        async.elapse(const Duration(milliseconds: 120)); // 发起第一个
        async.flushMicrotasks();
        expect(grabbed, <int>[10000]);

        // 第一个还没完成时再来两次（in-flight）
        c.request(0.2, desktop: true); // 20000
        async.elapse(const Duration(milliseconds: 120));
        c.request(0.3, desktop: true); // 30000 (最新 pending)
        async.elapse(const Duration(milliseconds: 120));
        async.flushMicrotasks();
        // 仍只发了第一个（单飞）
        expect(grabbed, <int>[10000]);

        // 第一个完成 → 补发最新 pending(30000)，合并掉 20000
        complete();
        async.flushMicrotasks();
        expect(grabbed, <int>[10000, 30000], reason: '完成后只补发最新 pending，跳过中间过期');
      });
      c.dispose();
    });

    test('软取消：取帧完成时 generation 已变则丢结果', () async {
      ui.Image? produced;
      late void Function() complete;
      final VideoThumbnailPreviewController c = VideoThumbnailPreviewController(
        grabber: (int _) {
          final Completer<ui.Image?> completer = Completer<ui.Image?>();
          complete = () async {
            produced = await _makeImage();
            completer.complete(produced);
          };
          return completer.future;
        },
        durationMsProvider: () => 100000,
        debounce: Duration.zero,
      );
      c.request(0.5, desktop: true);
      await Future<void>.delayed(Duration.zero); // 触发取帧
      // 取帧在途时 hide（bump generation 作废）
      c.hide();
      expect(c.state.phase, ThumbnailPreviewPhase.hidden);
      complete();
      await Future<void>.delayed(Duration.zero);
      // 过期帧不应渲染（仍是 hidden）
      expect(c.state.phase, ThumbnailPreviewPhase.hidden);
      c.dispose();
    });

    test('取帧成功 → ready 带 image', () async {
      final VideoThumbnailPreviewController c = VideoThumbnailPreviewController(
        grabber: (int _) async => _makeImage(),
        durationMsProvider: () => 100000,
        debounce: Duration.zero,
      );
      c.request(0.5, desktop: true);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(c.state.phase, ThumbnailPreviewPhase.ready);
      expect(c.state.image, isNotNull);
      c.dispose();
    });

    test('取帧失败 → 降级 timestampOnly', () async {
      final VideoThumbnailPreviewController c = VideoThumbnailPreviewController(
        grabber: (int _) async => null,
        durationMsProvider: () => 100000,
        debounce: Duration.zero,
      );
      c.request(0.5, desktop: true);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(c.state.phase, ThumbnailPreviewPhase.timestampOnly);
      expect(c.state.image, isNull);
      c.dispose();
    });

    test('grabber 抛异常 → 不崩，降级 timestampOnly', () async {
      final VideoThumbnailPreviewController c = VideoThumbnailPreviewController(
        grabber: (int _) async => throw StateError('boom'),
        durationMsProvider: () => 100000,
        debounce: Duration.zero,
      );
      c.request(0.5, desktop: true);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(c.state.phase, ThumbnailPreviewPhase.timestampOnly);
      c.dispose();
    });
  });

  group('VideoThumbnailPreviewOverlay widget', () {
    testWidgets('hidden → SizedBox.shrink（不渲染气泡）', (WidgetTester tester) async {
      final VideoThumbnailPreviewController c = VideoThumbnailPreviewController(
        grabber: (int _) async => null,
        durationMsProvider: () => 100000,
      );
      await tester.pumpWidget(_wrap(c));
      expect(find.byType(Text), findsNothing);
      c.dispose();
    });

    testWidgets('timestampOnly → 只渲染时间戳，无 RawImage',
        (WidgetTester tester) async {
      final VideoThumbnailPreviewController c = VideoThumbnailPreviewController(
        grabber: (int _) async => null,
        durationMsProvider: () => 0, // 无时长 → timestampOnly
      );
      c.request(0.5, desktop: true);
      await tester.pumpWidget(_wrap(c));
      await tester.pump();
      expect(find.byType(RawImage), findsNothing);
      expect(find.byType(Text), findsOneWidget);
      c.dispose();
    });

    testWidgets('ready → 渲染 RawImage', (WidgetTester tester) async {
      final ui.Image img = await _makeImage();
      final VideoThumbnailPreviewController c = VideoThumbnailPreviewController(
        grabber: (int _) async => img,
        durationMsProvider: () => 100000,
        debounce: Duration.zero,
      );
      c.request(0.5, desktop: true);
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pumpWidget(_wrap(c));
      await tester.pump();
      expect(find.byType(RawImage), findsOneWidget);
      c.dispose();
    });

    testWidgets('controlsVisible=false → 不渲染', (WidgetTester tester) async {
      final VideoThumbnailPreviewController c = VideoThumbnailPreviewController(
        grabber: (int _) async => null,
        durationMsProvider: () => 0,
      );
      c.request(0.5, desktop: true);
      await tester.pumpWidget(_wrap(c, controlsVisible: false));
      await tester.pump();
      expect(find.byType(Text), findsNothing);
      c.dispose();
    });
  });
}

Widget _wrap(
  VideoThumbnailPreviewController c, {
  bool controlsVisible = true,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Stack(
        children: <Widget>[
          VideoThumbnailPreviewOverlay(
            controller: c,
            trackWidth: 800,
            bottomOffset: 40,
            colorScheme: const ColorScheme.dark(),
            uiScale: 1.0,
            controlsVisible: controlsVisible,
          ),
        ],
      ),
    ),
  );
}
