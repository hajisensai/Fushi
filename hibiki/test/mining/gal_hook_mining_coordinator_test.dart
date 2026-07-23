import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/gal_hook_mining_coordinator.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

class _RecordingRepo extends BaseAnkiRepository {
  _RecordingRepo({
    this.settings = const AnkiSettings(),
    this.delay = Duration.zero,
  });

  final AnkiSettings settings;
  final Duration delay;
  final List<Map<String, Object?>> payloads = <Map<String, Object?>>[];
  final List<AnkiMiningContext> contexts = <AnkiMiningContext>[];
  final List<int> updatedNoteIds = <int>[];
  int activeCalls = 0;
  int maxActiveCalls = 0;

  Future<MineOutcome> _record(
    String rawPayloadJson,
    AnkiMiningContext context,
  ) async {
    activeCalls++;
    if (activeCalls > maxActiveCalls) maxActiveCalls = activeCalls;
    try {
      if (delay != Duration.zero) await Future<void>.delayed(delay);
      payloads.add(
        (jsonDecode(rawPayloadJson) as Map<Object?, Object?>)
            .cast<String, Object?>(),
      );
      contexts.add(context);
      return MineOutcome.success(noteId: 100 + contexts.length);
    } finally {
      activeCalls--;
    }
  }

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) =>
      _record(rawPayloadJson, context);

  @override
  Future<MineOutcome> updateMinedNote({
    required int noteId,
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) {
    updatedNoteIds.add(noteId);
    return _record(rawPayloadJson, context);
  }

  @override
  Future<AnkiSettings> loadSettings() async => settings;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late TexthookerService service;
  late Directory testRoot;
  late GalHookSessionState activeState;

  setUp(() async {
    service = TexthookerService.test();
    testRoot = await Directory.systemTemp.createTemp('gal_hook_coordinator_');
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

  tearDown(() async {
    if (testRoot.existsSync()) await testRoot.delete(recursive: true);
  });

  GalHookMiningCoordinator coordinator({
    required bool Function(TexthookerLineEntry entry) validator,
    Future<Uint8List?> Function({
      required String lineId,
      required String sentence,
      required String outputExtension,
    })? audio,
    Future<Uint8List?> Function({required int hwnd})? gif,
    Future<WindowCaptureResult> Function(int hwnd)? still,
    Future<Directory> Function()? tempFactory,
  }) =>
      GalHookMiningCoordinator(
        textService: service,
        lineLookup: service.entryById,
        lineValidator: validator,
        stateLoader: () => activeState,
        captureAudio: audio ??
            ({
              required String lineId,
              required String sentence,
              required String outputExtension,
            }) async =>
                Uint8List.fromList(<int>[7, 8, 9]),
        captureGif: gif ??
            ({required int hwnd}) async =>
                Uint8List.fromList(<int>[71, 73, 70]),
        captureStill: still ??
            (int hwnd) async => WindowCaptureResult(
                  pngBytes: Uint8List.fromList(<int>[80, 78, 71]),
                ),
        createTempDirectory: tempFactory,
      );

  test('exact duplicate lines keep distinct scene and audio context', () async {
    final DateTime now = DateTime(2026, 7, 20, 12, 0, 1);
    final TexthookerLineEntry first = service.appendLine(
      '同じ台詞',
      receivedAt: now,
    )!;
    final TexthookerLineEntry second = service.appendLine(
      '同じ台詞',
      receivedAt: now.add(const Duration(milliseconds: 1)),
    )!;
    final List<String> audioLineIds = <String>[];
    final _RecordingRepo repo = _RecordingRepo(
      settings: const AnkiSettings(fieldMappings: <String, String>{
        'Sentence': '{sentence}',
        'Image': '{card-image}',
        'SentenceAudio': '{sentence-audio}',
        'Audio': '{audio}',
      }),
    );
    final GalHookMiningCoordinator subject = coordinator(
      validator: (_) => true,
      audio: ({
        required String lineId,
        required String sentence,
        required String outputExtension,
      }) async {
        audioLineIds.add(lineId);
        return Uint8List.fromList(<int>[audioLineIds.length]);
      },
    );

    final GalHookMiningResult firstResult = await subject.mineLine(
      lineId: first.id,
      fields: const <String, String>{
        'expression': '同じ',
        'audio': '[sound:word.mp3]',
        'image': '<img src="dictionary.jpg">',
      },
      compression: MiningMediaCompression.compressed,
      repo: repo,
    );
    final GalHookMiningResult secondResult = await subject.mineLine(
      lineId: second.id,
      fields: const <String, String>{'expression': '台詞'},
      compression: MiningMediaCompression.highFidelity,
      repo: repo,
      updateNoteId: 731,
    );

    expect(firstResult.success, isTrue);
    expect(secondResult.success, isTrue);
    expect(audioLineIds, <String>[first.id, second.id]);
    expect(repo.contexts.map((AnkiMiningContext c) => c.sentence),
        <String>['同じ台詞', '同じ台詞']);
    expect(repo.updatedNoteIds, <int>[731]);
    expect(repo.payloads.first['audio'], '[sound:word.mp3]');
    expect(repo.payloads.first['image'], '<img src="dictionary.jpg">');
    expect(firstResult.unmappedTokens, isEmpty);
  });

  test('GIF failure falls back to PNG and both failures abort', () async {
    final TexthookerLineEntry entry = service.appendLine('画面付き台詞')!;
    final _RecordingRepo pngRepo = _RecordingRepo();
    final GalHookMiningResult pngResult = await coordinator(
      validator: (_) => true,
      gif: ({required int hwnd}) async => null,
    ).mineLine(
      lineId: entry.id,
      fields: const <String, String>{'expression': '画面'},
      compression: MiningMediaCompression.compressed,
      repo: pngRepo,
    );

    expect(pngResult.success, isTrue);
    expect(pngResult.degradedToStill, isTrue);
    expect(pngRepo.contexts.single.coverPath, endsWith('.png'));

    final _RecordingRepo failedRepo = _RecordingRepo();
    final GalHookMiningResult failed = await coordinator(
      validator: (_) => true,
      gif: ({required int hwnd}) async => null,
      still: (int hwnd) async =>
          const WindowCaptureResult(error: 'window disappeared'),
    ).mineLine(
      lineId: entry.id,
      fields: const <String, String>{'expression': '画面'},
      compression: MiningMediaCompression.compressed,
      repo: failedRepo,
    );

    expect(failed.aborted, isTrue);
    expect(failed.failureReason, 'window disappeared');
    expect(failedRepo.contexts, isEmpty);
  });

  test('expired line is rejected before scene or audio capture', () async {
    final TexthookerLineEntry entry = service.appendLine('过期台词')!;
    int gifCalls = 0;
    int audioCalls = 0;
    final GalHookMiningResult result = await coordinator(
      validator: (_) => false,
      gif: ({required int hwnd}) async {
        gifCalls++;
        return Uint8List(0);
      },
      audio: ({
        required String lineId,
        required String sentence,
        required String outputExtension,
      }) async {
        audioCalls++;
        return Uint8List(0);
      },
    ).mineLine(
      lineId: entry.id,
      fields: const <String, String>{'expression': '过期'},
      compression: MiningMediaCompression.compressed,
      repo: _RecordingRepo(),
    );

    expect(result.aborted, isTrue);
    expect(result.failureReason, contains('no longer available'));
    expect(gifCalls, 0);
    expect(audioCalls, 0);
  });

  test('missing sentence audio still creates the scene card with warning state',
      () async {
    final TexthookerLineEntry entry = service.appendLine('无句音也保留画面')!;
    final _RecordingRepo repo = _RecordingRepo(
      settings: const AnkiSettings(
        fieldMappings: <String, String>{'Expression': '{expression}'},
      ),
    );
    final GalHookMiningResult result = await coordinator(
      validator: (_) => true,
      audio: ({
        required String lineId,
        required String sentence,
        required String outputExtension,
      }) async =>
          null,
    ).mineLine(
      lineId: entry.id,
      fields: const <String, String>{'expression': '句音'},
      compression: MiningMediaCompression.compressed,
      repo: repo,
    );

    expect(result.success, isTrue);
    expect(result.sentenceAudioMissing, isTrue);
    expect(repo.contexts.single.sasayakiAudioPath, isNull);
    expect(result.unmappedTokens,
        containsAll(<String>['{sentence}', '{card-image}', '{audio}']));
    expect(result.unmappedTokens, isNot(contains('{sentence-audio}')),
        reason: 'there is no sentence-audio media to map for this card');
  });

  test('legacy {book-cover}/{sasayaki-audio} aliases are not reported missing',
      () async {
    // TODO-1298 改名前建的 Lapis 卡组持久化里 Picture 仍是 {book-cover}、
    // SentenceAudio 仍是 {sasayaki-audio}（都渲染同一媒体）。诊断必须认这些别名，
    // 否则误报「缺少游戏卡片字段: {card-image}」，尽管画面/句音其实已通过别名落卡。
    final TexthookerLineEntry entry = service.appendLine('旧别名映射台词')!;
    final _RecordingRepo repo = _RecordingRepo(
      settings: const AnkiSettings(fieldMappings: <String, String>{
        'Sentence': '{sentence}',
        'Picture': '{book-cover}',
        'SentenceAudio': '{sasayaki-audio}',
        'Audio': '{audio}',
      }),
    );
    final GalHookMiningResult result = await coordinator(
      validator: (_) => true,
      audio: ({
        required String lineId,
        required String sentence,
        required String outputExtension,
      }) async =>
          Uint8List.fromList(<int>[1]),
    ).mineLine(
      lineId: entry.id,
      fields: const <String, String>{'expression': '别名'},
      compression: MiningMediaCompression.compressed,
      repo: repo,
    );

    expect(result.success, isTrue);
    expect(result.unmappedTokens, isEmpty,
        reason: '{book-cover} 是 {card-image} 的别名，不该报缺游戏卡片字段');
  });

  test('制卡历史行标注 staleScene，制卡当前最新行不标（BUG-955 ②）', () async {
    final TexthookerLineEntry older = service.appendLine('古い台詞')!;
    final TexthookerLineEntry newer = service.appendLine('最新の台詞')!;
    final GalHookMiningCoordinator subject =
        coordinator(validator: (_) => true);

    final GalHookMiningResult historical = await subject.mineLine(
      lineId: older.id,
      fields: const <String, String>{'expression': '古い'},
      compression: MiningMediaCompression.compressed,
      repo: _RecordingRepo(),
    );
    expect(historical.staleScene, isTrue, reason: '历史行的画面无法重建，当前帧只能标注为可能不对应');

    final GalHookMiningResult live = await subject.mineLine(
      lineId: newer.id,
      fields: const <String, String>{'expression': '最新'},
      compression: MiningMediaCompression.compressed,
      repo: _RecordingRepo(),
    );
    expect(live.staleScene, isFalse, reason: '制卡当前最新行时，当前帧就是该台词的画面');
  });

  test('resource-only mode rejects a card when sentence audio is missing',
      () async {
    activeState = activeState.copyWith(allowAudioFallback: false);
    final TexthookerLineEntry entry = service.appendLine('必须匹配资源音频')!;
    final _RecordingRepo repo = _RecordingRepo();

    final GalHookMiningResult result = await coordinator(
      validator: (_) => true,
      audio: ({
        required String lineId,
        required String sentence,
        required String outputExtension,
      }) async =>
          null,
    ).mineLine(
      lineId: entry.id,
      fields: const <String, String>{'expression': '资源音频'},
      compression: MiningMediaCompression.compressed,
      repo: repo,
    );

    expect(result.aborted, isTrue);
    expect(result.audioFallbackDisabled, isTrue);
    expect(result.sentenceAudioMissing, isTrue);
    expect(repo.contexts, isEmpty);
  });

  test('concurrent jobs serialize and use isolated temporary directories',
      () async {
    final TexthookerLineEntry first = service.appendLine('第一句')!;
    final TexthookerLineEntry second = service.appendLine('第二句')!;
    final List<Directory> directories = <Directory>[];
    final _RecordingRepo repo = _RecordingRepo(
      delay: const Duration(milliseconds: 20),
    );
    final GalHookMiningCoordinator subject = coordinator(
      validator: (_) => true,
      tempFactory: () async {
        final Directory dir = await Directory(
          '${testRoot.path}${Platform.pathSeparator}job_${directories.length}',
        ).create();
        directories.add(dir);
        return dir;
      },
    );

    final List<GalHookMiningResult> results = await Future.wait(
      <Future<GalHookMiningResult>>[
        subject.mineLine(
          lineId: first.id,
          fields: const <String, String>{'expression': '一'},
          compression: MiningMediaCompression.compressed,
          repo: repo,
        ),
        subject.mineLine(
          lineId: second.id,
          fields: const <String, String>{'expression': '二'},
          compression: MiningMediaCompression.compressed,
          repo: repo,
        ),
      ],
    );

    expect(
        results.every((GalHookMiningResult result) => result.success), isTrue);
    expect(repo.maxActiveCalls, 1);
    expect(directories, hasLength(2));
    expect(directories[0].path, isNot(directories[1].path));
    expect(directories.every((Directory dir) => !dir.existsSync()), isTrue);
  });
}
