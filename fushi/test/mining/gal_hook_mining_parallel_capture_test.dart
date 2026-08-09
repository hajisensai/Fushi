import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_hook_mining_coordinator.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/immersion_mining_request.dart'
    show MiningAnimatedFormat, VideoMiningImageMode;
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/utils/misc/desktop_audio_clipper.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// BUG-1473 守卫：gal 场景卡的**画面捕获**与**语音抓取**必须并行。
///
/// 两者之间没有任何数据依赖，串行会让耗时直接相加。视频侧 BUG-1205 已经并行化，
/// 但 gal 走的是引擎的 `providedCoverBytes` / `providedAudioBytes` 分支——进引擎时
/// 两者都已经在这个协调器里串行做完了，引擎里的并行对 gal 完全是空转。
///
/// ⚠️ 判据只能是「**两条同时在途**」。单向挂住是假绿，这一点视频侧那条守卫
/// （`immersion_mining_parallel_test.dart`）已经用变异实测证过：
///   · 只挂音频、断言封面已开工 —— 串行版本来就是封面在前，恒真；
///   · 只挂封面、断言音频已开工 —— Future 一创建就同步跑到内部首个 await，也恒真。
/// 两边都挂住才对**两个方向**都确定性，且全 Completer 驱动、不看 wall-clock，不 flaky。
class _StubRepo extends BaseAnkiRepository {
  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async =>
      const MineOutcome.success(noteId: 1);

  @override
  Future<AnkiSettings> loadSettings() async => const AnkiSettings(
        fieldMappings: <String, String>{
          'Sentence': '{sentence}',
          'Image': '{card-image}',
          'SentenceAudio': '{sentence-audio}',
        },
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late TexthookerService service;
  late Directory testRoot;
  late GalHookSessionState activeState;

  setUp(() async {
    service = TexthookerService.test();
    testRoot = await Directory.systemTemp.createTemp('gal_parallel_');
    activeState = GalHookSessionState(
      phase: GalHookSessionPhase.running,
      externalWindowMode: true,
      boundWindow: const ExternalWindowInfo(
        hwnd: 901,
        pid: 88,
        title: 'Test game',
      ),
      sessionStartedAt: DateTime(2026, 8, 9, 12),
    );
  });

  tearDown(() async {
    if (testRoot.existsSync()) await testRoot.delete(recursive: true);
  });

  test('画面与语音真并行：两条必须同时在途（任一方向的串行都挂死）', () async {
    final Completer<void> gifStarted = Completer<void>();
    final Completer<void> gifRelease = Completer<void>();
    final Completer<void> audioStarted = Completer<void>();
    final Completer<void> audioRelease = Completer<void>();

    final TexthookerLineEntry line = service.appendLine(
      'こんにちは。',
      receivedAt: DateTime(2026, 8, 9, 12, 0, 1),
    )!;

    final GalHookMiningCoordinator subject = GalHookMiningCoordinator(
      textService: service,
      lineLookup: service.entryById,
      lineValidator: (_) => true,
      stateLoader: () => activeState,
      createTempDirectory: () async => testRoot,
      captureGif: ({
        required int hwnd,
        MiningAnimatedFormat format = MiningAnimatedFormat.gif,
      }) async {
        if (!gifStarted.isCompleted) gifStarted.complete();
        await gifRelease.future;
        return (bytes: Uint8List.fromList(<int>[71, 73, 70]), format: format);
      },
      captureStill: (int hwnd) async =>
          WindowCaptureResult(pngBytes: Uint8List.fromList(<int>[80, 78, 71])),
      captureAudio: ({
        required String lineId,
        required String sentence,
        required String outputExtension,
      }) async {
        if (!audioStarted.isCompleted) audioStarted.complete();
        await audioRelease.future;
        return Uint8List.fromList(<int>[1, 2, 3]);
      },
    );

    final Future<GalHookMiningResult> mining = subject.mineLine(
      lineId: line.id,
      fields: const <String, String>{'expression': 'こんにちは'},
      compression: MiningMediaCompression.compressed,
      repo: _StubRepo(),
      imageMode: VideoMiningImageMode.gif,
    );

    await gifStarted.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail('画面捕获从未开工'),
    );
    await audioStarted.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail('语音抓取在画面捕获完成前从未开工——两者又串行了'),
    );

    gifRelease.complete();
    audioRelease.complete();
    await mining;
  });
}
