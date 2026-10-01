// Pure decisions of the machine-wide heavy-run lease (tool/heavy.dart,
// heavy_lease.dart): what a command costs, how many may run at once, and
// whether the machine has room for one more right now. No I/O here, so the
// rules are unit-tested (test/tools/heavy_budget_test.dart).
//
// Why (2026-09-30 / 10-01): several agents ran `flutter test` / analyze /
// builds at once on the user's desktop. The old gate counted dart.exe
// processes every 30 s (all waiters saw "2 busy" and started together), ran
// anyway after 30 min, ignored memory, and only pre_push_check used it. The
// machine went down to ~1 GB free and the user's own programs stalled.

/// What kind of work a wrapped command is; decides its cost.
enum HeavyKind { test, analyze, build, other }

/// The cost model of one heavy run.
class HeavyNeed {
  const HeavyNeed({
    required this.kind,
    required this.needMb,
    required this.capMb,
    required this.worktreeExclusive,
  });

  final HeavyKind kind;

  /// Memory the run is expected to take; admission waits until the machine
  /// has this much on top of the reserve kept for the user.
  final int needMb;

  /// Hard ceiling (Windows job memory limit) for the whole process tree; a
  /// runaway run fails alone instead of paging out the desktop.
  final int capMb;

  /// Runs that write the checkout's build/ (native assets, sqlite3.dll,
  /// result files) must not overlap inside one worktree.
  final bool worktreeExclusive;
}

const HeavyNeed _test = HeavyNeed(
  kind: HeavyKind.test,
  needMb: 3072,
  capMb: 12288,
  worktreeExclusive: true,
);
const HeavyNeed _analyze = HeavyNeed(
  kind: HeavyKind.analyze,
  needMb: 3072,
  capMb: 8192,
  worktreeExclusive: false,
);
const HeavyNeed _build = HeavyNeed(
  kind: HeavyKind.build,
  needMb: 6144,
  capMb: 16384,
  worktreeExclusive: true,
);
const HeavyNeed _other = HeavyNeed(
  kind: HeavyKind.other,
  needMb: 2048,
  capMb: 16384,
  worktreeExclusive: true,
);

/// The [HeavyNeed] for a kind (pre_push_check leases per step by kind).
HeavyNeed heavyNeedFor(HeavyKind kind) => switch (kind) {
      HeavyKind.test => _test,
      HeavyKind.analyze => _analyze,
      HeavyKind.build => _build,
      HeavyKind.other => _other,
    };

String _base(String path) {
  final String name = path.replaceAll(r'\', '/').split('/').last.toLowerCase();
  final int dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// Classifies `argv` (`flutter test ...`, `dart analyze`, `gradlew.bat
/// assembleRelease`, `powershell -File tool/run_windows_itest.ps1`, ...).
HeavyNeed classifyHeavyCommand(List<String> argv) {
  if (argv.isEmpty) return _other;
  final String exe = _base(argv.first);
  final List<String> rest = argv.skip(1).toList();
  final String? verb =
      rest.where((String a) => !a.startsWith('-')).firstOrNull?.toLowerCase();
  if (exe == 'flutter' || exe == 'dart' || exe == 'fvm') {
    // `fvm flutter test` / `fvm dart analyze`: classify the inner tool.
    if (exe == 'fvm' && rest.isNotEmpty) return classifyHeavyCommand(rest);
    switch (verb) {
      case 'test':
        return _test;
      case 'analyze':
        return _analyze;
      case 'build':
      case 'run':
        return _build;
    }
    return _other;
  }
  if (exe == 'gradlew' || exe == 'gradle' || exe == 'xcodebuild') {
    return _build;
  }
  final String line = argv.join(' ').toLowerCase();
  if (line.contains('run_windows_itest')) return _build;
  return _other;
}

/// Concurrent heavy runs this machine allows: one per 20 GB of RAM, 1..4.
/// (64 GB -> 3: three runs of 4 testers each next to a desktop in use.)
int defaultHeavySlots(int totalPhysMb) =>
    (totalPhysMb ~/ (20 * 1024)).clamp(1, 4);

/// A reading of the machine's memory, in MB. [availCommitMb] is commit
/// limit minus commit charge (Windows); null where the OS has no such notion.
class MemorySnapshot {
  const MemorySnapshot({
    required this.totalPhysMb,
    required this.availPhysMb,
    this.availCommitMb,
  });

  final int totalPhysMb;
  final int availPhysMb;
  final int? availCommitMb;
}

/// Physical memory always left to the user: 4 GB, less on small machines.
int physReserveMb(int totalPhysMb) => (totalPhysMb ~/ 8).clamp(1024, 4096);

/// Commit headroom always left: Windows fails allocations (every program,
/// not just ours) when the commit charge reaches the limit, RAM free or not.
int commitReserveMb(int totalPhysMb) => (totalPhysMb ~/ 6).clamp(2048, 8192);

/// Null when a run needing [needMb] may start; otherwise why not.
/// [pendingMb] is memory promised to runs that just started and have not
/// allocated it yet (see [pendingReservationMb]).
String? heavyAdmissionBlocker(
  MemorySnapshot m,
  int needMb, {
  int pendingMb = 0,
}) {
  final int want = needMb + pendingMb;
  final int phys = physReserveMb(m.totalPhysMb);
  if (m.availPhysMb - want < phys) {
    return 'available RAM ${m.availPhysMb} MB < need $needMb'
        '${pendingMb > 0 ? ' + starting $pendingMb' : ''} + reserve $phys MB';
  }
  final int? commit = m.availCommitMb;
  final int commitReserve = commitReserveMb(m.totalPhysMb);
  if (commit != null && commit - want < commitReserve) {
    return 'commit headroom $commit MB < need $needMb'
        '${pendingMb > 0 ? ' + starting $pendingMb' : ''} + reserve '
        '$commitReserve MB';
  }
  return null;
}

/// One held slot, as its holder recorded it.
class HeavyHolder {
  const HeavyHolder({
    required this.slot,
    required this.pid,
    required this.needMb,
    required this.startedAtMs,
    required this.label,
    required this.cwd,
  });

  final int slot;
  final int pid;
  final int needMb;
  final int startedAtMs;
  final String label;
  final String cwd;

  Map<String, Object> toJson() => <String, Object>{
        'pid': pid,
        'needMb': needMb,
        'startedAt': startedAtMs,
        'label': label,
        'cwd': cwd,
      };

  static HeavyHolder? fromJson(int slot, Object? json) {
    if (json is! Map) return null;
    final Object? pid = json['pid'];
    final Object? need = json['needMb'];
    final Object? at = json['startedAt'];
    if (pid is! int || need is! int || at is! int) return null;
    return HeavyHolder(
      slot: slot,
      pid: pid,
      needMb: need,
      startedAtMs: at,
      label: '${json['label'] ?? ''}',
      cwd: '${json['cwd'] ?? ''}',
    );
  }
}

/// Memory promised to holders that started within [warmup]: a run admitted a
/// second ago has not allocated its memory yet, so the next waiter reading
/// "available" would see room that is already spoken for (the old gate's
/// race, moved from process counts to megabytes).
int pendingReservationMb(
  Iterable<HeavyHolder> holders,
  int nowMs, {
  Duration warmup = const Duration(seconds: 90),
}) {
  int sum = 0;
  for (final HeavyHolder h in holders) {
    if (nowMs - h.startedAtMs < warmup.inMilliseconds) sum += h.needMb;
  }
  return sum;
}

/// True when [peakMb] means the run hit its [capMb] (allocations near the
/// ceiling fail, so the peak stops just short of it).
bool heavyCapHit(int peakMb, int capMb) => peakMb >= capMb - 64;

/// The environment variable a lease holder passes to its process tree: a
/// nested tool (pre_push_check under tool/heavy.dart) must not queue again
/// for a slot its own parent holds, nor wait on the worktree lock its parent
/// holds (that would deadlock).
const String kHeavyLeaseEnv = 'FUSHI_HEAVY_LEASE';

/// Why no lease is taken in [env], or null when one is. CI runners are
/// single-tenant (and small: a reserve sized for a desktop would keep a 7 GB
/// runner waiting forever); `FUSHI_HEAVY=off` is the manual escape.
String? heavyLeaseSkipReason(Map<String, String> env) {
  if (env['CI'] == 'true') return 'CI';
  if ((env['FUSHI_HEAVY'] ?? '').toLowerCase() == 'off') {
    return 'FUSHI_HEAVY=off';
  }
  final String parent = env[kHeavyLeaseEnv] ?? '';
  if (parent.isNotEmpty) return 'held by parent pid $parent';
  return null;
}
