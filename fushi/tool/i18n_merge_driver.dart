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
/// = conflict: %A then holds the merged file with ours' value for every
/// conflicting key, and the keys are listed on stderr.
///
/// Only local merges use it — GitHub's server-side merge ignores custom
/// drivers, so a PR page can still say "conflicts" that a local
/// `git merge origin/develop` resolves by itself.
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

  final Map<String, dynamic> base;
  final Map<String, dynamic> ours;
  final Map<String, dynamic> theirs;
  try {
    base = _read(args[0]);
    ours = _read(args[1]);
    theirs = _read(args[2]);
  } on FormatException catch (e) {
    // Leave %A untouched: git reports the file as conflicted and keeps ours.
    stderr.writeln('i18n merge driver: not valid JSON, falling back ($e)');
    exit(1);
  }

  final I18nMergeResult result = mergeI18nThreeWay(
    base: base,
    ours: ours,
    theirs: theirs,
  );
  File(args[1]).writeAsStringSync(encodeI18nJson(result.json));

  if (result.conflicts.isEmpty) exit(0);
  stderr.writeln(
    'i18n merge driver: both sides changed these keys differently; '
    'kept ours, please review: ${result.conflicts.join(', ')}',
  );
  exit(1);
}

/// An absent ancestor (add/add) arrives as an empty file.
Map<String, dynamic> _read(String path) {
  final String text = File(path).readAsStringSync();
  if (text.trim().isEmpty) return <String, dynamic>{};
  return jsonDecode(text) as Map<String, dynamic>;
}
