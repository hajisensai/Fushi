import 'dart:io';
import 'dart:ui' show Display;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/main.dart' as app;
import 'package:fushi/src/startup/test_root_shared_preferences.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/legacy_support_dir_migration.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';
import 'package:fushi/src/utils/window_caption_channel.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_helpers.dart';

/// BUG-5591: the runner-owned fullscreen is ONE geometry step each way, never
/// passes through another window size (the old exit restored the
/// pre-maximize normal rectangle first: a small window in the middle of the
/// screen), and puts the window back exactly — maximized, or the same
/// rectangle. Asserted on the runner's own transition trace
/// (`windows/runner/fullscreen_trace.h`, read via the window channel): every
/// WM_WINDOWPOSCHANGED, child (Flutter view) resize and rasterized-frame
/// report, stamped from SetFullscreen's start.
///
/// Off-screen runner (the window is parked at -32000, never on the desktop,
/// never activated); the origin pin keeps every rectangle there, sizes are
/// real. Two launches, one per starting state:
///   .\tool\run_windows_itest.ps1 integration_test\win_fullscreen_geometry_itest.dart
///   ... -DartDefine PROBE_MAXIMIZED=true
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('fullscreen enter / exit: one step, exact restore', (
    WidgetTester tester,
  ) async {
    if (!Platform.isWindows) return;
    UpdateChecker.disableAutoCheckForTesting = true;
    const bool maximized = bool.fromEnvironment('PROBE_MAXIMIZED');
    isolateSharedPreferencesUnderTestRoot();
    await migrateLegacySupportDir();
    final AppPaths paths = await AppPaths.resolve();
    final FushiDatabase db = FushiDatabase(paths.supportRoot.path);
    try {
      await db.setPrefTyped<bool>('first_time_setup', false);
      await db.setPrefTyped<bool>('onboarding_completed', true);
    } finally {
      await db.close();
    }
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('desktop_main_window_x', 100);
    await prefs.setDouble('desktop_main_window_y', 100);
    await prefs.setDouble('desktop_main_window_width', 1200);
    await prefs.setDouble('desktop_main_window_height', 800);
    await prefs.setBool('desktop_main_window_maximized', maximized);
    final FlutterExceptionHandler? testOnError = FlutterError.onError;
    app.main();
    expect(await waitForHome(tester), isTrue);
    await tester.pump(const Duration(seconds: 2));

    final Display display =
        WidgetsBinding.instance.platformDispatcher.views.first.display;
    final _Size monitor = _Size(
      display.size.width.round(),
      display.size.height.round(),
    );

    await WindowCaptionChannel.setFullscreen(true);
    await tester.pump(const Duration(seconds: 1));
    final List<_Event> enter = _parse(
      await WindowCaptionChannel.fullscreenTrace(),
    );
    await WindowCaptionChannel.setFullscreen(false);
    await tester.pump(const Duration(seconds: 1));
    final List<_Event> exit = _parse(
      await WindowCaptionChannel.fullscreenTrace(),
    );
    FlutterError.onError = testOnError;
    _dump('enter', enter);
    _dump('exit', exit);

    final _Event before = enter.first;
    expect(before.kind, _Kind.begin);
    expect(before.a, 1, reason: 'enter trace starts with an enter');
    expect(
      before.zoomed,
      maximized,
      reason: 'the launch put the window in the probed state',
    );

    // A zoomed window parked at -32000 by the off-screen runner gets
    // window_manager's work-area-relative WM_NCCALCSIZE answer: a negative
    // client (measured: -60134x-61814), so the view has no size and the
    // fullscreen insets measured from it are meaningless. Only the window
    // geometry (one size each way, exact rectangle and show-state restore)
    // is meaningful then; the client / view checks need a real client, which
    // the normal-window launch has.
    final bool clientValid =
        before.client.width > 0 && before.client.height > 0;
    expect(
      maximized || clientValid,
      isTrue,
      reason: 'a normal window always has a real client',
    );

    // Enter: exactly one window size, the fullscreen one, from the first
    // geometry change to the end of the record (frames after SetFullscreen
    // returned included); the client is the monitor.
    final _Event enterEnd = enter.firstWhere((_Event e) => e.kind == _Kind.end);
    expect(enterEnd.zoomed, isFalse);
    if (clientValid) {
      expect(enterEnd.client, monitor, reason: 'fullscreen client = monitor');
    }
    expect(_windowSizes(enter), <_Size>[
      enterEnd.window.size,
    ], reason: 'entering passed through another window size');
    expect(
      _windowSizes(enter).length,
      lessThanOrEqualTo(1),
      reason: 'one geometry step',
    );

    // Exit: exactly one window size, the one before entering, and the same
    // show state.
    expect(exit.first.kind, _Kind.begin);
    expect(exit.first.a, 0);
    final _Event exitEnd = exit.firstWhere((_Event e) => e.kind == _Kind.end);
    expect(exitEnd.zoomed, maximized, reason: 'show state restored');
    expect(exitEnd.window, before.window, reason: 'rectangle restored');
    if (clientValid) {
      expect(exitEnd.client, before.client, reason: 'client restored');
    }
    expect(_windowSizes(exit), <_Size>[
      before.window.size,
    ], reason: 'leaving passed through another window size');

    // The view followed each jump with a frame at the new size.
    if (!clientValid) return;
    for (final (String label, List<_Event> trace, _Size target) in [
      ('enter', enter, enterEnd.client),
      ('exit', exit, exitEnd.client),
    ]) {
      final _Event? delivered = trace
          .where((_Event e) => e.kind == _Kind.childDelivered && e.ab == target)
          .firstOrNull;
      final _Event? raster = trace
          .where((_Event e) => e.kind == _Kind.rasterized && e.ab == target)
          .firstOrNull;
      expect(delivered, isNotNull, reason: '$label: child got $target');
      expect(
        raster,
        isNotNull,
        reason: '$label: no frame rasterized at $target',
      );
      debugPrint(
        '[fs-trace] $label child resize ${delivered!.c} ms at '
        '${delivered.tUs} us, first frame at the new size rasterized at '
        '${raster!.tUs} us',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

enum _Kind {
  begin,
  end,
  windowPos,
  childDelivered,
  rasterized,
  snapshotReleased,
}

@immutable
class _Size {
  const _Size(this.width, this.height);
  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is _Size && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => '${width}x$height';
}

@immutable
class _Rect {
  const _Rect(this.left, this.top, this.right, this.bottom);
  final int left;
  final int top;
  final int right;
  final int bottom;

  _Size get size => _Size(right - left, bottom - top);

  @override
  bool operator ==(Object other) =>
      other is _Rect &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => '($left,$top,$right,$bottom)';
}

class _Event {
  _Event(Map<Object?, Object?> raw)
    : kind = _Kind.values[raw['kind']! as int],
      tUs = raw['tUs']! as int,
      window = _Rect(
        raw['left']! as int,
        raw['top']! as int,
        raw['right']! as int,
        raw['bottom']! as int,
      ),
      client = _Size(raw['clientWidth']! as int, raw['clientHeight']! as int),
      zoomed = raw['zoomed']! as bool,
      iconic = raw['iconic']! as bool,
      a = raw['a']! as int,
      b = raw['b']! as int,
      c = raw['c']! as int;

  final _Kind kind;
  final int tUs;
  final _Rect window;
  final _Size client;
  final bool zoomed;
  final bool iconic;
  final int a;
  final int b;
  final int c;

  _Size get ab => _Size(a, b);

  @override
  String toString() =>
      '${tUs}us ${kind.name} win=$window client=$client '
      'zoomed=$zoomed iconic=$iconic a=$a b=$b c=$c';
}

List<_Event> _parse(List<Map<Object?, Object?>> raw) => <_Event>[
  for (final Map<Object?, Object?> e in raw) _Event(e),
];

/// Distinct window sizes over every geometry change after the start of the
/// transition (consecutive repeats collapsed).
List<_Size> _windowSizes(List<_Event> trace) {
  final List<_Size> sizes = <_Size>[];
  for (final _Event e in trace) {
    if (e.kind != _Kind.windowPos) continue;
    if (sizes.isEmpty || sizes.last != e.window.size) sizes.add(e.window.size);
  }
  return sizes;
}

void _dump(String label, List<_Event> trace) {
  for (final _Event e in trace) {
    debugPrint('[fs-trace] $label $e');
  }
}
