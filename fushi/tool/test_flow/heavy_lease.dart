// The machine-wide heavy-run lease: every local `flutter test` / analyze /
// build an agent starts takes one (tool/heavy.dart wraps any command;
// pre_push_check and flutter_test_failures take theirs themselves).
//
//   * Slots are OS file locks under <LOCALAPPDATA>/fushi-heavy/slot-N.lock.
//     Taking one is atomic, and a process that dies releases it -- no polling
//     race (the old gate let every waiter start at once) and no stale holder
//     (a dead run used to keep the gate shut for hours).
//   * A free slot is taken right away: there is no memory admission (removed
//     2026-10-03, see heavy_budget.dart). The slot count alone bounds the
//     machine's concurrency.
//   * Writers of one checkout's build/ (native assets, sqlite3.dll, result
//     files) additionally hold <repo>/.codex-test/heavy/worktree.lock.
//   * On Windows the holder joins a Job Object: below-normal priority (the
//     desktop wins every contended core), a memory ceiling for the whole tree,
//     and kill-on-close (a flutter_tester can no longer outlive its run and
//     lock sqlite3.dll for the next one).
//   * Waiters queue first come, first served: each holds a locked ticket under
//     <state>/queue/ and only the oldest live ticket may take a free slot, so
//     a run is never starved by later arrivals. A dead waiter's ticket is no
//     longer locked and is swept by whoever sees it.
// Nothing ever "runs anyway", and nothing gives up by default: a run waits in
// the queue until it is admitted (owner's call, 2026-10-03). An explicit wait
// limit is still honoured: past it the run fails and says why.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'heavy_budget.dart';

/// Where the slot locks live: one directory per machine (per user).
Directory heavyStateDir([Map<String, String>? environment]) {
  final Map<String, String> env = environment ?? Platform.environment;
  final String? override = env['FUSHI_HEAVY_DIR'];
  if (override != null && override.isNotEmpty) return Directory(override);
  final String base = Platform.isWindows
      ? (env['LOCALAPPDATA'] ?? env['TEMP'] ?? '.')
      : '${env['HOME'] ?? '.'}/.cache';
  return Directory('$base/fushi-heavy');
}

/// The checkout (main or worktree: `.git` is a file there) containing the
/// current directory, or null outside one.
String? locateCheckoutRoot() {
  Directory d = Directory.current.absolute;
  while (true) {
    if (FileSystemEntity.typeSync('${d.path}/.git') !=
        FileSystemEntityType.notFound) {
      return d.path;
    }
    final Directory up = d.parent;
    if (up.path == d.path) return null;
    d = up;
  }
}

/// The slot count: `FUSHI_HEAVY_SLOTS`, else [defaultHeavySlots] of the RAM.
int heavySlotCount(MemorySnapshot? memory, [Map<String, String>? environment]) {
  final Map<String, String> env = environment ?? Platform.environment;
  final int? forced = int.tryParse(env['FUSHI_HEAVY_SLOTS'] ?? '');
  if (forced != null && forced > 0) return forced;
  return memory == null ? 2 : defaultHeavySlots(memory.totalPhysMb);
}

/// This machine's memory, or null where it cannot be read (macOS: slots
/// alone then pace the runs).
MemorySnapshot? readMemorySnapshot() {
  if (Platform.isWindows) return _windowsMemory();
  if (Platform.isLinux) return _linuxMemory();
  return null;
}

MemorySnapshot? _linuxMemory() {
  try {
    final Map<String, int> kb = <String, int>{};
    for (final String line in File('/proc/meminfo').readAsLinesSync()) {
      final RegExpMatch? m = RegExp(r'^(\w+):\s+(\d+)').firstMatch(line);
      if (m != null) kb[m.group(1)!] = int.parse(m.group(2)!);
    }
    final int? total = kb['MemTotal'];
    final int? avail = kb['MemAvailable'];
    if (total == null || avail == null) return null;
    return MemorySnapshot(
      totalPhysMb: total ~/ 1024,
      availPhysMb: avail ~/ 1024,
    );
  } on FileSystemException {
    return null;
  }
}

/// A taken lease; [release] it when the run is over (process death releases
/// the OS locks anyway).
class HeavyLease {
  HeavyLease._({
    required this.slot,
    required this.skipReason,
    required this.waited,
    RandomAccessFile? slotLock,
    _WorktreeLock? worktreeLock,
    File? slotInfo,
  })  : _slotLock = slotLock,
        _worktreeLock = worktreeLock,
        _slotInfo = slotInfo;

  /// The slot held, or null when no lease was needed ([skipReason]).
  final int? slot;
  final String? skipReason;
  final Duration waited;
  RandomAccessFile? _slotLock;
  _WorktreeLock? _worktreeLock;
  final File? _slotInfo;

  /// Environment for children: nested tools see the lease as already held.
  Map<String, String> get childEnvironment => slot == null
      ? const <String, String>{}
      : <String, String>{kHeavyLeaseEnv: '$pid'};

  void release() {
    final RandomAccessFile? s = _slotLock;
    if (s != null) {
      _slotLock = null;
      if (slot != null) _heldInProcess.remove(slot);
      try {
        _slotInfo?.writeAsStringSync('');
      } on FileSystemException {
        // Diagnostic file only; the lock is what counts.
      }
      s.closeSync();
    }
    final _WorktreeLock? w = _worktreeLock;
    if (w != null) {
      _worktreeLock = null;
      w.release();
    }
  }
}

/// Thrown when no slot was free within the wait limit.
class HeavyLeaseTimeout implements Exception {
  HeavyLeaseTimeout(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Slots this process holds. POSIX record locks do not conflict within one
/// process (and closing any descriptor of the file drops them), so a process
/// that runs two lanes at once must never reopen a slot it holds.
final Set<int> _heldInProcess = <int>{};

/// Serializes this process's own admissions (same POSIX reason).
Future<void> _admissionChain = Future<void>.value();

/// Takes a lease for [need]. [worktreeRoot] (the repo root) is required for
/// worktree-exclusive needs; [waitMax] bounds the queueing (null: no bound).
/// [environment] / [readMemory] default to the real ones (tests inject).
Future<HeavyLease> acquireHeavyLease({
  required HeavyNeed need,
  required String label,
  String? worktreeRoot,
  Duration? waitMax,
  void Function(String line)? log,
  Map<String, String>? environment,
  MemorySnapshot? Function() readMemory = readMemorySnapshot,
  Duration poll = const Duration(seconds: 5),
}) async {
  final Map<String, String> env = environment ?? Platform.environment;
  final void Function(String) say = log ?? (String l) => stderr.writeln(l);
  final String? skip = heavyLeaseSkipReason(env);
  if (skip != null) {
    return HeavyLease._(slot: null, skipReason: skip, waited: Duration.zero);
  }
  final Stopwatch sw = Stopwatch()..start();
  final Directory dir = heavyStateDir(env)..createSync(recursive: true);

  _WorktreeLock? worktree;
  if (need.worktreeExclusive && worktreeRoot != null) {
    worktree = await _waitWorktreeLock(worktreeRoot, label, sw, waitMax, say);
  }
  try {
    final Completer<void> mine = Completer<void>();
    final Future<void> before = _admissionChain;
    _admissionChain = mine.future;
    await before;
    try {
      return await _waitSlot(
        dir,
        label,
        sw,
        waitMax,
        say,
        worktree,
        env: env,
        readMemory: readMemory,
        poll: poll,
      );
    } finally {
      mine.complete();
    }
  } catch (_) {
    worktree?.release();
    rethrow;
  }
}

/// Worktree lock files this process holds (lower-cased absolute paths).
final Set<String> _heldWorktrees = <String>{};

class _WorktreeLock {
  _WorktreeLock(this.file, this.key);
  final RandomAccessFile file;
  final String key;

  void release() {
    _heldWorktrees.remove(key);
    file.closeSync();
  }
}

Future<_WorktreeLock> _waitWorktreeLock(
  String root,
  String label,
  Stopwatch sw,
  Duration? waitMax,
  void Function(String) say,
) async {
  final Directory d = Directory('$root/.codex-test/heavy')
    ..createSync(recursive: true);
  final File info = File('${d.path}/worktree.json');
  final File lockFile = File('${d.path}/worktree.lock');
  final String key = lockFile.absolute.path.toLowerCase();
  bool told = false;
  while (true) {
    // Held by this very process (another lane): do not even open the file --
    // POSIX would grant the lock again, and closing the probe would drop it.
    final RandomAccessFile? f =
        _heldWorktrees.contains(key) ? null : _tryLock(lockFile);
    if (f != null) {
      _heldWorktrees.add(key);
      info.writeAsStringSync(
        jsonEncode(<String, Object>{
          'pid': pid,
          'label': label,
          'startedAt': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      return _WorktreeLock(f, key);
    }
    if (!told) {
      say(
        'heavy: this worktree already has a test/build running '
        '(${_readText(info)}); waiting for it',
      );
      told = true;
    }
    if (waitMax != null && sw.elapsed > waitMax) {
      throw HeavyLeaseTimeout(
        'heavy: worktree still busy after '
        '${sw.elapsed.inMinutes} min (${_readText(info)})',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

String _readText(File f) {
  try {
    return f.readAsStringSync();
  } on FileSystemException {
    return '?';
  }
}

/// The holders of the slots other processes hold right now (a free slot's
/// stale info file is ignored: the lock, not the file, is the truth).
List<HeavyHolder> readHeavyHolders(Directory dir, int slots) {
  final List<HeavyHolder> out = <HeavyHolder>[];
  for (int i = 0; i < slots; i++) {
    if (_heldInProcess.contains(i)) {
      final HeavyHolder? h = _holderInfo(dir, i);
      if (h != null) out.add(h);
      continue;
    }
    final RandomAccessFile? probe = _tryLock(File('${dir.path}/slot-$i.lock'));
    if (probe != null) {
      probe.closeSync();
      continue;
    }
    final HeavyHolder? h = _holderInfo(dir, i);
    out.add(
      h ??
          HeavyHolder(
            slot: i,
            pid: 0,
            startedAtMs: 0,
            label: '?',
            cwd: '',
          ),
    );
  }
  return out;
}

HeavyHolder? _holderInfo(Directory dir, int slot) {
  try {
    return HeavyHolder.fromJson(
      slot,
      jsonDecode(File('${dir.path}/slot-$slot.json').readAsStringSync()),
    );
  } on Object {
    return null;
  }
}

RandomAccessFile? _tryLock(File f) {
  final RandomAccessFile raf = f.openSync(mode: FileMode.append);
  try {
    raf.lockSync(FileLock.exclusive);
    return raf;
  } on FileSystemException {
    raf.closeSync();
    return null;
  }
}

Future<HeavyLease> _waitSlot(
  Directory dir,
  String label,
  Stopwatch sw,
  Duration? waitMax,
  void Function(String) say,
  _WorktreeLock? worktree, {
  required Map<String, String> env,
  required MemorySnapshot? Function() readMemory,
  required Duration poll,
}) async {
  String? lastReason;
  _Ticket? ticket;
  try {
    while (true) {
      // One admission at a time across the machine: two waiters must not both
      // read the same slot as free and race over its holder info, and a
      // ticket is created, locked and swept only under this gate.
      final RandomAccessFile gate = File(
        '${dir.path}/admission.lock',
      ).openSync(mode: FileMode.append);
      String reason;
      try {
        gate.lockSync(FileLock.blockingExclusive);
        ticket ??= _Ticket.take(dir, label);
        final (HeavyLease? lease, String blocker) = _admitHead(
          dir,
          ticket,
          label,
          sw,
          say,
          worktree,
          env: env,
          readMemory: readMemory,
        );
        if (lease != null) return lease;
        reason = blocker;
      } finally {
        gate.closeSync();
      }
      if (reason != lastReason) {
        say('heavy: waiting before $label -- $reason');
        lastReason = reason;
      }
      if (waitMax != null && sw.elapsed > waitMax) {
        throw HeavyLeaseTimeout(
          'heavy: $label not admitted after '
          '${sw.elapsed.inMinutes} min -- $reason. Not running it anyway.',
        );
      }
      await Future<void>.delayed(poll);
    }
  } finally {
    ticket?.release();
  }
}

/// Under the admission gate: the slot lease for [ticket] if it heads the
/// queue and a slot is free, else null and why not.
(HeavyLease?, String) _admitHead(
  Directory dir,
  _Ticket ticket,
  String label,
  Stopwatch sw,
  void Function(String) say,
  _WorktreeLock? worktree, {
  required Map<String, String> env,
  required MemorySnapshot? Function() readMemory,
}) {
  final List<HeavyQueued> queue = readHeavyQueue(dir);
  final int ahead = queue.indexWhere((HeavyQueued q) => q.name == ticket.name);
  if (ahead > 0) {
    return (
      null,
      'queued behind $ahead earlier run(s): '
          '${queue.take(ahead).map((HeavyQueued q) => q.label).join(', ')}',
    );
  }
  final MemorySnapshot? memory = readMemory();
  final int slots = heavySlotCount(memory, env);
  final List<HeavyHolder> holders = readHeavyHolders(dir, slots);
  final Set<int> busy = holders.map((HeavyHolder h) => h.slot).toSet();
  if (busy.length >= slots) {
    return (
      null,
      'all $slots slots busy: '
          '${holders.map((HeavyHolder h) => '${h.label} (pid ${h.pid})').join(', ')}',
    );
  }
  for (int i = 0; i < slots; i++) {
    if (busy.contains(i) || _heldInProcess.contains(i)) continue;
    final RandomAccessFile? lock = _tryLock(File('${dir.path}/slot-$i.lock'));
    if (lock == null) continue;
    _heldInProcess.add(i);
    final File info = File('${dir.path}/slot-$i.json');
    try {
      info.writeAsStringSync(
        jsonEncode(
          HeavyHolder(
            slot: i,
            pid: pid,
            startedAtMs: DateTime.now().millisecondsSinceEpoch,
            label: label,
            cwd: Directory.current.path,
          ).toJson(),
        ),
      );
    } on FileSystemException {
      // Diagnostics only, but do not keep a slot nobody will release.
      _heldInProcess.remove(i);
      lock.closeSync();
      rethrow;
    }
    if (sw.elapsed.inSeconds >= 5) {
      say('heavy: $label admitted to slot $i after ${sw.elapsed.inSeconds} s');
    }
    final HeavyLease lease = HeavyLease._(
      slot: i,
      skipReason: null,
      waited: sw.elapsed,
      slotLock: lock,
      worktreeLock: worktree,
      slotInfo: info,
    );
    return (lease, '');
  }
  return (null, 'slots changed while probing');
}

/// Ticket names this process holds (see [_heldInProcess] for why a process
/// must never probe its own lock).
final Set<String> _heldTickets = <String>{};
int _ticketSeq = 0;

/// A waiter's place in the machine-wide queue: `queue/<enqueued us>-<pid>-<n>`
/// (`.ticket` holds the lock, `.json` the label for --status). Names sort in
/// arrival order.
class _Ticket {
  _Ticket._(this.dir, this.name, this.lock);
  final Directory dir;
  final String name;
  final RandomAccessFile lock;

  static _Ticket take(Directory state, String label) {
    final Directory dir = Directory('${state.path}/queue')
      ..createSync(recursive: true);
    final String us = '${DateTime.now().microsecondsSinceEpoch}'.padLeft(
      20,
      '0',
    );
    final String name = '$us-$pid-${_ticketSeq++}';
    final RandomAccessFile? lock = _tryLock(File('${dir.path}/$name.ticket'));
    if (lock == null) {
      throw StateError('heavy: fresh queue ticket $name is already locked');
    }
    _heldTickets.add(name);
    File('${dir.path}/$name.json').writeAsStringSync(
      jsonEncode(<String, Object>{'pid': pid, 'label': label}),
    );
    return _Ticket._(dir, name, lock);
  }

  void release() {
    _heldTickets.remove(name);
    lock.closeSync();
    _deleteTicketFiles(dir, name);
  }
}

void _deleteTicketFiles(Directory dir, String name) {
  for (final String ext in <String>['ticket', 'json']) {
    try {
      File('${dir.path}/$name.$ext').deleteSync();
    } on FileSystemException {
      // Already gone, or (Windows) still closing: the next sweep retries.
    }
  }
}

/// One live waiter in the queue.
class HeavyQueued {
  const HeavyQueued({
    required this.name,
    required this.pid,
    required this.label,
  });
  final String name;
  final int pid;
  final String label;
}

/// The live queue, oldest first. Tickets whose lock nobody holds belong to
/// dead waiters: skipped, and deleted when [sweep] is set. Sweep only under
/// the admission gate -- outside it a ticket created but not yet locked would
/// look dead and be deleted under its owner (--status reads without sweeping).
List<HeavyQueued> readHeavyQueue(Directory state, {bool sweep = true}) {
  final Directory dir = Directory('${state.path}/queue');
  if (!dir.existsSync()) return <HeavyQueued>[];
  final List<String> names = <String>[
    for (final FileSystemEntity e in dir.listSync())
      if (e is File && e.path.endsWith('.ticket'))
        e.uri.pathSegments.last.replaceAll('.ticket', ''),
  ]..sort();
  final List<HeavyQueued> out = <HeavyQueued>[];
  for (final String name in names) {
    if (!_heldTickets.contains(name)) {
      final RandomAccessFile? probe = _tryLock(
        File('${dir.path}/$name.ticket'),
      );
      if (probe != null) {
        probe.closeSync();
        if (sweep) _deleteTicketFiles(dir, name);
        continue;
      }
    }
    out.add(_queuedInfo(dir, name));
  }
  return out;
}

HeavyQueued _queuedInfo(Directory dir, String name) {
  try {
    final Object? j = jsonDecode(
      File('${dir.path}/$name.json').readAsStringSync(),
    );
    if (j is Map<String, Object?>) {
      return HeavyQueued(
        name: name,
        pid: (j['pid'] as int?) ?? 0,
        label: (j['label'] as String?) ?? '?',
      );
    }
  } on Object {
    // Label not written yet or unreadable: the ticket still counts.
  }
  return HeavyQueued(name: name, pid: 0, label: '?');
}

// ---- Windows: memory status and the Job Object ---------------------------

final class _MemoryStatusEx extends Struct {
  @Uint32()
  external int dwLength;
  @Uint32()
  external int dwMemoryLoad;
  @Uint64()
  external int ullTotalPhys;
  @Uint64()
  external int ullAvailPhys;
  @Uint64()
  external int ullTotalPageFile;
  @Uint64()
  external int ullAvailPageFile;
  @Uint64()
  external int ullTotalVirtual;
  @Uint64()
  external int ullAvailVirtual;
  @Uint64()
  external int ullAvailExtendedVirtual;
}

DynamicLibrary? _kernel32Lib;
DynamicLibrary get _kernel32 =>
    _kernel32Lib ??= DynamicLibrary.open('kernel32.dll');

MemorySnapshot? _windowsMemory() {
  final int Function(Pointer<_MemoryStatusEx>) globalMemoryStatusEx =
      _kernel32.lookupFunction<Int32 Function(Pointer<_MemoryStatusEx>),
          int Function(Pointer<_MemoryStatusEx>)>('GlobalMemoryStatusEx');
  final Pointer<_MemoryStatusEx> p = calloc<_MemoryStatusEx>();
  try {
    p.ref.dwLength = sizeOf<_MemoryStatusEx>();
    if (globalMemoryStatusEx(p) == 0) return null;
    const int mb = 1024 * 1024;
    return MemorySnapshot(
      totalPhysMb: p.ref.ullTotalPhys ~/ mb,
      availPhysMb: p.ref.ullAvailPhys ~/ mb,
      // ullTotalPageFile / ullAvailPageFile are the commit limit / what is
      // left of it, despite the names.
      availCommitMb: p.ref.ullAvailPageFile ~/ mb,
    );
  } finally {
    calloc.free(p);
  }
}

// JOBOBJECT_EXTENDED_LIMIT_INFORMATION (x64): BasicLimitInformation is 64
// bytes (LimitFlags at 16, PriorityClass at 56), IoInfo 48, then
// ProcessMemoryLimit 112, JobMemoryLimit 120, PeakProcessMemoryUsed 128,
// PeakJobMemoryUsed 136; 144 in all.
const int _kExtendedLimitInformation = 9;
const int _kExtendedLimitSize = 144;
const int _kLimitPriorityClass = 0x20;
const int _kLimitJobMemory = 0x200;
const int _kLimitKillOnJobClose = 0x2000;
const int _kBelowNormalPriorityClass = 0x4000;

/// LimitFlags of the [joinHeavyJob] job: below-normal priority and
/// kill-on-close always, the job-wide memory ceiling only with [memoryCap].
int heavyJobLimitFlags({required bool memoryCap}) =>
    _kLimitPriorityClass |
    _kLimitKillOnJobClose |
    (memoryCap ? _kLimitJobMemory : 0);

/// This process's throttling Job Object (Windows x64), joined with
/// [joinHeavyJob]; every process started afterwards is inside it.
class HeavyJob {
  HeavyJob._(this._handle, this.capMb);

  final int _handle;

  /// The tree's memory ceiling in MB; null when the job has none.
  final int? capMb;

  /// Peak committed memory of the whole tree so far, in MB.
  int? peakMb() {
    final Pointer<Uint8> info = calloc<Uint8>(_kExtendedLimitSize);
    try {
      final int ok = _queryJob(
        _handle,
        _kExtendedLimitInformation,
        info.cast(),
        _kExtendedLimitSize,
        nullptr,
      );
      if (ok == 0) return null;
      return info.cast<Uint64>()[136 ~/ 8] ~/ (1024 * 1024);
    } finally {
      calloc.free(info);
    }
  }
}

final int Function(Pointer<Void>, Pointer<Utf16>) _createJob =
    _kernel32.lookupFunction<IntPtr Function(Pointer<Void>, Pointer<Utf16>),
        int Function(Pointer<Void>, Pointer<Utf16>)>('CreateJobObjectW');
final int Function(int, int, Pointer<Void>, int) _setJob =
    _kernel32.lookupFunction<
        Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32),
        int Function(int, int, Pointer<Void>, int)>('SetInformationJobObject');
final int Function(int, int, Pointer<Void>, int, Pointer<Uint32>) _queryJob =
    _kernel32.lookupFunction<
        Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32, Pointer<Uint32>),
        int Function(int, int, Pointer<Void>, int,
            Pointer<Uint32>)>('QueryInformationJobObject');
final int Function(int, int) _assignJob = _kernel32
    .lookupFunction<Int32 Function(IntPtr, IntPtr), int Function(int, int)>(
  'AssignProcessToJobObject',
);
final int Function() _currentProcess = _kernel32
    .lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');

/// Puts this process (and so everything it starts from now on) into a job
/// with below-normal priority, a [capMb] memory ceiling for the whole tree
/// (none when [capMb] is null), and kill-on-close. Null where unsupported
/// (non-Windows, 32-bit, CI, or the OS refused); the run then proceeds
/// unthrottled and [log] says so.
HeavyJob? joinHeavyJob(int? capMb, {void Function(String line)? log}) {
  if (!Platform.isWindows || sizeOf<IntPtr>() != 8) return null;
  // CI and FUSHI_HEAVY=off mean "no throttling at all". (Nested holders do
  // join: their own job sits inside the parent's.)
  final String? skip = heavyLeaseSkipReason(Platform.environment);
  if (skip == 'CI' || skip == 'FUSHI_HEAVY=off') return null;
  final int job = _createJob(nullptr, nullptr);
  if (job == 0) {
    log?.call('heavy: CreateJobObject failed; running unthrottled');
    return null;
  }
  final Pointer<Uint8> info = calloc<Uint8>(_kExtendedLimitSize);
  try {
    info.cast<Uint32>()[16 ~/ 4] = heavyJobLimitFlags(memoryCap: capMb != null);
    info.cast<Uint32>()[56 ~/ 4] = _kBelowNormalPriorityClass;
    if (capMb != null) info.cast<Uint64>()[120 ~/ 8] = capMb * 1024 * 1024;
    if (_setJob(
              job,
              _kExtendedLimitInformation,
              info.cast(),
              _kExtendedLimitSize,
            ) ==
            0 ||
        _assignJob(job, _currentProcess()) == 0) {
      log?.call('heavy: could not join a Job Object; running unthrottled');
      return null;
    }
  } finally {
    calloc.free(info);
  }
  // The handle stays open for the life of this process: closing it (here, or
  // by exiting) kills whatever the run left behind.
  return HeavyJob._(job, capMb);
}
