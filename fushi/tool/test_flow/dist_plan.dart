/// Planning for `tool/dist_test.dart`: which suites must run where, and how
/// they are packed into batches that workers pull from a shared queue.
///
/// Design: docs/specs/2026-10-24-distributed-unit-tests.md (sections 3 and 4).
library;

import 'dart:convert';

/// Host platforms a worker can be. Linux-gated suites are not pinned (no
/// Linux worker exists; they self-skip on the others and CI covers them).
enum DistPlatform { windows, macos }

/// Tags whose suites need a worker that declared the matching capability
/// (see fushi/dart_test.yaml: they need real local fixtures or tools).
const Set<String> kDistCapabilityTags = <String>{
  'golden',
  'realdata',
  'ffmpeg',
  'chrome',
};

/// Where one suite has to run, derived from its source text.
class SuiteRequirement {
  const SuiteRequirement({
    this.platforms = const <DistPlatform>{},
    this.capabilities = const <String>{},
  });

  /// Empty: once, on any worker. Otherwise once on *each* listed platform
  /// (a suite gated on both Windows and macOS is run on both).
  final Set<DistPlatform> platforms;

  /// Every one of these must be among the worker's capabilities.
  final Set<String> capabilities;
}

final RegExp _platformCheck = RegExp(r'Platform\.is(Windows|MacOS)\b');
final RegExp _testOn = RegExp(r'''@TestOn\(\s*['"]([^'"]*)['"]''');
final RegExp _tagsAnnotation = RegExp(r'@Tags\(([^)]*)\)');
final RegExp _tagsNamedArg = RegExp(
  r'''\btags:\s*(?:const\s+)?(?:<String>\s*)?(\[[^\]]*\]|'[^']*'|"[^"]*")''',
);
final RegExp _quoted = RegExp(r'''['"]([A-Za-z0-9_-]+)['"]''');

/// Reads the platform gates and capability tags out of a test file.
///
/// Static and file-level on purpose: one `Platform.isWindows` anywhere pins
/// the whole file to Windows, which over-pins a little but never lets a
/// Windows-only branch be silently skipped on a Mac.
SuiteRequirement scanSuiteRequirement(String source) {
  final Set<DistPlatform> platforms = <DistPlatform>{};
  for (final RegExpMatch m in _platformCheck.allMatches(source)) {
    platforms.add(
      m.group(1) == 'Windows' ? DistPlatform.windows : DistPlatform.macos,
    );
  }
  for (final RegExpMatch m in _testOn.allMatches(source)) {
    final String selector = m.group(1)!;
    if (RegExp(r'(?<!!)\bwindows\b').hasMatch(selector)) {
      platforms.add(DistPlatform.windows);
    }
    if (RegExp(r'(?<!!)\b(mac-os|posix)\b').hasMatch(selector) ||
        selector.contains('!windows')) {
      platforms.add(DistPlatform.macos);
    }
    if (selector.contains('!mac-os')) platforms.add(DistPlatform.windows);
  }
  final Set<String> capabilities = <String>{};
  for (final RegExp pattern in <RegExp>[_tagsAnnotation, _tagsNamedArg]) {
    for (final RegExpMatch m in pattern.allMatches(source)) {
      for (final RegExpMatch q in _quoted.allMatches(m.group(1)!)) {
        final String tag = q.group(1)!;
        if (kDistCapabilityTags.contains(tag)) capabilities.add(tag);
      }
    }
  }
  return SuiteRequirement(platforms: platforms, capabilities: capabilities);
}

/// The checked-in manual pins, relative to `fushi/`: suites whose host
/// dependence sits in lib code (a `Platform.isMacOS` branch under test), which
/// [scanSuiteRequirement] cannot see in the test file.
const String kDistAffinityPath = 'tool/test_flow/dist_affinity.json';

/// Reads `{"pins": {path: {"platforms": [...], "reason": "..."}}}`; every pin
/// must name at least one platform and give a reason.
Map<String, Set<DistPlatform>> readDistAffinity(String text) {
  final Object? decoded = jsonDecode(text);
  final Object? pins = decoded is Map<String, Object?> ? decoded['pins'] : null;
  if (pins is! Map<String, Object?>) {
    throw const FormatException('expected {"pins": {path: {...}}}');
  }
  return <String, Set<DistPlatform>>{
    for (final MapEntry<String, Object?> e in pins.entries)
      e.key: _pinPlatforms(e.key, e.value),
  };
}

Set<DistPlatform> _pinPlatforms(String path, Object? pin) {
  if (pin is! Map<String, Object?> ||
      pin['platforms'] is! List<Object?> ||
      pin['reason'] is! String ||
      (pin['reason']! as String).trim().isEmpty) {
    throw FormatException('$path: needs "platforms" and a "reason"');
  }
  final Set<DistPlatform> platforms = <DistPlatform>{
    for (final Object? p in pin['platforms']! as List<Object?>)
      DistPlatform.values.firstWhere(
        (DistPlatform d) => d.name == p,
        orElse: () => throw FormatException('$path: unknown platform "$p"'),
      ),
  };
  if (platforms.isEmpty) throw FormatException('$path: empty "platforms"');
  return platforms;
}

/// [scanned] with a manual pin's platforms in place of the scanned ones.
SuiteRequirement applyDistPin(
  SuiteRequirement scanned,
  Set<DistPlatform>? pin,
) => pin == null
    ? scanned
    : SuiteRequirement(platforms: pin, capabilities: scanned.capabilities);

/// Cost model of one suite inside a `flutter test` process, in "weight"
/// milliseconds: its CI-measured run time plus the compile + tester start-up
/// every suite pays one after another (the CI table leaves that out: 0.1-0.3 s
/// there, ~1.5 s per suite measured on the M4 Mac). Only the *shape* of the
/// cost matters; each worker's measured speed factor (wall ms per weight ms,
/// [DistSpeed]) scales it to that machine.
const int kDistSuiteOverheadMs = 1500;

/// One suite placed once: a suite pinned to two platforms is two units.
class DistUnit {
  const DistUnit({
    required this.path,
    required this.weightMs,
    this.platform,
    this.capabilities = const <String>{},
  });

  /// Suite path relative to `fushi/` (`test/...`).
  final String path;
  final int weightMs;

  /// Null: any platform.
  final DistPlatform? platform;
  final Set<String> capabilities;

  bool get pinned => platform != null || capabilities.isNotEmpty;

  bool eligibleFor(DistPlatform workerPlatform, Set<String> workerCaps) =>
      (platform == null || platform == workerPlatform) &&
      workerCaps.containsAll(capabilities);

  String get label => <String>[
    platform?.name ?? 'any',
    ...(capabilities.toList()..sort()),
  ].join('+');
}

/// Every placement of every suite in [weights] (path → CI-measured ms).
List<DistUnit> distUnits({
  required Map<String, int> weights,
  required Map<String, SuiteRequirement> requirements,
}) => <DistUnit>[
  for (final String path in weights.keys)
    for (final DistPlatform? platform
        in (requirements[path]?.platforms.isEmpty ?? true)
            ? <DistPlatform?>[null]
            : (requirements[path]!.platforms.toList()
                ..sort((DistPlatform a, DistPlatform b) => a.index - b.index)))
      DistUnit(
        path: path,
        weightMs: weights[path]! + kDistSuiteOverheadMs,
        platform: platform,
        capabilities: requirements[path]?.capabilities ?? const <String>{},
      ),
];

/// What one worker runs in one `flutter test` process.
class DistBatch {
  DistBatch({required this.id, required this.units});

  final int id;
  final List<DistUnit> units;

  /// Suite paths, sorted.
  late final List<String> files = <String>[
    for (final DistUnit u in units) u.path,
  ]..sort();

  late final int weightMs = units.fold<int>(
    0,
    (int s, DistUnit u) => s + u.weightMs,
  );

  /// e.g. `any:110 windows:4 any+chrome:1`.
  String get label {
    final Map<String, int> counts = <String, int>{};
    for (final DistUnit u in units) {
      counts[u.label] = (counts[u.label] ?? 0) + 1;
    }
    return <String>[
      for (final String k in counts.keys.toList()..sort()) '$k:${counts[k]}',
    ].join(' ');
  }
}

/// The work no batch has taken yet. Units are kept heaviest first, so big
/// suites go out early and the end of the run is made of small ones.
class DistSuiteQueue {
  DistSuiteQueue(Iterable<DistUnit> units)
    : _units = units.toList()..sort(_heaviestFirst);

  final List<DistUnit> _units;
  int _nextId = 1;

  static int _heaviestFirst(DistUnit a, DistUnit b) {
    final int byWeight = b.weightMs.compareTo(a.weightMs);
    return byWeight != 0 ? byWeight : a.path.compareTo(b.path);
  }

  List<DistUnit> get remaining => List<DistUnit>.unmodifiable(_units);

  bool get isEmpty => _units.isEmpty;

  int remainingMs(bool Function(DistUnit unit) eligible) => _units
      .where(eligible)
      .fold<int>(0, (int s, DistUnit u) => s + u.weightMs);

  /// Takes up to [budgetMs] of weight (always at least one unit) of what
  /// [eligible] allows: units only some workers can run first, so a pinned
  /// suite is not left behind work anyone could have taken; heaviest first
  /// within each. Null when nothing is eligible.
  DistBatch? take({
    required bool Function(DistUnit unit) eligible,
    required int budgetMs,
  }) {
    final List<DistUnit> mine = <DistUnit>[
      for (final DistUnit u in _units)
        if (eligible(u) && u.pinned) u,
      for (final DistUnit u in _units)
        if (eligible(u) && !u.pinned) u,
    ];
    if (mine.isEmpty) return null;
    final List<DistUnit> taken = <DistUnit>[];
    int used = 0;
    for (final DistUnit u in mine) {
      if (taken.isNotEmpty && used + u.weightMs > budgetMs) continue;
      taken.add(u);
      used += u.weightMs;
      if (used >= budgetMs) break;
    }
    for (final DistUnit u in taken) {
      _units.remove(u);
    }
    return DistBatch(id: _nextId++, units: taken);
  }

  /// Puts a batch that did not get a fair run back (another worker may take
  /// it, split differently).
  void giveBack(DistBatch batch) {
    _units
      ..addAll(batch.units)
      ..sort(_heaviestFirst);
  }

  /// Units already given back once after an infrastructure failure.
  final Set<DistUnit> _retried = Set<DistUnit>.identity();

  /// After an infrastructure failure (ssh drop, timeout): puts [batch] back
  /// and returns true when none of its units had that second chance yet;
  /// false when one had (a suite that hangs every time is then reported, not
  /// retried until every worker is dropped). Kept per unit, not per batch:
  /// a given-back batch is cut up again into new batches.
  bool retryAfterInfra(DistBatch batch) {
    if (batch.units.any(_retried.contains)) return false;
    _retried.addAll(batch.units);
    giveBack(batch);
    return true;
  }
}

/// A worker's measured speed: wall milliseconds per weight millisecond, an
/// exponential moving average over the batches it finished ([kDistSpeedAlpha]
/// on the newest). Before the first one it is [prior].
///
/// Not a cumulative mean: the queue hands out heavy suites first and small ones
/// last, and the per-suite overhead a machine really pays shows up mostly in the
/// small ones, so the ratio drifts during a run (M4 Mac: 0.26 → 0.67). The
/// cumulative mean lagged so far behind that a "4 minute" batch ran 768 s.
class DistSpeed {
  DistSpeed({this.prior = 1.0});

  final double prior;
  double? _factor;

  bool get measured => _factor != null;

  double get factor => _factor ?? prior;

  void record({required int wallMs, required int weightMs}) {
    if (weightMs <= 0) return;
    final double ratio = wallMs / weightMs;
    final double? previous = _factor;
    _factor = previous == null
        ? ratio
        : kDistSpeedAlpha * ratio + (1 - kDistSpeedAlpha) * previous;
  }
}

/// Weight of the newest batch in [DistSpeed]'s moving average.
const double kDistSpeedAlpha = 0.6;

/// How much weight a worker takes next (guided self-scheduling): half of its
/// share of what it can still run, its share being its speed over the summed
/// speed of the live workers. Clamped so one batch lasts between
/// [minWall] (a process start costs seconds) and [maxWall] (bounded loss when
/// a machine drops out); a worker with no measurement yet takes a
/// [probeWall] batch first.
int distChunkBudgetMs({
  required int remainingEligibleMs,
  required DistSpeed speed,
  required double liveSpeedSum,
  Duration minWall = const Duration(seconds: 20),
  Duration maxWall = const Duration(minutes: 4),
  Duration probeWall = const Duration(minutes: 1),
}) {
  final double factor = speed.factor;
  final double share = liveSpeedSum <= 0 ? 1 : (1 / factor) / liveSpeedSum;
  final double wanted = remainingEligibleMs * share / 2;
  final Duration cap = speed.measured ? maxWall : probeWall;
  final double lo = minWall.inMilliseconds / factor;
  final double hi = cap.inMilliseconds / factor;
  return wanted.clamp(lo, hi < lo ? lo : hi).round();
}

/// Splits [files] into consecutive chunks of at most [maxChars] path
/// characters (plus one separator each); a single over-long path gets a chunk
/// of its own.
List<List<String>> splitByPathChars(List<String> files, int maxChars) {
  final List<List<String>> chunks = <List<String>>[];
  List<String> current = <String>[];
  int used = 0;
  for (final String f in files) {
    if (current.isNotEmpty && used + f.length + 1 > maxChars) {
      chunks.add(current);
      current = <String>[];
      used = 0;
    }
    current.add(f);
    used += f.length + 1;
  }
  if (current.isNotEmpty) chunks.add(current);
  return chunks;
}

/// Test file paths accepted on the wire to a worker. Anything else (spaces,
/// `..`, shell metacharacters, absolute paths) is rejected before it is put
/// on a remote command line or stdin.
final RegExp kDistTestPathPattern = RegExp(
  r'^test/[A-Za-z0-9_./-]+_test\.dart$',
);

bool isSafeDistTestPath(String path) =>
    (kDistTestPathPattern.hasMatch(path) ||
        kDistItestPathPattern.hasMatch(path)) &&
    !path.split('/').contains('..');

/// A path `dist_test.dart --analyze` may send (worker_analyze.sh checks the
/// same pattern): a file or directory of the app's Dart sources.
final RegExp kDistAnalyzePathPattern = RegExp(
  r'^(lib|test|tool|integration_test|test_driver|bin)(/[A-Za-z0-9_.-]+)*/?$',
);

bool isSafeDistAnalyzePath(String path) =>
    kDistAnalyzePathPattern.hasMatch(path) && !path.split('/').contains('..');

/// The `flutter analyze` options `dist_test.dart --analyze` passes on (the
/// shim and worker_analyze.sh accept these and nothing else).
const List<String> kDistAnalyzeOptions = <String>[
  '--fatal-infos',
  '--no-fatal-infos',
  '--fatal-warnings',
  '--no-fatal-warnings',
];

/// A remote `flutter analyze` taking longer is killed (a full one takes a
/// few minutes).
const Duration kDistAnalyzeTimeout = Duration(minutes: 30);

/// `dist_test.dart --offload` / `--analyze`: no other machine took any of the
/// work (none configured, reachable, free or allowed to run it). Nothing ran;
/// tool/heavy.dart runs the command on this machine instead.
const int kDistOffloadDeclined = 75;

/// Integration test files (`dist_test.dart --itest`): the real app, built and
/// launched on a desktop.
final RegExp kDistItestPathPattern = RegExp(
  r'^integration_test/[A-Za-z0-9_./-]+_test\.dart$',
);

bool isDistItestPath(String path) => path.startsWith('integration_test/');

/// The capability every integration test unit carries: a worker runs them
/// only when its config lists it (its owner agreed to the app being built
/// and launched there, off-screen, under an isolated data root).
const String kDistItestCapability = 'itest';

/// Which integration tests are distributed, and on which desktop platforms
/// (relative to `fushi/`). A list and not a scan: most of integration_test/
/// are probes that need real discs, games, devices or `--dart-define`d
/// files, and nothing in a file says which.
const String kDistItestManifestPath = 'tool/test_flow/dist_itests.json';

/// Model cost of one integration test file: one launch of the app built
/// once per run (start-up plus the test, 10-40 s measured), not a build.
const int kDistItestWeightMs = 40000;

/// The generated entry every distributed integration test is built into
/// (tool/dist_test/itest_entry.sh; git-ignored).
const String kDistItestEntryPath = 'integration_test/.dist/entry.dart';

/// Reads `{"itests": {path: {"platforms": [...]}}}`; every entry names at
/// least one platform and an `integration_test/..._test.dart` path.
Map<String, Set<DistPlatform>> readDistItests(String text) {
  final Object? decoded = jsonDecode(text);
  final Object? itests = decoded is Map<String, Object?>
      ? decoded['itests']
      : null;
  if (itests is! Map<String, Object?>) {
    throw const FormatException('expected {"itests": {path: {...}}}');
  }
  final Map<String, Set<DistPlatform>> out = <String, Set<DistPlatform>>{};
  for (final MapEntry<String, Object?> e in itests.entries) {
    if (!isSafeDistTestPath(e.key) || !isDistItestPath(e.key)) {
      throw FormatException('${e.key}: not an integration_test/*_test.dart');
    }
    final Object? entry = e.value;
    if (entry is! Map<String, Object?> ||
        entry['platforms'] is! List<Object?>) {
      throw FormatException('${e.key}: needs "platforms"');
    }
    final Set<DistPlatform> platforms = <DistPlatform>{
      for (final Object? p in entry['platforms']! as List<Object?>)
        DistPlatform.values.firstWhere(
          (DistPlatform d) => d.name == p,
          orElse: () =>
              throw FormatException('${e.key}: unknown platform "$p"'),
        ),
    };
    if (platforms.isEmpty) throw FormatException('${e.key}: empty "platforms"');
    out[e.key] = platforms;
  }
  return out;
}

/// One unit per (integration test, platform): each one is about the app on
/// that platform, so it runs on every platform the manifest lists.
/// [weights] holds measured ms where known.
List<DistUnit> distItestUnits(
  Map<String, Set<DistPlatform>> manifest, {
  Map<String, int> weights = const <String, int>{},
}) => <DistUnit>[
  for (final String path in manifest.keys)
    for (final DistPlatform platform
        in manifest[path]!.toList()
          ..sort((DistPlatform a, DistPlatform b) => a.index - b.index))
      DistUnit(
        path: path,
        weightMs: weights[path] ?? kDistItestWeightMs,
        platform: platform,
        capabilities: const <String>{kDistItestCapability},
      ),
];

/// The worker to re-run a red [unit] on for classification: one that may run
/// it and sits on a different machine than [redMachine] (another slot of the
/// same machine shares its disk, memory and load, so it would not tell a
/// machine-local false red from a real one). Faster machines first ([order]
/// is the caller's preference). Null when there is no such worker.
T? pickRerunTarget<T>(
  DistUnit unit, {
  required String redMachine,
  required List<T> order,
  required String Function(T worker) machineOf,
  required bool Function(T worker, DistUnit unit) eligible,
}) {
  for (final T w in order) {
    if (machineOf(w) != redMachine && eligible(w, unit)) return w;
  }
  return null;
}
