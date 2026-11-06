// How a tool/dist_test.dart run ends early: Ctrl-C, its own `--max-minutes`
// deadline, or an internal error. Unit-tested (test/tools/dist_stop_test.dart).
//
// Killing dist_test from outside (taskkill /F, SIGKILL) cannot do what this
// does: the workers' remote runs (worker_run.sh / worker_build.sh /
// worker_analyze.sh) go on, their heartbeat keeps the checkout lock fresh, and
// the next run finds the machine busy for as long as the remote run takes (up
// to [kDistBuildTimeout]). So the deadline lives here, where the workers are
// known, and heavy.dart passes it on instead of killing dist_test.
import 'dart:async';
import 'dart:io';

import 'dist_workers.dart';

/// Ends the run once: abandons every registered worker's prepare, kills its
/// in-flight remote run ([DistWorker.cancel]: worker_kill.sh / the shim's
/// `kill`), releases its checkout or lease ([DistWorker.finish]) and exits.
class DistStopper {
  DistStopper({Never Function(int code)? exitWith}) : _exit = exitWith ?? exit;

  final Never Function(int code) _exit;
  final List<DistWorker> _workers = <DistWorker>[];
  String? _runId;
  final List<StreamSubscription<ProcessSignal>> _signals =
      <StreamSubscription<ProcessSignal>>[];
  Timer? _deadline;
  final Completer<Never> _never = Completer<Never>();

  /// A stop is under way: nothing new may start (no prepare, no batch).
  bool get requested => _requested;
  bool _requested = false;

  /// Workers whose remote work a stop has to end.
  void register(Iterable<DistWorker> workers) => _workers.addAll(workers);

  /// The run whose checkouts / leases a stop releases.
  set runId(String id) => _runId = id;

  /// Stops on Ctrl-C (130), SIGTERM (143, not on Windows) and, with a
  /// [deadline], once it has passed (124; dist_test `--max-minutes=N`).
  void watch({Duration? deadline}) {
    _signals.add(
      ProcessSignal.sigint.watch().listen(
        (_) => unawaited(stop(130, '\ninterrupted: stopping the workers')),
      ),
    );
    if (!Platform.isWindows) {
      _signals.add(
        ProcessSignal.sigterm.watch().listen(
          (_) => unawaited(stop(143, 'terminated: stopping the workers')),
        ),
      );
    }
    if (deadline != null) {
      _deadline = Timer(
        deadline,
        () => unawaited(
          stop(
            124,
            'dist_test: still running after ${deadline.inMinutes} min '
            '(--max-minutes); stopping the workers',
          ),
        ),
      );
    }
  }

  /// Never completes once a stop is under way ([stop] exits the process), so
  /// a scheduler loop that gets here starts nothing more.
  Future<void> holdIfStopping() async {
    if (_requested) await _never.future;
  }

  /// Ends the run with [code] after stopping every worker; a second call
  /// (the deadline during a Ctrl-C) waits on the first.
  Future<Never> stop(int code, String why) async {
    if (_requested) return _never.future;
    _requested = true;
    _deadline?.cancel();
    stderr.writeln(why);
    final List<DistWorker> all = List<DistWorker>.of(_workers);
    await Future.wait(<Future<void>>[
      for (final DistWorker w in all) w.abandon(),
    ]);
    await Future.wait(<Future<void>>[
      for (final DistWorker w in all) w.cancel(),
    ]);
    final String? runId = _runId;
    if (runId != null) {
      await Future.wait(<Future<void>>[
        for (final DistWorker w in all) w.finish(runId),
      ]);
    }
    await stdout.flush();
    _exit(code);
  }

  /// Lets a run that ended normally return from main (an open signal
  /// subscription or timer would keep the process alive).
  Future<void> dispose() async {
    _deadline?.cancel();
    for (final StreamSubscription<ProcessSignal> s in _signals) {
      await s.cancel();
    }
    _signals.clear();
  }
}
