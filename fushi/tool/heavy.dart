// Runs one heavy command under the machine-wide lease (test_flow/heavy_lease.dart):
//
//   dart run tool/heavy.dart [--wait-max-min=0] [--max-minutes=120]
//                            [--cap-mb=N] [--here] -- <command...>
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
// Before queueing here, a `flutter test` of test/ suites or a `flutter
// analyze` run from fushi/ goes to the other machines of the dist_test worker
// config (FUSHI_DIST_CONFIG, else tool/dist_test/workers.local.json) through
// tool/dist_test.dart (test_flow/heavy_offload.dart): its output and exit code
// are then dist_test's (`DIST TEST VERDICT` / `DIST ANALYZE` last lines). When
// no other machine takes it, it runs here as before. `--here` or
// FUSHI_HEAVY_OFFLOAD=off keep it here.
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

  if (!own.contains('--here')) {
    final int? remote = await _offload(command, maxMinutes: maxMinutes);
    if (remote != null) exit(remote);
  }

  final HeavyJob? job = joinHeavyJob(
    need.capMb,
    log: (String l) => stderr.writeln(l),
  );
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
Future<int?> _offload(List<String> command, {required int maxMinutes}) async {
  final Map<String, String> env = Platform.environment;
  if (heavyLeaseSkipReason(env) != null || heavyOffloadDisabled(env)) {
    return null;
  }
  final String appDir = Directory.current.absolute.path.replaceAll(r'\', '/');
  final HeavyOffload? plan = planHeavyOffload(
    command,
    inAppDir:
        File('$appDir/tool/dist_test.dart').existsSync() &&
        File('$appDir/pubspec.yaml').existsSync(),
    exists: (String p) =>
        FileSystemEntity.typeSync('$appDir/$p') !=
        FileSystemEntityType.notFound,
  );
  if (plan == null) return null;
  final String? config = heavyOffloadConfig(env, appDir);
  if (config == null) return null;
  stderr.writeln(
    'heavy: handing this ${plan.kind.name} to the other machines '
    '(tool/dist_test.dart ${plan.distArgs.join(' ')}); --here or '
    'FUSHI_HEAVY_OFFLOAD=off keeps it on this machine',
  );
  final Process p;
  try {
    p = await Process.start(
      Platform.resolvedExecutable,
      <String>['tool/dist_test.dart', '--config=$config', ...plan.distArgs],
      workingDirectory: appDir,
      mode: ProcessStartMode.inheritStdio,
    );
  } on ProcessException catch (e) {
    stderr.writeln(
      'heavy: cannot start dist_test (${e.message}); running here',
    );
    return null;
  }
  bool cut = false;
  final Timer? limit = maxMinutes <= 0
      ? null
      : Timer(Duration(minutes: maxMinutes), () {
          cut = true;
          stderr.writeln(
            'heavy: offloaded run still going after $maxMinutes min; '
            'killing it',
          );
          _killTree(p);
        });
  final int code = await p.exitCode;
  limit?.cancel();
  if (cut) return 124;
  if (code == kDistOffloadDeclined) {
    stderr.writeln('heavy: no other machine took it; running it here');
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
