import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_hook_mining_coordinator.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart'
    show MiningAnimatedFormat;
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart';

/// 反馈 U9k4hlYaNZ / EJhUrX_mHY：制卡曾是**一个**串行作业（采样 + 句音 + 编码 + 写卡），
/// 下一张卡的画面要等上一张卡写完才开始抓。现在采样与收尾是两条队列：
/// 采样不等收尾；收尾仍按采样顺序串行写卡。
///
/// 全部由 Completer 驱动，不看 wall-clock：旧实现下第二张卡的采样永远等不到，
/// `secondCaptured` 超时即红。
class _GatedRepo extends BaseAnkiRepository {
  _GatedRepo(this.firstWriteGate);

  final Completer<void> firstWriteGate;
  final Completer<void> firstWriteStarted = Completer<void>();
  final List<String> writtenSentences = <String>[];
  final List<Uint8List> covers = <Uint8List>[];
  int activeWrites = 0;
  int maxActiveWrites = 0;

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    activeWrites++;
    if (activeWrites > maxActiveWrites) maxActiveWrites = activeWrites;
    try {
      final String? coverPath = context.coverPath;
      if (coverPath != null) covers.add(File(coverPath).readAsBytesSync());
      if (!firstWriteStarted.isCompleted) {
        firstWriteStarted.complete();
        await firstWriteGate.future;
      }
      writtenSentences.add(context.sentence);
      return MineOutcome.success(noteId: 100 + writtenSentences.length);
    } finally {
      activeWrites--;
    }
  }

  @override
  Future<AnkiSettings> loadSettings() async => const AnkiSettings();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// ffmpeg 不可用 / 编码失败的后端：每次都返回非零退出码。
class _FailingFfmpegBackend implements FfmpegBackend {
  int runs = 0;

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    runs++;
    return const FfmpegRunResult(returnCode: 1, output: 'encoder missing');
  }

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) =>
      run(args, timeout);

  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) =>
      run(args, timeout);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TexthookerService service;
  late GalHookSessionState activeState;

  setUp(() {
    service = TexthookerService.test();
    service.foldProgressiveLines = false;
    activeState = GalHookSessionState(
      phase: GalHookSessionPhase.running,
      externalWindowMode: true,
      boundWindow: const ExternalWindowInfo(
        hwnd: 901,
        pid: 88,
        title: 'Test game',
      ),
      sessionStartedAt: DateTime(2026, 11, 4, 12),
    );
  });

  Future<Uint8List?> audio({
    required String lineId,
    required String sentence,
    required String outputExtension,
  }) async => Uint8List.fromList(<int>[7, 8, 9]);

  test('上一张卡还在写库时，下一张卡的画面立刻采样；写卡仍按采样顺序串行', () async {
    final TexthookerLineEntry first = service.appendLine('一句目。')!;
    final TexthookerLineEntry second = service.appendLine('二句目。')!;
    final Completer<void> firstWriteGate = Completer<void>();
    final _GatedRepo repo = _GatedRepo(firstWriteGate);
    final Completer<void> secondCaptured = Completer<void>();
    int captures = 0;

    final GalHookMiningCoordinator coordinator = GalHookMiningCoordinator(
      textService: service,
      lineLookup: service.entryById,
      lineValidator: (_) => true,
      stateLoader: () => activeState,
      captureAudio: audio,
      captureGif:
          ({
            required int hwnd,
            MiningAnimatedFormat format = MiningAnimatedFormat.gif,
          }) async {
            captures++;
            if (captures == 2) secondCaptured.complete();
            return (
              bytes: Uint8List.fromList(<int>[71, 73, 70, captures]),
              format: format,
            );
          },
      captureStill: (int hwnd) =>
          throw StateError('GIF succeeded; no still capture expected'),
    );

    final Future<GalHookMiningResult> firstCard = coordinator.mineLine(
      lineId: first.id,
      fields: const <String, String>{'expression': '一'},
      compression: MiningMediaCompression.compressed,
      repo: repo,
    );
    await repo.firstWriteStarted.future.timeout(const Duration(seconds: 10));

    final Future<GalHookMiningResult> secondCard = coordinator.mineLine(
      lineId: second.id,
      fields: const <String, String>{'expression': '二'},
      compression: MiningMediaCompression.compressed,
      repo: repo,
    );
    // 第一张卡的写库被挂住；第二张卡的画面必须照样被采到。
    await secondCaptured.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => fail('第二张卡的采样被第一张卡的写库挡住了'),
    );
    expect(repo.writtenSentences, isEmpty);

    firstWriteGate.complete();
    final List<GalHookMiningResult> results = await Future.wait(
      <Future<GalHookMiningResult>>[firstCard, secondCard],
    );

    expect(results.every((GalHookMiningResult r) => r.success), isTrue);
    expect(repo.writtenSentences, <String>[first.text, second.text]);
    expect(repo.maxActiveWrites, 1, reason: '收尾阶段仍是一条有序串行队列');
    expect(repo.covers, hasLength(2));
    expect(repo.covers[0].last, 1, reason: '每张卡的画面属于它自己的采样');
    expect(repo.covers[1].last, 2);
  });

  group('生产动图路径', () {
    const MethodChannel channel = MethodChannel(
      'app.fushi.reader/window_capture',
    );
    late _FailingFfmpegBackend backend;
    late int windowCaptures;

    setUp(() {
      backend = _FailingFfmpegBackend();
      setFfmpegBackendForTesting(backend);
      windowCaptures = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            if (call.method != 'captureWindow') return null;
            windowCaptures++;
            // 每帧字节带上帧号，便于认出进卡的是哪一帧。
            return <Object?, Object?>{
              'pngBytes': Uint8List.fromList(<int>[
                0x89,
                0x50,
                0x4E,
                0x47,
                windowCaptures,
              ]),
            };
          });
    });

    tearDown(() {
      setFfmpegBackendForTesting(null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('收尾编码失败时用采样到的第一帧降级静图，不在收尾时重抓窗口', () async {
      final TexthookerLineEntry line = service.appendLine('動画が作れない。')!;
      final Completer<void> gate = Completer<void>()..complete();
      final _GatedRepo repo = _GatedRepo(gate);
      int stillCaptures = 0;

      final GalHookMiningCoordinator coordinator = GalHookMiningCoordinator(
        textService: service,
        lineLookup: service.entryById,
        lineValidator: (_) => true,
        stateLoader: () => activeState,
        captureAudio: audio,
        // 不注入 captureGif：走生产采样 + 收尾编码。
        captureStill: (int hwnd) async {
          stillCaptures++;
          return WindowCaptureResult(
            pngBytes: Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 0xFF]),
          );
        },
      );

      final GalHookMiningResult result = await coordinator.mineLine(
        lineId: line.id,
        fields: const <String, String>{'expression': '動画'},
        compression: MiningMediaCompression.compressed,
        repo: repo,
      );

      expect(result.success, isTrue);
      expect(result.degradedToStill, isTrue);
      expect(backend.runs, greaterThan(0), reason: '确实进了编码');
      final int sampled = windowCaptures;
      expect(sampled, greaterThanOrEqualTo(2));
      expect(stillCaptures, 0, reason: '编码失败后不得重抓当前窗口');
      expect(
        repo.covers.single,
        Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 1]),
        reason: '进卡的是采样时的第一帧',
      );
    });
  });
}
