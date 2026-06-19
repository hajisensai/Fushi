import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Anti-recurrence guard for the project-wide integration-test discipline:
/// **integration tests drive the real app by focus + synthetic keys only,
/// never by coordinate taps.** See CLAUDE.md「集成测试一律焦点驱动」 and
/// docs/agent/integration-testing.md「焦点驱动操作」.
///
/// Coordinate taps depend on exact screen position; any layout / scroll /
/// scale / platform change silently misplaces them. Focus + key events are
/// position-independent and behave identically on the emulator, the Windows
/// off-screen runner and the Mac runner. The single legal interaction tool is
/// `integration_test/helpers/focus_driver.dart` (`FocusDriver`: `focusWidget`
/// + `activate()` Enter, `adjust()` arrows, `back()` gameButtonB).
///
/// What this guard forbids: `tester.tap(` / `tester.tapAt(` /
/// `tester.longPress(` (and the `widgetTester.` aliases). It does **not** match
/// `tester.drag(` / `.fling(` — those are legitimate "scroll a Scrollable into
/// view" operations (FocusDriver has no scroll primitive), and the current
/// tree contains exactly 5 such scroll drags that must stay legal.
///
/// Exemption channels (kept narrow on purpose):
///   1. `helpers/focus_driver.dart` — the focus-driving helper itself; its
///      doc-comments mention `tap` while explicitly forbidding it.
///   2. A trailing `// itest-tap-allow: <reason>` comment on the offending
///      line — for a deliberate, justified coordinate tap that genuinely has
///      no focus equivalent (e.g. tapping inside a platform WebView to prove
///      it does not steal keyboard focus). Must carry a reason.
///   3. A temporary `_legacyAllowlist` of files still pending migration — a
///      scaffold that only blocks *new* offenders. It must shrink to empty as
///      files are migrated; the guard fails if a listed file has *more*
///      offenders than recorded (new offender) AND fails if the allowlist is
///      stale (a listed file now has *fewer* than recorded — bump it down /
///      remove the entry). This forces monotonic decrement to zero.
void main() {
  // -------------------------------------------------------------------------
  // Forbidden coordinate-interaction calls. tapAt/longPress included; drag and
  // fling are deliberately excluded (legitimate scrolling).
  // -------------------------------------------------------------------------
  final RegExp forbiddenTap =
      RegExp(r'(?:tester|widgetTester)\.(?:tap|tapAt|longPress)\(');

  /// A `// itest-tap-allow: <reason>` marker exempts a deliberate, documented
  /// coordinate tap. A bare marker without a reason after the colon is
  /// rejected. The marker may sit on the matched line OR, because `dart format`
  /// can wrap a long `tester.tap(...)` call across several lines, on any line
  /// up to and including the one that terminates the statement (ends with
  /// `;`). So the guard scans the whole logical statement for the marker.
  final RegExp allowMarker = RegExp(r'//\s*itest-tap-allow:\s*\S');

  /// Files still containing un-migrated coordinate taps, with their current
  /// offender count. TEMPORARY SCAFFOLD — every entry must trend to 0 and be
  /// removed. Do NOT add new entries: new files must be focus-driven from the
  /// start (that is the whole point of this guard).
  const Map<String, int> legacyAllowlist = <String, int>{};

  /// The focus-driving helper itself is always exempt (its doc-comments
  /// reference `tap` while forbidding it).
  const Set<String> exemptBasenames = <String>{'focus_driver.dart'};

  test('integration_test uses focus driving, never tester.tap/longPress', () {
    final Directory dir = Directory('integration_test');
    expect(dir.existsSync(), isTrue,
        reason: 'run from the hibiki/ package root (cwd=hibiki/)');

    final List<String> hardOffenders = <String>[];
    final Map<String, int> perFileCounts = <String, int>{};

    for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String basename = entity.uri.pathSegments.last;
      if (exemptBasenames.contains(basename)) continue;

      final String content = entity.readAsStringSync();
      final List<String> lines = content.split('\n');
      for (int i = 0; i < lines.length; i++) {
        final String line = lines[i];
        if (!forbiddenTap.hasMatch(line)) continue;
        // A documented exemption removes this hit. The marker can be on the
        // matched line or on a later line of the same (possibly wrapped)
        // statement, up to and including the line that ends it with `;`.
        if (_statementHasAllowMarker(lines, i, allowMarker)) continue;

        perFileCounts[basename] = (perFileCounts[basename] ?? 0) + 1;
        if (!legacyAllowlist.containsKey(basename)) {
          hardOffenders.add('${entity.path}:${i + 1}');
        }
      }
    }

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
