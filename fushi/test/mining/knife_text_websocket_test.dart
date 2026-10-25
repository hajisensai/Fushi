import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/knife_text_websocket.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('knife_ws_test_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// 合成的 knife 安装：exe 占位 + romfs 结构（不含任何游戏内容）。
  String makeKnife({String assets = 'assets', String? ini, bool ogg = false}) {
    final String exe = p.join(root.path, 'knife.exe');
    File(exe).writeAsBytesSync(<int>[0x4d, 0x5a]);
    final Directory stream = Directory(p.join(root.path, assets, 'stream'))
      ..createSync(recursive: true);
    File(p.join(root.path, assets, 'allscr.mrg')).writeAsBytesSync(<int>[0]);
    File(p.join(stream.path, 'A00_01_00_0000_0.opus')).writeAsBytesSync(
      ogg
          ? <int>[0x4f, 0x67, 0x67, 0x53, 0, 2]
          : <int>[0x01, 0x00, 0x00, 0x80, 0x18, 0, 0, 0],
    );
    if (ini != null) {
      File(p.join(root.path, 'knife.ini')).writeAsStringSync(ini);
    }
    return exe;
  }

  group('parseKnifeIni', () {
    test('reads the two options, skips comments and empty values', () {
      final KnifeIniOptions options = parseKnifeIni(
        '﻿; comment\r\nassets-dir = romfs\r\n'
        '# text-websocket = 1.2.3.4:9\r\nlanguage =\r\n'
        'text-websocket = 127.0.0.1:7000\r\n',
      );
      expect(options.assetsDir, 'romfs');
      expect(options.textWebSocket, '127.0.0.1:7000');
      expect(parseKnifeIni('text-websocket =\n').textWebSocket, isNull);
      expect(parseKnifeIni('').assetsDir, isNull);
    });
  });

  group('knifeArgsEnableTextWebSocket', () {
    test('recognises every spelling knife accepts', () {
      expect(knifeArgsEnableTextWebSocket(<String>['-t', '127.0.0.1:1']), true);
      expect(knifeArgsEnableTextWebSocket(<String>['-t127.0.0.1:1']), true);
      expect(
        knifeArgsEnableTextWebSocket(<String>['--text-websocket', 'x:1']),
        true,
      );
      expect(
        knifeArgsEnableTextWebSocket(<String>['--text-websocket=x:1']),
        true,
      );
      expect(knifeArgsEnableTextWebSocket(<String>['--skip-intro']), false);
      expect(knifeArgsEnableTextWebSocket(<String>['-t']), false);
      expect(knifeArgsEnableTextWebSocket(<String>[]), false);
    });
  });

  group('detectKnifeInstall', () {
    test('accepts the romfs layout under the default assets folder', () {
      final KnifeInstall? install = detectKnifeInstall(makeKnife());
      expect(install, isNotNull);
      expect(install!.assetsDir, p.join(root.path, 'assets'));
      expect(install.iniTextWebSocket, isNull);
    });

    test('follows knife.ini assets-dir and reports its text-websocket', () {
      final KnifeInstall? install = detectKnifeInstall(
        makeKnife(
          assets: 'romfs',
          ini: 'assets-dir = romfs\ntext-websocket = 127.0.0.1:6677\n',
        ),
      );
      expect(install?.assetsDir, p.join(root.path, 'romfs'));
      expect(install?.iniTextWebSocket, '127.0.0.1:6677');
    });

    test('rejects other engines and non-Nintendo-Opus streams', () {
      // 同名目录但流文件是 Ogg（别的引擎的 stream/）。
      expect(detectKnifeInstall(makeKnife(ogg: true)), isNull);
      // 没有 romfs 的普通 exe。
      final String other = p.join(root.path, 'other', 'game.exe');
      Directory(p.dirname(other)).createSync(recursive: true);
      File(other).writeAsBytesSync(<int>[0x4d, 0x5a]);
      expect(detectKnifeInstall(other), isNull);
      expect(detectKnifeInstall(''), isNull);
    });
  });

  group('knifeAutoLaunchArgs', () {
    test('adds the server on a free port only when nothing enables it', () {
      final String exe = makeKnife();
      expect(
        knifeAutoLaunchArgs(
          executablePath: exe,
          userArgs: const <String>['--skip-intro'],
          freePort: 50123,
        ),
        <String>['--text-websocket', '127.0.0.1:50123'],
      );
      // 用户参数已开：不追加第二份。
      expect(
        knifeAutoLaunchArgs(
          executablePath: exe,
          userArgs: const <String>['-t', '127.0.0.1:1'],
          freePort: 50123,
        ),
        isEmpty,
      );
    });

    test('leaves a knife.ini that already enables it alone', () {
      final String exe = makeKnife(ini: 'text-websocket = 127.0.0.1:6677\n');
      expect(
        knifeAutoLaunchArgs(
          executablePath: exe,
          userArgs: const <String>[],
          freePort: 50123,
        ),
        isEmpty,
      );
    });

    test('never touches another engine', () {
      final String exe = makeKnife(ogg: true);
      expect(
        knifeAutoLaunchArgs(
          executablePath: exe,
          userArgs: const <String>[],
          freePort: 50123,
        ),
        isEmpty,
      );
    });
  });

  group('enableKnifeTextWebSocketInIni', () {
    test('appends one line and keeps the rest and its CRLF style', () {
      makeKnife(ini: 'assets-dir = assets\r\nskip-intro = true\r\n');
      final String ini = p.join(root.path, 'knife.ini');
      expect(enableKnifeTextWebSocketInIni(ini), kKnifeIniTextWebSocketAddress);
      expect(
        File(ini).readAsStringSync(),
        'assets-dir = assets\r\nskip-intro = true\r\n'
        'text-websocket = 127.0.0.1:6677\r\n',
      );
      expect(
        detectKnifeInstall(p.join(root.path, 'knife.exe'))?.iniTextWebSocket,
        '127.0.0.1:6677',
      );
    });

    test('fills an empty entry in place and keeps comments', () {
      makeKnife(ini: '# options\ntext-websocket =\nskip-intro = true');
      final String ini = p.join(root.path, 'knife.ini');
      enableKnifeTextWebSocketInIni(ini);
      expect(
        File(ini).readAsStringSync(),
        '# options\ntext-websocket = 127.0.0.1:6677\nskip-intro = true\n',
      );
    });

    test('creates knife.ini when it is missing, and never overrides', () {
      makeKnife();
      final String ini = p.join(root.path, 'knife.ini');
      enableKnifeTextWebSocketInIni(ini);
      expect(File(ini).readAsStringSync(), 'text-websocket = 127.0.0.1:6677\n');
      File(ini).writeAsStringSync('text-websocket = 0.0.0.0:7000\n');
      expect(enableKnifeTextWebSocketInIni(ini), '0.0.0.0:7000');
      expect(File(ini).readAsStringSync(), 'text-websocket = 0.0.0.0:7000\n');
    });
  });

  test('pickFreeLoopbackPort returns a bindable port', () async {
    final int port = await pickFreeLoopbackPort();
    expect(port, greaterThan(0));
    final ServerSocket socket = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      port,
    );
    await socket.close();
  });
}
