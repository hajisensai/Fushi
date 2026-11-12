import 'package:test/test.dart';
import 'package:fushi/src/mining/tyrano_dom/tyrano_dom_attach_probe.dart';

void main() {
  int? probe(String? commandLine) =>
      readRemoteDebuggingPortForPid(42, commandLineReader: (_) => commandLine);

  test('命令行里的调试端口按 Windows argv 规则读出', () {
    expect(
      probe(r'"C:\Games\My Game\game.exe" --remote-debugging-port=9333 -x'),
      9333,
    );
    expect(probe(r'C:\g\game.exe --remote-debugging-port 9444'), 9444);
  });

  test('读不到 / 没带 / 端口为 0 时返回 null（attach 不启用 DOM 源）', () {
    expect(probe(null), isNull);
    expect(probe(''), isNull);
    expect(probe(r'C:\g\game.exe --type=renderer'), isNull);
    expect(probe(r'C:\g\game.exe --remote-debugging-port=0'), isNull);
  });
}
