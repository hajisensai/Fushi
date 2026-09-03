// BUG-2067 — Locale Emulator 拉起的进程在 LoaderDll 装载阶段 APPCRASH（本机对每款
// x86 游戏复现，与 hook 注入无关）。`auto` 档是替用户做的转区决定，它失效时会话必须
// 退回不转区再拉一次，而不是对着一个已经死掉的 PID 降级 loopback + 排重试。

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/galgame_japanese_locale.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/sync/texthooker_ws_client.dart';

/// 第一次（转区）拉起：进程「已回报 pid 但已经死了」；第二次（不转区）拉起：正常。
class _LocaleEngine extends EngineHookGalAudioSource {
  _LocaleEngine({required this.localeApplied, required this.pid})
      : super(targetPid: 0, launchExe: 'game.exe', injectorPath: 'inj.exe');

  final bool localeApplied;
  final int pid;

  @override
  bool get japaneseLocaleApplied => localeApplied;

  @override
  int? get launchedPid => pid;

  @override
  int? get gamePid => pid;

  @override
  bool get textHookReady => !localeApplied;

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
  Future<bool> refreshReadiness() async => !localeApplied;

  @override
  Future<void> stop() async {}
}

class _QuietLoopback extends LoopbackGalAudioSource {
  @override
  Future<PcmFormat?> start() async => const PcmFormat(
        sampleRate: 44100,
        channels: 2,
        bitsPerSample: 16,
        isFloat: false,
      );

  @override
  Future<GalAudioSlice?> grabRecent(int backMs) async => null;

  @override
  Future<void> stop() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TexthookerService service;
  late ChangeNotifier endpoints;
  late List<GalJapaneseLocaleMode> requestedModes;
  late Set<int> alivePids;

  GalHookSessionController build() => GalHookSessionController(
        textService: service,
        isWindows: true,
        exe32BitProbe: (_) async => true,
        targetImagePathProbe: (int pid) =>
            alivePids.contains(pid) ? 'D:\\game\\game.exe' : null,
        injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
        engineSourceFactory: ({
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
          requestedModes.add(japaneseLocaleMode);
          final bool locale = japaneseLocaleMode != GalJapaneseLocaleMode.off;
          // 转区那次拿到的 pid 已死；不转区那次的 pid 活着。
          return _LocaleEngine(
              localeApplied: locale, pid: locale ? 1111 : 2222);
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
    service = TexthookerService.test();
    endpoints = ChangeNotifier();
    requestedModes = <GalJapaneseLocaleMode>[];
    alivePids = <int>{2222};
  });

  tearDown(() => endpoints.dispose());

  test('auto 转区拉起的进程立刻死亡 → 退回不转区重拉一次，会话以第二次为准', () async {
    final GalHookSessionController controller = build();
    final GalHookLaunchResult result =
        await controller.launchGame(r'D:\game\game.exe');
    expect(result.launched, isTrue);
    expect(
      requestedModes,
      <GalJapaneseLocaleMode>[
        GalJapaneseLocaleMode.auto,
        GalJapaneseLocaleMode.off,
      ],
      reason: '第二次拉起必须显式 off，而不是再 auto 一次',
    );
    expect(controller.state.gamePid, 2222, reason: '会话应绑定第二次拉起的进程');
    expect(controller.state.japaneseLocaleApplied, isFalse);
    final List<String> codes =
        controller.events.map((GalHookEvent e) => e.code).toList();
    expect(codes, contains('launch.japanese_locale_fallback'));
    expect(
      codes,
      isNot(contains('engine.launch_injection_degraded')),
      reason: '死掉的转区进程不能被当成「游戏在跑」去降级 loopback',
    );
    await controller.close();
  });

  test('用户显式选 on：转区拉起死亡不替他改主意，按原路径降级', () async {
    final GalHookSessionController controller = build();
    await controller.launchGame(
      r'D:\game\game.exe',
      japaneseLocaleMode: GalJapaneseLocaleMode.on,
    );
    expect(requestedModes, <GalJapaneseLocaleMode>[GalJapaneseLocaleMode.on]);
    final List<String> codes =
        controller.events.map((GalHookEvent e) => e.code).toList();
    expect(codes, isNot(contains('launch.japanese_locale_fallback')));
    await controller.close();
  });

  test('转区拉起的进程还活着（只是注入没就绪）→ 不重拉，走既有降级', () async {
    alivePids = <int>{1111, 2222};
    final GalHookSessionController controller = build();
    await controller.launchGame(r'D:\game\game.exe');
    expect(requestedModes, <GalJapaneseLocaleMode>[GalJapaneseLocaleMode.auto]);
    final List<String> codes =
        controller.events.map((GalHookEvent e) => e.code).toList();
    expect(codes, contains('engine.launch_injection_degraded'));
    await controller.close();
  });
}
