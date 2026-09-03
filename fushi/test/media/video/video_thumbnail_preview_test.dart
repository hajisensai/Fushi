import 'dart:async';
import 'dart:ui' as ui;

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_thumbnail_preview_controller.dart';
import 'package:fushi/src/media/video/video_thumbnail_preview_overlay.dart';

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

    test('同一格内连续移动只取一次帧（量化 + 单飞承担限流，不靠防抖）', () {
      int grabs = 0;
      final VideoThumbnailPreviewController c = VideoThumbnailPreviewController(
        grabber: (int _) async {
          grabs++;
          return null;
        },
        durationMsProvider: () => 100000,
      );
      fakeAsync((FakeAsync async) {
        // 同一格内的微小抖动（0.1 附近，远小于 1/600 的格宽）。
        c.request(0.1000, desktop: true);
        c.request(0.1002, desktop: true);
        c.request(0.1004, desktop: true);
        async.elapse(const Duration(milliseconds: 50));
        async.flushMicrotasks();
        expect(grabs, 1, reason: '同一格只取一次');

        // 但**第一次**就必须立刻发起，不能等指针停下——这是「鼠标动了不重新
        // 加载」的反面不变式。
        expect(grabs, greaterThan(0), reason: 'hover 一到就该发起，不等停手');
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
      );
      c.request(0.5, desktop: true);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(c.state.phase, ThumbnailPreviewPhase.timestampOnly);
      c.dispose();
    });
  });

  group('thumbnailBucketTargetMs (取帧目标量化)', () {
    test('相邻微动落进同一格 → 复用同一取帧目标', () {
      // 1200px 宽的进度条上挪一个像素约合 fraction 变化 1/1200，远小于 1/600 格宽。
      expect(
        thumbnailBucketTargetMs(0.5004, 120000),
        thumbnailBucketTargetMs(0.5, 120000),
        reason: '同一格必须给出同一目标，否则每挪一个像素就重新 seek 一次',
      );
    });

    test('跨格才换目标', () {
      expect(
        thumbnailBucketTargetMs(0.505, 120000),
        isNot(thumbnailBucketTargetMs(0.5, 120000)),
      );
    });

    test('量化后落在 [0, duration) 内，且末端永不等于总时长', () {
      expect(thumbnailBucketTargetMs(0.0, 120000), 0);
      expect(thumbnailBucketTargetMs(-1.0, 120000), 0);
      // 最后一格的代表点是它的**起点**，不是视频末尾——`ffmpeg -ss <duration>`
      // 那里没有帧可取，允许取到总时长会让进度条最右端永远只剩时间戳。
      final int last = thumbnailBucketTargetMs(1.0, 120000)!;
      expect(last, lessThan(120000));
      expect(last, 119800);
      expect(thumbnailBucketTargetMs(2.0, 120000), last);
    });

    test('无时长返回 null', () {
      expect(thumbnailBucketTargetMs(0.5, 0), isNull);
      expect(thumbnailBucketTargetMs(0.5, -1), isNull);
    });

    test('整条进度条被切成 kThumbnailBuckets 格', () {
      final Set<int> targets = <int>{};
      for (int i = 0; i <= 4000; i++) {
        targets.add(thumbnailBucketTargetMs(i / 4000, 600000)!);
      }
      expect(targets.length, kThumbnailBuckets,
          reason: '4000 个采样点只应压缩成 600 格，这就是缓存命中率的来源');
    });
  });

  group('缓存命中 / loading 语义 / 超时保护', () {
    test('同步缓存命中 → 直接 ready，不进 loading，也不调 grabber', () async {
      final ui.Image cached = await _makeImage();
      int grabs = 0;
      final VideoThumbnailPreviewController c = VideoThumbnailPreviewController(
        grabber: (int _) async {
          grabs++;
          return null;
        },
        cachedFrameLookup: (int _) => cached,
        durationMsProvider: () => 100000,
      );
      c.request(0.5, desktop: true);
      // 同一个 event loop turn 内就必须是 ready：命中缓存却先闪一下 loading，
      // 「回扫零延迟」的语义就没了。
      expect(c.state.phase, ThumbnailPreviewPhase.ready);
      expect(c.state.image, isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(grabs, 0, reason: '命中缓存不该再发起取帧');
      c.dispose();
    });

    test('缓存未命中 → loading 且沿用上一帧（而不是谎报 ready）', () async {
      final ui.Image img = await _makeImage();
      final Completer<ui.Image?> pending = Completer<ui.Image?>();
      bool first = true;
      final VideoThumbnailPreviewController c = VideoThumbnailPreviewController(
        grabber: (int _) {
          if (first) {
            first = false;
            return Future<ui.Image?>.value(img);
          }
          return pending.future;
        },
        durationMsProvider: () => 100000,
      );
      c.request(0.2, desktop: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.state.phase, ThumbnailPreviewPhase.ready);

      c.request(0.8, desktop: true);
      expect(c.state.phase, ThumbnailPreviewPhase.loading,
          reason: '手上这张不是当前位置的画面，态必须诚实');
      expect(c.state.image, isNotNull, reason: '沿用上一帧避免闪白');
      pending.complete(null);
      c.dispose();
    });

    test('取帧目标用量化值，时间戳用精确值', () async {
      final List<int> grabbed = <int>[];
      final VideoThumbnailPreviewController c = VideoThumbnailPreviewController(
        grabber: (int targetMs) async {
          grabbed.add(targetMs);
          return null;
        },
        durationMsProvider: () => 120000,
      );
      c.request(0.5004, desktop: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.state.targetMs, 60048, reason: '气泡时间戳跟手，用未量化的精确值');
      expect(grabbed, <int>[60000], reason: '取帧目标量化到格，才能命中缓存');
      c.dispose();
    });

    test('取帧挂死 → 超时放掉单飞闸门，后续 hover 仍能取帧', () {
      final List<int> grabbed = <int>[];
      final VideoThumbnailPreviewController c = VideoThumbnailPreviewController(
        // 永不完成：模拟 libmpv 卡在 seek / 媒体损坏。
        grabber: (int targetMs) {
          grabbed.add(targetMs);
          return Completer<ui.Image?>().future;
        },
        durationMsProvider: () => 100000,
        grabTimeout: const Duration(seconds: 2),
      );
      fakeAsync((FakeAsync async) {
        c.request(0.1, desktop: true);
        async.elapse(const Duration(milliseconds: 1)); // 放行 debounce timer
        async.flushMicrotasks();
        expect(grabbed, <int>[10000]);

        // 超时前：单飞闸门锁着，新 hover 只进 pending。
        c.request(0.5, desktop: true);
        async.elapse(const Duration(milliseconds: 500));
        async.flushMicrotasks();
        expect(grabbed, <int>[10000], reason: '单飞：不并发第二个取帧');

        // 超时后闸门放开 → 补发最新 pending。没有这条，一次挂死的取帧会让预览
        // 永久停更（后续 hover 全被并进 pending 再也发不出去）。
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(grabbed, <int>[10000, 50000],
            reason: 'grabTimeout 必须放掉 _inFlight 并补发 pending，否则预览永久停更');

        // 补发的那个也挂死 → 再超时一次，这回 generation 没变，诚实降级。
        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();
        expect(c.state.phase, ThumbnailPreviewPhase.timestampOnly,
            reason: '取不到帧就降级只显时间戳，而不是永远卡在 loading');
      });
      c.dispose();
    });

    test('取帧期间指针一直在动 → 结果仍必须落地，并立刻去追当前那一格', () async {
      final ui.Image img = await _makeImage();
      Completer<ui.Image?>? current;
      int grabs = 0;
      final VideoThumbnailPreviewController c = VideoThumbnailPreviewController(
        grabber: (int _) {
          grabs++;
          current = Completer<ui.Image?>();
          return current!.future;
        },
        durationMsProvider: () => 100000,
      );
      fakeAsync((FakeAsync async) {
        c.request(0.10, desktop: true);
        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(grabs, 1);

        // 取帧还没回来，指针继续匀速移动（真实 hover 约 16ms 一个事件，而一次
        // 取帧要几十毫秒——hover 一定比取帧快）。
        for (int i = 1; i <= 5; i++) {
          c.request(0.10 + 0.02 * i, desktop: true);
          async.elapse(const Duration(milliseconds: 16));
        }
        async.flushMicrotasks();
        expect(grabs, 1, reason: '单飞：在途期间不并发第二个');

        // 第一次取帧回来。期间用户一直在动鼠标——但那**不是**结果过期的理由。
        current!.complete(img);
        async.flushMicrotasks();

        expect(c.state.phase, ThumbnailPreviewPhase.ready,
            reason: '把「期间又 hover 过」当成过期丢掉，匀速划过进度条时预览'
                '一张图都换不出来（用户报的「鼠标动了还不会重新加载」）');
        expect(c.state.image, isNotNull);
        expect(grabs, 2, reason: '收尾后立刻去追当前指针所在那一格');
      });
      c.dispose();
    });

    test('预热只在首次 hover（从 hidden 进入）触发', () async {
      int warmUps = 0;
      final VideoThumbnailPreviewController c = VideoThumbnailPreviewController(
        grabber: (int _) async => null,
        durationMsProvider: () => 100000,
        onWarmUp: () => warmUps++,
      );
      c.request(0.1, desktop: true);
      c.request(0.2, desktop: true);
      c.request(0.3, desktop: true);
      expect(warmUps, 1, reason: '移动中不该反复预热');

      c.hide();
      c.request(0.4, desktop: true);
      expect(warmUps, 2, reason: '离开后再进来是新一轮 hover，需要重新预热');
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
      );
      c.request(0.5, desktop: true);
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pumpWidget(_wrap(c));
      await tester.pump();
      expect(find.byType(RawImage), findsOneWidget);
      c.dispose();
    });

    testWidgets('loading 且已有上一帧 → 安静换图，不叠 spinner',
        (WidgetTester tester) async {
      final ui.Image img = await _makeImage();
      final Completer<ui.Image?> pending = Completer<ui.Image?>();
      bool first = true;
      final VideoThumbnailPreviewController c = VideoThumbnailPreviewController(
        grabber: (int _) {
          if (first) {
            first = false;
            return Future<ui.Image?>.value(img);
          }
          return pending.future;
        },
        durationMsProvider: () => 100000,
      );
      c.request(0.2, desktop: true);
      await tester.pump(const Duration(milliseconds: 10));
      // 第二次 hover 落到别的格 → 进 loading，但上一帧还在。
      c.request(0.8, desktop: true);
      await tester.pumpWidget(_wrap(c));
      await tester.pump();
      expect(c.state.phase, ThumbnailPreviewPhase.loading);
      expect(find.byType(RawImage), findsOneWidget, reason: '上一帧继续显示');
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: '已有图时不叠 spinner，否则匀速划过进度条会变频闪');
      pending.complete(null);
      c.dispose();
    });

    testWidgets('loading 且一张图都还没有 → 显 spinner',
        (WidgetTester tester) async {
      final Completer<ui.Image?> pending = Completer<ui.Image?>();
      final VideoThumbnailPreviewController c = VideoThumbnailPreviewController(
        grabber: (int _) => pending.future,
        durationMsProvider: () => 100000,
      );
      c.request(0.5, desktop: true);
      await tester.pumpWidget(_wrap(c));
      await tester.pump();
      expect(c.state.phase, ThumbnailPreviewPhase.loading);
      expect(find.byType(RawImage), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      pending.complete(null);
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
