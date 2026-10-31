// Runs one heavy command under the machine-wide lease (test_flow/heavy_lease.dart):
//
//   dart run tool/heavy.dart [--wait-max-min=0] [--max-minutes=120]
//                            [--cap-mb=N] [--here] [--check-only]
//                            -- <command...>
//   dart run tool/heavy.dart --status
//
//   e.g. dart run tool/heavy.dart -- flutter test test/foo_test.dart --no-pub
//        dart run tool/heavy.dart -- flutter analyze --no-pub
//        dart run tool/heavy.dart -- .\gradlew.bat :app:assembleRelease
//
// It queues first come, first served for a free slot whose run's memory
// ceiling fits the budget next to the holders' (half the RAM; it never "runs
// anyway", never reads the live free memory, and unless --wait-max-min=N is
// given it never gives up waiting), keeps one build/-writing run per worktree, gives a
// `flutter test` without its own --concurrency a default of 4, and on
// Windows runs the command
// tree at below-normal priority under a memory ceiling, killing whatever the
// command leaves behind when it ends. A bare flutter / dart is resolved like
// the other repo tools (FUSHI_FLUTTER, FLUTTER_ROOT, the SDK running this
// script, PATH) and refused before queueing when that SDK is not the
// fushi/.fvmrc version (test_flow/heavy_sdk_check.dart). Exit code: the
// command's; 2 for a mismatched SDK; 75 when an
// explicit --wait-max-min ran out before admission; 124 when --max-minutes cut it off. CI / FUSHI_HEAVY=off
// run the command directly.
//
// Before queueing here, the work goes to the other machines of the dist_test
// worker config (FUSHI_DIST_CONFIG, else fushi/tool/dist_test/
// workers.local.json) through tool/dist_test.dart when it may
// (test_flow/heavy_offload.dart): a `flutter test` (also `--coverage`, merged
// back here) of the app from fushi/, a `flutter test` / `dart test` of a
// package from packages/<name>/, a `flutter analyze` from fushi/, and with
// --check-only a compile check (`flutter build apk|appbundle|windows|macos`
// from fushi/, `gradlew :app:assemble*` from fushi/android/) whose output is
// not wanted here. Its output and exit code are then dist_test's (`DIST TEST
// VERDICT` / `DIST ANALYZE` / `DIST BUILD` last lines). When no other machine
// takes it, it runs here as before; a compile check that was red elsewhere is
// built here once more, since that machine's toolchain may be the cause.
// `--here` or FUSHI_HEAVY_OFFLOAD=off keep it here.
import 'dart:async';
import 'dart:io';

import 'test_flow/dist_plan.dart' show kDistOffloadDeclined;
import 'test_flow/heavy_budget.dart';
import 'test_flow/heavy_lease.dart';
import 'test_flow/heavy_offload.dart';
import 'test_flow/heavy_sdk_check.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--status')) return _status();
  final int sep = args.indexOf('--');
  if (sep < 0 || sep == args.length - 1) {
    stderr.writeln(
      'usage: dart run tool/heavy.dart [options] -- <command...>\n'
      '       dart run tool/heavy.dart --status',
    );
    exit(64);
  }
  final List<String> own = args.sublist(0, sep);
  final String? checkout = locateCheckoutRoot();
  final HeavySdkCheck sdk = checkHeavyCommandSdk(
    args.sublist(sep + 1),
    pinned: checkout == null ? null : readPinnedFlutterVersion(checkout),
  );
  if (sdk.error != null) {
    stderr.writeln(sdk.error);
    exit(2);
  }
  final List<String> command = withDefaultTestConcurrency(sdk.command);
  final HeavyNeed classified = classifyHeavyCommand(command);
  final int? capOverride = _intArg(own, '--cap-mb=');
  final HeavyNeed need = HeavyNeed(
    kind: classified.kind,
    capMb: capOverride ?? classified.capMb,
    // An explicit --cap-mb books what it asks for.
    bookMb: capOverride ?? classified.bookMb,
    worktreeExclusive: classified.worktreeExclusive,
    light: classified.light,
  );
  final int waitMax = _intArg(own, '--wait-max-min=') ?? 0;
  final int maxMinutes = _intArg(own, '--max-minutes=') ?? 120;
  final String label = command.take(3).join(' ');

  // Joined before anything starts: the offloaded run (dist_test and its own
  // local fallback worker) and a run here after it declined both live in this
  // Job (below-normal priority, memory ceiling, whatever is left killed when
  // this process ends), as a run that never tried the other machines would.
  final HeavyJob? job = joinHeavyJob(
    need.capMb,
    log: (String l) => stderr.writeln(l),
  );

  if (!own.contains('--here') && checkout != null) {
    // Planned from the command as typed: the default --concurrency above is
    // this machine's, while an explicit -j caps the other machines too.
    final int? remote = await _offload(
      sdk.command,
      checkout: checkout,
      checkOnly: own.contains('--check-only'),
      maxMinutes: maxMinutes,
    );
    if (remote != null) exit(remote);
  }

  final HeavyLease lease;
  try {
    lease = await acquireHeavyLease(
      need: need,
      label: label,
      worktreeRoot: checkout,
      waitMax: waitMax > 0 ? Duration(minutes: waitMax) : null,
    );
  } on HeavyLeaseTimeout catch (e) {
    stderr.writeln(e.message);
    exit(75);
  }

  final Stopwatch ran = Stopwatch()..start();
  final Process p;
  try {
    p = await Process.start(
      command.first,
      command.skip(1).toList(),
      runInShell: Platform.isWindows,
      mode: ProcessStartMode.inheritStdio,
      environment: lease.childEnvironment,
    );
  } on ProcessException catch (e) {
    lease.release();
    stderr.writeln('heavy: cannot start ${command.first}: ${e.message}');
    exit(127);
  }
  bool cut = false;
  final Timer? limit = maxMinutes <= 0
      ? null
      : Timer(Duration(minutes: maxMinutes), () {
          cut = true;
          stderr.writeln(
            'heavy: $label still running after $maxMinutes min; '
            'killing it',
          );
          _killTree(p);
        });
  final int code = await p.exitCode;
  limit?.cancel();
  ran.stop();
  lease.release();

  final int? peak = job?.peakMb();
  stderr.writeln(
    'heavy: $label -> exit $code'
    '${lease.skipReason != null ? ' (no lease: ${lease.skipReason})' : ', slot ${lease.slot}'}'
    ', waited ${lease.waited.inSeconds} s, ran ${ran.elapsed.inSeconds} s'
    '${peak != null ? ', peak $peak MB of ${need.capMb} MB cap' : ''}',
  );
  if (peak != null && heavyCapHit(peak, need.capMb)) {
    stderr.writeln(
      'heavy: MEMORY CAP HIT -- failures in this run can come '
      'from the ${need.capMb} MB ceiling, not from the code. Narrow the run '
      '(fewer files, lower --concurrency) or raise --cap-mb.',
    );
  }
  exit(cut ? 124 : code);
}

/// Runs [command] on the other machines through tool/dist_test.dart when it
/// may go there (test_flow/heavy_offload.dart); its exit code, or null when
/// it is to run here (not offloadable, no worker config, or no other machine
/// took it).
Future<int?> _offload(
  List<String> command, {
  required String checkout,
  required bool checkOnly,
  required int maxMinutes,
}) async {
  final Map<String, String> env = Platform.environment;
  if (heavyLeaseSkipReason(env) != null || heavyOffloadDisabled(env)) {
    return null;
  }
  final String cwd = Directory.current.absolute.path.replaceAll(r'\', '/');
  final String? where = heavyOffloadWhere(cwd, checkout);
  final String appDir =
      '${Directory(checkout).absolute.path.replaceAll(r'\', '/')}/fushi';
  if (where == null || !File('$appDir/tool/dist_test.dart').existsSync()) {
    return null;
  }
  final HeavyOffload? plan = planHeavyOffload(
    command,
    where: where,
    cwd: cwd,
    checkOnly: checkOnly,
    exists: (String p) =>
        FileSystemEntity.typeSync('$cwd/$p') != FileSystemEntityType.notFound,
  );
  if (plan == null) return null;
  final String? config = heavyOffloadConfig(env, appDir);
  if (config == null) {
    final String? named = env['FUSHI_DIST_CONFIG'];
    if (named != null && named.isNotEmpty) {
      stderr.writeln(
        'heavy: FUSHI_DIST_CONFIG=$named does not exist; running it here',
      );
    }
    return null;
  }
  stderr.writeln(
    'heavy: handing this ${plan.kind.name} to the other machines '
    '(tool/dist_test.dart ${plan.distArgs.join(' ')}); --here or '
    'FUSHI_HEAVY_OFFLOAD=off keeps it on this machine',
  );
  final Process p;
  try {
    p = await Process.start(
      Platform.resolvedExecutable,
      <String>[
        'tool/dist_test.dart',
        '--config=$config',
        // dist_test keeps the deadline itself: it kills the remote run and
        // releases the worker's checkout before exiting 124.
        if (maxMinutes > 0) '--max-minutes=$maxMinutes',
        ...plan.distArgs,
      ],
      workingDirectory: appDir,
      mode: ProcessStartMode.inheritStdio,
    );
  } on ProcessException catch (e) {
    stderr.writeln(
      'heavy: cannot start dist_test (${e.message}); running here',
    );
    return null;
  }
  // Ctrl-C reaches dist_test too (same console / process group): it kills
  // the remote run and releases the worker before it exits, and this process
  // waits for that instead of dying first and leaving it half done.
  bool interrupted = false;
  final List<StreamSubscription<ProcessSignal>> signals =
      <StreamSubscription<ProcessSignal>>[
        ProcessSignal.sigint.watch().listen((_) {
          interrupted = true;
          if (!Platform.isWindows) p.kill(ProcessSignal.sigint);
        }),
        if (!Platform.isWindows)
          ProcessSignal.sigterm.watch().listen((_) {
            interrupted = true;
            p.kill(ProcessSignal.sigint);
          }),
      ];
  // Only a backstop for a dist_test that does not stop by itself at
  // --max-minutes (its own deadline cleans up; this kill cannot).
  bool cut = false;
  final Timer? limit = maxMinutes <= 0
      ? null
      : Timer(Duration(minutes: maxMinutes) + kHeavyOffloadStopGrace, () {
          cut = true;
          stderr.writeln(
            'heavy: offloaded run did not stop by itself '
            '${kHeavyOffloadStopGrace.inMinutes} min after its '
            '$maxMinutes min limit; killing it (the remote run may go on '
            'until its own timeout)',
          );
          _killTree(p);
        });
  final int code = await p.exitCode;
  limit?.cancel();
  for (final StreamSubscription<ProcessSignal> s in signals) {
    await s.cancel();
  }
  if (cut) return 124;
  if (interrupted) return 130;
  // Over its time limit there: as over it here, never run once more.
  if (code == 124) return 124;
  if (code == kDistOffloadDeclined) {
    stderr.writeln(
      'heavy: dist_test did not run it elsewhere (the DIST OFFLOAD line '
      'above says why); running it here',
    );
    return null;
  }
  if (plan.kind == HeavyOffloadKind.build && code != 0) {
    // Another machine's SDK / NDK / Visual Studio is not this one's: a red
    // compile check there is only taken as red once it is red here.
    stderr.writeln(
      'heavy: the compile check was red on another machine (exit $code); '
      'building here to tell the code from that machine\'s toolchain',
    );
    return null;
  }
  return code;
}

void _killTree(Process p) {
  if (Platform.isWindows) {
    Process.runSync('taskkill', <String>['/PID', '${p.pid}', '/T', '/F']);
  } else {
    p.kill(ProcessSignal.sigkill);
  }
}

void _status() {
  final MemorySnapshot? m = readMemorySnapshot();
  final int slots = heavySlotCount(m);
  final Directory dir = heavyStateDir()..createSync(recursive: true);
  final List<HeavyHolder> holders = readHeavyHolders(dir, slots);
  final int ours = holders.where((HeavyHolder h) => h.slot < slots).length;
  final int light = holders
      .where(
        (HeavyHolder h) =>
            h.slot >= kLightSlotBase &&
            h.slot < kLightSlotBase + kLightSlotCount,
      )
      .length;
  final int beyond = holders.length - ours - light;
  stdout.writeln(
    'heavy: $ours/$slots slots busy, $light/$kLightSlotCount light (analyze)'
    '${beyond > 0 ? ' (+$beyond past this slot count, booked below)' : ''}'
    ' (${dir.path})',
  );
  final int? budget = heavyBudgetMb(m);
  if (budget != null) {
    final int booked = holders.fold(
      0,
      (int a, HeavyHolder h) => a + h.bookedMb,
    );
    stdout.writeln('  memory budget: $booked / $budget MB booked');
  }
  if (m != null) {
    stdout.writeln(
      '  RAM available ${m.availPhysMb} / ${m.totalPhysMb} MB'
      '${m.availCommitMb != null ? '; commit headroom ${m.availCommitMb} MB' : ''}',
    );
  }
  final int now = DateTime.now().millisecondsSinceEpoch;
  final List<HeavyQueued> queue = readHeavyQueue(dir, sweep: false);
  stdout.writeln('  queue: ${queue.length} waiting');
  for (int i = 0; i < queue.length; i++) {
    stdout.writeln('    ${i + 1}. pid ${queue[i].pid}, ${queue[i].label}');
  }
  for (final HeavyHolder h in holders) {
    stdout.writeln(
      '  slot ${h.slot}: pid ${h.pid}, ${h.label}, ${h.bookedMb} MB, '
      '${((now - h.startedAtMs) / 60000).toStringAsFixed(1)} min, '
      '${h.cwd}',
    );
  }
}

int? _intArg(List<String> args, String prefix) {
  for (final String a in args) {
    if (a.startsWith(prefix)) return int.tryParse(a.substring(prefix.length));
  }
  return null;
}
