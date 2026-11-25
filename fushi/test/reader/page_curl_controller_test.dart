import 'dart:async';
import 'dart:math' show pi;
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

  /// 非 null 时截图卡在这里，模拟准备阶段（截图最长 450ms）里到达的交错事件。
  Completer<void>? captureGate;

  /// 宿主是否就绪（false = 换章 / 恢复在飞）。第一次被查询后可改，模拟连按中途跨章。
  @override
  bool canCurl = true;

  @override
  Future<ui.Image?> capturePage() async {
    calls.add('capture');
    final Completer<void>? gate = captureGate;
    if (gate != null) await gate.future;
    return captureFails ? null : image.clone();
  }

  /// 宿主报告的纸面矩形（null = 整个视口）。不进 [calls]：生命周期断言不关心它。
  Rect? paper;

  /// 双页时对面那一页（null = 单页）。
  Rect? facing;

  @override
  Future<PageCurlPaper?> paperRect() async {
    final Rect? rect = paper;
    return rect == null ? null : PageCurlPaper(rect, facing: facing);
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
  Future<void> swipeTurn({required bool forward}) async =>
      calls.add('swipe:${forward ? 'f' : 'b'}');

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

  group('Apple Books follow geometry', () {
    test('a drag lifts the real corner on the pressed half', () {
      expect(pageCurlCornerYFor(_size, 100), 0);
      expect(pageCurlCornerYFor(_size, 700), 800);
    });

    test('the paper edge catches up to the finger, then stays under it', () {
      Offset follow(Offset finger) => pageCurlFollowPoint(
        size: _size,
        start: const Offset(200, 400),
        finger: finger,
        cornerY: 800,
        forward: true,
      );
      // 刚按下：纸面平铺，角点在原位（不跳）。
      expect(follow(const Offset(200, 400)).dx, closeTo(400, 0.001));
      // 拖过追手距离后：纸边就在手指下。
      expect(follow(const Offset(50, 400)).dx, closeTo(50, 0.001));
      // 往反方向拖：不倒卷。
      expect(follow(const Offset(300, 400)).dx, closeTo(400, 0.001));
    });

    test('pressing near a corner lifts it toward the finger', () {
      Offset follow(Offset finger, {required double startY}) =>
          pageCurlFollowPoint(
            size: _size,
            start: Offset(380, startY),
            finger: finger,
            cornerY: 800,
            forward: true,
          );
      // 按在右下角附近（y = 720）横拖半页：角抬到手指高度，折痕是斜的。
      expect(
        follow(const Offset(180, 720), startY: 720).dy,
        closeTo(720, 0.001),
      );
      // 按在边缘中段（y = 420）横拖：角留在下缘，折痕竖直。
      expect(follow(const Offset(180, 420), startY: 420).dy, closeTo(800, 0.5));
    });

    test('a backward drag pulls the previous page in at twice the speed', () {
      final Offset p = pageCurlFollowPoint(
        size: _size,
        start: const Offset(20, 700),
        finger: const Offset(120, 700),
        cornerY: 800,
        forward: false,
      );
      expect(p.dx, closeTo(-200, 0.001));
    });
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

    final PageCurlDrag drag = curl.dragStart(
      position: const Offset(380, 400),
      size: _size,
      forward: true,
      mirror: false,
    );
    expect(drag.curling, isTrue);
    await settlePrepare(tester);
    expect(host.calls, <String>['capture', 'preview:f', 'paint']);
    expect(curl.visible, isTrue);

    drag.update(const Offset(200, 420));
    // 按在右缘附近：纸边追到手指下，之后贴着手指走。
    expect(curl.geometry.point.dx, closeTo(200, 0.5));
    drag.end(const Offset(200, 420), -0.1);
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

    final PageCurlDrag drag = curl.dragStart(
      position: const Offset(380, 400),
      size: _size,
      forward: true,
      mirror: false,
    );
    await settlePrepare(tester);
    drag.update(const Offset(340, 400));
    drag.end(const Offset(340, 400), 0);
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

    final PageCurlDrag drag = curl.dragStart(
      position: const Offset(20, 400),
      size: _size,
      forward: false,
      mirror: false,
    );
    await settlePrepare(tester);
    expect(host.calls, <String>['capture', 'preview:b', 'paint', 'capture']);
    expect(curl.base, isNotNull);
    drag.update(const Offset(220, 400));
    drag.end(const Offset(220, 400), 0.2);
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

    final PageCurlDrag drag = curl.dragStart(
      position: const Offset(380, 400),
      size: _size,
      forward: true,
      mirror: false,
    );
    await settlePrepare(tester);
    expect(curl.visible, isFalse);
    expect(drag.curling, isFalse, reason: 'aborted drag becomes a plain swipe');
    drag.end(const Offset(150, 400), 0);
    await tester.pump();
    // 拖动中途放弃 = 普通滑动：走宿主的滑动入口（跨章 / 在飞排队由宿主负责）。
    expect(host.calls, contains('swipe:f'));
    expect(host.calls, isNot(contains('fallback:f')));
    expect(host.calls.where((String c) => c.startsWith('commit')), isEmpty);
  });

  testWidgets('mirrored (right-to-left) drags follow the finger rightwards', (
    WidgetTester tester,
  ) async {
    final _FakeHost host = _FakeHost(image);
    final PageCurlController curl = controllerFor(host);
    addTearDown(curl.dispose);

    // 右开：前进 = 往右拖，书脊在右；几何在未镜像空间里与左开前进一致。
    final PageCurlDrag drag = curl.dragStart(
      position: const Offset(20, 400),
      size: _size,
      forward: true,
      mirror: true,
    );
    await settlePrepare(tester);
    drag.update(const Offset(220, 400));
    expect(curl.geometry.mirror, isTrue);
    expect(curl.geometry.point.dx, closeTo(180, 0.5));
    drag.end(const Offset(220, 400), 0.3);
    await settleAnimation(tester);
    expect(host.calls, contains('commit:f'));
  });

  group('spine constraint (Apple Books drag range)', () {
    const Offset corner = Offset(400, 800);
    final double radius = pageCurlRadiusFor(_size);
    const List<Offset> spine = <Offset>[Offset.zero, Offset(0, 800)];

    // 两个书脊角都在卷轴平铺一侧：|P − S|² ≤ |C − S|² − π·r·|C − P|。
    void expectFeasible(Offset p, double r) {
      final double len = (corner - p).distance;
      for (final Offset s in spine) {
        expect(
          (p - s).distanceSquared,
          lessThanOrEqualTo((corner - s).distanceSquared - pi * r * len + 1),
          reason: 'spine corner $s crosses the roll at point $p, r $r',
        );
      }
    }

    test('a modest drag is left alone', () {
      const Offset raw = Offset(300, 760);
      final ({Offset point, double radius}) c = constrainPageCurl(
        corner: corner,
        point: raw,
        size: _size,
        radius: radius,
        settling: false,
      );
      expect(c.point, raw);
      expect(c.radius, closeTo((corner - raw).distance / pi, 1e-9));
    });

    test('an extreme drag past the spine is pulled back into range', () {
      const Offset raw = Offset(-300, 300);
      final ({Offset point, double radius}) c = constrainPageCurl(
        corner: corner,
        point: raw,
        size: _size,
        radius: radius,
        settling: false,
      );
      expect(c.point, isNot(raw));
      expect(c.radius, inInclusiveRange(0, radius));
      expectFeasible(c.point, c.radius);
    });

    test('settling may roll further than a drag, down to a zero radius', () {
      const Offset raw = Offset(-300, 300);
      final ({Offset point, double radius}) drag = constrainPageCurl(
        corner: corner,
        point: raw,
        size: _size,
        radius: radius,
        settling: false,
      );
      final ({Offset point, double radius}) settle = constrainPageCurl(
        corner: corner,
        point: raw,
        size: _size,
        radius: radius,
        settling: true,
      );
      expect(
        (corner - settle.point).distance,
        greaterThanOrEqualTo((corner - drag.point).distance),
      );
      expectFeasible(settle.point, 0);
    });

    test('the fully turned page is reachable and lies flat', () {
      final ({Offset point, double radius}) c = constrainPageCurl(
        corner: corner,
        point: pageCurlTurnedPoint(_size, 800),
        size: _size,
        radius: radius,
        settling: true,
      );
      expect(c.point.dx, closeTo(-400, 0.5));
      expect(c.point.dy, closeTo(800, 0.5));
      expect(c.radius, closeTo(0, 1e-6));
    });
  });

  group('paper rect (manga letterbox is not paper)', () {
    testWidgets('a forward drag curls only the reported page rect', (
      WidgetTester tester,
    ) async {
      // 页图上下留黑边：纸面只有中间 400×500。
      final _FakeHost host = _FakeHost(image)
        ..paper = const Rect.fromLTWH(0, 150, 400, 500);
      final PageCurlController curl = controllerFor(host);
      addTearDown(curl.dispose);

      final PageCurlDrag drag = curl.dragStart(
        position: const Offset(380, 400),
        size: _size,
        forward: true,
        mirror: false,
      );
      await settlePrepare(tester);
      expect(curl.geometry.paper, const Rect.fromLTWH(0, 150, 400, 500));
      // 按在纸面下半：拎纸面的右下真角（纸面局部坐标）。
      expect(curl.geometry.corner, const Offset(400, 500));
      drag.update(const Offset(200, 420));
      expect(curl.geometry.point.dx, closeTo(200, 0.5));
      // 按在边缘中段：角点不往手指抬，只带上手指的纵向位移（+20）。
      expect(curl.geometry.point.dy, closeTo(520, 0.5));
      drag.end(const Offset(200, 420), -0.1);
      await settleAnimation(tester);
      expect(host.calls, contains('commit:f'));
    });

    testWidgets('a pillarboxed mirrored page keeps its spine on its own edge', (
      WidgetTester tester,
    ) async {
      // 右开、页图左右留黑边：纸面 [50, 350]，书脊在纸面右缘 x = 350。
      final _FakeHost host = _FakeHost(image)
        ..paper = const Rect.fromLTWH(50, 0, 300, 800);
      final PageCurlController curl = controllerFor(host);
      addTearDown(curl.dispose);

      final PageCurlDrag drag = curl.dragStart(
        position: const Offset(60, 400),
        size: _size,
        forward: true,
        mirror: true,
      );
      await settlePrepare(tester);
      expect(curl.geometry.corner, const Offset(300, 800));
      // 按下点离纸面左缘（镜像后的角）10px；往右拖 100 → 纸边已追到手指下，
      // 角点在局部 x = 190。
      drag.update(const Offset(160, 400));
      expect(curl.geometry.point.dx, closeTo(190, 0.5));
      drag.cancel();
      await settleAnimation(tester);
    });

    testWidgets('a tap turn lifts the low corner of the page rect', (
      WidgetTester tester,
    ) async {
      final _FakeHost host = _FakeHost(image)
        ..paper = const Rect.fromLTWH(0, 200, 400, 400);
      final PageCurlController curl = controllerFor(host);
      addTearDown(curl.dispose);

      unawaited(curl.turn(size: _size, forward: true, mirror: false));
      await settlePrepare(tester);
      expect(curl.geometry.corner, const Offset(400, 400));
      await settleAnimation(tester);
      expect(host.calls, contains('commit:f'));
    });

    testWidgets('a degenerate rect falls back to the whole viewport', (
      WidgetTester tester,
    ) async {
      final _FakeHost host = _FakeHost(image)
        ..paper = const Rect.fromLTWH(500, 0, 10, 10);
      final PageCurlController curl = controllerFor(host);
      addTearDown(curl.dispose);

      final PageCurlDrag drag = curl.dragStart(
        position: const Offset(380, 400),
        size: _size,
        forward: true,
        mirror: false,
      );
      await settlePrepare(tester);
      expect(curl.geometry.paper, Offset.zero & _size);
      drag.cancel();
      await settleAnimation(tester);
    });
  });

  group('two-page spread (only the outer page turns)', () {
    test('pageCurlSpreadPaper splits the view at the spine', () {
      const Size view = Size(1000, 600);
      final PageCurlPaper? ltr = pageCurlSpreadPaper(
        view: view,
        spineX: 480,
        mirror: false,
      );
      expect(ltr?.rect, const Rect.fromLTRB(480, 0, 1000, 600));
      expect(ltr?.facing, const Rect.fromLTRB(0, 0, 480, 600));
      expect(ltr?.spread, isTrue);
      final PageCurlPaper? rtl = pageCurlSpreadPaper(
        view: view,
        spineX: 480,
        mirror: true,
      );
      expect(rtl?.rect, const Rect.fromLTRB(0, 0, 480, 600));
      expect(rtl?.facing, const Rect.fromLTRB(480, 0, 1000, 600));
      expect(
        pageCurlSpreadPaper(view: view, spineX: 0, mirror: false),
        isNull,
        reason: '中缝不在视口内就按单页卷整个视口',
      );
      expect(
        pageCurlSpreadPaper(view: Size.zero, spineX: 10, mirror: false),
        isNull,
      );
    });

    testWidgets('forward: curls the right page around the spine and captures '
        'the next spread as the back of the sheet', (
      WidgetTester tester,
    ) async {
      final _FakeHost host = _FakeHost(image)
        ..paper = const Rect.fromLTRB(200, 0, 400, 800)
        ..facing = const Rect.fromLTRB(0, 0, 200, 800);
      final PageCurlController curl = controllerFor(host);
      addTearDown(curl.dispose);

      unawaited(curl.turn(size: _size, forward: true, mirror: false));
      await settlePrepare(tester);
      // 截当前跨页 → 预览下一跨页 → 等绘制 → 再截一张当纸背。
      expect(host.calls.take(4).toList(), <String>[
        'capture',
        'preview:f',
        'paint',
        'capture',
      ]);
      expect(curl.back, isNotNull);
      expect(curl.geometry.paper, const Rect.fromLTRB(200, 0, 400, 800));
      expect(curl.geometry.facing, const Rect.fromLTRB(0, 0, 200, 800));
      // 纸面局部：书脊在 x = 0（中缝），拎起的角在纸面宽（外侧页的外缘）。
      expect(curl.geometry.corner, const Offset(200, 800));
      await settleAnimation(tester);
      expect(host.calls, contains('commit:f'));
      expect(curl.visible, isFalse);
    });

    testWidgets('backward: the back of the sheet is the current spread', (
      WidgetTester tester,
    ) async {
      final _FakeHost host = _FakeHost(image)
        ..paper = const Rect.fromLTRB(200, 0, 400, 800)
        ..facing = const Rect.fromLTRB(0, 0, 200, 800);
      final PageCurlController curl = controllerFor(host);
      addTearDown(curl.dispose);

      unawaited(curl.turn(size: _size, forward: false, mirror: false));
      await settlePrepare(tester);
      expect(host.calls.take(4).toList(), <String>[
        'capture',
        'preview:b',
        'paint',
        'capture',
      ]);
      expect(curl.back, isNotNull);
      expect(identical(curl.back, curl.base), isTrue);
      await settleAnimation(tester);
      expect(host.calls, contains('commit:b'));
    });

    testWidgets('single page never takes the extra capture', (
      WidgetTester tester,
    ) async {
      final _FakeHost host = _FakeHost(image);
      final PageCurlController curl = controllerFor(host);
      addTearDown(curl.dispose);

      unawaited(curl.turn(size: _size, forward: true, mirror: false));
      await settlePrepare(tester);
      expect(curl.back, isNull);
      expect(curl.geometry.facing, isNull);
      await settleAnimation(tester);
      expect(host.calls.where((String c) => c == 'capture').length, 1);
    });
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
        final PageCurlDrag drag = curl.dragStart(
          position: Offset(x0, 400),
          size: _size,
          forward: true,
          mirror: mirror,
        );
        drag.update(Offset(x0 + sign * 30, 400));
        drag.end(Offset(x0 + sign * 60, 400), sign * 2.0);
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

    final PageCurlDrag drag = curl.dragStart(
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
    drag.update(const Offset(340, 400));
    drag.end(const Offset(340, 400), 0);
    await settleAnimation(tester);
    expect(host.calls.where((String c) => c.startsWith('commit')), isEmpty);
  });

  testWidgets('a drag during the settle fast-forwards and is not dropped', (
    WidgetTester tester,
  ) async {
    final _FakeHost host = _FakeHost(image);
    final PageCurlController curl = controllerFor(host);
    addTearDown(curl.dispose);

    final PageCurlDrag drag = curl.dragStart(
      position: const Offset(380, 400),
      size: _size,
      forward: true,
      mirror: false,
    );
    await settlePrepare(tester);
    drag.update(const Offset(100, 400));
    drag.end(const Offset(100, 400), -0.5);
    await tester.pump();
    expect(curl.active, isTrue, reason: 'first curl still settling');

    final PageCurlDrag second = curl.dragStart(
      position: const Offset(380, 400),
      size: _size,
      forward: true,
      mirror: false,
    );
    expect(second.curling, isTrue);
    second.update(const Offset(100, 400));
    second.end(const Offset(100, 400), -0.5);
    await settlePrepare(tester);
    await settleAnimation(tester);
    expect(host.calls.where((String c) => c == 'commit:f').length, 2);
    expect(host.calls, isNot(contains('swipe:f')));
    expect(curl.active, isFalse);
  });

  group('drag events are bound to their own session', () {
    testWidgets('a drag arriving while a tap prepares cannot touch the tap '
        'and is handed over as a plain swipe', (WidgetTester tester) async {
      final _FakeHost host = _FakeHost(image)..captureGate = Completer<void>();
      final PageCurlController curl = controllerFor(host);
      addTearDown(curl.dispose);

      bool tapDone = false;
      curl
          .turn(size: _size, forward: true, mirror: false)
          .then((_) => tapDone = true);
      await tester.pump();
      expect(host.calls, <String>['capture'], reason: 'tap is preparing');

      // 点按准备期间手指拖动：拿到的句柄不卷页，事件不改写点按会话。
      final PageCurlDrag drag = curl.dragStart(
        position: const Offset(380, 400),
        size: _size,
        forward: true,
        mirror: false,
      );
      expect(drag.curling, isFalse);
      drag.update(const Offset(360, 100));
      drag.end(const Offset(100, 400), -0.8);
      await tester.pump();
      // 被拒的滑动照常翻页（宿主滑动入口，排在点按后面），而不是被吞。
      expect(host.calls.last, 'swipe:f');

      host.captureGate!.complete();
      await settlePrepare(tester);
      expect(tapDone, isTrue);
      // 点按自己的会话照常提交一次、不回卷。
      expect(host.calls.where((String c) => c == 'commit:f').length, 1);
      expect(host.calls, isNot(contains('revert')));
      await settleAnimation(tester);
      expect(curl.active, isFalse);
    });

    testWidgets('a cancel from a rejected drag does not revert the tap', (
      WidgetTester tester,
    ) async {
      final _FakeHost host = _FakeHost(image)..captureGate = Completer<void>();
      final PageCurlController curl = controllerFor(host);
      addTearDown(curl.dispose);

      curl.turn(size: _size, forward: true, mirror: false);
      await tester.pump();
      final PageCurlDrag drag = curl.dragStart(
        position: const Offset(380, 400),
        size: _size,
        forward: true,
        mirror: false,
      );
      drag.update(const Offset(300, 400));
      drag.cancel();

      host.captureGate!.complete();
      await settlePrepare(tester);
      await settleAnimation(tester);
      expect(host.calls.where((String c) => c == 'commit:f').length, 1);
      expect(host.calls, isNot(contains('revert')));
      expect(host.calls, isNot(contains('swipe:f')));
    });

    testWidgets('a tap at the chapter end still crosses the chapter when a '
        'short drag interleaves', (WidgetTester tester) async {
      final _FakeHost host = _FakeHost(image)
        ..hasNeighbour = false
        ..captureGate = Completer<void>();
      final PageCurlController curl = controllerFor(host);
      addTearDown(curl.dispose);

      bool tapDone = false;
      curl
          .turn(size: _size, forward: true, mirror: false)
          .then((_) => tapDone = true);
      await tester.pump();
      // 一次很短的拖动（按滑动口径不翻页）在点按准备期间松手。
      final PageCurlDrag drag = curl.dragStart(
        position: const Offset(380, 400),
        size: _size,
        forward: true,
        mirror: false,
      );
      drag.update(const Offset(370, 400));
      drag.end(const Offset(370, 400), 0);

      host.captureGate!.complete();
      await settlePrepare(tester);
      expect(tapDone, isTrue);
      // 点按的跨章翻页不被拖动的进度改判。
      expect(host.calls, contains('fallback:f'));
      expect(host.calls, isNot(contains('swipe:f')));
    });

    testWidgets('a tap while an aborted drag is still held is not polluted', (
      WidgetTester tester,
    ) async {
      final _FakeHost host = _FakeHost(image)..hasNeighbour = false;
      final PageCurlController curl = controllerFor(host);
      addTearDown(curl.dispose);

      final PageCurlDrag drag = curl.dragStart(
        position: const Offset(380, 400),
        size: _size,
        forward: true,
        mirror: false,
      );
      await settlePrepare(tester);
      expect(drag.curling, isFalse, reason: 'no neighbour: aborted mid-drag');

      // 手指还按着时按键翻上一页：走自己的会话。
      host.hasNeighbour = true;
      bool tapDone = false;
      curl
          .turn(size: _size, forward: false, mirror: false)
          .then((_) => tapDone = true);
      await settlePrepare(tester);
      expect(tapDone, isTrue);
      expect(host.calls, contains('commit:b'));

      // 松手只按它自己的起点 / 位移判普通滑动。
      drag.end(const Offset(330, 400), 0);
      await tester.pump();
      expect(host.calls, isNot(contains('swipe:f')));
      await settleAnimation(tester);
      expect(curl.active, isFalse);
    });

    testWidgets('while the host is mid chapter load a drag is a plain swipe', (
      WidgetTester tester,
    ) async {
      final _FakeHost host = _FakeHost(image)..canCurl = false;
      final PageCurlController curl = controllerFor(host);
      addTearDown(curl.dispose);

      final PageCurlDrag drag = curl.dragStart(
        position: const Offset(20, 400),
        size: _size,
        forward: false,
        mirror: false,
      );
      expect(drag.curling, isFalse);
      drag.update(const Offset(250, 400));
      drag.end(const Offset(250, 400), 0.1);
      await tester.pump();
      // 不截图、不卷，交给宿主的滑动入口（换章在飞时由宿主排队重放）。
      expect(host.calls, <String>['swipe:b']);
      expect(curl.active, isFalse);
    });

    testWidgets('a drag while curl is disabled by the host is a plain swipe', (
      WidgetTester tester,
    ) async {
      final _FakeHost host = _FakeHost(image);
      final PageCurlController curl = controllerFor(host);
      addTearDown(curl.dispose);

      final PageCurlDrag drag = curl.dragStart(
        position: const Offset(380, 400),
        size: _size,
        forward: true,
        mirror: false,
        allowCurl: false,
      );
      expect(drag.curling, isFalse);
      drag.end(const Offset(340, 400), 0);
      await tester.pump();
      expect(host.calls, isEmpty, reason: 'short drag does not turn');

      final PageCurlDrag fling = curl.dragStart(
        position: const Offset(380, 400),
        size: _size,
        forward: true,
        mirror: false,
        allowCurl: false,
      );
      fling.end(const Offset(340, 400), -1.5);
      await tester.pump();
      expect(host.calls, <String>['swipe:f']);
    });

    testWidgets('a stale drag handle is ignored by the next session', (
      WidgetTester tester,
    ) async {
      final _FakeHost host = _FakeHost(image);
      final PageCurlController curl = controllerFor(host);
      addTearDown(curl.dispose);

      final PageCurlDrag first = curl.dragStart(
        position: const Offset(380, 400),
        size: _size,
        forward: true,
        mirror: false,
      );
      await settlePrepare(tester);
      first.cancel();
      await settleAnimation(tester);
      expect(curl.active, isFalse);

      final PageCurlDrag second = curl.dragStart(
        position: const Offset(380, 400),
        size: _size,
        forward: true,
        mirror: false,
      );
      await settlePrepare(tester);
      // 旧句柄迟到的事件不动新会话。
      first.update(const Offset(0, 0));
      first.end(const Offset(0, 0), -3);
      second.update(const Offset(360, 400));
      // 拖了 20px：纸边还在追手指的途中（smoothstep(0.2) = 0.104）。
      expect(curl.geometry.point.dx, closeTo(377.92, 0.5));
      second.end(const Offset(360, 400), 0);
      await settleAnimation(tester);
      expect(host.calls.where((String c) => c.startsWith('commit')), isEmpty);
      expect(host.calls.where((String c) => c == 'revert').length, 2);
    });
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
