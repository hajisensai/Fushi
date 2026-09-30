/// Pure selection logic for `tool/pre_push_check.dart`: which local checks a set
/// of changed files needs so that what CI would turn red is caught before push.
///
/// Measured 2026-09-20..30 on upstream: of 36 PRs whose CI caught a regression
/// the PR itself introduced, 15 were red ONLY on source-scan guards and 3 more
/// on guards plus other tests; `flutter analyze` failed once in 10 days. Agents
/// ran analyze + hand-picked targeted tests, so the guards that scan the files
/// they touched (named by path literal in the guard) and the directory-scanning
/// guard batch never ran before push.
library;

/// Enumeration guards listed in docs/agent/fast-workflow.md, section
/// "### 清单" (up to the next heading). That table is the single source of
/// truth for the batch; parsing it keeps this tool from growing a second copy.
List<String> parseEnumerationGuards(String fastWorkflowMarkdown) {
  final int start = fastWorkflowMarkdown.indexOf('\n### 清单');
  if (start < 0) return <String>[];
  final RegExp nextHeading = RegExp(r'\n#{2,3} ');
  final Match? end = nextHeading.firstMatch(
    fastWorkflowMarkdown.substring(start + 1),
  );
  final String section = end == null
      ? fastWorkflowMarkdown.substring(start)
      : fastWorkflowMarkdown.substring(start, start + 1 + end.start);
  final RegExp row =
      RegExp(r'^\| `(test/[^`]+_test\.dart)` \|', multiLine: true);
  return row.allMatches(section).map((Match m) => m.group(1)!).toSet().toList()
    ..sort();
}

/// Whether [changed] touches a Dart source tree the enumeration guard batch
/// scans. When it does not (docs / workflows / native only), the batch is
/// skipped: the few batch guards whose scan root is outside the Dart trees name
/// that root by path literal, so tests_for_changes still selects them.
bool touchesDartTrees(Iterable<String> changed) => changed.any((String c) =>
    c.startsWith('fushi/lib/') ||
    c.startsWith('fushi/test/') ||
    c.startsWith('fushi/integration_test/') ||
    RegExp(r'^packages/[^/]+/(lib|test)/').hasMatch(c));

/// Budget mode (the default) for path-literal matching: [changed] triggers
/// [ref] only when [ref] IS that file, or a directory with at most
/// [maxDirFiles] files that contains it. tests_for_changes' wide rule also
/// fires on same-directory siblings and on directories of any size -- right for
/// "which guards could care", far too wide to run locally: replaying 36
/// regression PRs, a typical PR selected 600-1500 test files that way (3 files
/// changed under pages/implementations selected 782). Large trees are what the
/// enumeration batch already scans.
bool budgetTrigger(
  String changed,
  String ref, {
  required bool Function(String) isDirectory,
  required int Function(String) dirFileCount,
  int maxDirFiles = 60,
}) {
  if (changed == ref) return true;
  if (!changed.startsWith('$ref/') || !isDirectory(ref)) return false;
  return dirFileCount(ref) <= maxDirFiles;
}

/// Splits [keys] into libraries imported by at most [hubLimit] of the tests in
/// [testSources] and "hubs" imported by more (app_model.dart,
/// preference_keys.dart, generated i18n ...). A hub change touches most of the
/// suite; locally it only keeps same-name tests and the guards, the sharded CI
/// suite covers the rest -- and the tool says so.
({Set<String> kept, Set<String> hubs}) splitHubImportKeys(
  Set<String> keys,
  Map<String, String> testSources, {
  int hubLimit = 40,
}) {
  final Set<String> kept = <String>{};
  final Set<String> hubs = <String>{};
  for (final String k in keys) {
    int importers = 0;
    for (final String src in testSources.values) {
      if (src.contains("'$k'") || src.contains('"$k"')) importers++;
      if (importers > hubLimit) break;
    }
    (importers > hubLimit ? hubs : kept).add(k);
  }
  return (kept: kept, hubs: hubs);
}

/// Packages whose tests CI never runs from the package loop (vendored / forks /
/// stubs, and fushi_torrent which needs a real DLL). Mirrors main.yml's `skip`.
const Set<String> kCiSkippedPackages = <String>{
  'flutter_inappwebview_windows',
  'gamepads_windows',
  'gamepads_android_stub',
  'fushi_torrent',
};

/// Pure-Dart packages that CI also `dart analyze`s on their own
/// (server-gate.yml); `flutter analyze` in fushi/ does not cover them.
const Set<String> kSeparatelyAnalyzedPackages = <String>{
  'fushi_engine',
  'fushi_server',
};

/// `package:` URIs that import the library a changed file belongs to.
///
/// [packageNames] maps a `packages/<dir>` directory to its pubspec name.
/// [partOwner] is the `part of '<uri>'` target of the changed file when it is a
/// part (read by the caller; null for libraries or deleted files): a part is
/// never imported itself, its owning library is.
Set<String> importKeysForChange(
  String repoPath, {
  required Map<String, String> packageNames,
  String? partOwner,
}) {
  String libraryPath = repoPath;
  if (partOwner != null) {
    final int slash = repoPath.lastIndexOf('/');
    libraryPath = _normalize('${repoPath.substring(0, slash)}/$partOwner');
  }
  if (!libraryPath.endsWith('.dart')) return <String>{};
  final List<String> seg = libraryPath.split('/');
  if (seg.length > 2 && seg[0] == 'fushi' && seg[1] == 'lib') {
    return <String>{'package:fushi/${seg.sublist(2).join('/')}'};
  }
  if (seg.length > 3 && seg[0] == 'packages' && seg[2] == 'lib') {
    final String? name = packageNames[seg[1]];
    if (name == null) return <String>{};
    return <String>{'package:$name/${seg.sublist(3).join('/')}'};
  }
  return <String>{};
}

String _normalize(String path) {
  final List<String> out = <String>[];
  for (final String s in path.split('/')) {
    if (s == '..') {
      if (out.isNotEmpty) out.removeLast();
    } else if (s.isNotEmpty && s != '.') {
      out.add(s);
    }
  }
  return out.join('/');
}

/// `part of '<uri>';` target in [source], or null.
String? partOfTarget(String source) {
  final Match? m = RegExp(r'''^part of ['"]([^'"]+)['"];''', multiLine: true)
      .firstMatch(source);
  return m?.group(1);
}

/// App tests (repo-root relative, under fushi/test/) affected through Dart
/// imports by [changed]:
/// * a changed `_test.dart` file itself;
/// * tests that import a changed library by its `package:` URI ([importKeys]);
/// * tests that import a changed non-test helper under fushi/test/ (matched by
///   `/<basename>'` in an import, over-selecting on name clashes on purpose);
/// * `<name>_test.dart` for a changed `<name>.dart`.
/// Barrel re-exports are deliberately NOT followed (they would select most of
/// the suite); the full sharded suite on CI stays the backstop for those.
Set<String> directImpactTests({
  required Iterable<String> changed,
  required Map<String, String> testSources,
  required Set<String> importKeys,
}) {
  final Set<String> out = <String>{};
  final Set<String> helperNames = <String>{};
  final Set<String> sameNameTests = <String>{};
  for (final String c in changed) {
    if (c.startsWith('fushi/test/') && c.endsWith('_test.dart')) {
      if (testSources.containsKey(c)) out.add(c);
      continue;
    }
    final String base = c.split('/').last;
    if (c.startsWith('fushi/test/') && base.endsWith('.dart')) {
      helperNames.add(base);
    }
    if (base.endsWith('.dart')) {
      sameNameTests.add('${base.substring(0, base.length - 5)}_test.dart');
    }
  }
  for (final MapEntry<String, String> t in testSources.entries) {
    final String src = t.value;
    if (sameNameTests.contains(t.key.split('/').last) ||
        importKeys
            .any((String k) => src.contains("'$k'") || src.contains('"$k"')) ||
        helperNames
            .any((String h) => src.contains("/$h'") || src.contains("'$h'"))) {
      out.add(t.key);
    }
  }
  return out;
}

/// Packages under packages/ touched by [changed] whose tests CI runs.
Set<String> changedTestablePackages(Iterable<String> changed) => <String>{
      for (final String c in changed)
        if (c.startsWith('packages/') && c.split('/').length > 2)
          c.split('/')[1],
    }..removeAll(kCiSkippedPackages);

/// Whether the JS behaviour suites CI runs in the build job are affected.
bool touchesJsSuites(Iterable<String> changed) => changed.any((String c) =>
    c.startsWith('test/js/') ||
    c.startsWith('tools/browser-extension/') ||
    c.startsWith('fushi/assets/') ||
    c.endsWith('.js') ||
    c.endsWith('.mjs'));

/// Splits test paths into batches whose joined length stays under [maxChars]:
/// `flutter.bat` goes through cmd.exe on Windows (8191-char command line; the
/// rest of the flutter test invocation fits in the remaining ~690 chars).
List<List<String>> chunkByCommandLength(List<String> paths,
    {int maxChars = 7500}) {
  final List<List<String>> batches = <List<String>>[];
  List<String> cur = <String>[];
  int len = 0;
  for (final String p in paths) {
    if (cur.isNotEmpty && len + p.length + 1 > maxChars) {
      batches.add(cur);
      cur = <String>[];
      len = 0;
    }
    cur.add(p);
    len += p.length + 1;
  }
  if (cur.isNotEmpty) batches.add(cur);
  return batches;
}
