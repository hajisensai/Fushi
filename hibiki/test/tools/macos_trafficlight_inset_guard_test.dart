import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the BUG-869 fix: on macOS the app enables a transparent titlebar +
/// full-size content view unconditionally (`main.dart`, required by macos_ui's
/// ToolBar). Flutter content then extends under the red/yellow/green traffic
/// light buttons, and macOS does NOT report those as `MediaQuery.padding.top`,
/// so a plain `SafeArea` lets the traffic lights sit on top of the Material
/// desktop shell's nav rail / back button.
///
/// The fix reserves the titlebar height (`kMacTitleBarHeight`) as the minimum
/// top inset in both `_buildDesktopLayout` branches (settings full-screen +
/// normal rail+content). A source guard is the strongest feasible landing
/// layer here: the branch is gated on `dart:io`'s `Platform.isMacOS`, which
/// (unlike `debugDefaultTargetPlatformOverride`) can't be faked in a widget
/// test on the Linux CI host, so we can't drive the real macOS layout there.
void main() {
  test('kMacTitleBarHeight is a positive titlebar reserve (BUG-869)', () {
    final String source = File('lib/src/utils/adaptive/adaptive_platform.dart')
        .readAsStringSync();
    final RegExp decl =
        RegExp(r'const\s+double\s+kMacTitleBarHeight\s*=\s*([0-9.]+)\s*;');
    final Match? m = decl.firstMatch(source);
    expect(m, isNotNull,
        reason: 'kMacTitleBarHeight must be defined in adaptive_platform.dart '
            'so both desktop shells reserve the same macOS traffic-light band.');
    final double value = double.parse(m!.group(1)!);
    // Traffic lights are 12pt discs at roughly y=[6,18]; the reserve must
    // comfortably clear them. 20pt is a conservative lower bound.
    expect(value, greaterThanOrEqualTo(20.0),
        reason: 'kMacTitleBarHeight must be tall enough to clear the traffic '
            'lights (they sit within the standard ~28pt titlebar).');
  });

  test(
      'both _buildDesktopLayout SafeAreas reserve the macOS titlebar (BUG-869)',
      () {
    final String source =
        File('lib/src/pages/implementations/home_page.dart').readAsStringSync();

    final int start = source.indexOf('Widget _buildDesktopLayout(');
    expect(start, greaterThanOrEqualTo(0),
        reason: '_buildDesktopLayout must exist in home_page.dart.');
    // Bound the scan to the method body (up to the next top-level `Widget `
    // member) so we only inspect this one method's two Scaffolds.
    final int next = source.indexOf('\n  Widget ', start + 1);
    final String body =
        next > start ? source.substring(start, next) : source.substring(start);

    // The macOS traffic-light reserve, applied via SafeArea.minimum. Both the
    // settings full-screen branch and the rail+content branch must carry it,
    // so require the pattern to appear at least twice.
    final RegExp inset = RegExp(
      r'minimum:\s*EdgeInsets\.only\(\s*top:\s*Platform\.isMacOS\s*\?\s*'
      r'kMacTitleBarHeight\s*:\s*0',
    );
    final int occurrences = inset.allMatches(body).length;
    expect(occurrences, greaterThanOrEqualTo(2),
        reason: 'Both _buildDesktopLayout Scaffolds (settings full-screen and '
            'rail+content) must reserve kMacTitleBarHeight as the SafeArea '
            'minimum top inset on macOS, or the traffic lights overlap the nav '
            'rail / back button again (BUG-869).');
  });
}
