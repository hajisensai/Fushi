import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi/src/mining/immersion_mining_engine.dart';
import 'package:fushi/src/mining/immersion_mining_request.dart';
import 'package:fushi/src/utils/misc/desktop_audio_clipper.dart'
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
          required FrameExtractor frame,
          RemoteAudioMaterializer? materializer}) =>
      ImmersionMiningEngine(
          gifExtractor: gif,
          audioExtractor: audio,
          frameExtractor: frame,
          audioMaterializer: materializer);

  Future<String?> okGif(
          {required String inputPath,
          required int startMs,
          required int endMs,
          required String outputPath,
          int fps = 8,
          int width = 320,
          MiningAnimatedFormat format = MiningAnimatedFormat.gif,
          bool diagnosticOnly = false,
          FfmpegFailureReporter? onFailure,
          String? tlsPinSha256}) async =>
      outputPath;
  Future<String?> nullGif(
          {required String inputPath,
          required int startMs,
          required int endMs,
          required String outputPath,
          int fps = 8,
          int width = 320,
          MiningAnimatedFormat format = MiningAnimatedFormat.gif,
          bool diagnosticOnly = false,
          FfmpegFailureReporter? onFailure,
          String? tlsPinSha256}) async =>
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
          String audioBitrate = '64k',
          String? tlsPinSha256}) async =>
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
          String audioBitrate = '64k',
          String? tlsPinSha256}) async =>
      null;
  Future<String?> okFrame(
          {required String inputPath,
          required String outputPath,
          double atSeconds = 10.0,
          FfmpegFailureReporter? onFailure,
          String? tlsPinSha256}) async =>
      outputPath;
  Future<String?> nullFrame(
          {required String inputPath,
          required String outputPath,
          double atSeconds = 10.0,
          FfmpegFailureReporter? onFailure,
          String? tlsPinSha256}) async =>
      null;

  test('gif+audio success builds context and calls mineEntry', () async {
    final repo = _FakeRepo();
    final res = await build(gif: okGif, audio: okAudio, frame: okFrame).mine(
        const ImmersionMiningRequest(
            source: AnkiMiningSource.video,
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
    expect(repo.minedContext!.sentenceAudioPath,
        endsWith('immersion_audio.${immersionMiningAudioExtension()}'));
    expect(repo.minedContext!.source, AnkiMiningSource.video);
  });

  test('BUG-1004 remoteAudioClipper 命中远端流 → 用 host 端裁产物、不调 ffmpeg 音频抽取',
      () async {
    final repo = _FakeRepo();
    bool audioCalled = false;
    bool clipperCalled = false;
    Future<String?> trackingAudio(
        {required String inputPath,
        required int startMs,
        required int endMs,
        required String outputPath,
        int? audioStreamIndex,
        int? audioStreamCount,
        FfmpegFailureReporter? onFailure,
        int audioChannels = 1,
        String audioBitrate = '64k',
        String? tlsPinSha256}) async {
      audioCalled = true;
      return outputPath;
    }

    final res =
        await build(gif: okGif, audio: trackingAudio, frame: okFrame).mine(
            ImmersionMiningRequest(
              source: AnkiMiningSource.video,
              fields: const {'expression': '走る'},
              // 互联 host 自签 https 流：client ffmpeg 打不开，改走 host 端裁。
              mediaSource:
                  'https://host.example:38765/api/library/videos/v/stream?token=x',
              clipStartMs: 1000,
              clipEndMs: 3000,
              sentence: '走り出した。',
              remoteAudioClipper: ({
                required int startMs,
                required int endMs,
                required String outputPath,
              }) async {
                clipperCalled = true;
                expect(startMs, 1000);
                expect(endMs, 3000);
                return outputPath;
              },
            ),
            compression: MiningMediaCompression.compressed,
            tempDir: tmp.path,
            repo: repo);
    expect(res.aborted, false);
    expect(clipperCalled, true, reason: 'host 端裁切器应被调用');
    expect(audioCalled, false, reason: 'host 端裁命中后不得再对远端 URL 跑 ffmpeg 抽取');
    expect(repo.minedContext!.sentenceAudioPath,
        endsWith('immersion_audio_host.aac'));
  });

  test('BUG-1004 remoteAudioClipper 返回 null → 回退 ffmpeg-over-URL 抽取', () async {
    final repo = _FakeRepo();
    bool audioCalled = false;
    Future<String?> trackingAudio(
        {required String inputPath,
        required int startMs,
        required int endMs,
        required String outputPath,
        int? audioStreamIndex,
        int? audioStreamCount,
        FfmpegFailureReporter? onFailure,
        int audioChannels = 1,
        String audioBitrate = '64k',
        String? tlsPinSha256}) async {
      audioCalled = true;
      return outputPath;
    }

    final res =
        await build(gif: okGif, audio: trackingAudio, frame: okFrame).mine(
            ImmersionMiningRequest(
              source: AnkiMiningSource.video,
              fields: const {'expression': '走る'},
              mediaSource:
                  'https://host.example:38765/api/library/videos/v/stream?token=x',
              clipStartMs: 1000,
              clipEndMs: 3000,
              sentence: '走り出した。',
              // 老 host 无 clipaudio 端点 / 网络失败：裁切器返 null。
              remoteAudioClipper: ({
                required int startMs,
                required int endMs,
                required String outputPath,
              }) async =>
                  null,
            ),
            compression: MiningMediaCompression.compressed,
            tempDir: tmp.path,
            repo: repo);
    expect(res.aborted, false);
    expect(audioCalled, true,
        reason: 'host 端裁返 null 后必须回退直连 ffmpeg 抽取（Never break userspace）');
    expect(repo.minedContext!.sentenceAudioPath,
        endsWith('immersion_audio.${immersionMiningAudioExtension()}'));
  });

  test('provided audio bytes use the platform-aware immersion audio filename',
      () async {
    final repo = _FakeRepo();
    await build(gif: nullGif, audio: nullAudio, frame: nullFrame).mine(
        ImmersionMiningRequest(
            source: AnkiMiningSource.video,
            fields: const {'expression': 'x'},
            clipStartMs: 0,
            clipEndMs: 0,
            sentence: 's',
            providedAudioBytes: Uint8List.fromList(<int>[1, 2, 3])),
        compression: MiningMediaCompression.compressed,
        tempDir: tmp.path,
        repo: repo);
    expect(repo.minedContext!.sentenceAudioPath,
        endsWith('immersion_audio.${immersionMiningAudioExtension()}'));
  });

  test('gif fails -> frame fallback yields still cover', () async {
    final repo = _FakeRepo();
    final res = await build(gif: nullGif, audio: okAudio, frame: okFrame).mine(
        const ImmersionMiningRequest(
            source: AnkiMiningSource.video,
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

  test('large GIF keeps the selected quality and is not size-downgraded',
      () async {
    final repo = _FakeRepo();
    final List<({int fps, int width})> calls = <({int fps, int width})>[];
    Future<String?> largeGif({
      required String inputPath,
      required int startMs,
      required int endMs,
      required String outputPath,
      int fps = 8,
      int width = 320,
      MiningAnimatedFormat format = MiningAnimatedFormat.gif,
      bool diagnosticOnly = false,
      FfmpegFailureReporter? onFailure,
      String? tlsPinSha256,
    }) async {
      calls.add((fps: fps, width: width));
      await File(outputPath).writeAsBytes(List<int>.filled(5 * 1024 * 1024, 0));
      return outputPath;
    }

    final res = await build(
      gif: largeGif,
      audio: okAudio,
      frame: okFrame,
    ).mine(
      const ImmersionMiningRequest(
        source: AnkiMiningSource.video,
        fields: {'expression': 'x'},
        mediaSource: '/v.mp4',
        clipStartMs: 0,
        clipEndMs: 4000,
        sentence: 's',
      ),
      compression: MiningMediaCompression.highFidelity,
      tempDir: tmp.path,
      repo: repo,
    );

    expect(calls, <({int fps, int width})>[(fps: 12, width: 720)]);
    expect(res.degradedToStill, isFalse);
    expect(repo.minedContext!.coverPath, endsWith('immersion_clip.gif'));
    expect(File(repo.minedContext!.coverPath!).lengthSync(),
        greaterThan(4 * 1024 * 1024));
  });

  test('requireAudio && audio missing -> abort, no mine', () async {
    final repo = _FakeRepo();
    final res = await build(gif: okGif, audio: nullAudio, frame: nullFrame)
        .mine(
            const ImmersionMiningRequest(
                source: AnkiMiningSource.video,
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
                source: AnkiMiningSource.video,
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
    expect(repo.minedContext!.sentenceAudioPath, isNull);
    expect(repo.minedContext!.coverPath, endsWith('.jpg'));
  });

  test(
      'audioSource (youtube split) is materialized locally then cut (TODO-1314 B5)',
      () async {
    final repo = _FakeRepo();
    String? gifInput;
    String? audioInput;
    String? materializedUrl;
    final String localAudio = '${tmp.path}/materialized_audio_src';
    Future<String?> capGif(
        {required String inputPath,
        required int startMs,
        required int endMs,
        required String outputPath,
        int fps = 8,
        int width = 320,
        MiningAnimatedFormat format = MiningAnimatedFormat.gif,
        bool diagnosticOnly = false,
        FfmpegFailureReporter? onFailure,
        String? tlsPinSha256}) async {
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
        String audioBitrate = '64k',
        String? tlsPinSha256}) async {
      audioInput = inputPath;
      return outputPath;
    }

    Future<String?> capMaterialize(
        {required String audioUrl,
        required String outputPath,
        FfmpegFailureReporter? onFailure}) async {
      materializedUrl = audioUrl;
      return localAudio;
    }

    await build(
            gif: capGif,
            audio: capAudio,
            frame: okFrame,
            materializer: capMaterialize)
        .mine(
            const ImmersionMiningRequest(
                source: AnkiMiningSource.video,
                fields: {'expression': 'x'},
                mediaSource: 'https://video-only.example/v',
                audioSource: 'https://audio-only.example/a',
                clipStartMs: 0,
                clipEndMs: 2000,
                sentence: 's'),
            compression: MiningMediaCompression.compressed,
            tempDir: tmp.path,
            repo: repo);
    expect(gifInput, 'https://video-only.example/v'); // GIF 仍从视频流
    // 分离 audio-only 流先经 range 分片下载物化到本地，再对本地文件裁（不再对 URL 直接 HTTP seek）。
    expect(materializedUrl, 'https://audio-only.example/a');
    expect(audioInput, localAudio);
  });

  test('updateNoteId routes to updateMinedNote', () async {
    final repo = _FakeRepo();
    await build(gif: okGif, audio: okAudio, frame: okFrame).mine(
        const ImmersionMiningRequest(
            source: AnkiMiningSource.video,
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
                source: AnkiMiningSource.video,
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
                source: AnkiMiningSource.video,
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

  // ── 视频制卡封面图片模式（VideoMiningImageMode）─────────────────────────
  // gif 模式与旧阶梯逐字等价（上面 'gif+audio success' / 'gif fails -> frame fallback'
  // 已覆盖，且 imageMode 默认 gif）。以下覆盖两个静态模式：主动选静态图不置 degradedToStill、
  // 走对的来源、且不调 GIF。

  // 制卡时截图：当前解码帧（stillFallback → immersion_shot.jpg）优先，不抽 GIF、非降级。
  test('imageMode=currentFrame uses screenshot, no gif, not degraded',
      () async {
    final repo = _FakeRepo();
    bool gifCalled = false;
    Future<String?> flagGif(
        {required String inputPath,
        required int startMs,
        required int endMs,
        required String outputPath,
        int fps = 8,
        int width = 320,
        MiningAnimatedFormat format = MiningAnimatedFormat.gif,
        bool diagnosticOnly = false,
        FfmpegFailureReporter? onFailure,
        String? tlsPinSha256}) async {
      gifCalled = true;
      return outputPath;
    }

    final res = await build(gif: flagGif, audio: okAudio, frame: okFrame).mine(
        ImmersionMiningRequest(
            source: AnkiMiningSource.video,
            fields: const {'expression': 'x'},
            mediaSource: '/v.mp4',
            clipStartMs: 1000,
            clipEndMs: 3000,
            sentence: 's',
            imageMode: VideoMiningImageMode.currentFrame,
            stillFallback: () async => Uint8List.fromList(<int>[9, 9, 9])),
        compression: MiningMediaCompression.compressed,
        tempDir: tmp.path,
        repo: repo);
    expect(res.aborted, false);
    expect(gifCalled, false, reason: '静态模式不该抽 GIF');
    expect(res.degradedToStill, false, reason: '用户主动选静态图，非降级');
    expect(repo.minedContext!.coverPath, endsWith('immersion_shot.jpg'));
  });

  // 字幕开头截图：字幕起点单帧（immersion_frame.jpg）优先，不抽 GIF、非降级。
  test('imageMode=subtitleStart uses start frame, no gif, not degraded',
      () async {
    final repo = _FakeRepo();
    bool gifCalled = false;
    Future<String?> flagGif(
        {required String inputPath,
        required int startMs,
        required int endMs,
        required String outputPath,
        int fps = 8,
        int width = 320,
        MiningAnimatedFormat format = MiningAnimatedFormat.gif,
        bool diagnosticOnly = false,
        FfmpegFailureReporter? onFailure,
        String? tlsPinSha256}) async {
      gifCalled = true;
      return outputPath;
    }

    final res = await build(gif: flagGif, audio: okAudio, frame: okFrame).mine(
        const ImmersionMiningRequest(
            source: AnkiMiningSource.video,
            fields: {'expression': 'x'},
            mediaSource: '/v.mp4',
            clipStartMs: 1000,
            clipEndMs: 3000,
            sentence: 's',
            imageMode: VideoMiningImageMode.subtitleStart),
        compression: MiningMediaCompression.compressed,
        tempDir: tmp.path,
        repo: repo);
    expect(res.aborted, false);
    expect(gifCalled, false, reason: '静态模式不该抽 GIF');
    expect(res.degradedToStill, false, reason: '用户主动选静态图，非降级');
    expect(repo.minedContext!.coverPath, endsWith('immersion_frame.jpg'));
  });

  // currentFrame 无 stillFallback（如无当前帧）→ 退字幕起点单帧，仍非降级。
  test('imageMode=currentFrame without screenshot falls back to start frame',
      () async {
    final repo = _FakeRepo();
    final res = await build(gif: nullGif, audio: okAudio, frame: okFrame).mine(
        const ImmersionMiningRequest(
            source: AnkiMiningSource.video,
            fields: {'expression': 'x'},
            mediaSource: '/v.mp4',
            clipStartMs: 1000,
            clipEndMs: 3000,
            sentence: 's',
            imageMode: VideoMiningImageMode.currentFrame),
        compression: MiningMediaCompression.compressed,
        tempDir: tmp.path,
        repo: repo);
    expect(res.aborted, false);
    expect(res.degradedToStill, false);
    expect(repo.minedContext!.coverPath, endsWith('immersion_frame.jpg'));
  });

  // subtitleStart 起点帧失败 → 退当前解码帧（immersion_shot.jpg），仍非降级。
  test('imageMode=subtitleStart with frame failure falls back to screenshot',
      () async {
    final repo = _FakeRepo();
    final res = await build(gif: okGif, audio: okAudio, frame: nullFrame).mine(
        ImmersionMiningRequest(
            source: AnkiMiningSource.video,
            fields: const {'expression': 'x'},
            mediaSource: '/v.mp4',
            clipStartMs: 1000,
            clipEndMs: 3000,
            sentence: 's',
            imageMode: VideoMiningImageMode.subtitleStart,
            stillFallback: () async => Uint8List.fromList(<int>[7, 7, 7])),
        compression: MiningMediaCompression.compressed,
        tempDir: tmp.path,
        repo: repo);
    expect(res.aborted, false);
    expect(res.degradedToStill, false);
    expect(repo.minedContext!.coverPath, endsWith('immersion_shot.jpg'));
  });

  // wireName 往返 + 未知值回退 gif（持久化契约，向后兼容）。
  test('VideoMiningImageMode.fromWireName round-trips and defaults to gif', () {
    for (final VideoMiningImageMode mode in VideoMiningImageMode.values) {
      expect(VideoMiningImageMode.fromWireName(mode.wireName), mode);
    }
    expect(VideoMiningImageMode.fromWireName(null), VideoMiningImageMode.gif);
    expect(VideoMiningImageMode.fromWireName('nonsense'),
        VideoMiningImageMode.gif);
    expect(VideoMiningImageMode.gif.isStill, false);
    expect(VideoMiningImageMode.currentFrame.isStill, true);
    expect(VideoMiningImageMode.subtitleStart.isStill, true);
  });
}
