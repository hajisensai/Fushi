import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// BUG-5588：`tool/notarize_submit.sh` 把「上传」与「等结论」分开，轮询途中本地查询
/// 失败（runner 断网 / DNS）不丢弃已上传的 submission。
///
/// 跑的是**真脚本**，PATH 最前面放假 `xcrun`（按 FAKE_INFO_SEQ 逐次回 info 结果，
/// `fail` 表示这一次查询像断网一样退出 1）和假 `plutil`（macOS 才有，这里用 sed 取
/// JSON 字段），断言：
/// - 查询失败几次后拿到 Accepted → 退出 0，且只上传一次；
/// - Invalid → 退出 1 并打印 `notarytool log`；
/// - 上传本身失败 → 立即退出 1，不进入轮询；
/// - 一直 In Progress → 到总时限退出 1。
void main() {
  // 相对路径字面量 `../tool/…` 让 ci-config-gate.yml 的磁盘枚举把本测试收进去。
  final File script = File('../tool/notarize_submit.sh').absolute;

  late Directory tmp;
  late File log;

  setUpAll(() {
    expect(script.existsSync(), isTrue, reason: '缺 ${script.path}');
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('notarize_submit_');
    log = File(p.join(tmp.path, 'xcrun.log'));
    final File fakeXcrun = File(p.join(tmp.path, 'bin', 'xcrun'))
      ..createSync(recursive: true);
    fakeXcrun.writeAsStringSync(r'''#!/usr/bin/env bash
# $1 = notarytool, $2 = 子命令
echo "$2" >> "$FAKE_XCRUN_LOG"
case "$2" in
  submit)
    if [ -n "${FAKE_SUBMIT_FAIL:-}" ]; then
      echo 'Error: HTTPError(statusCode: nil, error: NSURLErrorDomain Code=-1009)' >&2
      exit 1
    fi
    echo '{"id":"sub-1","message":"Successfully uploaded file"}'
    ;;
  info)
    n=$(grep -c '^info$' "$FAKE_XCRUN_LOG")
    read -r -a seq <<< "$FAKE_INFO_SEQ"
    idx=$(( n - 1 ))
    if [ "$idx" -ge "${#seq[@]}" ]; then idx=$(( ${#seq[@]} - 1 )); fi
    case "${seq[$idx]}" in
      fail) echo 'Error: The Internet connection appears to be offline. (-1009)' >&2; exit 1 ;;
      InProgress) echo '{"id":"sub-1","status":"In Progress"}' ;;
      *) echo "{\"id\":\"sub-1\",\"status\":\"${seq[$idx]}\"}" ;;
    esac
    ;;
  log) echo 'notary log for sub-1: binary not signed' ;;
  *) echo "unexpected xcrun call: $*" >&2; exit 2 ;;
esac
''');
    final File fakePlutil = File(p.join(tmp.path, 'bin', 'plutil'))
      ..createSync(recursive: true);
    // 只实现脚本用到的形态：plutil -extract <key> raw -o - -（从 stdin 读 JSON）。
    fakePlutil.writeAsStringSync(r'''#!/usr/bin/env bash
key="$2"
v=$(sed -n "s/.*\"$key\":\"\([^\"]*\)\".*/\1/p")
[ -n "$v" ] || exit 1
printf '%s' "$v"
''');
    if (!Platform.isWindows) {
      Process.runSync('chmod', <String>['+x', fakeXcrun.path, fakePlutil.path]);
    }
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  Future<ProcessResult> run({
    required String infoSeq,
    bool submitFails = false,
    int timeoutSeconds = 60,
  }) {
    final String sep = Platform.isWindows ? ';' : ':';
    return Process.run(
      _bashExecutable(),
      <String>[script.path, 'Fushi.dmg', 'AuthKey.p8', 'KEYID', 'ISSUER'],
      environment: <String, String>{
        'PATH': '${p.join(tmp.path, 'bin')}$sep${Platform.environment['PATH']}',
        'FAKE_XCRUN_LOG': log.path,
        'FAKE_INFO_SEQ': infoSeq,
        if (submitFails) 'FAKE_SUBMIT_FAIL': '1',
        'NOTARIZE_POLL_SECONDS': '0',
        'NOTARIZE_TIMEOUT_SECONDS': '$timeoutSeconds',
      },
    );
  }

  List<String> calls() => log.existsSync()
      ? log.readAsLinesSync().where((String l) => l.isNotEmpty).toList()
      : <String>[];

  test('轮询途中查询失败不丢 submission：断网两次后 Accepted 判成功', () async {
    final ProcessResult r = await run(infoSeq: 'fail InProgress fail Accepted');
    expect(r.exitCode, 0, reason: _io(r));
    expect(r.stdout, contains('Notarization accepted: sub-1'));
    expect(
      r.stdout,
      contains('::warning title=Notarization status query failed'),
    );
    expect(calls(), <String>['submit', 'info', 'info', 'info', 'info']);
  });

  test('服务端判 Invalid：退出 1 并打印 notarytool log', () async {
    final ProcessResult r = await run(infoSeq: 'InProgress Invalid');
    expect(r.exitCode, 1, reason: _io(r));
    expect(
      r.stdout,
      contains('::error title=Notarization rejected::status=Invalid'),
    );
    expect(r.stdout, contains('notary log for sub-1'));
    expect(calls(), <String>['submit', 'info', 'info', 'log']);
  });

  test('上传失败立即判失败，不进入轮询', () async {
    final ProcessResult r = await run(infoSeq: 'Accepted', submitFails: true);
    expect(r.exitCode, 1, reason: _io(r));
    expect(r.stdout, contains('::error title=Notarization submit failed'));
    expect(calls(), <String>['submit']);
  });

  test('一直拿不到终态：到总时限判失败', () async {
    final ProcessResult r = await run(infoSeq: 'InProgress', timeoutSeconds: 0);
    expect(r.exitCode, 1, reason: _io(r));
    expect(r.stdout, contains('::error title=Notarization timed out::sub-1'));
  });
}

String _io(ProcessResult r) =>
    'exit=${r.exitCode}\nstdout=${r.stdout}\nstderr=${r.stderr}';

/// Windows 上 `Process.start('bash')` 先命中 System32 的 WSL bash，顺着 git 的安装
/// 位置找 Git Bash（同 bump_rolling_release_tag_script_test.dart）。
String _bashExecutable() {
  if (!Platform.isWindows) return 'bash';
  final ProcessResult where = Process.runSync('where', <String>['git']);
  for (final String line in (where.stdout as String).split(RegExp(r'\r?\n'))) {
    final String gitPath = line.trim();
    if (gitPath.isEmpty) continue;
    Directory dir = File(gitPath).parent;
    for (int i = 0; i < 3; i++) {
      final File bash = File(p.join(dir.path, 'bin', 'bash.exe'));
      if (bash.existsSync()) return bash.path;
      dir = dir.parent;
    }
  }
  return 'bash';
}
