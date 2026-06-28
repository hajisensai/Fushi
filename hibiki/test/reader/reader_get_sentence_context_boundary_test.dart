import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-948/952 characterization test: pin down what
/// `hoshiSelection.getSentenceContext` returns for the boundary DOM shapes the
/// user's "card has no sentence/sentence audio" report blamed (no `<p>`, no
/// sentence delimiter, sentence split across sibling text nodes, and an empty
/// container).
///
/// This is a CHARACTERIZATION test, not a behaviour change: it executes the
/// real selection JS (extracted verbatim from `reader_selection_scripts.dart`)
/// against a minimal fake DOM and asserts the ACTUAL current output, so the
/// repository records — with evidence — that:
///   * a NON-EMPTY container (with or without `<p>`/punctuation) always yields
///     a non-empty sentence (the extractor falls back to the whole container
///     text); and
///   * ONLY a whitespace-only container yields an empty sentence.
/// i.e. "content -> empty sentence" is NOT a real failure mode here; an empty
/// `{sentence}` on the card comes from a genuinely empty selection or an
/// unmapped Anki field (the two cases the mining diagnostics now surface).
///
/// The JS executes via Node (same harness pattern as
/// reader_paged_touch_swipe_behavior_test). When no `node` is on PATH the test
/// is skipped (the source-contract test in reader_selection_scripts_test.dart
/// still guards getSentenceContext's presence).
void main() {
  test(
      'getSentenceContext boundary characterization (executes selection JS via '
      'node)', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS execution');
      return;
    }

    final File jsTest = File(
      'test/reader/reader_get_sentence_context_boundary_test.js',
    );
    expect(jsTest.existsSync(), isTrue,
        reason: 'characterization harness ${jsTest.path} must exist');

    final ProcessResult result = await Process.run(
      nodeExe,
      <String>[jsTest.path],
      workingDirectory: Directory.current.path,
    );

    expect(
      result.exitCode,
      0,
      reason: 'getSentenceContext characterization failed.\n'
          'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
    final String stdout = result.stdout.toString();
    expect(stdout, contains('all assertions passed'),
        reason: 'harness must reach its success marker');
    // The empty-sentence path must remain the whitespace-only case (the toast
    // `card_mined_no_sentence_captured` keys off exactly this).
    expect(stdout, contains('case4_whitespace_only :: {"sentence":""'),
        reason: 'only the whitespace-only container yields an empty sentence');
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
