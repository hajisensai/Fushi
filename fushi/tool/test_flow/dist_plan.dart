/// Planning for `tool/dist_test.dart`: which suites must run where, and how
/// they are packed into batches that workers pull from a shared queue.
///
/// Design: docs/specs/2026-10-24-distributed-unit-tests.md (sections 3 and 4).
library;

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
  r'''\btags:\s*(\[[^\]]*\]|'[^']*'|"[^"]*")''',
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

/// One unit of queue work: one `flutter test` process on one worker.
class DistBatch {
  DistBatch({
    required this.id,
    required this.files,
    required this.estimatedMs,
    required this.platform,
    required this.capabilities,
  });

  final int id;

  /// Suite paths relative to `fushi/` (`test/...`), sorted.
  final List<String> files;

  /// Sum of the suites' CI-measured (or size-estimated) run times.
  final int estimatedMs;

  /// Null: any platform.
  final DistPlatform? platform;
  final Set<String> capabilities;

  /// Infrastructure attempts so far (ssh drop, timeout); test failures are
  /// never retried.
  int attempts = 0;

  bool eligibleFor(DistPlatform workerPlatform, Set<String> workerCaps) =>
      (platform == null || platform == workerPlatform) &&
      workerCaps.containsAll(capabilities);

  String get requirementLabel {
    final List<String> parts = <String>[
      platform?.name ?? 'any',
      ...(capabilities.toList()..sort()),
    ];
    return parts.join('+');
  }
}

/// Packs [weights] (suite → ms) into batches of about [targetMs] each.
///
/// Suites are grouped by placement (platform × capabilities); a suite with N
/// pinned platforms appears in N groups. Inside a group, suites are taken
/// heaviest first and each goes onto the currently lightest of
/// ceil(groupMs / targetMs) bins (LPT), so batches of a group come out even.
/// Batches come out heaviest first with ids 1..N; which one a worker takes
/// next is [takeNextBatch]'s call.
List<DistBatch> planDistBatches({
  required Map<String, int> weights,
  required Map<String, SuiteRequirement> requirements,
  required int targetMs,
}) {
  final Map<String, List<String>> groups = <String, List<String>>{};
  final Map<String, (DistPlatform?, Set<String>)> groupKeys =
      <String, (DistPlatform?, Set<String>)>{};
  for (final String path in weights.keys) {
    final SuiteRequirement req = requirements[path] ?? const SuiteRequirement();
    final List<DistPlatform?> placements = req.platforms.isEmpty
        ? <DistPlatform?>[null]
        : (req.platforms.toList()..sort((a, b) => a.index - b.index));
    final List<String> caps = req.capabilities.toList()..sort();
    for (final DistPlatform? platform in placements) {
      final String key = '${platform?.name ?? 'any'}|${caps.join(',')}';
      groups.putIfAbsent(key, () => <String>[]).add(path);
      groupKeys[key] = (platform, req.capabilities);
    }
  }

  final List<DistBatch> batches = <DistBatch>[];
  final List<String> keys = groups.keys.toList()..sort();
  for (final String key in keys) {
    final List<String> paths = groups[key]!
      ..sort((String a, String b) {
        final int byWeight = weights[b]!.compareTo(weights[a]!);
        return byWeight != 0 ? byWeight : a.compareTo(b);
      });
    final int total = paths.fold<int>(0, (int s, String p) => s + weights[p]!);
    final int binCount = ((total / targetMs).ceil()).clamp(1, paths.length);
    final List<List<String>> bins = List<List<String>>.generate(
      binCount,
      (_) => <String>[],
    );
    final List<int> loads = List<int>.filled(binCount, 0);
    for (final String path in paths) {
      int target = 0;
      for (int i = 1; i < binCount; i++) {
        if (loads[i] < loads[target]) target = i;
      }
      bins[target].add(path);
      loads[target] += weights[path]!;
    }
    final (DistPlatform?, Set<String>) placement = groupKeys[key]!;
    for (int i = 0; i < binCount; i++) {
      batches.add(
        DistBatch(
          id: 0,
          files: bins[i]..sort(),
          estimatedMs: loads[i],
          platform: placement.$1,
          capabilities: placement.$2,
        ),
      );
    }
  }
  batches.sort((DistBatch a, DistBatch b) {
    final int byWeight = b.estimatedMs.compareTo(a.estimatedMs);
    return byWeight != 0 ? byWeight : a.files.first.compareTo(b.files.first);
  });
  return <DistBatch>[
    for (int i = 0; i < batches.length; i++)
      DistBatch(
        id: i + 1,
        files: batches[i].files,
        estimatedMs: batches[i].estimatedMs,
        platform: batches[i].platform,
        capabilities: batches[i].capabilities,
      ),
  ];
}

/// Takes the next batch [eligible] for a worker out of [pending]: the pinned
/// batches (those only some workers can run) before free ones, heaviest
/// first within each, so the one Windows box is not stuck behind work any
/// Mac could have taken.
DistBatch? takeNextBatch(
  List<DistBatch> pending,
  bool Function(DistBatch batch) eligible,
) {
  DistBatch? best;
  for (final DistBatch batch in pending) {
    if (!eligible(batch)) continue;
    if (best == null) {
      best = batch;
      continue;
    }
    final bool pinned = batch.platform != null || batch.capabilities.isNotEmpty;
    final bool bestPinned =
        best.platform != null || best.capabilities.isNotEmpty;
    if (pinned != bestPinned) {
      if (pinned) best = batch;
      continue;
    }
    if (batch.estimatedMs > best.estimatedMs) best = batch;
  }
  if (best != null) pending.remove(best);
  return best;
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
    kDistTestPathPattern.hasMatch(path) && !path.split('/').contains('..');
