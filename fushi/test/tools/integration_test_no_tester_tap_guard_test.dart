import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../helpers/scan_scale.dart';
import '../helpers/source_guard.dart';

// Anti-recurrence guard for the project-wide integration-test discipline:
// **integration tests drive the real app by focus + synthetic keys only,
// never by coordinate taps.** See CLAUDE.md「集成测试一律焦点驱动」 and
// docs/agent/integration-testing.md「焦点驱动操作」.
//
// Coordinate taps depend on exact screen position; any layout / scroll /
// scale / platform change silently misplaces them. Focus + key events are
// position-independent and behave identically on the emulator, the Windows
// off-screen runner and the Mac runner. The single legal interaction tool is
// `integration_test/helpers/focus_driver.dart` (`FocusDriver`: `focusWidget`
// + `activate()` Enter, `adjust()` arrows, `back()` gameButtonB).
//
// What this guard forbids: `tester.tap(` / `tester.tapAt(` /
// `tester.longPress(` (and the `widgetTester.` aliases). It does **not** match
// `tester.drag(` / `.fling(` — those are legitimate "scroll a Scrollable into
// view" operations (FocusDriver has no scroll primitive), and the current
// tree contains exactly 5 such scroll drags that must stay legal.
//
// Exemption channels (kept narrow on purpose):
//   1. A trailing `// itest-tap-allow: <reason>` comment on the offending
//      line — for a deliberate, justified coordinate tap that genuinely has
//      no focus equivalent (e.g. tapping inside a platform WebView to prove
//      it does not steal keyboard focus). Must carry a reason.
//   2. A temporary `_legacyAllowlist` of files still pending migration — a
//      scaffold that only blocks *new* offenders. It must shrink to empty as
//      files are migrated; the guard fails if a listed file has *more*
//      offenders than recorded (new offender) AND fails if the allowlist is
//      stale (a listed file now has *fewer* than recorded — bump it down /
//      remove the entry). This forces monotonic decrement to zero.
//
// TODO-2715 fixed two defects in the guard itself:
//   * **Basename keys.** The allowlist and the per-file counters were keyed by
//     `entity.uri.pathSegments.last`, so two same-named files in different
//     directories (`video/foo_test.dart` + `reader/foo_test.dart`) shared one
//     budget: one could gain offenders while the other lost them and the
//     guard stayed green. Keys are now repository-relative paths.
//   * **No comment stripping.** `forbiddenTap` ran on raw lines, so a
//     commented-out `// await tester.tap(...)` counted as a violation (false
//     red) — which is precisely why `focus_driver.dart` needed a blanket
//     exemption in the first place. The match now runs on lexically masked
//     lines (the `// itest-tap-allow:` marker is still read off the original
//     lines, which is legal because the mask is length-preserving), so the
//     whole-file exemption is gone: a *real* `tester.tap(` inside
//     `focus_driver.dart` is now a violation like anywhere else.
// ---------------------------------------------------------------------------
// Forbidden coordinate-interaction calls. tapAt/longPress included; drag and
// fling are deliberately excluded (legitimate scrolling).
// ---------------------------------------------------------------------------
final RegExp kForbiddenTap =
    RegExp(r'(?:tester|widgetTester)\.(?:tap|tapAt|longPress)\(');

/// A `// itest-tap-allow: <reason>` marker exempts a deliberate, documented
/// coordinate tap. A bare marker without a reason after the colon is
/// rejected. The marker may sit on the matched line OR, because `dart format`
/// can wrap a long `tester.tap(...)` call across several lines, on any line
/// up to and including the one that terminates the statement (ends with
/// `;`). So the guard scans the whole logical statement for the marker.
final RegExp kAllowMarker = RegExp(r'//\s*itest-tap-allow:\s*\S');

/// 1-based line numbers of unexcused coordinate taps in [content].
///
/// Violations are matched on comment-masked lines (a commented-out tap is not
/// a tap); the allow marker is matched on the original lines (it *is* a
/// comment). Both arrays are index-aligned because the mask is
/// length-preserving.
List<int> unexcusedCoordinateTapLines(String content) {
  final List<String> lines = content.split('\n');
  final List<String> code = maskComments(content).split('\n');
  final List<int> hits = <int>[];
  for (int i = 0; i < lines.length; i++) {
    if (!kForbiddenTap.hasMatch(code[i])) continue;
    if (_statementHasAllowMarker(lines, i, kAllowMarker)) continue;
    hits.add(i + 1);
  }
  return hits;
}

void main() {
  /// Files still containing un-migrated coordinate taps, with their current
  /// offender count. TEMPORARY SCAFFOLD — every entry must trend to 0 and be
  /// removed. Do NOT add new entries: new files must be focus-driven from the
  /// start (that is the whole point of this guard).
  ///
  /// Keys are **repository-relative paths** (`integration_test/...`), never
  /// basenames: a basename budget is shared by every same-named file in the
  /// tree, which lets a new offender hide behind another file's migration.
  const Map<String, int> legacyAllowlist = <String, int>{};

  test('integration_test uses focus driving, never tester.tap/longPress', () {
    final Directory dir = Directory('integration_test');
    expect(dir.existsSync(), isTrue,
        reason: 'run from the fushi/ package root (cwd=fushi/)');

    final List<String> hardOffenders = <String>[];
    final Map<String, int> perFileCounts = <String, int>{};
    int scanned = 0;

    for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String relative = entity.path.replaceAll(r'\', '/');
      scanned++;

      for (final int line
          in unexcusedCoordinateTapLines(entity.readAsStringSync())) {
        perFileCounts[relative] = (perFileCounts[relative] ?? 0) + 1;
        if (!legacyAllowlist.containsKey(relative)) {
          hardOffenders.add('${entity.path}:$line');
        }
      }
    }

    expectScanScale(scanned,
        what: 'integration_test/ 下的 .dart', atLeast: 60, measured: 87);

    // 1) No coordinate taps in files outside the temporary allowlist.
    expect(
      hardOffenders,
      isEmpty,
      reason: 'Coordinate taps are forbidden in integration tests — they break '
          'on any layout/scroll/scale/platform change. Drive the app with '
          'FocusDriver (focusWidget + activate/back/adjust) from '
          'integration_test/helpers/focus_driver.dart instead. If a tap is '
          'genuinely unavoidable (e.g. tapping a platform WebView to prove it '
          'does not steal focus), append `// itest-tap-allow: <reason>`. See '
          'docs/agent/integration-testing.md.\nOffenders:\n'
          '${hardOffenders.join('\n')}',
    );

    // 2) Listed files must not gain *new* offenders beyond the recorded count.
    final List<String> overBudget = <String>[];
    for (final MapEntry<String, int> e in legacyAllowlist.entries) {
      final int actual = perFileCounts[e.key] ?? 0;
      if (actual > e.value) {
        overBudget.add('${e.key}: recorded ${e.value}, found $actual '
            '(do not add new coordinate taps to a migrating file)');
      }
    }
    expect(overBudget, isEmpty,
        reason: 'New coordinate taps added to a file pending migration:\n'
            '${overBudget.join('\n')}');

    // 3) Allowlist must stay tight: a listed file that now has *fewer* (or no)
    //    offenders means migration progressed — decrement / remove the entry so
    //    the scaffold keeps shrinking and cannot silently mask the real state.
    final List<String> stale = <String>[];
    for (final MapEntry<String, int> e in legacyAllowlist.entries) {
      final int actual = perFileCounts[e.key] ?? 0;
      if (actual < e.value) {
        stale.add('${e.key}: recorded ${e.value}, found $actual — '
            'decrement to $actual or remove the entry');
      }
    }
    expect(stale, isEmpty,
        reason: 'Stale allowlist entries — migration progressed but the '
            'recorded count was not lowered. The scaffold must shrink to '
            'empty:\n${stale.join('\n')}');
  });

  // TODO-2715: the scan above is a forbid-type assertion that is permanently
  // empty in a healthy tree, so it never exercises the detector. These feed
  // hand-written sources through the same function, both directions.
  group('detector self-check (hand-written sources, no disk involved)', () {
    test('a bare coordinate tap is a violation', () {
      expect(
          unexcusedCoordinateTapLines('await tester.tap(finder);'), <int>[1]);
      expect(
          unexcusedCoordinateTapLines('await tester.tapAt(offset);'), <int>[1]);
      expect(unexcusedCoordinateTapLines('await widgetTester.longPress(f);'),
          <int>[1]);
    });

    test('a commented-out tap is not a violation (false-red direction)', () {
      expect(
          unexcusedCoordinateTapLines('// await tester.tap(finder);'), isEmpty);
      expect(unexcusedCoordinateTapLines('/* await tester.tap(finder); */'),
          isEmpty);
      expect(
        unexcusedCoordinateTapLines(
            '/// Drive by focus; never `await tester.tap(finder)`.'),
        isEmpty,
        reason: 'this is exactly why focus_driver.dart used to need a '
            'whole-file exemption',
      );
    });

    test('a marker with a reason excuses the tap, a bare marker does not', () {
      expect(
        unexcusedCoordinateTapLines(
            'await tester.tap(f); // itest-tap-allow: platform WebView'),
        isEmpty,
      );
      expect(
        unexcusedCoordinateTapLines('await tester.tap(f); // itest-tap-allow:'),
        <int>[1],
        reason: 'a marker without a reason is not a reviewed exception',
      );
    });

    test('the marker survives dart format wrapping the statement', () {
      expect(
        unexcusedCoordinateTapLines('''
await tester.tap(
  finder,
  warnIfMissed: false,
); // itest-tap-allow: platform WebView
'''),
        isEmpty,
      );
    });

    test('drag/fling stay legal (scrolling has no focus equivalent)', () {
      expect(unexcusedCoordinateTapLines('await tester.drag(f, o);'), isEmpty);
      expect(unexcusedCoordinateTapLines('await tester.fling(f, o, 300);'),
          isEmpty);
    });
  });
}

/// Returns true if the statement starting at [lines]`[start]` carries the
/// `// itest-tap-allow:` [marker] anywhere from its first line through the line
/// that terminates it with a `;`. This survives `dart format` wrapping a long
/// `tester.tap(...)` call (and its trailing comment) across multiple lines.
bool _statementHasAllowMarker(
  List<String> lines,
  int start,
  RegExp marker, {
  int maxSpan = 8,
}) {
  for (int j = start; j < lines.length && j <= start + maxSpan; j++) {
    if (marker.hasMatch(lines[j])) return true;
    if (lines[j].trimRight().endsWith(';')) break; // statement ended
  }
  return false;
}
