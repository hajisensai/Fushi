import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/playback_route_marks.dart';
import 'package:fushi/src/stats/study_cover_tracker.dart';

/// 播放页登记自己的路由：被它盖住的页面才算「被播放页盖住」（BUG-4084）。
class _FakePlayer extends StatefulWidget {
  const _FakePlayer({required this.marks});
  final PlaybackRouteMarks marks;

  @override
  State<_FakePlayer> createState() => _FakePlayerState();
}

class _FakePlayerState extends State<_FakePlayer> {
  late final PlaybackRouteMark _mark = PlaybackRouteMark(marks: widget.marks);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _mark.attach(ModalRoute.of(context));
  }

  @override
  void dispose() {
    _mark.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Text('player');
}

void main() {
  late StudyCoverTracker tracker;
  late PlaybackRouteMarks marks;
  late GlobalKey<NavigatorState> navKey;
  late List<bool> changes;
  late PlaybackCoverWatch watch;
  late BuildContext browserContext;

  Future<void> pumpApp(WidgetTester tester) async {
    tracker = StudyCoverTracker();
    marks = PlaybackRouteMarks();
    navKey = GlobalKey<NavigatorState>();
    changes = <bool>[];
    watch = PlaybackCoverWatch(
      tracker: tracker,
      marks: marks,
      onChanged: () => changes.add(watch.covered),
    );
    addTearDown(watch.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        navigatorObservers: <NavigatorObserver>[tracker],
        home: const Text('home'),
      ),
    );
    navKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) {
          browserContext = context;
          return const Text('browser');
        },
      ),
    );
    await tester.pumpAndSettle();
    watch.attach(ModalRoute.of(browserContext));
  }

  testWidgets('播放页盖住 → 盖住；返回 → 露出', (WidgetTester tester) async {
    await pumpApp(tester);
    expect(watch.covered, isFalse);

    navKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => _FakePlayer(marks: marks)),
    );
    await tester.pumpAndSettle();
    expect(watch.covered, isTrue);
    expect(changes, <bool>[true]);

    navKey.currentState!.pop();
    // 出栈当帧就判露出，不等转场、不等播放页拆完。
    await tester.pump();
    expect(watch.covered, isFalse);
    await tester.pumpAndSettle();
    expect(changes, <bool>[true, false]);
    expect(marks.isPlayback(ModalRoute.of(browserContext)!), isFalse);
  });

  testWidgets('别的整页路由（设置页等）盖住不算', (WidgetTester tester) async {
    await pumpApp(tester);
    navKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('settings')),
    );
    await tester.pumpAndSettle();
    expect(watch.covered, isFalse);
    expect(changes, isEmpty);
  });

  testWidgets('播放页之上再压一页仍算盖住；播放页在浏览页下面不算', (WidgetTester tester) async {
    await pumpApp(tester);
    navKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => _FakePlayer(marks: marks)),
    );
    await tester.pumpAndSettle();
    navKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('panel')),
    );
    await tester.pumpAndSettle();
    expect(watch.covered, isTrue);

    // 从播放页再开一个浏览页：它下面的播放页不算盖住它。
    late BuildContext upperContext;
    navKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) {
          upperContext = context;
          return const Text('browser 2');
        },
      ),
    );
    await tester.pumpAndSettle();
    final PlaybackCoverWatch upper = PlaybackCoverWatch(
      tracker: tracker,
      marks: marks,
      onChanged: () {},
    );
    addTearDown(upper.dispose);
    upper.attach(ModalRoute.of(upperContext));
    expect(upper.covered, isFalse);
  });

  test('routesAbove：不在栈里的路由 → 空', () {
    final StudyCoverTracker t = StudyCoverTracker();
    final Route<void> r = MaterialPageRoute<void>(
      builder: (_) => const SizedBox(),
    );
    expect(t.routesAbove(null), isEmpty);
    expect(t.routesAbove(r), isEmpty);
  });
}
