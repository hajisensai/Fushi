import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/port_process_terminator.dart';

void main() {
  group('parseNetstatListenerPid', () {
    const String netstatOutput = '''
Active Connections

  Proto  Local Address          Foreign Address        State           PID
  TCP    0.0.0.0:135            0.0.0.0:0              LISTENING       1234
  TCP    0.0.0.0:19633          0.0.0.0:0              LISTENING       188544
  TCP    127.0.0.1:19633        127.0.0.1:52001        ESTABLISHED     188544
  TCP    127.0.0.1:52001        127.0.0.1:19633        TIME_WAIT       0
  TCP    [::]:19633             [::]:0                 LISTENING       188544
''';

    test('resolves LISTENING pid on the target port', () {
      expect(parseNetstatListenerPid(netstatOutput, 19633), 188544);
    });

    test('ignores other ports and non-LISTEN states', () {
      expect(parseNetstatListenerPid(netstatOutput, 52001), isNull);
      expect(parseNetstatListenerPid(netstatOutput, 135), 1234);
    });

    test('does not match ports that merely share a suffix', () {
      // 9633 是 19633 的后缀：`:9633` 不能匹配到 `:19633` 的行。
      expect(parseNetstatListenerPid(netstatOutput, 9633), isNull);
    });

    test('returns null on empty or malformed output', () {
      expect(parseNetstatListenerPid('', 19633), isNull);
      expect(parseNetstatListenerPid('garbage output', 19633), isNull);
    });
  });

  group('parseTasklistProcessName', () {
    test('extracts image name from CSV row', () {
      expect(
        parseTasklistProcessName(
          '"python.exe","188544","Console","1","25,932 K"\r\n',
        ),
        'python.exe',
      );
    });

    test('returns null when no matching task (info message)', () {
      expect(
        parseTasklistProcessName(
          'INFO: No tasks are running which match the specified criteria.',
        ),
        isNull,
      );
      expect(parseTasklistProcessName(''), isNull);
    });
  });

  group('isProtectedSystemProcess', () {
    test('rejects PID 0/4 (Windows Idle/System) and PID 1 (init/launchd)', () {
      expect(
        isProtectedSystemProcess(
          listenerPid: 0,
          processName: 'System Idle Process',
        ),
        isTrue,
      );
      expect(
        isProtectedSystemProcess(listenerPid: 4, processName: 'System'),
        isTrue,
      );
      expect(
        isProtectedSystemProcess(listenerPid: 1, processName: 'launchd'),
        isTrue,
      );
    });

    test('rejects whitelisted system image names case-insensitively', () {
      expect(
        isProtectedSystemProcess(
          listenerPid: 1544,
          processName: 'svchost.exe',
        ),
        isTrue,
      );
      expect(
        isProtectedSystemProcess(
          listenerPid: 1544,
          processName: 'SvcHost.EXE',
        ),
        isTrue,
      );
      expect(
        isProtectedSystemProcess(listenerPid: 900, processName: 'lsass.exe'),
        isTrue,
      );
      expect(
        isProtectedSystemProcess(listenerPid: 321, processName: 'systemd'),
        isTrue,
      );
    });

    test('allows ordinary processes', () {
      expect(
        isProtectedSystemProcess(
          listenerPid: 188544,
          processName: 'python.exe',
        ),
        isFalse,
      );
      expect(
        isProtectedSystemProcess(listenerPid: 5000, processName: 'node.exe'),
        isFalse,
      );
      expect(
        isProtectedSystemProcess(
          listenerPid: 5000,
          processName: 'hibiki.exe',
        ),
        isFalse,
      );
    });
  });

  group('isSameExecutablePath', () {
    test('matches Windows paths ignoring case and separator style', () {
      expect(
        isSameExecutablePath(
          r'D:\Apps\Hibiki\hibiki.exe',
          'd:/apps/hibiki/HIBIKI.EXE',
        ),
        isTrue,
      );
    });

    test('null/empty/different paths do not match', () {
      expect(isSameExecutablePath(null, r'D:\a\hibiki.exe'), isFalse);
      expect(isSameExecutablePath('', r'D:\a\hibiki.exe'), isFalse);
      expect(
        isSameExecutablePath(
          r'C:\python\python.exe',
          r'D:\a\hibiki.exe',
        ),
        isFalse,
      );
    });
  });
}
