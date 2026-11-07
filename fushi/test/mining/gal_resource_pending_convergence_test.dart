import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_japanese_locale.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/sync/texthooker_ws_client.dart';

/// BUG-4206（反馈 3drXfc4GFk，STEINS;GATE RE:BOOT）：资源通道就绪、但这句还没配上
/// 原件时，行状态是「匹配中」——
///  ① 不得被标成 backend=game_resource（UI 会据此弹出点了没声的资源弹窗）；
///  ② 必须有终态：播放已经走过这句的配对容差后收束成 missing，而不是永远「匹配中」；
///  ③ 收束后资源晚落盘仍能升格成 matched（不撤出待匹配集合）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> waitUntil(bool Function() done) async {
    for (int i = 0; i < 400 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  GalHookSessionController buildController(
    TexthookerService service,
    _ResourceEngine engine,
    ChangeNotifier endpoints,
  ) => GalHookSessionController(
    textService: service,
    isWindows: true,
    targetWow64Probe: (_) async => false,
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
        }) => engine,
    loopbackSourceFactory: _SilentLoopback.new,
    textPollInterval: const Duration(milliseconds: 5),
    endpointListenable: endpoints,
    endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
  );

  test('未配上的行是「匹配中」且不带 game_resource，越过配对容差后收束成 missing', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final _ResourceEngine engine = _ResourceEngine()
      ..lines.add(
        const GalHookedLine(
          seq: 1,
          timestampMs: 10000,
          text: '一句目',
          threadId: 5,
          hookName: 'fake',
        ),
      );
    final GalHookSessionController controller = buildController(
      service,
      engine,
      endpoints,
    );

    // 干净源策略（cleanOnly）下 loopback 兜底整个跳过：修复前「匹配中」在这里没有
    // 任何出口。full 策略下逐行 loopback 冻结会另行给出终态，不是本用例的对象。
    controller.setAudioFallbackPolicy(GalAudioFallbackPolicy.cleanOnly);
    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 3, pid: 4242, title: 'Game'),
    );
    await controller.selectTextThread(5);
    await waitUntil(() => service.entries.isNotEmpty);
    // 让几轮 poll 走完：同一句还没有后续台词，状态必须停在「匹配中」。
    await waitUntil(() => engine.pollCalls > 5);

    TexthookerLineEntry first = service.entries.single;
    expect(first.audioStatus, TexthookerLineAudioStatus.pending);
    expect(
      first.audioBackend,
      isNull,
      reason: '还没配上原件的行不是 game_resource（BUG-4206）',
    );
    expect(first.audioResourceId, isNull);

    // 下一句在配对容差之内开始：仍可能有资源属于第一句，不收束。
    engine.lines.add(
      GalHookedLine(
        seq: 2,
        timestampMs: 10000 + kGalVoicePairingWindowMs,
        text: '二句目',
        threadId: 5,
        hookName: 'fake',
      ),
    );
    await waitUntil(() => service.entries.length >= 2);
    final int polls = engine.pollCalls;
    await waitUntil(() => engine.pollCalls > polls + 3);
    first = service.entries.first;
    expect(
      first.audioStatus,
      TexthookerLineAudioStatus.pending,
      reason: '${first.fallbackReason} ${first.audioBackend}',
    );

    // 再下一句超出第一句的配对容差：第一句收束成 missing，后两句各自仍在匹配中
    // 或已收束（第二句距第三句同样超出容差）。
    engine.lines.add(
      GalHookedLine(
        seq: 3,
        timestampMs: 10000 + 3 * kGalVoicePairingWindowMs,
        text: '三句目',
        threadId: 5,
        hookName: 'fake',
      ),
    );
    await waitUntil(
      () =>
          service.entries.length >= 3 &&
          service.entries.first.audioStatus ==
              TexthookerLineAudioStatus.missing,
    );
    first = service.entries.first;
    expect(first.audioStatus, TexthookerLineAudioStatus.missing);
    expect(first.fallbackReason, kGalResourceNotPairedReason);
    expect(first.audioBackend, isNull);
    expect(
      service.entries.last.audioStatus,
      TexthookerLineAudioStatus.pending,
      reason: '最新一句还在自己的配对容差内',
    );

    // 资源晚落盘：收束过的行仍被升格成 matched。
    engine.resources[10000] = 'late-voice.xwma';
    await waitUntil(
      () =>
          service.entries.first.audioStatus ==
          TexthookerLineAudioStatus.matched,
    );
    first = service.entries.first;
    expect(first.audioStatus, TexthookerLineAudioStatus.matched);
    expect(first.audioBackend, 'game_resource');
    expect(first.audioResourceId, 'late-voice.xwma');
    expect(first.fallbackReason, isNull);

    await controller.close();
    endpoints.dispose();
  });
}

class _ResourceEngine extends EngineHookGalAudioSource {
  _ResourceEngine()
    : super(targetPid: 0, launchExe: 'fake.exe', injectorPath: 'fake.exe');

  final List<GalHookedLine> lines = <GalHookedLine>[];

  /// text timestamp → 资源 id；测试中途写入模拟资源晚落盘。
  final Map<int, String> resources = <int, String>{};

  int pollCalls = 0;

  @override
  int? get gamePid => 4242;

  @override
  bool get textHookReady => true;

  @override
  bool get rawVoiceReady => true;

  @override
  bool get pcmReady => false;

  @override
  Future<PcmFormat?> start() async => null;

  @override
  Future<bool> refreshReadiness() async => true;

  @override
  Future<GalTextPoll?> pollText(int sinceSeq) async {
    pollCalls++;
    return GalTextPoll(
      count: lines.length,
      lines: <GalHookedLine>[
        for (final GalHookedLine line in lines)
          if (line.seq > sinceSeq) line,
      ],
    );
  }

  @override
  Future<bool> selectTextThread(int? threadId) async => true;

  @override
  Future<GalAudioSlice?> grabUtterance(
    int tsMs, {
    int? sourcePtr,
    List<int>? exclude,
    int? endTsMs,
  }) async => null;

  @override
  Future<GalAudioSlice?> grabClipNear(
    int tsMs, {
    int tolMs = 8000,
    int? sourcePtr,
    List<int>? exclude,
    int? endTsMs,
  }) async => null;

  @override
  String? findPairedVoiceResourceId(
    int textTsMs, {
    int? textEventId,
    bool allowLatestSessionFallback = true,
  }) => resources[textTsMs];

  @override
  Future<Uint8List?> grabPairedVoiceBytes(
    int textTsMs, {
    required String outputExtension,
    int? textEventId,
    String? resourceId,
    bool allowLatestSessionFallback = true,
  }) async => null;

  @override
  Future<void> stop() async {}
}

class _SilentLoopback extends LoopbackGalAudioSource {
  @override
  Future<PcmFormat?> start() async => const PcmFormat(
    sampleRate: 44100,
    channels: 2,
    bitsPerSample: 16,
    isFloat: false,
  );

  @override
  Future<void> stop() async {}

  @override
  Future<GalAudioSlice?> grabRecent(int backMs) async => null;
}
