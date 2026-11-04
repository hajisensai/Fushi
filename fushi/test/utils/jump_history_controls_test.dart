import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_jump_history_controls.dart';
import 'package:fushi/src/utils/misc/jump_history.dart';

/// 「跳转记录」共用件（2026-11-02 浮动胶囊改顶栏图标）：历史栈的条目 / 多步走、
/// 旧设置折算、自动隐藏判据、面板行序、刻度几何、顶栏按钮长按。
void main() {
  DateTime now = DateTime(2026, 11, 2, 12);
  JumpHistory<int> history() =>
      JumpHistory<int>(isSamePlace: (int a, int b) => a == b, clock: () => now);

  group('JumpHistory entries', () {
    test('records time and source, refreshes same-place top', () {
      final JumpHistory<int> h = history();
      expect(h.recordDeparture(10, source: JumpSource.search), isTrue);
      now = now.add(const Duration(minutes: 1));
      expect(
        h.recordDeparture(10, source: JumpSource.tableOfContents),
        isFalse,
      );
      expect(h.backEntries, hasLength(1));
      expect(h.backEntries.single.source, JumpSource.tableOfContents);
      expect(h.backEntries.single.at, now);
    });

    test('goBackSteps equals repeated goBack', () {
      final JumpHistory<int> a = history();
      final JumpHistory<int> b = history();
      for (final JumpHistory<int> h in <JumpHistory<int>>[a, b]) {
        h.recordDeparture(1);
        h.recordDeparture(2);
        h.recordDeparture(3);
      }
      expect(a.goBackSteps(4, 3), 1);
      int here = 4;
      for (int i = 0; i < 3; i++) {
        here = b.goBack(here)!;
      }
      expect(here, 1);
      expect(
        a.forwardEntries.map((JumpHistoryEntry<int> e) => e.point),
        b.forwardEntries.map((JumpHistoryEntry<int> e) => e.point),
      );
      expect(a.goForwardSteps(1, 2), 3);
      expect(a.backTarget, 2);
      expect(a.forwardTarget, 4);
    });

    test('steps out of range leave stacks untouched', () {
      final JumpHistory<int> h = history()..recordDeparture(1);
      expect(h.goBackSteps(2, 2), isNull);
      expect(h.goForwardSteps(2, 1), isNull);
      expect(h.backTarget, 1);
    });

    test('replaceBackTop keeps time and source', () {
      final JumpHistory<int> h = history()
        ..recordDeparture(1, source: JumpSource.cue);
      h.replaceBackTop(7);
      expect(h.backEntries.single.point, 7);
      expect(h.backEntries.single.source, JumpSource.cue);
    });
  });

  group('settings', () {
    test('legacy video auto-hide migrates', () {
      expect(migrateLegacyJumpPillAutoHide(null), 0);
      expect(migrateLegacyJumpPillAutoHide(0), 0);
      expect(migrateLegacyJumpPillAutoHide(5), 30);
      expect(migrateLegacyJumpPillAutoHide(15), 30);
      expect(kJumpHistoryAutoHideDefaultSeconds, 0);
      expect(kJumpHistoryAutoHideOptions.first, 0);
    });

    test('toolbar visibility needs setting, history and no expiry', () {
      expect(
        jumpHistoryToolbarVisible(
          enabled: true,
          hasHistory: true,
          expired: false,
        ),
        isTrue,
      );
      expect(
        jumpHistoryToolbarVisible(
          enabled: false,
          hasHistory: true,
          expired: false,
        ),
        isFalse,
      );
      expect(
        jumpHistoryToolbarVisible(
          enabled: true,
          hasHistory: false,
          expired: false,
        ),
        isFalse,
      );
      expect(
        jumpHistoryToolbarVisible(
          enabled: true,
          hasHistory: true,
          expired: true,
        ),
        isFalse,
      );
    });
  });

  test('panel rows: forward far-to-near, current, back near-to-far', () {
    final JumpHistory<int> h = history()
      ..recordDeparture(1)
      ..recordDeparture(2)
      ..recordDeparture(3);
    h.goBackSteps(4, 2); // here = 2; back [1]; forward [4, 3]
    final List<JumpHistoryPanelRow<int>> rows = jumpHistoryPanelRows<int>(h);
    expect(rows.map((JumpHistoryPanelRow<int> r) => r.steps), <int>[
      2,
      1,
      0,
      -1,
    ]);
    expect(rows.map((JumpHistoryPanelRow<int> r) => r.point), <int?>[
      4,
      3,
      null,
      1,
    ]);
    // 点「前进 2 步」落到 4。
    expect(h.goForwardSteps(2, rows.first.steps), 4);
  });

  test('mark fractions skip points off this axis', () {
    final JumpHistory<int> h = history()
      ..recordDeparture(10)
      ..recordDeparture(-1)
      ..recordDeparture(50);
    h.goBack(80);
    final ({List<double> back, List<double> forward}) marks =
        jumpHistoryMarkFractions<int>(h, (int p) => p < 0 ? null : p / 100);
    expect(marks.back, <double>[0.1]);
    expect(marks.forward, <double>[0.8]);
  });

  test('tick rect sits on the fraction, vertically centred', () {
    final Rect r = JumpProgressMarksPainter.tickRect(
      const Size(200, 20),
      0.25,
      tickWidth: 4,
      tickHeight: 14,
    );
    expect(r.center, const Offset(50, 10));
    expect(r.width, 4);
    expect(r.height, 14);
  });

  testWidgets('back button: tap walks back, long-press opens the panel', (
    WidgetTester tester,
  ) async {
    int back = 0;
    int panel = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: FushiJumpHistoryActions(
              items: jumpHistoryToolbarItems(
                backLabel: '12.4%',
                forwardLabel: null,
                onBack: () => back++,
                onForward: () {},
                onOpenPanel: () => panel++,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('fushi_jump_forward')),
      findsNothing,
    );
    final Finder backButton = find.byKey(
      const ValueKey<String>('fushi_jump_back'),
    );
    await tester.tap(backButton);
    await tester.pumpAndSettle();
    expect(back, 1);
    await tester.longPress(backButton);
    await tester.pumpAndSettle();
    expect(panel, 1);
    expect(back, 1);
  });

  test('no labels, no items', () {
    expect(
      jumpHistoryToolbarItems(
        backLabel: null,
        forwardLabel: null,
        onBack: () {},
        onForward: () {},
        onOpenPanel: () {},
      ),
      isEmpty,
    );
    expect(
      jumpHistoryToolbarItems(
        backLabel: '1',
        forwardLabel: '2',
        onBack: () {},
        onForward: () {},
        onOpenPanel: () {},
      ).every((FushiToolbarItem i) => i.emphasized && i.onLongPress != null),
      isTrue,
    );
  });

  group('JumpHistoryAutoHide (single-source timer)', () {
    const JumpHistoryPrefs base = JumpHistoryPrefs(
      toolbar: true,
      progressMarks: true,
      autoHideSeconds: 30,
    );
    JumpHistoryPrefs withSeconds(int s) => JumpHistoryPrefs(
      toolbar: base.toolbar,
      progressMarks: base.progressMarks,
      autoHideSeconds: s,
    );

    test('expires exactly when its timer fires, once', () {
      fakeAsync((FakeAsync async) {
        final ValueNotifier<JumpHistoryPrefs> prefs =
            ValueNotifier<JumpHistoryPrefs>(base);
        final JumpHistoryAutoHide hide = JumpHistoryAutoHide(
          prefs: prefs,
          stopwatch: () => async.getClock(DateTime(2026)).stopwatch(),
        );
        int notified = 0;
        hide.addListener(() => notified++);
        expect(hide.expired, isFalse);
        hide.markJump();
        expect(notified, 1);
        async.elapse(const Duration(seconds: 29));
        expect(hide.expired, isFalse);
        async.elapse(const Duration(seconds: 1));
        expect(hide.expired, isTrue);
        expect(notified, 2);
        async.elapse(const Duration(minutes: 5));
        expect(notified, 2);
        // 下一次跳转：图标回来、重新计时。
        hide.markJump();
        expect(hide.expired, isFalse);
        hide.dispose();
      });
    });

    test('setting changed to "never" cancels the timer and shows again', () {
      fakeAsync((FakeAsync async) {
        final ValueNotifier<JumpHistoryPrefs> prefs =
            ValueNotifier<JumpHistoryPrefs>(base);
        final JumpHistoryAutoHide hide = JumpHistoryAutoHide(
          prefs: prefs,
          stopwatch: () => async.getClock(DateTime(2026)).stopwatch(),
        )..markJump();
        async.elapse(const Duration(seconds: 10));
        prefs.value = withSeconds(0);
        async.elapse(const Duration(minutes: 10));
        expect(hide.expired, isFalse, reason: '改成不隐藏后旧计时器不得到点');
        prefs.value = withSeconds(30);
        expect(hide.expired, isTrue, reason: '距上次跳转已过 10 分钟 ≥ 30 秒');
        // 已经藏了再改成不隐藏：图标回来。
        prefs.value = withSeconds(0);
        expect(hide.expired, isFalse);
        hide.dispose();
      });
    });

    test('setting changed mid-wait reschedules from monotonic elapsed', () {
      fakeAsync((FakeAsync async) {
        final ValueNotifier<JumpHistoryPrefs> prefs =
            ValueNotifier<JumpHistoryPrefs>(withSeconds(0));
        final JumpHistoryAutoHide hide = JumpHistoryAutoHide(
          prefs: prefs,
          stopwatch: () => async.getClock(DateTime(2026)).stopwatch(),
        )..markJump();
        async.elapse(const Duration(seconds: 20));
        expect(hide.expired, isFalse);
        // 0 → 60：从「已过去 20 秒」起算，再 40 秒到点；不是随下一次重建随机消失。
        prefs.value = withSeconds(60);
        async.elapse(const Duration(seconds: 39));
        expect(hide.expired, isFalse);
        async.elapse(const Duration(seconds: 1));
        expect(hide.expired, isTrue);
        hide.dispose();
      });
    });

    test('reset stops the timer; no jump yet never expires', () {
      fakeAsync((FakeAsync async) {
        final ValueNotifier<JumpHistoryPrefs> prefs =
            ValueNotifier<JumpHistoryPrefs>(base);
        final JumpHistoryAutoHide hide = JumpHistoryAutoHide(
          prefs: prefs,
          stopwatch: () => async.getClock(DateTime(2026)).stopwatch(),
        );
        prefs.value = withSeconds(5);
        async.elapse(const Duration(minutes: 1));
        expect(hide.expired, isFalse);
        hide.markJump();
        hide.reset();
        async.elapse(const Duration(minutes: 1));
        expect(hide.expired, isFalse);
        hide.dispose();
      });
    });
  });

  group('JumpHistoryPrefsListenable', () {
    test('notifies only when one of the three jump settings changes', () {
      // 偏好仓库的替身：写任何偏好都会通知。
      final ValueNotifier<int> source = ValueNotifier<int>(0);
      JumpHistoryPrefs current = const JumpHistoryPrefs(
        toolbar: true,
        progressMarks: true,
        autoHideSeconds: 0,
      );
      final JumpHistoryPrefsListenable prefs = JumpHistoryPrefsListenable(
        source: source,
        read: () => current,
      );
      int notified = 0;
      prefs.addListener(() => notified++);
      // 写了别的偏好：值没变，不连带重建。
      source.value++;
      expect(notified, 0);
      current = const JumpHistoryPrefs(
        toolbar: false,
        progressMarks: true,
        autoHideSeconds: 0,
      );
      source.value++;
      expect(notified, 1);
      expect(prefs.value.toolbar, isFalse);
      prefs.dispose();
      // dispose 后不再监听源。
      source.value++;
      source.dispose();
    });

    testWidgets(
      'toggling the toolbar setting hides / shows the buttons at once',
      (WidgetTester tester) async {
        final ValueNotifier<int> source = ValueNotifier<int>(0);
        bool toolbar = true;
        final JumpHistoryPrefsListenable prefs = JumpHistoryPrefsListenable(
          source: source,
          read: () => JumpHistoryPrefs(
            toolbar: toolbar,
            progressMarks: true,
            autoHideSeconds: 0,
          ),
        );
        addTearDown(source.dispose);
        addTearDown(prefs.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: ListenableBuilder(
                  listenable: prefs,
                  builder: (BuildContext context, Widget? _) =>
                      FushiJumpHistoryActions(
                        items:
                            jumpHistoryToolbarVisible(
                              enabled: prefs.value.toolbar,
                              hasHistory: true,
                              expired: false,
                            )
                            ? jumpHistoryToolbarItems(
                                backLabel: '1:00',
                                forwardLabel: null,
                                onBack: () {},
                                onForward: () {},
                                onOpenPanel: () {},
                              )
                            : const <FushiToolbarItem>[],
                      ),
                ),
              ),
            ),
          ),
        );
        const Key back = ValueKey<String>('fushi_jump_back');
        expect(find.byKey(back), findsOneWidget);
        toolbar = false;
        source.value++;
        await tester.pump();
        expect(find.byKey(back), findsNothing, reason: '关掉开关后立即消失，不等下一次跳转');
        toolbar = true;
        source.value++;
        await tester.pump();
        expect(find.byKey(back), findsOneWidget);
      },
    );
  });

  testWidgets(
    'custom iconBuilder: long-press / right-click open the panel, tap walks',
    (WidgetTester tester) async {
      int back = 0;
      int panel = 0;
      final List<FushiToolbarItem> items = jumpHistoryToolbarItems(
        backLabel: '1:00',
        forwardLabel: null,
        onBack: () => back++,
        onForward: () {},
        onOpenPanel: () => panel++,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: FushiToolbarButton(
                item: items.single,
                foreground: Colors.black,
                selectedContainer: Colors.grey,
                selectedForeground: Colors.black,
                iconBuilder: (BuildContext _, FushiToolbarItem it, Color _) =>
                    IconButton(
                      key: const ValueKey<String>('bare'),
                      icon: const Icon(Icons.undo),
                      onPressed: it.onPressed,
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final Finder target = find.byKey(const ValueKey<String>('bare'));
      await tester.tap(target);
      await tester.pumpAndSettle();
      expect(back, 1);
      await tester.longPress(target);
      await tester.pumpAndSettle();
      expect(panel, 1, reason: '提示在外、长按在里：长按不能被提示抢走');
      await tester.tap(target, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(panel, 2);
      expect(back, 1);
    },
  );

  group('JumpHistoryWalker', () {
    test('a second walk while the first is sampling is dropped', () async {
      final JumpHistory<int> h = history();
      h.recordDeparture(1);
      h.recordDeparture(2);
      h.recordDeparture(3);
      final JumpHistoryWalker<int> walker = JumpHistoryWalker<int>();
      final Completer<int?> sample = Completer<int?>();
      final List<int> restored = <int>[];
      int samples = 0;
      Future<bool> walk() => walker.walk(
        h,
        -1,
        here: (int _) {
          samples++;
          return sample.future;
        },
        restore: (int target) async => restored.add(target),
      );
      final Future<bool> first = walk();
      expect(walker.busy, isTrue, reason: '第一个 await 之前就占住');
      final Future<bool> second = walk();
      sample.complete(10);
      expect(await first, isTrue);
      expect(await second, isFalse);
      expect(samples, 1);
      expect(restored, <int>[3]);
      expect(h.backEntries.map((JumpHistoryEntry<int> e) => e.point), <int>[
        1,
        2,
      ]);
      expect(h.forwardEntries.map((JumpHistoryEntry<int> e) => e.point), <int>[
        10,
      ]);
      expect(walker.busy, isFalse);
    });

    test('sampling failure leaves stacks untouched and releases', () async {
      final JumpHistory<int> h = history()..recordDeparture(1);
      final JumpHistoryWalker<int> walker = JumpHistoryWalker<int>();
      expect(
        await walker.walk(
          h,
          -1,
          here: (int _) async => null,
          restore: (int _) async {},
        ),
        isFalse,
      );
      expect(h.backTarget, 1);
      expect(walker.busy, isFalse);
    });
  });
}
