#!/usr/bin/env dart

/// Git merge driver for `fushi/lib/i18n/*.i18n.json`: merges by key instead of
/// by line, so two branches that each add / edit / remove different keys never
/// conflict — not even when the keys sort next to each other.
///
/// Wiring (done by `tool/setup_worktree.ps1`; repo-wide git config, so one run
/// covers the main checkout and every worktree):
///
///   .gitattributes:  fushi/lib/i18n/*.i18n.json merge=fushi-i18n-json
///   git config merge.fushi-i18n-json.driver \
///     "dart fushi/tool/i18n_merge_driver.dart %O %A %B"
///
/// Git runs the driver from the work tree root with the ancestor (%O), ours
/// (%A, also the output) and theirs (%B) as temp files. Exit 0 = merged; exit 1
/// = conflict: %A then holds the merged file with every key both sides changed
/// differently written as a `<<<<<<< ours` / `=======` / `>>>>>>> theirs`
/// block (see [renderI18nMergeResult]) and the keys are listed on stderr —
/// neither side's value is silently dropped. A side that is not a JSON object
/// (already holds conflict markers, a hand-broken edit, ...) falls back to
/// git's own line-level `git merge-file`, so %A again carries both sides.
///
/// Only local merges use it — GitHub's server-side merge ignores custom
/// drivers, so a PR page can still say "conflicts" that a local
/// `git merge origin/develop` resolves by itself. Where the driver is not
/// defined in git config (CI, a clone that never ran setup) git uses its
/// built-in line merge for these files instead.
library;

import 'dart:convert';
import 'dart:io';

import 'i18n_sync.dart';

void main(List<String> args) {
  if (args.length != 3) {
    stderr.writeln(
      'usage: dart fushi/tool/i18n_merge_driver.dart <base %O> <ours %A> <theirs %B>',
    );
    exit(2);
  }
  final String basePath = args[0];
  final String oursPath = args[1];
  final String theirsPath = args[2];

  final Map<String, dynamic> base;
  final Map<String, dynamic> ours;
  final Map<String, dynamic> theirs;
  try {
    base = _read(basePath);
    ours = _read(oursPath);
    theirs = _read(theirsPath);
  } on FormatException catch (e) {
    stderr.writeln(
      'i18n merge driver: not an i18n JSON object ($e); '
      'falling back to line-level git merge-file',
    );
    exit(
      _lineMerge(
        basePath: basePath,
        oursPath: oursPath,
        theirsPath: theirsPath,
      ),
    );
  }

  final I18nMergeResult result = mergeI18nThreeWay(
    base: base,
    ours: ours,
    theirs: theirs,
  );
  File(oursPath).writeAsStringSync(
    renderI18nMergeResult(result, ours: ours, theirs: theirs),
  );

  if (result.conflicts.isEmpty) exit(0);
  stderr.writeln(
    'i18n merge driver: both sides changed these keys differently; '
    'left conflict markers for: ${result.conflicts.join(', ')}',
  );
  exit(1);
}

/// An absent ancestor (add/add) arrives as an empty file.
Map<String, dynamic> _read(String path) {
  final String text = File(path).readAsStringSync();
  if (text.trim().isEmpty) return <String, dynamic>{};
  final Object? decoded = jsonDecode(text);
  if (decoded is! Map<String, dynamic>) {
    throw FormatException('top level is not a JSON object', path);
  }
  return decoded;
}

/// git's own three-way line merge into [oursPath]: 0 = clean, 1 = conflict
/// markers written, or merge-file could not run (then %A is still ours and git
/// keeps the path unmerged).
int _lineMerge({
  required String basePath,
  required String oursPath,
  required String theirsPath,
}) {
  try {
    final ProcessResult r = Process.runSync('git', <String>[
      'merge-file',
      '-L',
      'ours',
      '-L',
      'base',
      '-L',
      'theirs',
      oursPath,
      basePath,
      theirsPath,
    ]);
    stderr.write(r.stderr);
    return r.exitCode == 0 ? 0 : 1;
  } on ProcessException catch (e) {
    stderr.writeln('i18n merge driver: git merge-file failed to start ($e)');
    return 1;
  }
}
