// Where tool/heavy.dart runs a `flutter analyze` / `dart analyze` that runs
// on this machine (Windows only): from a fixed path per light slot,
// `<state dir>/analyze-<slot>`, a directory junction pointed at the checkout
// for the length of the run.
//
// Why: the analysis server's on-disk cache (%LOCALAPPDATA%/.dartServer/
// .analysis-driver, shared machine-wide) keys its diagnostics by each file's
// absolute path, so the first analyze in a fresh worktree recomputes them even
// when an identical tree was analyzed minutes before. The workers of
// tool/dist_test.dart analyze in fixed directories and stay warm. The server
// does not resolve the junction back to the real path, so a run through
// analyze-<slot> finds what the slot's previous run (any worktree, mostly the
// same code) left under the same paths (measured 2026-11-20, see
// docs/agent/heavy-lease.md). It is an alias, not a copy: the run reads the
// checkout itself (working tree, untracked files, generated strings.g.dart).
//
// The slot lock is held for the whole run, so two analyzes never share one
// junction. Re-pointing deletes only the junction itself (Link.deleteSync
// removes the reparse point, never what it points at); anything at the path
// that is not a link is left alone and the run goes from the real path.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'heavy_budget.dart' show HeavyKind;

/// Set to `off` to run analyze from the real path.
const String kHeavyAnalyzeViaEnv = 'FUSHI_HEAVY_ANALYZE_VIA';

/// A local analyze run from its slot's junction instead of [checkout].
class HeavyAnalyzeVia {
  const HeavyAnalyzeVia({
    required this.link,
    required this.checkout,
    required this.cwd,
  });

  /// The junction: `<state dir>/analyze-<slot>`.
  final String link;

  /// The checkout root the junction points at.
  final String checkout;

  /// The command's working directory, under [link] (the same place relative
  /// to the checkout as where heavy was started).
  final String cwd;
}

String _norm(String p, bool isWindows) {
  final String s = p.replaceAll(r'\', '/').replaceFirst(RegExp(r'/+$'), '');
  return isWindows ? s.toLowerCase() : s;
}

/// The junction path of light slot [slot] in [stateDir].
String heavyAnalyzeLinkPath(String stateDir, int slot) =>
    '${stateDir.replaceAll(r'\', '/').replaceFirst(RegExp(r'/+$'), '')}'
    '/analyze-$slot';

/// How an analyze admitted to [slot] runs from its slot's junction, or null
/// when it runs where it was started: not Windows, not an analyze, no slot
/// (lease skipped: CI / FUSHI_HEAVY=off), no checkout, [cwd] outside the
/// checkout, already started through a junction of [stateDir], or
/// [kHeavyAnalyzeViaEnv]=off.
HeavyAnalyzeVia? planHeavyAnalyzeVia({
  required HeavyKind kind,
  required bool isWindows,
  required int? slot,
  required String? checkout,
  required String cwd,
  required String stateDir,
  required Map<String, String> environment,
}) {
  if (!isWindows || kind != HeavyKind.analyze) return null;
  if (slot == null || checkout == null) return null;
  if ((environment[kHeavyAnalyzeViaEnv] ?? '').toLowerCase() == 'off') {
    return null;
  }
  final String root = _norm(checkout, isWindows);
  final String here = _norm(cwd, isWindows);
  if (here != root && !here.startsWith('$root/')) return null;
  // Started from a junction already (or from inside the state dir): pointing
  // a junction at itself or at a sibling junction is never wanted.
  final String state = _norm(stateDir, isWindows);
  if (root == state || root.startsWith('$state/')) return null;
  final String link = heavyAnalyzeLinkPath(stateDir, slot);
  final String rel = cwd
      .replaceAll(r'\', '/')
      .replaceFirst(RegExp(r'/+$'), '')
      .substring(
        checkout.replaceAll(r'\', '/').replaceFirst(RegExp(r'/+$'), '').length,
      );
  return HeavyAnalyzeVia(
    link: link,
    checkout: checkout.replaceAll(r'\', '/').replaceFirst(RegExp(r'/+$'), ''),
    cwd: '$link$rel',
  );
}

/// Points the junction [link] at [target]: an existing link there is deleted
/// first (the link only: never anything under its target). Throws a
/// [FileSystemException] when [link] exists and is not a link, leaving it as
/// it is.
void pointHeavyAnalyzeLink(String link, String target) {
  removeHeavyAnalyzeLink(link);
  Directory(link).parent.createSync(recursive: true);
  // A junction, explicitly: dart:io's Link.create makes a directory symlink
  // where the account may (developer mode), and only the junction was
  // measured to keep the analysis server on the alias path.
  final ProcessResult r = Process.runSync('cmd', <String>[
    '/c',
    'mklink',
    '/J',
    link.replaceAll('/', r'\'),
    target.replaceAll('/', r'\'),
  ]);
  if (r.exitCode != 0) {
    throw FileSystemException(
      'mklink /J failed (exit ${r.exitCode}): '
      '${'${r.stdout}${r.stderr}'.trim()}',
      link,
    );
  }
}

/// Deletes the junction [link] if there is one, never what it points at.
/// Throws a [FileSystemException] when [link] exists and is not a link.
void removeHeavyAnalyzeLink(String link) {
  final FileSystemEntityType t = FileSystemEntity.typeSync(
    link,
    followLinks: false,
  );
  if (t == FileSystemEntityType.notFound) return;
  if (t != FileSystemEntityType.link) {
    throw FileSystemException(
      'exists and is not a junction; heavy does not touch it',
      link,
    );
  }
  // Removes the reparse point itself; the target directory is not followed.
  Link(link).deleteSync();
}

/// [plan] with its junction in place, or null (and why, through [log]) when
/// the junction cannot be made: the run then goes from the real path, which
/// gives the same result, only without the warm cache.
HeavyAnalyzeVia? openHeavyAnalyzeVia(
  HeavyAnalyzeVia? plan, {
  required void Function(String line) log,
}) {
  if (plan == null) return null;
  try {
    pointHeavyAnalyzeLink(plan.link, plan.checkout);
  } on FileSystemException catch (e) {
    log(
      'heavy: cannot point ${plan.link} at ${plan.checkout} '
      '(${e.message}${e.osError != null ? ': ${e.osError!.message}' : ''}); '
      'analyzing from the real path, without the warm cache',
    );
    return null;
  }
  return plan;
}

/// Removes [via]'s junction after the run (the cache is keyed by the path
/// string, not by the junction being there, so nothing warm is lost).
void closeHeavyAnalyzeVia(
  HeavyAnalyzeVia? via, {
  required void Function(String line) log,
}) {
  if (via == null) return;
  try {
    removeHeavyAnalyzeLink(via.link);
  } on FileSystemException catch (e) {
    log('heavy: could not remove ${via.link}: ${e.message}');
  }
}

/// [text] with [via]'s junction path (either slash, any case) written as the
/// checkout path, so what the run prints points into the worktree.
String unaliasHeavyAnalyzeOutput(String text, HeavyAnalyzeVia via) {
  final String pattern = via.link
      .split(RegExp(r'[\\/]+'))
      .where((String s) => s.isNotEmpty)
      .map(RegExp.escape)
      .join(r'[\\/]+');
  final String checkoutBackslash = via.checkout.replaceAll('/', r'\');
  // Not the start of a longer name (analyze-100 in analyze-1000).
  return text.replaceAllMapped(
    RegExp('$pattern(?![\\w.-])', caseSensitive: false),
    (Match m) {
      // Keep the separator style the tool printed.
      return m[0]!.contains(r'\') ? checkoutBackslash : via.checkout;
    },
  );
}

/// Copies [p]'s stdout / stderr to this process's, line by line through
/// [unaliasHeavyAnalyzeOutput]; completes when both streams are drained.
Future<void> forwardHeavyAnalyzeOutput(Process p, HeavyAnalyzeVia via) {
  Future<void> pipe(Stream<List<int>> from, IOSink to) => from
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .forEach(
        (String line) => to.writeln(unaliasHeavyAnalyzeOutput(line, via)),
      );
  return Future.wait(<Future<void>>[
    pipe(p.stdout, stdout),
    pipe(p.stderr, stderr),
  ]).then((_) {});
}
