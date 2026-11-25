import 'package:test/test.dart';

import '../../tool/test_flow/heavy_command_check.dart';

void main() {
  HeavyCommandCheck windows(
    List<String> command, {
    String cwd = r'D:\repo\fushi',
    Set<String> files = const <String>{},
    String path = r'C:\Windows\System32;D:\sdk\bin',
  }) => checkHeavyCommandStarts(
    command,
    cwd: cwd,
    environment: <String, String>{
      'PATH': path,
      'PATHEXT': '.COM;.EXE;.BAT;.CMD',
    },
    isWindows: true,
    fileExists: files.contains,
  );

  HeavyCommandCheck posix(
    List<String> command, {
    String cwd = '/repo/fushi',
    Set<String> files = const <String>{},
    String path = '/usr/bin:/opt/flutter/bin',
  }) => checkHeavyCommandStarts(
    command,
    cwd: cwd,
    environment: <String, String>{'PATH': path},
    isWindows: false,
    fileExists: files.contains,
  );

  group('a command with a directory in it', () {
    test('gradlew typed in the wrong directory is refused before queueing', () {
      final HeavyCommandCheck c = windows(<String>[
        r'.\gradlew.bat',
        ':app:assembleRelease',
      ]);
      expect(c.error, contains(r'cannot run .\gradlew.bat'));
      expect(c.error, contains(r'D:\repo\fushi'));
      expect(c.error, contains('Not queueing'));
    });

    test('found: the absolute native path is what gets started', () {
      final HeavyCommandCheck c = windows(
        <String>[r'.\gradlew.bat', ':app:assembleRelease'],
        cwd: r'D:\repo\fushi\android',
        files: <String>{r'D:\repo\fushi\android\gradlew.bat'},
      );
      expect(c.error, isNull);
      expect(c.executable, r'D:\repo\fushi\android\gradlew.bat');
    });

    test('./name on Windows: cmd.exe would run "."; the file is started', () {
      final HeavyCommandCheck c = windows(
        <String>['./gradlew.bat', ':app:testDebugUnitTest'],
        cwd: 'D:/repo/fushi/android',
        files: <String>{r'D:\repo\fushi\android\gradlew.bat'},
      );
      expect(c.error, isNull);
      expect(c.executable, r'D:\repo\fushi\android\gradlew.bat');
    });

    test('Windows appends a PATHEXT extension to a name without one', () {
      final HeavyCommandCheck c = windows(
        <String>[r'..\tool\run'],
        files: <String>{r'D:\repo\tool\run.cmd'},
      );
      expect(c.error, isNull);
      expect(c.executable, r'D:\repo\tool\run.cmd');
    });

    test('an absolute launcher path passes as it is', () {
      final HeavyCommandCheck c = windows(
        <String>[r'D:\sdk\bin\flutter.bat', 'test'],
        files: <String>{r'D:\sdk\bin\flutter.bat'},
      );
      expect(c.error, isNull);
      expect(c.executable, r'D:\sdk\bin\flutter.bat');
    });

    test('POSIX: relative path under the working directory', () {
      expect(
        posix(
          <String>['./gradlew', ':app:assembleRelease'],
          cwd: '/repo/fushi/android',
          files: <String>{'/repo/fushi/android/gradlew'},
        ).executable,
        '/repo/fushi/android/gradlew',
      );
      expect(posix(<String>['./gradlew']).error, contains('no such file'));
    });

    test('.. never climbs above the root', () {
      expect(
        posix(
          <String>['../../../../bin/tool'],
          files: <String>{'/bin/tool'},
        ).executable,
        '/bin/tool',
      );
    });
  });

  // HBK-AUDIT-047: the normalisation folded a UNC path's leading `\\` into
  // one `\`, so a script on an SMB share was looked for under the current
  // drive's root and refused before queueing although it exists.
  group('UNC paths keep their share root', () {
    test('an absolute UNC batch file with spaces passes as it is', () {
      final HeavyCommandCheck c = windows(
        <String>[r'\\nas\build share\tools\run build.bat', 'all'],
        files: <String>{r'\\nas\build share\tools\run build.bat'},
      );
      expect(c.error, isNull);
      expect(c.executable, r'\\nas\build share\tools\run build.bat');
    });

    test('forward-slash UNC gets native separators and a PATHEXT ext', () {
      final HeavyCommandCheck c = windows(
        <String>['//nas/build share/tools/run build'],
        files: <String>{r'\\nas\build share\tools\run build.cmd'},
      );
      expect(c.error, isNull);
      expect(c.executable, r'\\nas\build share\tools\run build.cmd');
    });

    test('relative to a working directory on a share', () {
      final HeavyCommandCheck c = windows(
        <String>[r'.\gradlew.bat', 'tasks'],
        cwd: r'\\nas\build share\repo\fushi\android',
        files: <String>{r'\\nas\build share\repo\fushi\android\gradlew.bat'},
      );
      expect(c.error, isNull);
      expect(c.executable, r'\\nas\build share\repo\fushi\android\gradlew.bat');
    });

    test('.. never climbs above the share root', () {
      final HeavyCommandCheck c = windows(
        <String>[r'..\..\..\..\..\..\run.bat'],
        cwd: r'\\nas\build share\repo\fushi',
        files: <String>{r'\\nas\build share\run.bat'},
      );
      expect(c.error, isNull);
      expect(c.executable, r'\\nas\build share\run.bat');
    });

    test('a bare name is found in a working directory on a share', () {
      final HeavyCommandCheck c = windows(
        <String>['gradlew.bat', 'tasks'],
        cwd: r'\\nas\build share\repo\fushi\android',
        files: <String>{r'\\nas\build share\repo\fushi\android\gradlew.bat'},
      );
      expect(c.error, isNull);
      expect(c.executable, 'gradlew.bat');
    });

    test('a root-relative path stays on the working directory share', () {
      final HeavyCommandCheck c = windows(
        <String>[r'\tools\run.bat'],
        cwd: r'\\nas\build share\repo\fushi',
        files: <String>{r'\\nas\build share\tools\run.bat'},
      );
      expect(c.error, isNull);
      expect(c.executable, r'\\nas\build share\tools\run.bat');
    });

    test('a missing UNC script is still refused', () {
      final HeavyCommandCheck c = windows(<String>[
        r'\\nas\build share\tools\gone.bat',
      ]);
      expect(c.error, contains('no such file'));
    });
  });

  group('a bare name', () {
    test('found on PATH: left for the shell to resolve', () {
      final HeavyCommandCheck c = windows(
        <String>['powershell', '-NoProfile'],
        files: <String>{r'C:\Windows\System32\powershell.exe'},
      );
      expect(c.error, isNull);
      expect(c.executable, 'powershell');
    });

    test('Windows finds it in the working directory first', () {
      final HeavyCommandCheck c = windows(
        <String>['gradlew.bat', 'tasks'],
        cwd: r'D:\repo\fushi\android',
        files: <String>{r'D:\repo\fushi\android\gradlew.bat'},
      );
      expect(c.error, isNull);
      expect(c.executable, 'gradlew.bat');
    });

    test('POSIX does not look in the working directory', () {
      expect(
        posix(
          <String>['gradlew'],
          files: <String>{'/repo/fushi/gradlew'},
        ).error,
        contains('not found'),
      );
    });

    test('nowhere: refused before queueing', () {
      final HeavyCommandCheck c = windows(<String>['gradlew.bat', 'tasks']);
      expect(c.error, contains('cannot run gradlew.bat'));
      expect(c.error, contains('Not queueing'));
    });

    test('a cmd.exe builtin has no file and still runs', () {
      expect(windows(<String>['echo', 'hi']).error, isNull);
      expect(posix(<String>['echo', 'hi']).error, contains('not found'));
    });
  });

  test('an empty command is an error', () {
    expect(windows(<String>[]).error, isNotNull);
  });
}
