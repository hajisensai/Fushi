// 制卡封面动图格式（AVIF / WebP / GIF）的取值域、档位解析、ffmpeg 参数与降级契约。
//
// 覆盖的三条真实风险（都不是「枚举有几个值」这种同义反复）：
//  1. 顶格档语义随格式变——AVIF 源直通、WebP/GIF 封顶。写错就是「用户选了 AVIF 却拿不到
//     原图档」或「GIF 拿到源分辨率」（= BUG-1039 那个 54 MB / 撞超时的配置）。
//  2. 编码失败降级到 GIF 时，**必须换成 GIF 自己的顶格档参数**。沿用 AVIF 的 0/0 会把
//     源分辨率+源帧率喂给 GIF，正中 BUG-1039。
//  3. 输出扩展名必须与实际产出格式一致——ffmpeg 按扩展名选 muxer，Anki 按扩展名判 MIME。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/galgame_window_gif.dart';
import 'package:hibiki/src/mining/immersion_mining_engine.dart';
import 'package:hibiki/src/mining/immersion_mining_request.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

class _RecordingRepo extends BaseAnkiRepository {
  AnkiMiningContext? minedContext;

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    minedContext = context;
    return const MineOutcome.success(noteId: 1);
  }

  @override
  Future<AnkiSettings> loadSettings() async => const AnkiSettings();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 一次动图抽取调用的实参快照（用来断言降级时参数换对了）。
typedef _GifCall = ({
  MiningAnimatedFormat format,
  int fps,
  int width,
  String outputPath,
});

void main() {
  group('MiningAnimatedFormat 取值域', () {
    test('缺省与未知 wire 值都回落 avif（新默认）', () {
      expect(
          MiningAnimatedFormat.fromWireName(null), MiningAnimatedFormat.avif);
      expect(
          MiningAnimatedFormat.fromWireName('nope'), MiningAnimatedFormat.avif);
      // 老用户存过的 'gif' 必须仍解析成 gif——换默认值不等于抹掉已有选择。
      expect(
          MiningAnimatedFormat.fromWireName('gif'), MiningAnimatedFormat.gif);
    });

    test('wireName 往返稳定（改了就是破坏已落盘偏好）', () {
      for (final MiningAnimatedFormat f in MiningAnimatedFormat.values) {
        expect(MiningAnimatedFormat.fromWireName(f.wireName), f);
      }
      expect(
        MiningAnimatedFormat.values.map((MiningAnimatedFormat f) => f.wireName),
        <String>['avif', 'webp', 'gif'],
      );
      expect(
        MiningAnimatedFormat.values
            .map((MiningAnimatedFormat f) => f.fileExtension),
        <String>['avif', 'webp', 'gif'],
      );
    });

    test('只有 AVIF 声明源直通顶格档', () {
      expect(MiningAnimatedFormat.avif.maxTierIsSourcePassthrough, isTrue);
      // WebP 规格上有帧间差分，但实测在源分辨率下比 GIF 还慢（libwebp_anim 是逐帧
      // 帧内的静态图编码器）。它和 GIF 一样吃封顶值，这不是笔误。
      expect(MiningAnimatedFormat.webp.maxTierIsSourcePassthrough, isFalse);
      expect(MiningAnimatedFormat.gif.maxTierIsSourcePassthrough, isFalse);
      expect(MiningAnimatedFormat.webp.maxTierFps,
          MiningAnimatedFormat.gif.maxTierFps);
      expect(MiningAnimatedFormat.webp.maxTierWidth,
          MiningAnimatedFormat.gif.maxTierWidth);
    });
  });

  group('MiningMediaCompression.resolve 顶格档随格式分叉', () {
    test('顶格档：AVIF 拿 0/0（源直通），WebP/GIF 拿封顶值', () {
      final MiningMediaCompression avif = MiningMediaCompression.resolve(
        imageTier: MiningMediaCompression.imageTierMax,
        audioTier: 0,
        format: MiningAnimatedFormat.avif,
      );
      expect(avif.gifFps, 0);
      expect(avif.gifWidth, 0);

      for (final MiningAnimatedFormat capped in <MiningAnimatedFormat>[
        MiningAnimatedFormat.webp,
        MiningAnimatedFormat.gif,
      ]) {
        final MiningMediaCompression r = MiningMediaCompression.resolve(
          imageTier: MiningMediaCompression.imageTierMax,
          audioTier: 0,
          format: capped,
        );
        expect(r.gifFps, capped.maxTierFps, reason: '$capped 不该拿到源帧率');
        expect(r.gifWidth, capped.maxTierWidth, reason: '$capped 不该拿到源分辨率');
        expect(r.gifWidth, greaterThan(0));
      }
    });

    test('低三档与格式无关（同一滑块位置在三种格式下含义一致）', () {
      for (int tier = 0; tier < MiningMediaCompression.imageTierMax; tier++) {
        final List<MiningMediaCompression> all = MiningAnimatedFormat.values
            .map((MiningAnimatedFormat f) => MiningMediaCompression.resolve(
                  imageTier: tier,
                  audioTier: 0,
                  format: f,
                ))
            .toList();
        expect(all.map((MiningMediaCompression c) => c.gifFps).toSet(),
            hasLength(1),
            reason: '档 $tier 的帧率不该随格式变');
        expect(all.map((MiningMediaCompression c) => c.gifWidth).toSet(),
            hasLength(1),
            reason: '档 $tier 的宽度不该随格式变');
        expect(all.first.gifFps, greaterThan(0));
      }
    });

    test('不传 format 时逐字节等价于改动前（默认 gif 封顶）', () {
      final MiningMediaCompression legacy = MiningMediaCompression.resolve(
        imageTier: MiningMediaCompression.imageTierMax,
        audioTier: 0,
      );
      expect(legacy.gifFps, MiningMediaCompression.gifMaxTierFps);
      expect(legacy.gifWidth, MiningMediaCompression.gifMaxTierWidth);
      // 截图侧的原图直通语义自始至终没变。
      expect(legacy.screenshotMaxLongEdge, 0);
    });
  });

  group('buildFfmpegClipAnimatedArgs 按格式分派', () {
    List<String> argsFor(MiningAnimatedFormat f,
            {int fps = 8, int width = 480}) =>
        buildFfmpegClipAnimatedArgs(
          format: f,
          inputPath: '/v.mp4',
          startMs: 1000,
          endMs: 5000,
          outputPath: '/out.${f.fileExtension}',
          fps: fps,
          width: width,
        );

    test('GIF 走 filter_complex 双趟调色板且不带 -c:v（与改动前逐字等价）', () {
      final List<String> gif = argsFor(MiningAnimatedFormat.gif);
      expect(gif, contains('-filter_complex'));
      expect(gif.contains('-vf'), isFalse);
      expect(gif.join(' '), contains('palettegen'));
      expect(gif.join(' '), contains('paletteuse'));
      expect(gif.contains('-c:v'), isFalse,
          reason: 'gif 由扩展名选编码器，显式 -c:v 会改字节');
      // 薄委托必须与泛化版完全一致。
      expect(
        buildFfmpegClipGifArgs(
          inputPath: '/v.mp4',
          startMs: 1000,
          endMs: 5000,
          outputPath: '/out.gif',
          fps: 8,
          width: 480,
        ),
        gif,
      );
    });

    test('WebP/AVIF 走单趟 -vf、不生成调色板、且带各自编码器', () {
      final List<String> webp = argsFor(MiningAnimatedFormat.webp);
      expect(webp, contains('-vf'));
      expect(webp.contains('-filter_complex'), isFalse);
      expect(webp.join(' '), isNot(contains('palettegen')));
      expect(webp.join(' '), contains('libwebp_anim'));

      final List<String> avif = argsFor(MiningAnimatedFormat.avif);
      expect(avif, contains('-vf'));
      expect(avif.join(' '), isNot(contains('palettegen')));
      expect(avif.join(' '), contains('libsvtav1'));
    });

    test('源直通档（fps/width=0）不加 fps/scale 滤镜，且 -vf 不为空串', () {
      final List<String> avif =
          argsFor(MiningAnimatedFormat.avif, fps: 0, width: 0);
      final int vf = avif.indexOf('-vf');
      expect(vf, greaterThanOrEqualTo(0));
      final String chain = avif[vf + 1];
      expect(chain, isNotEmpty, reason: 'ffmpeg 的 -vf 不接受空串');
      expect(chain, isNot(contains('fps=')));
      expect(chain, isNot(contains('scale=')));
    });

    test('非 GIF 用 -2 取偶高度（AVIF/WebP 编码器要求偶数维度）', () {
      expect(argsFor(MiningAnimatedFormat.avif).join(' '),
          contains('scale=480:-2'));
      expect(argsFor(MiningAnimatedFormat.webp).join(' '),
          contains('scale=480:-2'));
    });

    test('三种格式的输出扩展名与格式一致', () {
      for (final MiningAnimatedFormat f in MiningAnimatedFormat.values) {
        expect(argsFor(f).last, endsWith('.${f.fileExtension}'));
      }
    });
  });

  group('galgame 窗口动图参数', () {
    List<String> galArgs(MiningAnimatedFormat f) => buildGalWindowAnimatedArgs(
          format: f,
          inputPattern: '/tmp/frame_%03d.png',
          outputPath: '/tmp/out.${f.fileExtension}',
          fps: 8,
          maxWidth: 480,
        );

    test('GIF 保留双趟调色板；WebP/AVIF 单趟且带编码器', () {
      expect(
          galArgs(MiningAnimatedFormat.gif).join(' '), contains('palettegen'));
      expect(galArgs(MiningAnimatedFormat.webp).join(' '),
          isNot(contains('palettegen')));
      expect(galArgs(MiningAnimatedFormat.webp).join(' '),
          contains('libwebp_anim'));
      expect(
          galArgs(MiningAnimatedFormat.avif).join(' '), contains('libsvtav1'));
    });

    test('GIF 用 -1 高度、非 GIF 用 -2（编码器要求偶数维度）', () {
      expect(galArgs(MiningAnimatedFormat.gif).join(' '),
          contains('scale=480:-1'));
      expect(galArgs(MiningAnimatedFormat.avif).join(' '),
          contains('scale=480:-2'));
      expect(galArgs(MiningAnimatedFormat.webp).join(' '),
          contains('scale=480:-2'));
    });

    test('输出扩展名与格式一致', () {
      for (final MiningAnimatedFormat f in MiningAnimatedFormat.values) {
        expect(galArgs(f).last, endsWith('.${f.fileExtension}'));
      }
    });
  });

  // 视频 cue 动图与 galgame 窗口动图是两条独立链路（输入形态不同），但编码器参数必须
  // 同源。历史上这类「两处各写一份」正是漂开的起点，这里锁死它们引用同一个函数的产物。
  test('两条链路共用同一份编码器参数（防漂开）', () {
    for (final MiningAnimatedFormat f in MiningAnimatedFormat.values) {
      final List<String> shared = animatedEncoderArgs(f);
      final String video = buildFfmpegClipAnimatedArgs(
        format: f,
        inputPath: '/v.mp4',
        startMs: 0,
        endMs: 1000,
        outputPath: '/o.${f.fileExtension}',
      ).join(' ');
      final String gal = buildGalWindowAnimatedArgs(
        format: f,
        inputPattern: '/f_%03d.png',
        outputPath: '/o.${f.fileExtension}',
        fps: 8,
        maxWidth: 480,
      ).join(' ');
      if (shared.isEmpty) {
        // GIF：两边都不显式指定编码器。
        expect(video, isNot(contains('-c:v')));
        expect(gal, isNot(contains('-c:v')));
      } else {
        expect(video, contains(shared.join(' ')));
        expect(gal, contains(shared.join(' ')));
      }
    }
  });

  group('引擎：编码失败时降级 GIF', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('anim_fmt_');
    });
    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

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

    /// 只让 GIF 成功的抽取器 + 调用流水账。模拟「旧包捆绑的 ffmpeg 没有 libsvtav1」。
    ({GifExtractor extractor, List<_GifCall> calls}) gifOnly() {
      final List<_GifCall> calls = <_GifCall>[];
      Future<String?> extractor({
        required String inputPath,
        required int startMs,
        required int endMs,
        required String outputPath,
        int fps = 8,
        int width = 320,
        MiningAnimatedFormat format = MiningAnimatedFormat.gif,
        FfmpegFailureReporter? onFailure,
        String? tlsPinSha256,
      }) async {
        calls.add(
            (format: format, fps: fps, width: width, outputPath: outputPath));
        return format == MiningAnimatedFormat.gif ? outputPath : null;
      }

      return (extractor: extractor, calls: calls);
    }

    test('AVIF 顶格档失败降级 GIF 时，换成 GIF 自己的封顶参数（BUG-1039 陷阱）', () async {
      final ({GifExtractor extractor, List<_GifCall> calls}) fake = gifOnly();
      final _RecordingRepo repo = _RecordingRepo();
      // 顶格档 + AVIF → compression 是 0/0（源直通）。
      final MiningMediaCompression top = MiningMediaCompression.resolve(
        imageTier: MiningMediaCompression.imageTierMax,
        audioTier: 0,
        format: MiningAnimatedFormat.avif,
      );
      expect(top.gifFps, 0);

      await ImmersionMiningEngine(
        gifExtractor: fake.extractor,
        audioExtractor: okAudio,
      ).mine(
        ImmersionMiningRequest(
          source: AnkiMiningSource.video,
          fields: const <String, String>{'expression': 'x'},
          mediaSource: '/v.mp4',
          clipStartMs: 1000,
          clipEndMs: 5000,
          sentence: 's',
          animatedFormat: MiningAnimatedFormat.avif,
        ),
        compression: top,
        tempDir: tmp.path,
        repo: repo,
      );

      expect(fake.calls, hasLength(2), reason: '首选 avif 失败后必须降级 gif 再试一次');
      expect(fake.calls[0].format, MiningAnimatedFormat.avif);
      expect(fake.calls[0].fps, 0, reason: 'AVIF 顶格档就是源帧率直通');
      expect(fake.calls[0].width, 0);

      expect(fake.calls[1].format, MiningAnimatedFormat.gif);
      expect(fake.calls[1].fps, MiningAnimatedFormat.gif.maxTierFps,
          reason: '沿用 0 会把源帧率喂给 GIF —— 正是 BUG-1039 的 54 MB / 撞超时配置');
      expect(fake.calls[1].width, MiningAnimatedFormat.gif.maxTierWidth);
      expect(fake.calls[1].outputPath, endsWith('.gif'),
          reason: '扩展名必须跟着实际尝试的格式走，否则 muxer 选错');
      // 降级后仍是动图，不是「降级为静态帧」，不该弹那个 OSD。
      expect(repo.minedContext!.coverPath, endsWith('.gif'));
    });

    test('低档位降级 GIF 时沿用原参数（非顶格档没有 0 哨兵，无需替换）', () async {
      final ({GifExtractor extractor, List<_GifCall> calls}) fake = gifOnly();
      final MiningMediaCompression std = MiningMediaCompression.resolve(
        imageTier: 1,
        audioTier: 0,
        format: MiningAnimatedFormat.avif,
      );
      await ImmersionMiningEngine(
        gifExtractor: fake.extractor,
        audioExtractor: okAudio,
      ).mine(
        ImmersionMiningRequest(
          source: AnkiMiningSource.video,
          fields: const <String, String>{'expression': 'x'},
          mediaSource: '/v.mp4',
          clipStartMs: 1000,
          clipEndMs: 5000,
          sentence: 's',
          animatedFormat: MiningAnimatedFormat.avif,
        ),
        compression: std,
        tempDir: tmp.path,
        repo: _RecordingRepo(),
      );
      expect(fake.calls, hasLength(2));
      expect(fake.calls[0].fps, std.gifFps);
      expect(fake.calls[1].fps, std.gifFps, reason: '有限值不该被顶格档逻辑改写');
      expect(fake.calls[1].width, std.gifWidth);
    });

    test('首选就是 GIF 时只调一次（不做无谓的二次尝试）', () async {
      final ({GifExtractor extractor, List<_GifCall> calls}) fake = gifOnly();
      await ImmersionMiningEngine(
        gifExtractor: fake.extractor,
        audioExtractor: okAudio,
      ).mine(
        ImmersionMiningRequest(
          source: AnkiMiningSource.video,
          fields: const <String, String>{'expression': 'x'},
          mediaSource: '/v.mp4',
          clipStartMs: 1000,
          clipEndMs: 5000,
          sentence: 's',
          animatedFormat: MiningAnimatedFormat.gif,
        ),
        compression: MiningMediaCompression.compressed,
        tempDir: tmp.path,
        repo: _RecordingRepo(),
      );
      expect(fake.calls, hasLength(1));
      expect(fake.calls.single.format, MiningAnimatedFormat.gif);
    });

    test('AVIF 成功时不降级，封面扩展名是 .avif', () async {
      final List<_GifCall> calls = <_GifCall>[];
      Future<String?> always({
        required String inputPath,
        required int startMs,
        required int endMs,
        required String outputPath,
        int fps = 8,
        int width = 320,
        MiningAnimatedFormat format = MiningAnimatedFormat.gif,
        FfmpegFailureReporter? onFailure,
        String? tlsPinSha256,
      }) async {
        calls.add(
            (format: format, fps: fps, width: width, outputPath: outputPath));
        return outputPath;
      }

      final _RecordingRepo repo = _RecordingRepo();
      await ImmersionMiningEngine(
        gifExtractor: always,
        audioExtractor: okAudio,
      ).mine(
        ImmersionMiningRequest(
          source: AnkiMiningSource.video,
          fields: const <String, String>{'expression': 'x'},
          mediaSource: '/v.mp4',
          clipStartMs: 1000,
          clipEndMs: 5000,
          sentence: 's',
          animatedFormat: MiningAnimatedFormat.avif,
        ),
        compression: MiningMediaCompression.compressed,
        tempDir: tmp.path,
        repo: repo,
      );
      expect(calls, hasLength(1));
      expect(calls.single.format, MiningAnimatedFormat.avif);
      expect(repo.minedContext!.coverPath, endsWith('.avif'));
    });
  });
}
