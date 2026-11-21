// BUG-4968: flatpak-builder refuses to start when its --state-dir and the
// parent of the build dir it is given (--force-clean "$work/build") are on
// different filesystems. CI and build_flatpak.sh put FLATPAK_STATE_DIR on a
// bind mount / volume while the container's /tmp is the overlay root, so a
// work dir made with a bare `mktemp -d` broke every BaseApp rebuild
// ("The state dir (/src/build/flatpak-state) is not on the same filesystem as
// the target dir (/tmp/tmp.XXXX)"). The work dir must be created next to the
// state dir.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _buildScript() => File(
  p.join(
    Directory.current.parent.path,
    'tool',
    'linux',
    'flatpak',
    'flatpak_build.sh',
  ),
).readAsStringSync();

void main() {
  test('the work dir is created on the state dir filesystem', () {
    final String script = _buildScript();
    expect(
      script,
      contains(r'mktemp -d -p "$(dirname "$STATE_DIR")"'),
      reason: 'make_workdir must place the work dir next to STATE_DIR',
    );
    // No bare mktemp -d: it lands in the container's /tmp (another fs).
    expect(
      RegExp(r'mktemp -d\)').hasMatch(script),
      isFalse,
      reason: 'a bare `mktemp -d` puts the build dir in /tmp',
    );
  });

  test('every flatpak-builder build dir lives in the shared work dir', () {
    final String script = _buildScript();
    final int builds = RegExp(
      r'--force-clean "\$work/build"',
    ).allMatches(script).length;
    expect(builds, greaterThan(0));
    // Each command that runs flatpak-builder gets its work dir from
    // make_workdir, not from its own mktemp.
    expect(
      RegExp(r'make_workdir\n  work="\$WORK"').allMatches(script).length,
      builds,
    );
    expect(RegExp(r'work="\$\(mktemp').hasMatch(script), isFalse);
  });
}
