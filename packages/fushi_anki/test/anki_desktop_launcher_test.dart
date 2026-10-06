import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

class _FakeHost implements AnkiDesktopLauncherHost {
  _FakeHost({
    this.isDesktop = true,
    this.operatingSystem = 'windows',
    this.listening = false,
    this.runningExecutable,
    this.startError,
  });

  @override
  final bool isDesktop;
  @override
  final String operatingSystem;
  final bool listening;
  final String? runningExecutable;
  final Object? startError;

  final List<AnkiDesktopLaunchCommand> started = <AnkiDesktopLaunchCommand>[];
  final List<String> probed = <String>[];

  @override
  Future<bool> isPortListening(String host, int port) async {
    probed.add('$host:$port');
    return listening;
  }

  @override
  String? findRunningAnkiExecutable() => runningExecutable;

  @override
  Future<void> start(AnkiDesktopLaunchCommand command) async {
    if (startError != null) throw startError!;
    started.add(command);
  }
}

const String _winExe = r'C:\Program Files\Anki\anki.exe';

void main() {
  tearDown(() => AnkiDesktopLauncher.debugHost = null);

  group('AnkiSettings 持久化', () {
    test('缺键的老配置升级后：不自动启动、路径为空', () {
      final AnkiSettings s = AnkiSettings.fromJson(const <String, dynamic>{});
      expect(s.autoLaunchAnkiDesktop, isFalse);
      expect(s.ankiDesktopExecutable, '');
    });

    test('两个新字段 toJson/fromJson 往返不丢', () {
      const AnkiSettings original = AnkiSettings(
        autoLaunchAnkiDesktop: true,
        ankiDesktopExecutable: _winExe,
      );
      final AnkiSettings back = AnkiSettings.fromJson(original.toJson());
      expect(back.autoLaunchAnkiDesktop, isTrue);
      expect(back.ankiDesktopExecutable, _winExe);
      final AnkiSettings copied = back.copyWith(ankiDesktopExecutable: '');
      expect(copied.ankiDesktopExecutable, '');
      expect(copied.autoLaunchAnkiDesktop, isTrue);
    });
  });

  group('resolveCommand', () {
    test('Windows 没配路径 = 无法启动（不猜注册表 / 默认目录）', () {
      expect(
        AnkiDesktopLauncher.resolveCommand('', operatingSystem: 'windows'),
        isNull,
      );
      expect(
        AnkiDesktopLauncher.resolveCommand('   ', operatingSystem: 'windows'),
        isNull,
      );
    });

    test('配了路径：直接执行它，工作目录是它所在目录', () {
      final AnkiDesktopLaunchCommand? cmd = AnkiDesktopLauncher.resolveCommand(
        ' $_winExe ',
        operatingSystem: 'windows',
      );
      expect(cmd, isNotNull);
      expect(cmd!.executable, _winExe);
      expect(cmd.arguments, isEmpty);
      expect(cmd.workingDirectory, File(_winExe).parent.path);
    });

    test('macOS 没配走 open -a Anki，配了 .app 交给 open -a', () {
      expect(
        AnkiDesktopLauncher.resolveCommand('', operatingSystem: 'macos'),
        const AnkiDesktopLaunchCommand('open', <String>['-a', 'Anki']),
      );
      expect(
        AnkiDesktopLauncher.resolveCommand(
          '/Applications/Anki.app',
          operatingSystem: 'macos',
        ),
        const AnkiDesktopLaunchCommand('open', <String>[
          '-a',
          '/Applications/Anki.app',
        ]),
      );
    });

    test('Linux 没配走 PATH 上的 anki', () {
      expect(
        AnkiDesktopLauncher.resolveCommand('', operatingSystem: 'linux'),
        const AnkiDesktopLaunchCommand('anki', <String>[]),
      );
    });
  });

  group('launch', () {
    test('本机 AnkiConnect 已在监听：不重复启动', () async {
      final _FakeHost host = _FakeHost(listening: true);
      AnkiDesktopLauncher.debugHost = host;
      final AnkiDesktopLaunchResult r = await AnkiDesktopLauncher.launch(
        const AnkiSettings(ankiDesktopExecutable: _winExe),
      );
      expect(r.status, AnkiDesktopLaunchStatus.alreadyRunning);
      expect(host.started, isEmpty);
      expect(host.probed, <String>['localhost:8765']);
      // 已配路径时不覆盖用户的选择。
      expect(r.learnedExecutable, isNull);
    });

    test('已在运行且没配路径：回填认出来的入口 exe', () async {
      AnkiDesktopLauncher.debugHost = _FakeHost(
        listening: true,
        runningExecutable: _winExe,
      );
      final AnkiDesktopLaunchResult r = await AnkiDesktopLauncher.launch(
        const AnkiSettings(),
      );
      expect(r.status, AnkiDesktopLaunchStatus.alreadyRunning);
      expect(r.learnedExecutable, _winExe);
    });

    test('没在运行：按配置路径启动', () async {
      final _FakeHost host = _FakeHost();
      AnkiDesktopLauncher.debugHost = host;
      final AnkiDesktopLaunchResult r = await AnkiDesktopLauncher.launch(
        const AnkiSettings(ankiDesktopExecutable: _winExe),
      );
      expect(r.status, AnkiDesktopLaunchStatus.launched);
      expect(host.started.single.executable, _winExe);
    });

    test('Windows 没配路径：notConfigured，不启动任何东西', () async {
      final _FakeHost host = _FakeHost();
      AnkiDesktopLauncher.debugHost = host;
      final AnkiDesktopLaunchResult r = await AnkiDesktopLauncher.launch(
        const AnkiSettings(),
      );
      expect(r.status, AnkiDesktopLaunchStatus.notConfigured);
      expect(host.started, isEmpty);
    });

    test('启动抛异常：failed 并带出错误文本', () async {
      AnkiDesktopLauncher.debugHost = _FakeHost(
        startError: const ProcessException('anki.exe', <String>[], 'nope'),
      );
      final AnkiDesktopLaunchResult r = await AnkiDesktopLauncher.launch(
        const AnkiSettings(ankiDesktopExecutable: _winExe),
      );
      expect(r.status, AnkiDesktopLaunchStatus.failed);
      expect(r.detail, contains('nope'));
    });

    test('AnkiConnect 指向别的机器：不探测端口，按用户要求照样启动本机 Anki', () async {
      final _FakeHost host = _FakeHost(listening: true);
      AnkiDesktopLauncher.debugHost = host;
      final AnkiDesktopLaunchResult r = await AnkiDesktopLauncher.launch(
        const AnkiSettings(
          ankiConnectHost: '192.168.1.20',
          ankiDesktopExecutable: _winExe,
        ),
      );
      expect(r.status, AnkiDesktopLaunchStatus.launched);
      expect(host.probed, isEmpty);
    });

    test('移动端：skipped', () async {
      final _FakeHost host = _FakeHost(isDesktop: false);
      AnkiDesktopLauncher.debugHost = host;
      final AnkiDesktopLaunchResult r = await AnkiDesktopLauncher.launch(
        const AnkiSettings(ankiDesktopExecutable: _winExe),
      );
      expect(r.status, AnkiDesktopLaunchStatus.skipped);
      expect(host.started, isEmpty);
    });
  });

  group('autoLaunchOnStartup', () {
    test('开关默认关：什么都不做', () async {
      final _FakeHost host = _FakeHost();
      AnkiDesktopLauncher.debugHost = host;
      final AnkiDesktopLaunchResult r =
          await AnkiDesktopLauncher.autoLaunchOnStartup(
            const AnkiSettings(ankiDesktopExecutable: _winExe),
          );
      expect(r.status, AnkiDesktopLaunchStatus.skipped);
      expect(host.probed, isEmpty);
      expect(host.started, isEmpty);
    });

    test('走同步客户端后端（不需要 AnkiConnect）：不启动', () async {
      final _FakeHost host = _FakeHost();
      AnkiDesktopLauncher.debugHost = host;
      final AnkiDesktopLaunchResult r =
          await AnkiDesktopLauncher.autoLaunchOnStartup(
            const AnkiSettings(
              autoLaunchAnkiDesktop: true,
              useAnkiSyncClient: true,
              ankiDesktopExecutable: _winExe,
            ),
          );
      expect(r.status, AnkiDesktopLaunchStatus.skipped);
      expect(host.started, isEmpty);
    });

    test('AnkiConnect 指向别的机器：本机 Anki 帮不上忙，不启动', () async {
      final _FakeHost host = _FakeHost();
      AnkiDesktopLauncher.debugHost = host;
      final AnkiDesktopLaunchResult r =
          await AnkiDesktopLauncher.autoLaunchOnStartup(
            const AnkiSettings(
              autoLaunchAnkiDesktop: true,
              ankiConnectHost: '192.168.1.20',
              ankiDesktopExecutable: _winExe,
            ),
          );
      expect(r.status, AnkiDesktopLaunchStatus.skipped);
      expect(host.started, isEmpty);
    });

    test('开关打开、本机没在监听：启动', () async {
      final _FakeHost host = _FakeHost();
      AnkiDesktopLauncher.debugHost = host;
      final AnkiDesktopLaunchResult r =
          await AnkiDesktopLauncher.autoLaunchOnStartup(
            const AnkiSettings(
              autoLaunchAnkiDesktop: true,
              ankiConnectHost: '127.0.0.1',
              ankiDesktopExecutable: _winExe,
            ),
          );
      expect(r.status, AnkiDesktopLaunchStatus.launched);
      expect(host.started, hasLength(1));
    });
  });

  group('真实平台实现', () {
    test('端口探测：有人监听 = alreadyRunning；没人监听 = 去启动', () async {
      final ServerSocket server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final int port = server.port;
      try {
        final AnkiDesktopLaunchResult running =
            await AnkiDesktopLauncher.launch(
              AnkiSettings(
                ankiConnectHost: '127.0.0.1',
                ankiConnectPort: port,
                ankiDesktopExecutable: _winExe,
              ),
            );
        expect(running.status, AnkiDesktopLaunchStatus.alreadyRunning);
      } finally {
        await server.close();
      }

      // 端口释放后去启动一个不存在的程序：真实 Process.start 抛错 → failed。
      final AnkiDesktopLaunchResult missing = await AnkiDesktopLauncher.launch(
        AnkiSettings(
          ankiConnectHost: '127.0.0.1',
          ankiConnectPort: port,
          ankiDesktopExecutable:
              '${Directory.systemTemp.path}${Platform.pathSeparator}'
              'fushi_no_such_anki_${DateTime.now().microsecondsSinceEpoch}.exe',
        ),
      );
      expect(missing.status, AnkiDesktopLaunchStatus.failed);
      expect(missing.detail, isNotEmpty);
    });
  });
}
