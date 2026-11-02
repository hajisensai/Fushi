import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/reader/page_curl/page_curl.dart';
import 'package:fushi/src/reader/page_turn_animation.dart';

/// 记录宿主收到的每一次调用，按顺序断言卷页的生命周期契约。
class _FakeHost implements PageCurlHost {
  _FakeHost(this.image);

  final ui.Image image;
  final List<String> calls = <String>[];
  bool hasNeighbour = true;
  bool captureFails = false;

  /// 宿主是否就绪（false = 换章 / 恢复在飞）。第一次被查询后可改，模拟连按中途跨章。
  @override
  bool canCurl = true;

  @override
  Future<ui.Image?> capturePage() async {
    calls.add('capture');
    return captureFails ? null : image.clone();
  }

  @override
  Future<bool> previewNeighbour({required bool forward}) async {
    calls.add('preview:${forward ? 'f' : 'b'}');
    return hasNeighbour;
  }

  @override
  Future<void> revertPreview() async => calls.add('revert');

  @override
  Future<void> commitTurn({required bool forward}) async =>
      calls.add('commit:${forward ? 'f' : 'b'}');

  @override
  Future<void> fallbackTurn({required bool forward}) async =>
      calls.add('fallback:${forward ? 'f' : 'b'}');

  @override
  Future<void> waitForPaint() async => calls.add('paint');
}

const Size _size = Size(400, 800);

void main() {
  late ui.Image image;

  setUpAll(() {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 4, 4),
      Paint()..color = const Color(0xFFFFFFFF),
    );
    image = recorder.endRecording().toImageSync(4, 4);
  });

  PageCurlController controllerFor(_FakeHost host) => PageCurlController(
    host: host,
    duration: () => PageTurnAnimationSpeed.normal.curlDuration,
  );

  /// 跑完准备阶段（截图 / 预览 / 等帧都是微任务 + endOfFrame）。
  Future<void> settlePrepare(WidgetTester tester) async {
    for (int i = 0; i < 6; i++) {
      await tester.pump();
    }
  }

  /// 落定动画：第一帧给 ticker 定起点，第二帧推过整段时长，再把收尾的微任务跑完。
  Future<void> settleAnimation(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    for (int i = 0; i < 4; i++) {
      await tester.pump();
    }
  }

  group('pageCurlShouldCommit', () {
    test('commits past the fraction or on a fling, never backwards', () {
      expect(
        pageCurlShouldCommit(progressPx: 120, velocity: 0, width: 400),
        isTrue,
      );
      expect(
        pageCurlShouldCommit(progressPx: 60, velocity: 0, width: 400),
        isFalse,
      );
      expect(
        pageCurlShouldCommit(progressPx: 30, velocity: 0.9, width: 400),
        isTrue,
      );
      // 拖过阈值又往回甩 = 取消。
      expect(
        pageCurlShouldCommit(progressPx: 200, velocity: -0.9, width: 400),
        isFalse,
      );
      expect(
        pageCurlShouldCommit(progressPx: -50, velocity: 2, width: 400),
        isFalse,
      );
    });
  });

  test('clampPageCurlPoint keeps the corner within one page of the spine', () {
    final Offset p = clampPageCurlPoint(
      const Offset(-900, 400),
      size: _size,
      y0: 400,
    );
    expect(p.dx, closeTo(-400, 0.001));
    expect(p.dy, closeTo(400, 0.001));
    const Offset inside = Offset(100, 300);
    expect(clampPageCurlPoint(inside, size: _size, y0: 400), inside);
  });

  test('curl speeds are one token above the slide speeds', () {
    for (final PageTurnAnimationSpeed s in PageTurnAnimationSpeed.values) {
      expect(s.curlDuration > s.duration, isTrue, reason: s.key);
    }
    expect(PageTurnAnimation.curl.isDirectional, isTrue);
    expect(
      PageTurnAnimation.fromKey('curl', fallback: PageTurnAnimation.none),
      PageTurnAnimation.curl,
    );
  });

  testWidgets('forward drag past the threshold commits exactly once', (
    WidgetTester tester,
  ) async {
    final _FakeHost host = _FakeHost(image);
    final PageCurlController curl = controllerFor(host);
    addTearDown(curl.dispose);

    expect(
      curl.dragStart(
        position: const Offset(380, 400),
        size: _size,
        forward: true,
        mirror: false,
      ),
      isTrue,
    );
    await settlePrepare(tester);
    expect(host.calls, <String>['capture', 'preview:f', 'paint']);
    expect(curl.visible, isTrue);

    curl.dragUpdate(const Offset(200, 420));
    // 角点跟着手指走（相对位移），轴线随之左移。
    expect(curl.geometry.point.dx, closeTo(220, 0.5));
    curl.dragEnd(const Offset(200, 420), -0.1);
    await tester.pump();
    expect(host.calls.where((String c) => c.startsWith('commit')), <String>[
      'commit:f',
    ]);
    await settleAnimation(tester);
    expect(curl.active, isFalse);
    expect(curl.visible, isFalse);
    expect(host.calls, isNot(contains('revert')));
  });

  testWidgets('a short forward drag curls back and reverts the preview', (
    WidgetTester tester,
  ) async {
    final _FakeHost host = _FakeHost(image);
    final PageCurlController curl = controllerFor(host);
    addTearDown(curl.dispose);

    curl.dragStart(
      position: const Offset(380, 400),
      size: _size,
      forward: true,
      mirror: false,
    );
    await settlePrepare(tester);
    curl.dragUpdate(const Offset(340, 400));
    curl.dragEnd(const Offset(340, 400), 0);
    await settleAnimation(tester);
    expect(host.calls, contains('revert'));
    expect(host.calls.where((String c) => c.startsWith('commit')), isEmpty);
    expect(curl.active, isFalse);
  });

  testWidgets('backward drag captures base + previous page and commits back', (
    WidgetTester tester,
  ) async {
    final _FakeHost host = _FakeHost(image);
    final PageCurlController curl = controllerFor(host);
    addTearDown(curl.dispose);

    curl.dragStart(
      position: const Offset(20, 400),
      size: _size,
      forward: false,
      mirror: false,
    );
    await settlePrepare(tester);
    expect(host.calls, <String>['capture', 'preview:b', 'paint', 'capture']);
    expect(curl.base, isNotNull);
    curl.dragUpdate(const Offset(220, 400));
    curl.dragEnd(const Offset(220, 400), 0.2);
    await settleAnimation(tester);
    expect(host.calls, contains('commit:b'));
    expect(curl.active, isFalse);
  });

  testWidgets('no neighbour (chapter edge) falls back to the plain turn', (
    WidgetTester tester,
  ) async {
    final _FakeHost host = _FakeHost(image)..hasNeighbour = false;
    final PageCurlController curl = controllerFor(host);
    addTearDown(curl.dispose);

    curl.dragStart(
      position: const Offset(380, 400),
      size: _size,
      forward: true,
      mirror: false,
    );
    await settlePrepare(tester);
    expect(curl.visible, isFalse);
    curl.dragEnd(const Offset(150, 400), 0);
    await tester.pump();
    expect(host.calls, contains('fallback:f'));
    expect(host.calls.where((String c) => c.startsWith('commit')), isEmpty);
  });

  testWidgets('mirrored (right-to-left) drags follow the finger rightwards', (
    WidgetTester tester,
  ) async {
    final _FakeHost host = _FakeHost(image);
    final PageCurlController curl = controllerFor(host);
    addTearDown(curl.dispose);

    // 右开：前进 = 往右拖，书脊在右；几何在未镜像空间里与左开前进一致。
    curl.dragStart(
      position: const Offset(20, 400),
      size: _size,
      forward: true,
      mirror: true,
    );
    await settlePrepare(tester);
    curl.dragUpdate(const Offset(220, 400));
    expect(curl.geometry.mirror, isTrue);
    expect(curl.geometry.point.dx, closeTo(200, 0.5));
    curl.dragEnd(const Offset(220, 400), 0.3);
    await settleAnimation(tester);
    expect(host.calls, contains('commit:f'));
  });

  testWidgets('tap turn resolves once committed; a second turn fast-forwards', (
    WidgetTester tester,
  ) async {
    final _FakeHost host = _FakeHost(image);
    final PageCurlController curl = controllerFor(host);
    addTearDown(curl.dispose);

    bool firstDone = false;
    curl
        .turn(size: _size, forward: true, mirror: false)
        .then((_) => firstDone = true);
    await settlePrepare(tester);
    expect(firstDone, isTrue);
    expect(curl.active, isTrue, reason: 'animation still playing');

    bool secondDone = false;
    curl
        .turn(size: _size, forward: true, mirror: false)
        .then((_) => secondDone = true);
    await settlePrepare(tester);
    expect(secondDone, isTrue);
    expect(host.calls.where((String c) => c == 'commit:f').length, 2);
    await settleAnimation(tester);
    expect(curl.active, isFalse);
  });

  testWidgets('presses arriving while the first turn prepares are queued', (
    WidgetTester tester,
  ) async {
    final _FakeHost host = _FakeHost(image);
    final PageCurlController curl = controllerFor(host);
    addTearDown(curl.dispose);

    // 三次按键同一帧内到达：第一次还在截图 / 预览（准备阶段）。
    int done = 0;
    for (int i = 0; i < 3; i++) {
      curl.turn(size: _size, forward: true, mirror: false).then((_) => done++);
    }
    for (int i = 0; i < 3; i++) {
      await settlePrepare(tester);
    }
    expect(done, 3);
    expect(host.calls.where((String c) => c == 'commit:f').length, 3);
    await settleAnimation(tester);
    expect(curl.active, isFalse);
  });

  testWidgets('a queued press that runs while the host is mid chapter load '
      'is handed to the host instead of curling', (WidgetTester tester) async {
    final _FakeHost host = _FakeHost(image);
    final PageCurlController curl = controllerFor(host);
    addTearDown(curl.dispose);

    // 第一页翻到章末、提交即触发换章；第二次按键排在它后面，轮到时宿主在飞。
    int done = 0;
    curl.turn(size: _size, forward: true, mirror: false).then((_) {
      done++;
      host.canCurl = false;
    });
    curl.turn(size: _size, forward: true, mirror: false).then((_) => done++);
    for (int i = 0; i < 2; i++) {
      await settlePrepare(tester);
    }
    expect(done, 2);
    expect(host.calls.where((String c) => c == 'commit:f').length, 1);
    // 在飞时不截图、不预览，直接交给宿主的普通翻页（宿主自己排队重放）。
    expect(host.calls.last, 'fallback:f');
    expect(host.calls.where((String c) => c == 'capture').length, 1);
    await settleAnimation(tester);
    expect(curl.active, isFalse);
  });

  for (final bool mirror in <bool>[false, true]) {
    testWidgets(
      'a quick fling released before prepare commits (mirror=$mirror)',
      (WidgetTester tester) async {
        final _FakeHost host = _FakeHost(image);
        final PageCurlController curl = controllerFor(host);
        addTearDown(curl.dispose);

        // 前进方向：左开往左甩，右开往右甩。屏幕坐标。
        final double sign = mirror ? 1 : -1;
        final double x0 = mirror ? 40 : 360;
        curl.dragStart(
          position: Offset(x0, 400),
          size: _size,
          forward: true,
          mirror: mirror,
        );
        curl.dragUpdate(Offset(x0 + sign * 30, 400));
        curl.dragEnd(Offset(x0 + sign * 60, 400), sign * 2.0);
        await settlePrepare(tester);
        await settleAnimation(tester);
        expect(host.calls, contains('commit:f'));
        expect(curl.active, isFalse);
      },
    );
  }

  testWidgets('a press during a finger drag yields to the gesture', (
    WidgetTester tester,
  ) async {
    final _FakeHost host = _FakeHost(image);
    final PageCurlController curl = controllerFor(host);
    addTearDown(curl.dispose);

    curl.dragStart(
      position: const Offset(380, 400),
      size: _size,
      forward: true,
      mirror: false,
    );
    await settlePrepare(tester);
    bool done = false;
    curl
        .turn(size: _size, forward: true, mirror: false)
        .then((_) => done = true);
    await tester.pump();
    expect(done, isTrue);
    curl.dragUpdate(const Offset(340, 400));
    curl.dragEnd(const Offset(340, 400), 0);
    await settleAnimation(tester);
    expect(host.calls.where((String c) => c.startsWith('commit')), isEmpty);
  });

  testWidgets('a drag during the settle fast-forwards and is not dropped', (
    WidgetTester tester,
  ) async {
    final _FakeHost host = _FakeHost(image);
    final PageCurlController curl = controllerFor(host);
    addTearDown(curl.dispose);

    curl.dragStart(
      position: const Offset(380, 400),
      size: _size,
      forward: true,
      mirror: false,
    );
    await settlePrepare(tester);
    curl.dragUpdate(const Offset(100, 400));
    curl.dragEnd(const Offset(100, 400), -0.5);
    await tester.pump();
    expect(curl.active, isTrue, reason: 'first curl still settling');

    expect(
      curl.dragStart(
        position: const Offset(380, 400),
        size: _size,
        forward: true,
        mirror: false,
      ),
      isTrue,
    );
    curl.dragUpdate(const Offset(100, 400));
    curl.dragEnd(const Offset(100, 400), -0.5);
    await settlePrepare(tester);
    await settleAnimation(tester);
    expect(host.calls.where((String c) => c == 'commit:f').length, 2);
    expect(curl.active, isFalse);
  });

  testWidgets('capture failure on a tap still turns the page', (
    WidgetTester tester,
  ) async {
    final _FakeHost host = _FakeHost(image)..captureFails = true;
    final PageCurlController curl = controllerFor(host);
    addTearDown(curl.dispose);

    bool done = false;
    curl
        .turn(size: _size, forward: false, mirror: false)
        .then((_) => done = true);
    await settlePrepare(tester);
    expect(done, isTrue);
    expect(host.calls, <String>['capture', 'fallback:b']);
    expect(curl.active, isFalse);
  });
}
