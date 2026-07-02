import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1104: audiobook mining from a DRAG selection that spans multiple
/// sentences must capture the WHOLE dragged span — both the card sentence text
/// and the sentence-normalized range that feeds the audio clip — not just the
/// sentence at the drag start.
///
/// This executes the REAL selection JS (extracted verbatim from
/// `reader_selection_scripts.dart`) against a minimal fake DOM + fake
/// `window.hoshiReader`, asserting:
///   * a two-sentence drag -> merged sentence text + range span start-head..end-tail;
///   * a collapsed selection (tap single point) -> byte-identical to the
///     start-sentence-only behaviour (never-break constraint);
///   * a reversed / discontiguous (cross-block) span -> conservative fallback to
///     the start sentence.
///
/// The JS runs via Node (same harness pattern as
/// reader_get_sentence_context_boundary_test). When no `node` is on PATH the
/// test is skipped; the source-contract guard in
/// reader_mining_audio_guard_test.dart still pins that the endpoint-merge logic
/// exists in the shipped source.
void main() {
  test(
      'audiobook mining spans the dragged sentence range (executes selection JS '
      'via node)', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS execution');
      return;
    }

    final File jsTest = File(
      'test/media/audiobook/mining_clip_span_test.js',
    );
    expect(jsTest.existsSync(), isTrue,
        reason: 'span harness ${jsTest.path} must exist');

    final ProcessResult result = await Process.run(
      nodeExe,
      <String>[jsTest.path],
      workingDirectory: Directory.current.path,
    );

    expect(
      result.exitCode,
      0,
      reason: 'mining clip span harness failed.\n'
          'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
    final String stdout = result.stdout.toString();
    expect(stdout, contains('all assertions passed'),
        reason: 'harness must reach its success marker');
    expect(stdout, contains('passed 6 cases'),
        reason: 'all six span cases must run');
  });
}

/// Resolve a usable `node` executable, returning null when none is on PATH.
String? _resolveNode() {
  final List<String> candidates =
      Platform.isWindows ? <String>['node.exe', 'node'] : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) {
        return name;
      }
    } on ProcessException {
      // Not found; try next candidate.
    }
  }
  return null;
}
