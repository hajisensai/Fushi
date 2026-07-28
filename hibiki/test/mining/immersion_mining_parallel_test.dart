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

  test('封面与音频真并行：两条必须同时在途（任一方向的串行都挂死）', () async {
    // 判据只能是「**两条同时在途**」——两边都挂住，要求两个 Started 都亮才放行。
    //
    // 单向挂（只挂音频 + 快 GIF、断言「音频在途时封面已开工」）是**假绿**，本守卫第一版
    // 正是那么写的：改造前的真实串行是**封面在前、音频在后**，那个顺序下 GIF 先跑完
    // （gifStarted 早已亮）、音频随后才开工（audioStarted 也亮），两个 await 都立即返回，
    // 断言恒真。变异实测证实：把引擎退回原始串行序，那一版全绿、抓不到回归。
    // 反着写（挂 GIF、断言音频已开工）同样假绿——`audioFuture` 一创建就同步跑到内部
    // 首个 await，串行也照样"已开工"。
    //
    // 两边都挂住则对**两个方向**都确定性：
    //   · 并行版 → 两条各自开工后卡住，两个 Started 都亮 → 通过；
    //   · 封面在前的串行 → GIF 卡住，音频永不开工 → audioStarted 等不到 → 红；
    //   · 音频在前的串行 → 反之 gifStarted 等不到 → 红。
    // 全 Completer 驱动、不依赖 wall-clock 阈值，故不 flaky；显式 timeout 让回归立刻
    // 红并说清哪条没开工，不必白等 30 秒默认超时。
    final Completer<void> audioStarted = Completer<void>();
    final Completer<void> audioRelease = Completer<void>();
    final Completer<void> gifStarted = Completer<void>();
    final Completer<void> gifRelease = Completer<void>();

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

    Future<String?> slowGif({
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
      await gifRelease.future;
      final File f = File(outputPath)..writeAsStringSync('gif');
      return f.path;
    }

    final _FakeRepo repo = _FakeRepo();
    final Future<ImmersionMiningResult> mining = ImmersionMiningEngine(
      gifExtractor: slowGif,
      audioExtractor: slowAudio,
    ).mine(
      request,
      compression: MiningMediaCompression.compressed,
      tempDir: tmp.path,
      repo: repo,
    );

    // 关键断言：两条**同时**卡在各自的 ffmpeg 里——这才是「并行」。任一方向的串行都
    // 只会有一条开工，另一条的 Started 永远不亮 → 这里超时红。
    await Future.wait<void>(
            <Future<void>>[audioStarted.future, gifStarted.future])
        .timeout(const Duration(seconds: 10), onTimeout: () {
      fail('封面与音频没有并行：只有 '
          '${gifStarted.isCompleted ? '封面' : '音频'} 开工了，'
          '另一条被前一条 await 挡住（引擎退回串行）');
    });
    gifRelease.complete();
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
