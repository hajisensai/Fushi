import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_hook_mining_coordinator.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_window_video.dart';
import 'package:fushi/src/mining/immersion_mining_request.dart'
    show MiningAnimatedFormat, VideoMiningImageMode;
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/utils/misc/desktop_audio_clipper.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// galgame「视频片段」模式的协调器契约：先等语音播完再导出录制帧（片段终点必须在
/// 语音之后、音频要混流）、区间按台词 hook 时间戳 - 300ms 起算、无时间戳时导出整环由
/// 编码器倒推、片段失败按动图 → 静图降级并分别打标。录制导出与编码器全部注入假件。
class _RecordingRepo extends BaseAnkiRepository {
  final List<AnkiMiningContext> contexts = <AnkiMiningContext>[];

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    jsonDecode(rawPayloadJson);
    contexts.add(context);
    return MineOutcome.success(noteId: 100 + contexts.length);
  }

  @override
  Future<AnkiSettings> loadSettings() async => const AnkiSettings();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ExportCall {
  const _ExportCall(this.fromTickMs, this.toTickMs);
  final int fromTickMs;
  final int toTickMs;
}

class _BuildCall {
  const _BuildCall(this.fromTickMs, this.toTickMs, this.audioBytes);
  final int? fromTickMs;
  final int toTickMs;
  final Uint8List? audioBytes;
}

void main() {
  late TexthookerService service;
  late GalHookSessionState activeState;
  late List<String> events;
  late List<_ExportCall> exportCalls;
  late List<_BuildCall> buildCalls;

  setUp(() {
    service = TexthookerService.test();
    events = <String>[];
    exportCalls = <_ExportCall>[];
    buildCalls = <_BuildCall>[];
    activeState = GalHookSessionState(
      phase: GalHookSessionPhase.running,
      externalWindowMode: true,
      boundWindow: const ExternalWindowInfo(
        hwnd: 901,
        pid: 88,
        title: 'Test game',
      ),
      sessionStartedAt: DateTime(2026, 7, 20, 12),
    );
  });

  final Uint8List mp4Bytes = Uint8List.fromList(<int>[
    0,
    0,
    0,
    0x18,
    0x66,
    0x74,
    0x79,
    0x70,
  ]);

  GalHookMiningCoordinator coordinator({
    int? lineTimestampMs,
    // 逐行时间戳（历史行制卡要靠下一行的时间戳定片段终点）。给了就按 id 查，
    // 没给就退回单值 [lineTimestampMs]，既有用例一字不用改。
    Map<String, int>? lineTimestamps,
    Duration audioDelay = const Duration(milliseconds: 20),
    Uint8List? audioBytes,
    bool clipSucceeds = true,
    bool gifSucceeds = true,
  }) =>
      GalHookMiningCoordinator(
        textService: service,
        lineLookup: service.entryById,
        lineValidator: (_) => true,
        stateLoader: () => activeState,
        lineTimestampLookup: (String lineId) =>
            lineTimestamps?[lineId] ?? lineTimestampMs,
        captureAudio: ({
          required String lineId,
          required String sentence,
          required String outputExtension,
        }) async {
          await Future<void>.delayed(audioDelay);
          events.add('audio');
          return audioBytes ?? Uint8List.fromList(<int>[7, 8, 9]);
        },
        exportRecording: ({
          required int fromTickMs,
          required int toTickMs,
          required String directory,
        }) async {
          events.add('export');
          exportCalls.add(_ExportCall(fromTickMs, toTickMs));
          expect(
            Directory(directory).existsSync(),
            isTrue,
            reason: '导出目录必须先于导出创建',
          );
          return WindowRecordingExport(
            frames: <WindowRecordingFrame>[
              WindowRecordingFrame(path: '$directory/f0.jpg', tickMs: 1),
              WindowRecordingFrame(path: '$directory/f1.jpg', tickMs: 2),
            ],
            nowTickMs: 10000,
          );
        },
        buildVideoClip: ({
          required WindowRecordingExport export,
          required int? fromTickMs,
          required int toTickMs,
          Uint8List? audioBytes,
          required String audioExtension,
          required Directory workDir,
        }) async {
          events.add('build');
          buildCalls.add(_BuildCall(fromTickMs, toTickMs, audioBytes));
          expect(audioExtension, isNotEmpty);
          return clipSucceeds ? (bytes: mp4Bytes, extension: 'mp4') : null;
        },
        captureGif: ({
          required int hwnd,
          MiningAnimatedFormat format = MiningAnimatedFormat.gif,
        }) async {
          events.add('gif');
          return gifSucceeds
              ? (bytes: Uint8List.fromList(<int>[71, 73, 70]), format: format)
              : null;
        },
        captureStill: (int hwnd) async {
          events.add('still');
          return WindowCaptureResult(
            pngBytes: Uint8List.fromList(<int>[80, 78, 71]),
          );
        },
      );

  Future<GalHookMiningResult> mine(
    GalHookMiningCoordinator subject,
    TexthookerLineEntry entry,
    _RecordingRepo repo,
  ) =>
      subject.mineLine(
        lineId: entry.id,
        fields: const <String, String>{'expression': '台詞'},
        compression: MiningMediaCompression.compressed,
        repo: repo,
        imageMode: VideoMiningImageMode.videoClip,
      );

  test('视频片段：先等语音播完再导出录制帧，音频混流进编码器，封面落 .mp4', () async {
    final TexthookerLineEntry entry = service.appendLine('録画の台詞')!;
    final _RecordingRepo repo = _RecordingRepo();
    final Uint8List audio = Uint8List.fromList(<int>[1, 2, 3, 4]);

    final GalHookMiningResult result = await mine(
      coordinator(lineTimestampMs: 5000, audioBytes: audio),
      entry,
      repo,
    );

    expect(result.success, isTrue);
    expect(
        events,
        <String>[
          'audio',
          'export',
          'build',
        ],
        reason: '片段终点必须在语音播完之后，导出不能先于音频返回');
    expect(repo.contexts.single.coverPath, endsWith('external_window.mp4'));
    expect(repo.contexts.single.sentenceAudioPath, isNotNull);
    expect(buildCalls.single.audioBytes, audio);
    expect(result.degradedToAnimated, isFalse);
    expect(result.degradedToStill, isFalse);
  });

  test('有 hook 时间戳：导出区间从 台词 - 300ms 起，到「现在」（toTickMs 0）', () async {
    final TexthookerLineEntry entry = service.appendLine('区間の台詞')!;
    await mine(coordinator(lineTimestampMs: 5000), entry, _RecordingRepo());

    expect(exportCalls.single.fromTickMs, 5000 - kGalWindowVideoLeadMs);
    expect(exportCalls.single.toTickMs, 0);
    expect(buildCalls.single.fromTickMs, 5000 - kGalWindowVideoLeadMs);
    expect(buildCalls.single.toTickMs, 0);
  });

  test('制卡历史行：片段在下一行出现的那一刻收尾，不是「现在」', () async {
    final TexthookerLineEntry first = service.appendLine('前の台詞')!;
    final TexthookerLineEntry second = service.appendLine('今の台詞')!;
    await mine(
      coordinator(lineTimestamps: <String, int>{
        first.id: 5000,
        second.id: 9000,
      }),
      first,
      _RecordingRepo(),
    );

    expect(exportCalls.single.fromTickMs, 5000 - kGalWindowVideoLeadMs);
    expect(
      exportCalls.single.toTickMs,
      9000,
      reason: '用 0（=现在）会把从那句到现在的所有后续台词画面全拼进 mp4，'
          '用户拿到一段跑马灯而不是那句话的画面',
    );
    expect(buildCalls.single.toTickMs, 9000);
  });

  test('制卡当前行仍录到「现在」（Never break）', () async {
    final TexthookerLineEntry first = service.appendLine('前の台詞')!;
    final TexthookerLineEntry latest = service.appendLine('今の台詞')!;
    await mine(
      coordinator(lineTimestamps: <String, int>{
        first.id: 5000,
        latest.id: 9000,
      }),
      latest,
      _RecordingRepo(),
    );
    expect(exportCalls.single.toTickMs, 0);
  });

  test('下一行没有时间戳 → 退回「现在」，不因为算不出终点就不出片段', () async {
    final TexthookerLineEntry first = service.appendLine('前の台詞')!;
    service.appendLine('今の台詞');
    await mine(
      coordinator(lineTimestamps: <String, int>{first.id: 5000}),
      first,
      _RecordingRepo(),
    );
    expect(exportCalls.single.toTickMs, 0);
  });

  test('时间戳很小不会算成负起点', () async {
    final TexthookerLineEntry entry = service.appendLine('起動直後')!;
    await mine(coordinator(lineTimestampMs: 100), entry, _RecordingRepo());
    expect(exportCalls.single.fromTickMs, 0);
    expect(buildCalls.single.fromTickMs, 0);
  });

  test('无 hook 时间戳：导出整个录制环，起点交编码器按音频时长倒推（fromTickMs null）', () async {
    final TexthookerLineEntry entry = service.appendLine('時刻なし')!;
    await mine(coordinator(lineTimestampMs: null), entry, _RecordingRepo());
    expect(exportCalls.single.fromTickMs, 0);
    expect(buildCalls.single.fromTickMs, isNull);
  });

  test('片段失败 → 退回动图并置 degradedToAnimated（不置 degradedToStill）', () async {
    final TexthookerLineEntry entry = service.appendLine('降格→動画')!;
    final _RecordingRepo repo = _RecordingRepo();
    final GalHookMiningResult result = await mine(
      coordinator(lineTimestampMs: 5000, clipSucceeds: false),
      entry,
      repo,
    );

    expect(result.success, isTrue);
    expect(events, <String>['audio', 'export', 'build', 'gif']);
    expect(repo.contexts.single.coverPath, endsWith('.gif'));
    expect(result.degradedToAnimated, isTrue);
    expect(result.degradedToStill, isFalse);
  });

  test('片段与动图都失败 → 静图并置 degradedToStill（不置 degradedToAnimated）', () async {
    final TexthookerLineEntry entry = service.appendLine('降格→静止画')!;
    final _RecordingRepo repo = _RecordingRepo();
    final GalHookMiningResult result = await mine(
      coordinator(
        lineTimestampMs: 5000,
        clipSucceeds: false,
        gifSucceeds: false,
      ),
      entry,
      repo,
    );

    expect(result.success, isTrue);
    expect(events, <String>['audio', 'export', 'build', 'gif', 'still']);
    expect(repo.contexts.single.coverPath, endsWith('.png'));
    expect(result.degradedToStill, isTrue);
    expect(result.degradedToAnimated, isFalse);
  });

  test('导出抛异常 → fail-open 降级动图，不让制卡整体失败', () async {
    final TexthookerLineEntry entry = service.appendLine('導出例外')!;
    final _RecordingRepo repo = _RecordingRepo();
    final GalHookMiningCoordinator subject = GalHookMiningCoordinator(
      textService: service,
      lineLookup: service.entryById,
      lineValidator: (_) => true,
      stateLoader: () => activeState,
      lineTimestampLookup: (_) => 5000,
      captureAudio: ({
        required String lineId,
        required String sentence,
        required String outputExtension,
      }) async =>
          Uint8List.fromList(<int>[7]),
      exportRecording: ({
        required int fromTickMs,
        required int toTickMs,
        required String directory,
      }) async =>
          throw StateError('recorder unavailable'),
      captureGif: ({
        required int hwnd,
        MiningAnimatedFormat format = MiningAnimatedFormat.gif,
      }) async =>
          (bytes: Uint8List.fromList(<int>[71, 73, 70]), format: format),
      captureStill: (int hwnd) async =>
          WindowCaptureResult(pngBytes: Uint8List.fromList(<int>[80, 78, 71])),
    );
    final GalHookMiningResult result = await mine(subject, entry, repo);
    expect(result.success, isTrue);
    expect(result.degradedToAnimated, isTrue);
    expect(repo.contexts.single.coverPath, endsWith('.gif'));
  });

  test('非视频片段模式不碰录制导出（Never break）', () async {
    final TexthookerLineEntry entry = service.appendLine('GIF のまま')!;
    final GalHookMiningResult result =
        await coordinator(lineTimestampMs: 5000).mineLine(
      lineId: entry.id,
      fields: const <String, String>{'expression': '台詞'},
      compression: MiningMediaCompression.compressed,
      repo: _RecordingRepo(),
      imageMode: VideoMiningImageMode.gif,
    );
    expect(result.success, isTrue);
    expect(exportCalls, isEmpty);
    expect(buildCalls, isEmpty);
    expect(result.degradedToAnimated, isFalse);
  });
}
