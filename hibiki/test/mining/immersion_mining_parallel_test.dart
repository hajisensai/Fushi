import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki/src/mining/immersion_mining_engine.dart';
import 'package:hibiki/src/mining/immersion_mining_request.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart'
    show MiningMediaCompression;

/// BUG-1203 守卫：
///  ① 封面（GIF）与句子音频两条 ffmpeg 抽取必须**并行**——它们之间没有数据依赖，
///     串行会让耗时直接相加（用户把图片档拉到最高时 GIF 单项就要数秒）。
///  ② 失败摘要必须按**来源**分流，不能再靠 onFailure 的调用顺序区分「首个=封面、
///     末个=音频」——并行后顺序不再确定，靠顺序必然串味。
class _FakeRepo implements BaseAnkiRepository {
  AnkiMiningContext? minedContext;

  @override
  Future<MineOutcome> mineEntry(
      {required String rawPayloadJson,
      required AnkiMiningContext context}) async {
    minedContext = context;
    return const MineOutcome.success(noteId: 1);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('immersion_parallel');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  const ImmersionMiningRequest request = ImmersionMiningRequest(
    source: AnkiMiningSource.video,
    fields: {'expression': '走る'},
    mediaSource: '/fake/video.mp4',
    clipStartMs: 1000,
    clipEndMs: 3000,
    sentence: '走り出した。',
  );

  test('封面不被音频阻塞：音频仍在 ffmpeg 里时，封面已经开工', () async {
    // 方向很关键：必须让**音频**挂住、看**封面**能否开工。
    //
    // 反过来写（挂住 GIF、断言音频已开工）是个**假绿**测试：`_resolveAudioPath` 是
    // async 函数，`audioFuture` 一创建就同步跑到它内部第一个 await，所以哪怕引擎退回
    // 「先 await 音频再做封面」的串行版，音频也照样"已开工"——断言恒真、抓不到回归。
    // 实测验证过：把 await 移回封面之前，那种写法依然全绿。
    //
    // 这里的写法则是确定性的：串行版会先 await 挂住的音频，封面永远轮不到，
    // gifStarted 等不到 → 测试超时红。不依赖 wall-clock 阈值，故不 flaky。
    final Completer<void> audioStarted = Completer<void>();
    final Completer<void> audioRelease = Completer<void>();
    final Completer<void> gifStarted = Completer<void>();

    Future<String?> slowAudio({
      required String inputPath,
      required int startMs,
      required int endMs,
      required String outputPath,
      int? audioStreamIndex,
      int? audioStreamCount,
      dynamic onFailure,
      int audioChannels = 1,
      String audioBitrate = '64k',
      String? tlsPinSha256,
    }) async {
      if (!audioStarted.isCompleted) audioStarted.complete();
      await audioRelease.future;
      final File f = File(outputPath)..writeAsStringSync('audio');
      return f.path;
    }

    Future<String?> fastGif({
      required String inputPath,
      required int startMs,
      required int endMs,
      required String outputPath,
      int fps = 8,
      int width = 320,
      dynamic onFailure,
      String? tlsPinSha256,
    }) async {
      if (!gifStarted.isCompleted) gifStarted.complete();
      final File f = File(outputPath)..writeAsStringSync('gif');
      return f.path;
    }

    final _FakeRepo repo = _FakeRepo();
    final Future<ImmersionMiningResult> mining = ImmersionMiningEngine(
      gifExtractor: fastGif,
      audioExtractor: slowAudio,
    ).mine(
      request,
      compression: MiningMediaCompression.compressed,
      tempDir: tmp.path,
      repo: repo,
    );

    await audioStarted.future;
    // 关键断言：音频还卡在 ffmpeg 里，封面已经开工——这就是「并行」。
    // 串行实现在这一行挂死。
    await gifStarted.future;
    audioRelease.complete();

    final ImmersionMiningResult res = await mining;
    expect(res.aborted, false);
    expect(repo.minedContext!.coverPath, endsWith('.gif'));
    expect(repo.minedContext!.sasayakiAudioPath, isNotNull);
  });

  test('失败摘要按来源分流：封面失败不会串进音频通道，反之亦然', () async {
    Future<String?> failingGif({
      required String inputPath,
      required int startMs,
      required int endMs,
      required String outputPath,
      int fps = 8,
      int width = 320,
      dynamic onFailure,
      String? tlsPinSha256,
    }) async {
      (onFailure as void Function(String)?)?.call('gif boom');
      return null;
    }

    Future<String?> failingFrame({
      required String inputPath,
      required String outputPath,
      double atSeconds = 0,
      dynamic onFailure,
      String? tlsPinSha256,
    }) async {
      (onFailure as void Function(String)?)?.call('frame boom');
      return null;
    }

    Future<String?> failingAudio({
      required String inputPath,
      required int startMs,
      required int endMs,
      required String outputPath,
      int? audioStreamIndex,
      int? audioStreamCount,
      dynamic onFailure,
      int audioChannels = 1,
      String audioBitrate = '64k',
      String? tlsPinSha256,
    }) async {
      (onFailure as void Function(String)?)?.call('audio boom');
      return null;
    }

    final List<String> cover = <String>[];
    final List<String> audio = <String>[];
    final List<String> merged = <String>[];

    final ImmersionMiningResult res = await ImmersionMiningEngine(
      gifExtractor: failingGif,
      audioExtractor: failingAudio,
      frameExtractor: failingFrame,
    ).mine(
      request,
      compression: MiningMediaCompression.compressed,
      tempDir: tmp.path,
      repo: _FakeRepo(),
      onFailure: merged.add,
      onCoverFailure: cover.add,
      onAudioFailure: audio.add,
    );

    // 封面通道只见封面来源（GIF + 起点帧降级），绝不含音频摘要。
    expect(cover, contains('gif boom'));
    expect(cover, contains('frame boom'));
    expect(cover, isNot(contains('audio boom')));
    // 音频通道只见音频来源。
    expect(audio, <String>['audio boom']);
    // 合流回调仍收全部（既有调用点零改动）。
    expect(merged.toSet(), <String>{'gif boom', 'frame boom', 'audio boom'});
    // 媒体全失败 → 不产空壳卡。
    expect(res.aborted, true);
  });
}
