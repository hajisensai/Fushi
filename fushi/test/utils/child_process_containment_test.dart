import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/mihon_child_process_containment.dart'
    show MihonChildProcessContainment;
import 'package:fushi/src/utils/misc/child_process_containment.dart';
import 'package:path/path.dart' as p;

Future<void> _waitForFile(File file) async {
  final Stopwatch elapsed = Stopwatch()..start();
  while (!await file.exists()) {
    if (elapsed.elapsed > const Duration(seconds: 15)) {
      throw TimeoutException('Contained fixture did not become ready');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test('empty containment and legacy factory remain idempotent', () async {
    final ChildProcessContainment containment =
        MihonChildProcessContainment.platform();
    await containment.terminateAndWait();
    containment.close();
    await containment.terminateAndWait();
    containment.close();
    expect(
      () => ChildProcessContainment.platform(
        terminationTimeout: const Duration(seconds: -1),
      ),
      throwsArgumentError,
    );
  });

  test(
    'Windows drain releases descendant file locks without touching another job',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'fushi-containment-test-',
      );
      final ChildProcessContainment containment =
          ChildProcessContainment.platform();
      final ChildProcessContainment unrelatedContainment =
          ChildProcessContainment.platform();
      final List<Process> processes = <Process>[];
      addTearDown(() async {
        containment.close();
        unrelatedContainment.close();
        for (final Process process in processes) {
          process.kill();
          await process.exitCode.timeout(const Duration(seconds: 5));
        }
        await temp.delete(recursive: true);
      });

      final File worker = File(p.join(temp.path, 'worker.ps1'));
      await worker.writeAsString(r'''
param([string]$LockPath, [string]$ReadyPath)
$ErrorActionPreference = 'Stop'
$stream = [IO.File]::Open($LockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
  [IO.File]::WriteAllText($ReadyPath, [string]$PID)
  [Threading.Thread]::Sleep([Threading.Timeout]::Infinite)
} finally { $stream.Dispose() }
''');
      final File launcher = File(p.join(temp.path, 'launcher.ps1'));
      await launcher.writeAsString(r'''
param([string]$Worker, [string]$LockPath, [string]$ReadyPath)
$ErrorActionPreference = 'Stop'
$null = [Console]::ReadLine()
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Worker -LockPath $LockPath -ReadyPath $ReadyPath
exit $LASTEXITCODE
''');

      Future<Process> launchTree(
        ChildProcessContainment owner,
        File lock,
        File ready,
      ) async {
        final Process process = await Process.start('powershell.exe', <String>[
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          launcher.path,
          '-Worker',
          worker.path,
          '-LockPath',
          lock.path,
          '-ReadyPath',
          ready.path,
        ]);
        processes.add(process);
        unawaited(process.stdout.drain<void>());
        unawaited(process.stderr.drain<void>());
        owner.attach(process.pid);
        process.stdin.writeln('attached');
        await process.stdin.flush();
        await _waitForFile(ready);
        return process;
      }

      final File targetLock = File(p.join(temp.path, 'target.lock'));
      final File targetReady = File(p.join(temp.path, 'target.ready'));
      final Process parent = await launchTree(
        containment,
        targetLock,
        targetReady,
      );
      final File unrelatedLock = File(p.join(temp.path, 'unrelated.lock'));
      final File unrelatedReady = File(p.join(temp.path, 'unrelated.ready'));
      final Process unrelated = await launchTree(
        unrelatedContainment,
        unrelatedLock,
        unrelatedReady,
      );
      bool unrelatedExited = false;
      unawaited(
        unrelated.exitCode.then<void>((int _) {
          unrelatedExited = true;
        }),
      );
      // The locked file belongs to a descendant, not the directly attached PID.
      expect(int.parse(await targetReady.readAsString()), isNot(parent.pid));
      expect(
        () => targetLock.openSync(mode: FileMode.write),
        throwsA(isA<FileSystemException>()),
      );

      await containment.terminateAndWait();
      await parent.exitCode.timeout(const Duration(seconds: 2));
      final RandomAccessFile released = await targetLock.open(
        mode: FileMode.write,
      );
      await released.close();
      expect(unrelatedExited, isFalse);
      expect(
        () => unrelatedLock.openSync(mode: FileMode.write),
        throwsA(isA<FileSystemException>()),
      );
      await unrelatedContainment.terminateAndWait();
      await containment.terminateAndWait();
    },
    skip: !Platform.isWindows,
  );
}
