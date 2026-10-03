// Runs one heavy command under the machine-wide lease (test_flow/heavy_lease.dart):
//
//   dart run tool/heavy.dart [--wait-max-min=0] [--max-minutes=120]
//                            [--cap-mb=N] -- <command...>
//   dart run tool/heavy.dart --status
//
//   e.g. dart run tool/heavy.dart -- flutter test test/foo_test.dart --no-pub
//        dart run tool/heavy.dart -- flutter analyze --no-pub
//        dart run tool/heavy.dart -- .\gradlew.bat :app:assembleRelease
//
// It queues first come, first served for a free slot (it never "runs anyway",
// there is no memory admission, and unless --wait-max-min=N is given it never
// gives up waiting), keeps one build/-writing run per worktree, and on Windows runs the command
// tree at below-normal priority under a memory ceiling, killing whatever the
// command leaves behind when it ends. Exit code: the command's; 75 when an
// explicit --wait-max-min ran out before admission; 124 when --max-minutes cut it off. CI / FUSHI_HEAVY=off
// run the command directly.
import 'dart:async';
import 'dart:io';

import 'test_flow/heavy_budget.dart';
import 'test_flow/heavy_lease.dart';

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
  final List<String> command = args.sublist(sep + 1);
  final HeavyNeed classified = classifyHeavyCommand(command);
  final HeavyNeed need = HeavyNeed(
    kind: classified.kind,
    capMb: _intArg(own, '--cap-mb=') ?? classified.capMb,
    worktreeExclusive: classified.worktreeExclusive,
  );
  final int waitMax = _intArg(own, '--wait-max-min=') ?? 0;
  final int maxMinutes = _intArg(own, '--max-minutes=') ?? 120;
  final String label = command.take(3).join(' ');

  final HeavyJob? job = joinHeavyJob(
    need.capMb,
    log: (String l) => stderr.writeln(l),
  );
  final HeavyLease lease;
  try {
    lease = await acquireHeavyLease(
      need: need,
      label: label,
      worktreeRoot: locateCheckoutRoot(),
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
  stdout.writeln('heavy: ${holders.length}/$slots slots busy (${dir.path})');
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
      '  slot ${h.slot}: pid ${h.pid}, ${h.label}, '
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
