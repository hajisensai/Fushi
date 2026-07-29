import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_child_process_containment.dart';

void main() {
  test('macOS sidecar launches in an independent process group', () {
    final String runtime = File(
      'lib/src/media/manga/mihon/desktop_mihon_runtime.dart',
    ).readAsStringSync();
    final String containment = File(
      'lib/src/media/manga/mihon/mihon_child_process_containment.dart',
    ).readAsStringSync();

    expect(runtime, contains('_processContainment.start('));
    expect(containment, contains('ProcessStartMode.detachedWithStdio'));
    expect(containment, contains('_MacOsProcessGroupContainment'));
  });

  test('macOS shutdown is TERM then bounded wait then KILL', () {
    final String source = File(
      'lib/src/media/manga/mihon/mihon_child_process_containment.dart',
    ).readAsStringSync();
    final int controllerStart =
        source.indexOf('class MihonPosixProcessGroupController');
    final int controllerEnd =
        source.indexOf('class _MacOsProcessGroupContainment');
    final String containment = source.substring(controllerStart, controllerEnd);

    final int term = containment.indexOf('ProcessSignal.sigterm');
    final int wait = containment.indexOf('_waitForProcessGroupExit');
    final int kill = containment.indexOf('ProcessSignal.sigkill');
    expect(term, greaterThanOrEqualTo(0));
    expect(wait, greaterThan(term));
    expect(kill, greaterThan(wait));
    expect(containment, contains('if (!await _processGroupExists'));
  });

  test('POSIX group fast-exit closes on its first liveness probe', () async {
    final List<(int, ProcessSignal?)> calls = <(int, ProcessSignal?)>[];
    final MihonPosixProcessGroupController controller =
        MihonPosixProcessGroupController(
      signalGroup: (int processGroupId, ProcessSignal? signal) {
        calls.add((processGroupId, signal));
        return MihonPosixSignalResult.noSuchProcess;
      },
    );

    await controller.terminate(41);

    expect(calls, <(int, ProcessSignal?)>[(41, null)]);
  });

  test('POSIX hung group is TERM, bounded poll, KILL, final ESRCH', () async {
    final List<(int, ProcessSignal?)> calls = <(int, ProcessSignal?)>[];
    bool killed = false;
    final MihonPosixProcessGroupController controller =
        MihonPosixProcessGroupController(
      signalGroup: (int processGroupId, ProcessSignal? signal) {
        calls.add((processGroupId, signal));
        if (signal == ProcessSignal.sigkill) killed = true;
        return signal == null && killed
            ? MihonPosixSignalResult.noSuchProcess
            : MihonPosixSignalResult.delivered;
      },
      termWait: Duration.zero,
      killWait: Duration.zero,
      pollInterval: Duration.zero,
    );

    await controller.terminate(42);

    expect(
      calls,
      <(int, ProcessSignal?)>[
        (42, null),
        (42, ProcessSignal.sigterm),
        (42, null),
        (42, ProcessSignal.sigkill),
        (42, null),
      ],
    );
  });

  test('POSIX group EPERM is never treated as exited or delivered', () async {
    final MihonPosixProcessGroupController controller =
        MihonPosixProcessGroupController(
      signalGroup: (int processGroupId, ProcessSignal? signal) =>
          MihonPosixSignalResult.permissionDenied,
    );

    await expectLater(controller.terminate(43), throwsStateError);
  });

  test('macOS parent identity mismatch kills only the owned group', () {
    final String containment = File(
      'lib/src/media/manga/mihon/mihon_child_process_containment.dart',
    ).readAsStringSync();

    expect(
      containment,
      contains(r'[ "$current_identity" != "$parent_identity" ]'),
    );
    expect(containment, contains(r'kill -TERM -- "-$$"'));
    expect(containment, isNot(contains(r'kill -TERM "$parent_pid"')));
    expect(containment, contains('trap shutdown_group EXIT HUP INT TERM'));
    expect(containment, contains('actualProcessGroupId != process.pid'));
  });

  test(
    'Windows containment terminates only its exact child when closed',
    () async {
      final Process child = await Process.start(
        'powershell.exe',
        <String>[
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          'Start-Sleep -Seconds 30',
        ],
      );
      final MihonChildProcessContainment containment =
          MihonChildProcessContainment.platform();
      addTearDown(() async {
        await containment.close();
        child.kill();
        try {
          await child.exitCode.timeout(const Duration(seconds: 2));
        } on TimeoutException {
          // The assertion below reports a failed containment more clearly.
        }
      });

      containment.attach(child.pid);
      await containment.close();

      await child.exitCode.timeout(const Duration(seconds: 2));
    },
    skip: !Platform.isWindows,
  );
}
