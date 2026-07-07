import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki/src/mining/immersion_mining_engine.dart';
import 'package:hibiki/src/mining/immersion_mining_request.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart'
    show MiningMediaCompression, FfmpegFailureReporter;

class _FakeRepo implements BaseAnkiRepository {
  AnkiMiningContext? minedContext;
  int? updatedNoteId;

  @override
  Future<MineOutcome> mineEntry(
      {required String rawPayloadJson,
      required AnkiMiningContext context}) async {
    minedContext = context;
    return const MineOutcome.success(noteId: 42);
  }

  @override
  Future<MineOutcome> updateMinedNote(
      {required int noteId,
      required String rawPayloadJson,
      required AnkiMiningContext context}) async {
    updatedNoteId = noteId;
    minedContext = context;
    return const MineOutcome.success(noteId: 99);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('immersion_engine');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  ImmersionMiningEngine build(
          {required GifExtractor gif,
          required AudioExtractor audio,
          required FrameExtractor frame}) =>
      ImmersionMiningEngine(
          gifExtractor: gif, audioExtractor: audio, frameExtractor: frame);

  Future<String?> okGif(
          {required String inputPath,
          required int startMs,
          required int endMs,
          required String outputPath,
          int fps = 8,
          int width = 320,
          FfmpegFailureReporter? onFailure}) async =>
      outputPath;
  Future<String?> nullGif(
          {required String inputPath,
          required int startMs,
          required int endMs,
          required String outputPath,
          int fps = 8,
          int width = 320,
          FfmpegFailureReporter? onFailure}) async =>
      null;
  Future<String?> okAudio(
          {required String inputPath,
          required int startMs,
          required int endMs,
          required String outputPath,
          int? audioStreamIndex,
          int? audioStreamCount,
          FfmpegFailureReporter? onFailure,
          int audioChannels = 1,
          String audioBitrate = '64k'}) async =>
      outputPath;
  Future<String?> nullAudio(
          {required String inputPath,
          required int startMs,
          required int endMs,
          required String outputPath,
          int? audioStreamIndex,
          int? audioStreamCount,
          FfmpegFailureReporter? onFailure,
          int audioChannels = 1,
          String audioBitrate = '64k'}) async =>
      null;
  Future<String?> okFrame(
          {required String inputPath,
          required String outputPath,
          double atSeconds = 10.0,
          FfmpegFailureReporter? onFailure}) async =>
      outputPath;
  Future<String?> nullFrame(
          {required String inputPath,
          required String outputPath,
          double atSeconds = 10.0,
          FfmpegFailureReporter? onFailure}) async =>
      null;

  test('gif+audio success builds context and calls mineEntry', () async {
    final repo = _FakeRepo();
    final res = await build(gif: okGif, audio: okAudio, frame: okFrame).mine(
        const ImmersionMiningRequest(
            fields: {'expression': '走る'},
            mediaSource: '/fake/video.mp4',
            clipStartMs: 1000,
            clipEndMs: 3000,
            sentence: '走り出した。'),
        compression: MiningMediaCompression.compressed,
        tempDir: tmp.path,
        repo: repo);
    expect(res.aborted, false);
    expect(repo.minedContext!.sentence, '走り出した。');
    expect(repo.minedContext!.coverPath, endsWith('.gif'));
    expect(repo.minedContext!.sasayakiAudioPath,
        endsWith('immersion_audio.${immersionMiningAudioExtension()}'));
    expect(repo.minedContext!.source, AnkiMiningSource.video);
  });

  test('provided audio bytes use the platform-aware immersion audio filename',
      () async {
    final repo = _FakeRepo();
    await build(gif: nullGif, audio: nullAudio, frame: nullFrame).mine(
        ImmersionMiningRequest(
            fields: const {'expression': 'x'},
            clipStartMs: 0,
            clipEndMs: 0,
            sentence: 's',
            providedAudioBytes: Uint8List.fromList(<int>[1, 2, 3])),
        compression: MiningMediaCompression.compressed,
        tempDir: tmp.path,
        repo: repo);
    expect(repo.minedContext!.sasayakiAudioPath,
        endsWith('immersion_audio.${immersionMiningAudioExtension()}'));
  });

  test('gif fails -> frame fallback yields still cover', () async {
    final repo = _FakeRepo();
    final res = await build(gif: nullGif, audio: okAudio, frame: okFrame).mine(
        const ImmersionMiningRequest(
            fields: {'expression': 'x'},
            mediaSource: '/v.mp4',
            clipStartMs: 0,
            clipEndMs: 2000,
            sentence: 's'),
        compression: MiningMediaCompression.compressed,
        tempDir: tmp.path,
        repo: repo);
    expect(res.degradedToStill, true);
    expect(repo.minedContext!.coverPath, endsWith('.jpg'));
  });

  test('requireAudio && audio missing -> abort, no mine', () async {
    final repo = _FakeRepo();
    final res = await build(gif: okGif, audio: nullAudio, frame: nullFrame)
        .mine(
            const ImmersionMiningRequest(
                fields: {'expression': 'x'},
                mediaSource: '/v.mp4',
                clipStartMs: 0,
                clipEndMs: 2000,
                sentence: 's'),
            compression: MiningMediaCompression.compressed,
            tempDir: tmp.path,
            repo: repo);
    expect(res.aborted, true);
    expect(repo.minedContext, isNull);
  });

  test('requireAudio=false (netflix 2A) allows still-only card', () async {
    final repo = _FakeRepo();
    final res = await build(gif: nullGif, audio: nullAudio, frame: okFrame)
        .mine(
            const ImmersionMiningRequest(
                fields: {'expression': 'x'},
                mediaSource: '/v.mp4',
                clipStartMs: 0,
                clipEndMs: 2000,
                sentence: 's',
                requireAudio: false),
            compression: MiningMediaCompression.compressed,
            tempDir: tmp.path,
            repo: repo);
    expect(res.aborted, false);
    expect(repo.minedContext!.sasayakiAudioPath, isNull);
    expect(repo.minedContext!.coverPath, endsWith('.jpg'));
  });

  test('audioSource overrides mediaSource for audio extraction (youtube split)',
      () async {
    final repo = _FakeRepo();
    String? gifInput;
    String? audioInput;
    Future<String?> capGif(
        {required String inputPath,
        required int startMs,
        required int endMs,
        required String outputPath,
        int fps = 8,
        int width = 320,
        FfmpegFailureReporter? onFailure}) async {
      gifInput = inputPath;
      return outputPath;
    }

    Future<String?> capAudio(
        {required String inputPath,
        required int startMs,
        required int endMs,
        required String outputPath,
        int? audioStreamIndex,
        int? audioStreamCount,
        FfmpegFailureReporter? onFailure,
        int audioChannels = 1,
        String audioBitrate = '64k'}) async {
      audioInput = inputPath;
      return outputPath;
    }

    await build(gif: capGif, audio: capAudio, frame: okFrame).mine(
        const ImmersionMiningRequest(
            fields: {'expression': 'x'},
            mediaSource: 'https://video-only.example/v',
            audioSource: 'https://audio-only.example/a',
            clipStartMs: 0,
            clipEndMs: 2000,
            sentence: 's'),
        compression: MiningMediaCompression.compressed,
        tempDir: tmp.path,
        repo: repo);
    expect(gifInput, 'https://video-only.example/v'); // GIF 从视频流
    expect(audioInput, 'https://audio-only.example/a'); // 音频从独立音频流
  });

  test('updateNoteId routes to updateMinedNote', () async {
    final repo = _FakeRepo();
    await build(gif: okGif, audio: okAudio, frame: okFrame).mine(
        const ImmersionMiningRequest(
            fields: {'expression': 'x'},
            mediaSource: '/v.mp4',
            clipStartMs: 0,
            clipEndMs: 2000,
            sentence: 's',
            updateNoteId: 7),
        compression: MiningMediaCompression.compressed,
        tempDir: tmp.path,
        repo: repo);
    expect(repo.updatedNoteId, 7);
  });

  // TODO-1303：Netflix provided-bytes 路径（无 range）本应带音频却丢音轨 → 中止而非静默出
  // 无声卡。此前 requireAudio 被 `&& hasRange` 门控架空（Netflix clip 恒 hasRange=false），
  // 音频丢时永不中止 → 「制卡失败报成功」的无声/空壳卡。带回 abortReason 供远端写日志 + 回传。
  test('audio expected via provided cover but audio missing -> abort',
      () async {
    final repo = _FakeRepo();
    final res = await build(gif: nullGif, audio: nullAudio, frame: nullFrame)
        .mine(
            ImmersionMiningRequest(
                fields: const {'expression': 'x'},
                clipStartMs: 0,
                clipEndMs: 0,
                sentence: 's',
                providedCoverBytes: Uint8List.fromList(<int>[1, 2, 3]),
                providedCoverName: 'netflix_clip.gif',
                requireAudio: true),
            compression: MiningMediaCompression.compressed,
            tempDir: tmp.path,
            repo: repo);
    expect(res.aborted, true);
    expect(res.abortReason, contains('audio'));
    expect(repo.minedContext, isNull);
  });

  // TODO-1303：空壳卡兜底——封面 + 音频全无（截图/GIF/音频全失败）→ 中止，绝不产出无媒体卡，
  // 即便 requireAudio=false（这正是「降级空壳卡仍报成功」的根）。
  test('empty shell (no cover, no audio) -> abort', () async {
    final repo = _FakeRepo();
    final res = await build(gif: nullGif, audio: nullAudio, frame: nullFrame)
        .mine(
            const ImmersionMiningRequest(
                fields: {'expression': 'x'},
                clipStartMs: 0,
                clipEndMs: 0,
                sentence: 's',
                requireAudio: false),
            compression: MiningMediaCompression.compressed,
            tempDir: tmp.path,
            repo: repo);
    expect(res.aborted, true);
    expect(res.abortReason, contains('no cover'));
    expect(repo.minedContext, isNull);
  });
}
