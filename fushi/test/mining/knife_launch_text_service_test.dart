// knife 的台词服务默认关闭：从游戏库启动时会话要替用户追加
// `--text-websocket 127.0.0.1:<空闲端口>`；用户参数 / knife.ini 已开、或不是 knife
// 时启动参数原样不动。

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/galgame_japanese_locale.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/sync/texthooker_ws_client.dart';
import 'package:path/path.dart' as p;

class _ReadyEngine extends EngineHookGalAudioSource {
  _ReadyEngine({required String exe})
    : super(targetPid: 0, launchExe: exe, injectorPath: 'inj.exe');

  @override
  bool get gameLaunchConfirmed => true;

  @override
  bool get localeGameLaunchConfirmed => false;

  @override
  bool get japaneseLocaleApplied => false;

  @override
  int? get launchedPid => 2222;

  @override
  int? get gamePid => 2222;

  @override
  bool get textHookReady => true;

  @override
  bool get rawVoiceReady => false;

  @override
  PcmFormat? get readyPcmFormat => null;

  @override
  bool get pcmReady => false;

  @override
  GalHookInjectorDiagnostics get lastFailure =>
      const GalHookInjectorDiagnostics();

  @override
  Future<PcmFormat?> start() async => null;

  @override
  Future<bool> refreshReadiness() async => true;

  @override
  Future<void> stop() async {}
}

class _QuietLoopback extends LoopbackGalAudioSource {
  @override
  Future<PcmFormat?> start() async => null;

  @override
  Future<GalAudioSlice?> grabRecent(int backMs) async => null;

  @override
  Future<void> stop() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late TexthookerService service;
  late ChangeNotifier endpoints;
  late List<List<String>> launched;

  /// 合成的 knife 安装（不含任何游戏内容）。
  String makeExe({bool knife = true, String? ini}) {
    final String exe = p.join(root.path, 'knife.exe');
    File(exe).writeAsBytesSync(<int>[0x4d, 0x5a]);
    if (knife) {
      final Directory stream = Directory(p.join(root.path, 'assets', 'stream'))
        ..createSync(recursive: true);
      File(
        p.join(root.path, 'assets', 'allscr.mrg'),
      ).writeAsBytesSync(<int>[0]);
      File(
        p.join(stream.path, 'A00_01_00_0000_0.opus'),
      ).writeAsBytesSync(<int>[0x01, 0x00, 0x00, 0x80, 0x18, 0, 0, 0]);
    }
    if (ini != null) {
      File(p.join(root.path, 'knife.ini')).writeAsStringSync(ini);
    }
    return exe;
  }

  GalHookSessionController build(String exe) => GalHookSessionController(
    textService: service,
    isWindows: true,
    exe32BitProbe: (_) async => false,
    targetImagePathProbe: (int pid) => pid == 2222 ? exe : null,
    injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
    engineSourceFactory:
        ({
          required int targetPid,
          required String? launchExe,
          required String injectorPath,
          required bool lunaPcHooks,
          int? lunaCodepage,
          List<String> launchArguments = const <String>[],
          String launchWorkdir = '',
          GalJapaneseLocaleMode japaneseLocaleMode =
              kGalDefaultJapaneseLocaleMode,
          String? contentLanguage,
        }) {
          if (launchExe != null) launched.add(launchArguments);
          return _ReadyEngine(exe: exe);
        },
    loopbackSourceFactory: _QuietLoopback.new,
    windowListLoader: () async => const <ExternalWindowInfo>[],
    windowPollAttempts: 1,
    endpointListenable: endpoints,
    endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    startWindowRecording: ({required int hwnd}) async => false,
    stopWindowRecording: () async {},
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('knife_launch_test_');
    service = TexthookerService.test();
    endpoints = ChangeNotifier();
    launched = <List<String>>[];
  });

  tearDown(() {
    endpoints.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('knife 未开台词服务：启动参数追加回环地址，用户参数保留在前', () async {
    final String exe = makeExe();
    final GalHookSessionController controller = build(exe);
    await controller.launchGame(
      exe,
      launchArguments: const <String>['--skip-intro'],
    );
    expect(launched, hasLength(1));
    final List<String> args = launched.single;
    expect(args.take(2), <String>['--skip-intro', '--text-websocket']);
    expect(args, hasLength(3));
    expect(args[2], matches(RegExp(r'^127\.0\.0\.1:\d+$')));
    await controller.close();
  });

  test('knife.ini 已开 / 用户参数已开 / 不是 knife：参数原样', () async {
    for (final ({bool knife, String? ini, List<String> user}) c
        in <({bool knife, String? ini, List<String> user})>[
          (
            knife: true,
            ini: 'text-websocket = 127.0.0.1:6677\n',
            user: <String>[],
          ),
          (knife: true, ini: null, user: <String>['-t', '127.0.0.1:9000']),
          (knife: false, ini: null, user: <String>['--skip-intro']),
        ]) {
      launched.clear();
      final String exe = makeExe(knife: c.knife, ini: c.ini);
      final GalHookSessionController controller = build(exe);
      await controller.launchGame(exe, launchArguments: c.user);
      expect(launched, <List<String>>[c.user]);
      await controller.close();
      root.deleteSync(recursive: true);
      root = Directory.systemTemp.createTempSync('knife_launch_test_');
    }
  });
}
