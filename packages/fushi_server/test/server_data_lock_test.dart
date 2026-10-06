/// 数据目录排他锁：serve 与离线命令不能同时打开同一份库。
///
/// 锁的持有方一律放在**子进程**里：POSIX fcntl 锁按进程计，同一进程里第二次
/// `lock` 不会冲突，进程内自测会假绿。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_server/src/cli.dart';
import 'package:fushi_server/src/commands/import_commands.dart';
import 'package:fushi_server/src/server_data_lock.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'command_harness.dart';
import 'support/dart_executable.dart';

/// 起一个子进程拿住数据目录锁，等它报 `locked <pid>`；返回进程与它自报的 pid
/// （即写进锁文件的那个；Windows 上与 [Process.pid] 不同，见 hold_data_lock.dart）。
Future<({Process proc, int pid})> _holdLock(String dataDir, String mode) async {
  final Process proc = await Process.start(dartExecutable(), <String>[
    p.join('test', 'support', 'hold_data_lock.dart'),
    dataDir,
    mode,
    'test holder',
  ]);
  final Completer<int> ready = Completer<int>();
  final StringBuffer err = StringBuffer();
  proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((String line) {
    final int? holderPid = line.startsWith('locked ') ? int.tryParse(line.substring(7)) : null;
    if (holderPid != null && !ready.isCompleted) ready.complete(holderPid);
  });
  proc.stderr.transform(utf8.decoder).listen(err.write);
  unawaited(
    proc.exitCode.then((int code) {
      if (!ready.isCompleted) ready.completeError(StateError('持锁进程提前退出 $code: $err'));
    }),
  );
  final int holderPid = await ready.future.timeout(const Duration(minutes: 2));
  return (proc: proc, pid: holderPid);
}

Future<void> _releaseHolder(Process proc) async {
  await proc.stdin.close();
  expect(await proc.exitCode.timeout(const Duration(minutes: 1)), 0);
}

void main() {
  late CommandHarness h;

  setUp(() async => h = await CommandHarness.create());
  tearDown(() => h.dispose());

  List<String> cli(List<String> args) => <String>['-c', h.configFile.path, ...args];

  test('serve 持锁：离线命令 75、第二个 serve 75；锁释放后可用', () async {
    final ({Process proc, int pid}) holder = await _holdLock(h.dataDir, 'serve');
    try {
      expect(await runFushiServerCli(cli(<String>['status'])), 75);
      expect(await runFushiServerCli(cli(<String>['serve', '--no-scan'])), 75);
      // 模块化离线命令（经 CliContext.withRuntime）同一条门。
      final String epub = p.join(h.tmp.path, 'book.epub');
      writeTestEpub(epub, 'Neko');
      expect(await h.run(ImportCommands(io: h.io), <String>['import', 'epub', epub]), 75);
      // 提示里带持有者 pid 与 WebUI 地址，指向 ctl。
      final ServerDataLockedException e = await _expectLocked(h.dataDir);
      expect(e.holder?.pid, holder.pid);
      expect(e.holder?.isServe, isTrue);
      expect(e.describe(), allOf(contains('pid ${holder.pid}'), contains('http://127.0.0.1:38766'), contains('ctl')));
    } finally {
      await _releaseHolder(holder.proc);
    }
    expect(await runFushiServerCli(cli(<String>['status'])), 0);
  });

  test('离线命令持锁：serve 拒绝启动 75，提示是离线命令占用', () async {
    final ({Process proc, int pid}) holder = await _holdLock(h.dataDir, 'offline');
    try {
      expect(await runFushiServerCli(cli(<String>['serve', '--no-scan'])), 75);
      final ServerDataLockedException e = await _expectLocked(h.dataDir);
      expect(e.holder?.mode, 'offline');
      expect(e.describe(), allOf(contains('离线命令'), contains('pid ${holder.pid}'), contains('test holder')));
    } finally {
      await _releaseHolder(holder.proc);
    }
    // 锁释放后持有者信息被清空，再拿锁不受影响。
    final ServerDataLock lock = await ServerDataLock.acquire(h.dataDir, mode: 'offline');
    await lock.release();
  });

  test('真 serve 进程：运行中离线命令与第二个 serve 都 75，停掉后恢复', () async {
    // 端口 0 / 关 WebUI：不和本机别的服务抢端口。
    final String yaml = h.configFile.readAsStringSync();
    h.configFile.writeAsStringSync(
      yaml
          .replaceFirst(RegExp(r'^port: .*$', multiLine: true), 'port: 0')
          .replaceFirst(RegExp(r'^admin_port: .*$', multiLine: true), 'admin_port: 0'),
    );
    final Process serve = await Process.start(dartExecutable(), <String>[
      'run',
      p.join('bin', 'fushi_server.dart'),
      ...cli(<String>['serve', '--no-scan']),
    ]);
    final Completer<void> started = Completer<void>();
    final StringBuffer err = StringBuffer();
    serve.stdout.transform(utf8.decoder).listen((String chunk) {
      if (chunk.contains('已启动') && !started.isCompleted) started.complete();
    });
    serve.stderr.transform(utf8.decoder).listen(err.write);
    unawaited(
      serve.exitCode.then((int code) {
        if (!started.isCompleted) started.completeError(StateError('serve 提前退出 $code: $err'));
      }),
    );
    try {
      await started.future.timeout(const Duration(minutes: 4));
      expect(await runFushiServerCli(cli(<String>['status'])), 75);
      expect(await runFushiServerCli(cli(<String>['serve', '--no-scan'])), 75);
      final ServerDataLockedException e = await _expectLocked(h.dataDir);
      expect(e.holder?.isServe, isTrue);
      expect(e.holder?.pid, isNotNull);
    } finally {
      serve.kill();
      await serve.exitCode.timeout(const Duration(minutes: 1));
    }
    expect(await runFushiServerCli(cli(<String>['status'])), 0);
  }, timeout: const Timeout(Duration(minutes: 6)));
}

Future<ServerDataLockedException> _expectLocked(String dataDir) async {
  try {
    final ServerDataLock lock = await ServerDataLock.acquire(dataDir, mode: 'offline');
    await lock.release();
  } on ServerDataLockedException catch (e) {
    return e;
  }
  fail('锁应当被占着');
}
