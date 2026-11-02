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

    test('expiry only with a positive timeout after a jump', () {
      final DateTime t0 = DateTime(2026);
      expect(
        jumpHistoryToolbarExpired(
          lastJumpAt: t0,
          autoHideSeconds: 0,
          now: t0.add(const Duration(days: 1)),
        ),
        isFalse,
      );
      expect(
        jumpHistoryToolbarExpired(
          lastJumpAt: null,
          autoHideSeconds: 30,
          now: t0,
        ),
        isFalse,
      );
      expect(
        jumpHistoryToolbarExpired(
          lastJumpAt: t0,
          autoHideSeconds: 30,
          now: t0.add(const Duration(seconds: 29)),
        ),
        isFalse,
      );
      expect(
        jumpHistoryToolbarExpired(
          lastJumpAt: t0,
          autoHideSeconds: 30,
          now: t0.add(const Duration(seconds: 30)),
        ),
        isTrue,
      );
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
}
