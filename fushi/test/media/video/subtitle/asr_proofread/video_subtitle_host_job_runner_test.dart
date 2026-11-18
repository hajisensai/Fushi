import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';
import 'package:fushi_engine/ai/web_search.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/moss_provisioning.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_language.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_host_job_runner.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart';
import 'package:fushi_engine/media/video/dvd/dvd_angle.dart'
    show dvdTitleAnglePath;
import 'package:fushi_engine/media/video/dvd/dvd_title_path.dart'
    show dvdTitlePath;
import 'package:fushi_engine/media/video/video_local_files.dart'
    show videoBookDiscTitlePath;
import 'package:fushi_engine/media/video/video_member_file.dart'
    show hasLocalMediaFile;
import 'package:fushi_engine/sync/host_jobs/host_job_runner.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

class _Recognizer implements VideoSubtitleRecognizer {
  int calls = 0;

  /// 每次识别收到的（视频名, 音轨流序号）。
  final List<(String, int?)> streams = <(String, int?)>[];

  @override
  String get id => 'fake';

  @override
  Future<List<SubtitleDraftCue>> recognize({
    required String videoPath,
    required Directory workDir,
    required VideoSubtitleRecognizeProgress onProgress,
    required SubtitleCancelToken cancel,
    int? audioStreamIndex,
  }) async {
    calls++;
    streams.add((p.basename(videoPath), audioStreamIndex));
    onProgress(0.5, 'transcribing');
    return <SubtitleDraftCue>[
      for (int i = 0; i < 5; i++)
        SubtitleDraftCue(
          startMs: i * 2000,
          endMs: i * 2000 + 1500,
          text: '${p.basenameWithoutExtension(videoPath)} 台詞$i',
        ),
    ];
  }
}

class _Settings implements AiSettingsSource {
  _Settings({this.assigned = true, this.images = false});

  final bool assigned;

  /// 提供商开没开图片输入。
  final bool images;

  @override
  List<AiProviderConfig> get aiProviders => <AiProviderConfig>[
    AiProviderConfig(
      id: 'p',
      presetId: kAiCustomPresetId,
      name: 'p',
      baseUrl: Uri.parse('https://example.com/v1'),
      apiKey: 'k',
      model: 'm',
      protocol: AiWireProtocol.anthropicMessages,
      acceptsImages: images,
    ),
  ];

  @override
  AiFeatureAssignments get aiFeatureAssignments => assigned
      ? const AiFeatureAssignments(
          providerIdByFeature: <AiFeature, String>{
            AiFeature.subtitleProofread: 'p',
          },
        )
      : const AiFeatureAssignments();

  @override
  List<WebKnowledgeSite> get aiWebKnowledgeSites => const <WebKnowledgeSite>[];

  @override
  WebSearchConfig? get aiWebSearch => null;
}

void main() {
  late Directory tmp;
  late _Recognizer recognizer;
  final List<(VideoSubtitleSegmenterMode, MossBackendPreference)> asked =
      <(VideoSubtitleSegmenterMode, MossBackendPreference)>[];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vshj_');
    recognizer = _Recognizer();
    asked.clear();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  VideoSubtitleHostJobRunner runner({
    AiSettingsSource? settings,
    AiChatClient Function()? client,
    Future<String?> Function(String, {int episodeIndex})? resolveVideo,
    Future<String?> Function(String, String)? resolveDiscTitle,
    VideoSubtitleAudioStreamResolver? resolveAudioStream,
  }) => VideoSubtitleHostJobRunner(
    resolveRecognizer:
        (
          VideoSubtitleSegmenterMode mode,
          MossBackendPreference backend,
          VideoSubtitleLanguage _,
        ) async {
          asked.add((mode, backend));
          return VideoSubtitleRecognizerChoice(
            recognizer: recognizer,
            mossUnavailableReason: 'no gpu',
          );
        },
    pipelineJobsRoot: Directory(p.join(tmp.path, 'pipeline')),
    aiSettings: settings == null ? null : () => settings,
    chatClientFactory: client,
    resolveVideoPath: resolveVideo,
    resolveDiscTitlePath: resolveDiscTitle,
    probeDurationMs: (String _) async => 1440000,
    resolveAudioStream: resolveAudioStream,
    // 测试里不起真 ffmpeg。
    frameSource: (String videoPath, int atMs) async => null,
  );

  (HostJobContext, List<(double, String?)>) context(
    Map<String, Object?> params, {
    String jobId = 'j1',
    HostJobCancelToken? cancel,
  }) {
    final Directory inputs = Directory(p.join(tmp.path, jobId, 'inputs'))
      ..createSync(recursive: true);
    final Directory outputs = Directory(p.join(tmp.path, jobId, 'outputs'))
      ..createSync(recursive: true);
    final List<(double, String?)> progress = <(double, String?)>[];
    return (
      HostJobContext(
        jobId: jobId,
        params: params,
        inputsDir: inputs,
        outputsDir: outputs,
        onProgress: (double f, String? m) => progress.add((f, m)),
        cancel: cancel ?? HostJobCancelToken(),
      ),
      progress,
    );
  }

  group('参数校验', () {
    test('默认要 AI 校对：host 没指派提供商直接 400，不悄悄不校对', () {
      expect(
        () => runner(
          settings: _Settings(assigned: false),
        ).validateParams(const <String, Object?>{}),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            contains('proofread'),
          ),
        ),
      );
      expect(
        () => runner().validateParams(const <String, Object?>{}),
        throwsFormatException,
      );
      runner().validateParams(const <String, Object?>{'proofread': false});
      runner(settings: _Settings()).validateParams(const <String, Object?>{});
    });

    test('枚举 / 组合 / 后缀不合法 → 400', () {
      final VideoSubtitleHostJobRunner r = runner(
        resolveVideo: (String _, {int episodeIndex = 0}) async => null,
      );
      for (final Map<String, Object?> bad in <Map<String, Object?>>[
        <String, Object?>{'proofread': false, 'segmenter': 'whisper'},
        <String, Object?>{'proofread': false, 'mossBackend': 'rocm'},
        <String, Object?>{'proofread': 'maybe'},
        <String, Object?>{'proofread': false, 'collectionId': 'x'},
        <String, Object?>{
          'proofread': false,
          'videoId': 'a',
          'collectionId': 1,
        },
        <String, Object?>{'proofread': false, 'suffix': '../ja'},
        // 这个 host 没接库：不收 collectionId。
        <String, Object?>{'proofread': false, 'collectionId': 3},
        // 集下标：非负整数，且只跟 videoId 一起。
        <String, Object?>{'proofread': false, 'videoId': 'a', 'episode': -1},
        <String, Object?>{'proofread': false, 'videoId': 'a', 'episode': 'x'},
        <String, Object?>{'proofread': false, 'videoId': 'a', 'episode': 1.5},
        <String, Object?>{'proofread': false, 'episode': 2},
        <String, Object?>{'proofread': false, 'collectionId': 3, 'episode': 1},
        // 原盘 title：只跟 videoId 一起、不与 episode 同给；这个 host 没接
        // resolveDiscTitlePath（老 host 形状）也拒。
        <String, Object?>{
          'proofread': false,
          'discTitle': 'BDMV/PLAYLIST/00005.mpls',
        },
        <String, Object?>{
          'proofread': false,
          'videoId': 'a',
          'episode': 1,
          'discTitle': 'BDMV/PLAYLIST/00005.mpls',
        },
        <String, Object?>{
          'proofread': false,
          'videoId': 'a',
          'discTitle': 'BDMV/PLAYLIST/00005.mpls',
        },
        // 音轨：非负整数，且只跟 videoId 一起。
        <String, Object?>{'proofread': false, 'videoId': 'a', 'audioTrack': -1},
        <String, Object?>{
          'proofread': false,
          'videoId': 'a',
          'audioTrack': 'x',
        },
        <String, Object?>{
          'proofread': false,
          'videoId': 'a',
          'audioTrack': 1.5,
        },
        <String, Object?>{'proofread': false, 'audioTrack': 1},
        <String, Object?>{
          'proofread': false,
          'collectionId': 3,
          'audioTrack': 1,
        },
      ]) {
        expect(
          () => r.validateParams(bad),
          throwsFormatException,
          reason: '$bad',
        );
      }
      final VideoSubtitleJobParams ok =
          VideoSubtitleJobParams.parse(const <String, Object?>{
            'proofread': 'false',
            'segmenter': 'moss',
            'mossBackend': 'vulkan',
            'regenerateGlossary': true,
            'suffix': 'ja',
            'videoId': 'v1',
          });
      expect(ok.proofread, isFalse);
      expect(ok.segmenter, VideoSubtitleSegmenterMode.moss);
      expect(ok.mossBackend, MossBackendPreference.vulkan);
      expect(ok.regenerateGlossary, isTrue);
      expect(ok.episode, 0, reason: '老客户端不带 episode：按第 0 集，行为不变');
      expect(ok.audioTrack, isNull, reason: '不带 audioTrack：按识别语言挑');
      final VideoSubtitleJobParams withTrack = VideoSubtitleJobParams.parse(
        const <String, Object?>{
          'videoId': 'v1',
          'episode': '2',
          'audioTrack': '1',
        },
      );
      expect((withTrack.episode, withTrack.audioTrack), (2, 1));
      expect(
        VideoSubtitleJobParams.parse(const <String, Object?>{
          'videoId': 'v1',
          'discTitle': 'BDMV/PLAYLIST/00005.mpls',
          'audioTrack': 0,
        }).audioTrack,
        0,
        reason: '可与 discTitle 组合',
      );
      expect(
        VideoSubtitleJobParams.parse(const <String, Object?>{
          'videoId': 'v1',
          'episode': 2,
        }).episode,
        2,
      );
      expect(
        VideoSubtitleJobParams.parse(const <String, Object?>{
          'videoId': 'v1',
          'episode': '3',
        }).episode,
        3,
      );
    });
  });

  test('上传的视频（不校对）：字幕进产物目录 + summary.json；进度带阶段名', () async {
    final (HostJobContext ctx, List<(double, String?)> progress) = context(
      const <String, Object?>{'proofread': false, 'segmenter': 'window'},
    );
    File(p.join(ctx.inputsDir.path, 'ep01.mkv')).writeAsBytesSync(<int>[1, 2]);
    File(p.join(ctx.inputsDir.path, 'note.txt')).writeAsStringSync('x');
    final HostJobOutcome outcome = await runner().run(ctx);

    expect(asked.single, (
      VideoSubtitleSegmenterMode.window,
      MossBackendPreference.auto,
    ));
    expect(outcome.primaryOutput, 'ep01.ja.srt');
    expect(
      outcome.outputs.keys,
      containsAll(<String>['ep01.ja.srt', kVideoSubtitleSummaryOutput]),
    );
    expect(ctx.output('ep01.ja.srt').readAsStringSync(), contains('ep01 台詞0'));
    // 上传目录里不留字幕（exportDir = 产物目录）。
    expect(
      File(p.join(ctx.inputsDir.path, 'ep01.ja.srt')).existsSync(),
      isFalse,
    );
    final Map<String, Object?> summary =
        jsonDecode(ctx.output(kVideoSubtitleSummaryOutput).readAsStringSync())
            as Map<String, Object?>;
    expect(summary['recognizer'], 'fake');
    expect(
      (summary['mossUnavailable']! as Map<String, Object?>)['reason'],
      'no gpu',
    );
    final List<Object?> episodes = summary['episodes']! as List<Object?>;
    expect((episodes.single! as Map<String, Object?>)['status'], 'exported');
    expect((episodes.single! as Map<String, Object?>)['cues'], 5);
    expect(
      progress.map(((double, String?) e) => e.$2).whereType<String>(),
      contains(startsWith('recognize: transcribing')),
    );
    expect(
      progress
          .map(((double, String?) e) => e.$1)
          .every((double f) => f >= 0 && f <= 1),
      isTrue,
    );
  });

  test('库视频：经 resolveVideoPath，字幕写在视频旁（规则同管线）并拷进产物', () async {
    final Directory lib = Directory(p.join(tmp.path, 'lib', 'Show'))
      ..createSync(recursive: true);
    final File video = File(p.join(lib.path, 'Show 01.mkv'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final (HostJobContext ctx, _) = context(const <String, Object?>{
      'proofread': false,
      'videoId': 'v1',
    });
    final HostJobOutcome outcome = await runner(
      resolveVideo: (String id, {int episodeIndex = 0}) async =>
          id == 'v1' && episodeIndex == 0 ? video.path : null,
    ).run(ctx);
    expect(File(p.join(lib.path, 'Show 01.ja.srt')).existsSync(), isTrue);
    expect(outcome.outputs, contains('Show 01.ja.srt'));
    expect(ctx.output('Show 01.ja.srt').existsSync(), isTrue);
  });

  test('库里的蓝光 title：字幕不写进盘里，落在管线任务根的 disc_out 并拷进产物', () async {
    final Directory disc = Directory(p.join(tmp.path, 'lib', 'Show Disc 1'));
    final Directory playlist = Directory(p.join(disc.path, 'BDMV', 'PLAYLIST'))
      ..createSync(recursive: true);
    Directory(p.join(disc.path, 'BDMV', 'STREAM')).createSync();
    final File mpls = File(p.join(playlist.path, '00001.mpls'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final (HostJobContext ctx, _) = context(const <String, Object?>{
      'proofread': false,
      'videoId': 'v1',
    });
    final HostJobOutcome outcome = await runner(
      resolveVideo: (String id, {int episodeIndex = 0}) async =>
          id == 'v1' ? mpls.path : null,
    ).run(ctx);
    expect(
      playlist.listSync().map((FileSystemEntity e) => p.basename(e.path)),
      <String>['00001.mpls'],
      reason: '盘结构里不能多出字幕',
    );
    final File written = File(
      p.join(
        videoSubtitleDiscExportDir(
          Directory(p.join(tmp.path, 'pipeline')),
          mpls.path,
        )!.path,
        '00001.ja.srt',
      ),
    );
    expect(written.existsSync(), isTrue);
    expect(outcome.outputs, contains('00001.ja.srt'));
    expect(ctx.output('00001.ja.srt').existsSync(), isTrue);
  });

  test(
    '同盘另一条 title（discTitle）：经 resolveDiscTitlePath 定位，字幕落 disc_out 并拷进产物',
    () async {
      final Directory disc = Directory(p.join(tmp.path, 'lib', 'Show Disc 1'));
      final Directory playlist = Directory(
        p.join(disc.path, 'BDMV', 'PLAYLIST'),
      )..createSync(recursive: true);
      final File main = File(p.join(playlist.path, '00001.mpls'))
        ..writeAsBytesSync(<int>[1, 2, 3]);
      final File bonus = File(p.join(playlist.path, '00005.mpls'))
        ..writeAsBytesSync(<int>[4, 5, 6]);
      final List<(String, String)> asked = <(String, String)>[];
      final VideoSubtitleHostJobRunner r = runner(
        resolveVideo: (String id, {int episodeIndex = 0}) async =>
            id == 'v1' ? main.path : null,
        resolveDiscTitle: (String id, String title) async {
          asked.add((id, title));
          return id == 'v1' && title == 'BDMV/PLAYLIST/00005.mpls'
              ? bonus.path
              : null;
        },
      );
      expect((await r.capability())['acceptsDiscTitle'], isTrue);
      final (HostJobContext ctx, _) = context(const <String, Object?>{
        'proofread': false,
        'videoId': 'v1',
        'discTitle': 'BDMV/PLAYLIST/00005.mpls',
      });
      r.validateParams(ctx.params);
      final HostJobOutcome outcome = await r.run(ctx);
      expect(asked, <(String, String)>[('v1', 'BDMV/PLAYLIST/00005.mpls')]);
      expect(outcome.outputs, contains('00005.ja.srt'));
      expect(outcome.outputs, isNot(contains('00001.ja.srt')));
      expect(
        File(
          p.join(
            videoSubtitleDiscExportDir(
              Directory(p.join(tmp.path, 'pipeline')),
              bonus.path,
            )!.path,
            '00005.ja.srt',
          ),
        ).existsSync(),
        isTrue,
      );
      expect(
        playlist.listSync().map((FileSystemEntity e) => p.basename(e.path)),
        unorderedEquals(<String>['00001.mpls', '00005.mpls']),
        reason: '盘结构里不能多出字幕',
      );

      // 认不到的 title：明确报出是哪条 title（→ 400），不退回 videoId 那一行。
      final (HostJobContext bad, _) = context(const <String, Object?>{
        'proofread': false,
        'videoId': 'v1',
        'discTitle': 'BDMV/PLAYLIST/00009.mpls',
      }, jobId: 'j2');
      await expectLater(
        r.run(bad),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            contains('unknown videoId v1 disc title BDMV/PLAYLIST/00009.mpls'),
          ),
        ),
      );
    },
  );

  test('多角度 title 的角度成员路径（discTitle）：按 host 的装配定位，产物按角度分开落 disc_out', () async {
    final Directory disc = Directory(p.join(tmp.path, 'lib', 'Angle Disc'));
    final Directory playlist = Directory(p.join(disc.path, 'BDMV', 'PLAYLIST'))
      ..createSync(recursive: true);
    final File main = File(p.join(playlist.path, '00001.mpls'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    // 与 app 主机 / fushi_server 的 resolveDiscTitlePath 同一装配：由这一行的盘根拼出
    // title 路径，再按「本机能读到媒体」判。
    final VideoSubtitleHostJobRunner r = runner(
      resolveVideo: (String id, {int episodeIndex = 0}) async =>
          id == 'v1' ? main.path : null,
      resolveDiscTitle: (String id, String title) async {
        if (id != 'v1') return null;
        final String? path = videoBookDiscTitlePath(
          videoPath: main.path,
          discTitle: title,
        );
        return path != null && await hasLocalMediaFile(path) ? path : null;
      },
    );
    expect((await r.capability())['acceptsDiscTitleAngle'], isTrue);
    final (HostJobContext ctx, _) = context(const <String, Object?>{
      'proofread': false,
      'videoId': 'v1',
      'discTitle': 'BDMV/PLAYLIST/00001.a2.mpls',
    });
    r.validateParams(ctx.params);
    final HostJobOutcome outcome = await r.run(ctx);
    expect(outcome.outputs, contains('00001.a2.ja.srt'));
    final String angle = p.join(playlist.path, '00001.a2.mpls');
    expect(
      File(
        p.join(
          videoSubtitleDiscExportDir(
            Directory(p.join(tmp.path, 'pipeline')),
            angle,
          )!.path,
          '00001.a2.ja.srt',
        ),
      ).existsSync(),
      isTrue,
    );
    expect(
      playlist.listSync().map((FileSystemEntity e) => p.basename(e.path)),
      <String>['00001.mpls'],
      reason: '角度成员路径是虚拟的，盘结构里不能多出文件',
    );
  });

  test(
    'DVD title（discTitle）：按 host 的装配定位到同一张 DVD 的 title，产物落 disc_out',
    () async {
      final Directory disc = Directory(p.join(tmp.path, 'lib', 'Show DVD'));
      final Directory videoTs = Directory(p.join(disc.path, 'VIDEO_TS'))
        ..createSync(recursive: true);
      File(
        p.join(videoTs.path, 'VIDEO_TS.IFO'),
      ).writeAsBytesSync(<int>[1, 2, 3]);
      final String main = dvdTitlePath(disc.path, 1);
      final VideoSubtitleHostJobRunner r = runner(
        resolveVideo: (String id, {int episodeIndex = 0}) async =>
            id == 'd1' && await hasLocalMediaFile(main) ? main : null,
        resolveDiscTitle: (String id, String title) async {
          if (id != 'd1') return null;
          final String? path = videoBookDiscTitlePath(
            videoPath: main,
            discTitle: title,
          );
          return path != null && await hasLocalMediaFile(path) ? path : null;
        },
      );
      expect((await r.capability())['acceptsDiscTitleDvd'], isTrue);
      final (HostJobContext ctx, _) = context(const <String, Object?>{
        'proofread': false,
        'videoId': 'd1',
        'discTitle': 'VIDEO_TS/TITLE_02.dvdtitle',
      });
      r.validateParams(ctx.params);
      final HostJobOutcome outcome = await r.run(ctx);
      expect(outcome.outputs, contains('TITLE_02.ja.srt'));
      expect(
        File(
          p.join(
            videoSubtitleDiscExportDir(
              Directory(p.join(tmp.path, 'pipeline')),
              dvdTitlePath(disc.path, 2),
            )!.path,
            'TITLE_02.ja.srt',
          ),
        ).existsSync(),
        isTrue,
      );
      expect(
        videoTs.listSync().map((FileSystemEntity e) => p.basename(e.path)),
        <String>['VIDEO_TS.IFO'],
        reason: 'DVD title 是虚拟路径，盘结构里不能多出文件',
      );

      // 多角度 title 的第 2 个角度：定位保留角度，产物按角度分开落 disc_out。
      expect((await r.capability())['acceptsDiscTitleDvdAngle'], isTrue);
      final (HostJobContext angleCtx, _) = context(const <String, Object?>{
        'proofread': false,
        'videoId': 'd1',
        'discTitle': 'VIDEO_TS/TITLE_02.a2.dvdtitle',
      });
      r.validateParams(angleCtx.params);
      final HostJobOutcome angleOutcome = await r.run(angleCtx);
      expect(angleOutcome.outputs, contains('TITLE_02.a2.ja.srt'));
      expect(
        File(
          p.join(
            videoSubtitleDiscExportDir(
              Directory(p.join(tmp.path, 'pipeline')),
              dvdTitleAnglePath(dvdTitlePath(disc.path, 2), 1),
            )!.path,
            'TITLE_02.a2.ja.srt',
          ),
        ).existsSync(),
        isTrue,
      );
      expect(
        videoTs.listSync().map((FileSystemEntity e) => p.basename(e.path)),
        <String>['VIDEO_TS.IFO'],
        reason: '角度成员路径也是虚拟的',
      );
    },
  );

  test('播放列表第 N 集：集下标交给 resolveVideoPath，字幕写在那一集旁', () async {
    final Directory lib = Directory(p.join(tmp.path, 'lib', 'Show'))
      ..createSync(recursive: true);
    final File ep1 = File(p.join(lib.path, 'Show 01.mkv'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final File ep2 = File(p.join(lib.path, 'Show 02.mkv'))
      ..writeAsBytesSync(<int>[4, 5, 6]);
    final List<(String, int)> asked = <(String, int)>[];
    Future<String?> resolve(String id, {int episodeIndex = 0}) async {
      asked.add((id, episodeIndex));
      if (id != 'v1') return null;
      return switch (episodeIndex) {
        0 => ep1.path,
        1 => ep2.path,
        _ => null,
      };
    }

    final (HostJobContext ctx, _) = context(const <String, Object?>{
      'proofread': false,
      'videoId': 'v1',
      'episode': 1,
    });
    final HostJobOutcome outcome = await runner(resolveVideo: resolve).run(ctx);
    expect(asked, <(String, int)>[('v1', 1)]);
    expect(File(p.join(lib.path, 'Show 02.ja.srt')).existsSync(), isTrue);
    expect(
      File(p.join(lib.path, 'Show 01.ja.srt')).existsSync(),
      isFalse,
      reason: '不能落到第 1 集旁',
    );
    expect(outcome.outputs, contains('Show 02.ja.srt'));

    // 越界的集：明确报出是哪一集认不到（→ 400），不退回第 0 集。
    final (HostJobContext bad, _) = context(const <String, Object?>{
      'proofread': false,
      'videoId': 'v1',
      'episode': 5,
    }, jobId: 'j2');
    await expectLater(
      runner(resolveVideo: resolve).run(bad),
      throwsA(
        isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          contains('unknown videoId v1 episode 5'),
        ),
      ),
    );
  });

  test('库视频旁有别的语言的 ASS：另出套了它样式的 .ja.ass，作首选产物并记进 summary', () async {
    final Directory lib = Directory(p.join(tmp.path, 'lib', 'Show'))
      ..createSync(recursive: true);
    final File video = File(p.join(lib.path, 'Show 01.mkv'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final StringBuffer zh = StringBuffer()
      ..writeln('[Script Info]')
      ..writeln('PlayResX: 1920')
      ..writeln('PlayResY: 1080')
      ..writeln('[V4+ Styles]')
      ..writeln(
        'Format: Name, Fontname, Fontsize, PrimaryColour, Alignment, MarginV',
      )
      ..writeln('Style: Top,Noto Sans,70,&H0000FFFF,8,40')
      ..writeln('[Events]')
      ..writeln(
        'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, '
        'Effect, Text',
      );
    for (int i = 0; i < 12; i++) {
      final String s = (i * 2).toString().padLeft(2, '0');
      zh.writeln('Dialogue: 0,0:00:$s.00,0:00:$s.90,Top,,0,0,0,,{\\an8}第$i句');
    }
    File(p.join(lib.path, 'Show 01.zh.ass')).writeAsStringSync('$zh');
    final (HostJobContext ctx, _) = context(const <String, Object?>{
      'proofread': false,
      'videoId': 'v1',
    });
    final HostJobOutcome outcome = await runner(
      resolveVideo: (String id, {int episodeIndex = 0}) async =>
          id == 'v1' && episodeIndex == 0 ? video.path : null,
    ).run(ctx);
    expect(outcome.outputs, contains('Show 01.ja.srt'));
    expect(outcome.outputs, contains('Show 01.ja.ass'));
    expect(outcome.primaryOutput, 'Show 01.ja.ass');
    expect(
      ctx.output('Show 01.ja.ass').readAsStringSync(),
      contains(r',Top,,0,0,0,,{\an8}Show 01 台詞0'),
    );
    final Map<String, Object?> episode =
        ((jsonDecode(ctx.output(kVideoSubtitleSummaryOutput).readAsStringSync())
                        as Map<String, Object?>)['episodes']!
                    as List<Object?>)
                .single!
            as Map<String, Object?>;
    expect(episode['styledOutput'], 'Show 01.ja.ass');
    expect(episode['styleReference'], 'Show 01.zh.ass');
  });

  test('AI 请求失败：任务以「暂停：AI 请求失败（原因）」结束；识别稿已缓存，重提交不再识别', () async {
    final _Settings settings = _Settings();
    AiChatClient failing() => AiChatClient(
      client: MockClient(
        (http.Request request) async => http.Response('{}', 401),
      ),
    );
    final (HostJobContext ctx, _) = context(const <String, Object?>{});
    File(p.join(ctx.inputsDir.path, 'ep01.mkv')).writeAsBytesSync(<int>[1, 2]);
    await expectLater(
      runner(settings: settings, client: failing).run(ctx),
      throwsA(
        isA<VideoSubtitleJobPaused>()
            .having(
              (VideoSubtitleJobPaused e) => '$e',
              'message',
              startsWith('暂停：AI 请求失败（unauthorized）'),
            )
            // 第一次请求就被拒：如实报「已调用 0 次」，而不是不报。
            .having(
              (VideoSubtitleJobPaused e) => '$e',
              'message',
              contains('本次已调用 AI 0 次'),
            )
            .having(
              (VideoSubtitleJobPaused e) => e.usage?.calls,
              'usage.calls',
              0,
            ),
      ),
    );
    expect(recognizer.calls, 1);

    // 重新提交（新的 host 任务、同一个文件）：识别稿走缓存。
    final (HostJobContext again, _) = context(
      const <String, Object?>{},
      jobId: 'j2',
    );
    File(
      p.join(again.inputsDir.path, 'ep01.mkv'),
    ).writeAsBytesSync(<int>[1, 2]);
    await expectLater(
      runner(settings: settings, client: failing).run(again),
      throwsA(isA<VideoSubtitleJobPaused>()),
    );
    expect(recognizer.calls, 1);
    expect(
      Directory(p.join(tmp.path, 'pipeline'))
          .listSync(recursive: true)
          .any(
            (FileSystemEntity e) => p.basename(e.path) == 'drafts.fake.json',
          ),
      isTrue,
    );
  });

  test('取消：换成 HostJobCancelledException', () async {
    final HostJobCancelToken token = HostJobCancelToken()..cancel();
    final (HostJobContext ctx, _) = context(const <String, Object?>{
      'proofread': false,
    }, cancel: token);
    File(p.join(ctx.inputsDir.path, 'ep01.mkv')).writeAsBytesSync(<int>[1, 2]);
    await expectLater(
      runner().run(ctx),
      throwsA(isA<HostJobCancelledException>()),
    );
  });

  test('frames：参数与能力位；只在 host 的提供商能收图时带画面（任务目录记下），否则纯文字', () async {
    expect(
      VideoSubtitleJobParams.parse(const <String, Object?>{
        'frames': true,
      }).frames,
      isTrue,
    );
    expect(
      VideoSubtitleJobParams.parse(const <String, Object?>{}).frames,
      isFalse,
      reason: '老客户端不带这个参数 = 不发画面',
    );
    expect(
      () => VideoSubtitleJobParams.parse(const <String, Object?>{
        'frames': 'maybe',
      }),
      throwsFormatException,
    );
    expect((await runner().capability())['framesAvailable'], isFalse);
    expect(
      (await runner(settings: _Settings()).capability())['framesAvailable'],
      isFalse,
    );
    expect(
      (await runner(
        settings: _Settings(images: true),
      ).capability())['framesAvailable'],
      isTrue,
    );

    AiChatClient failing() => AiChatClient(
      client: MockClient(
        (http.Request request) async => http.Response('{}', 401),
      ),
    );
    // 管线在第一次 AI 请求（401）之前就把「这次校对带不带画面」记进任务目录。
    Future<bool> recordedFrames(
      String jobId, {
      required bool images,
      required bool frames,
    }) async {
      final Directory pipeline = Directory(p.join(tmp.path, 'pipeline'));
      if (pipeline.existsSync()) pipeline.deleteSync(recursive: true);
      final (HostJobContext ctx, _) = context(<String, Object?>{
        'frames': frames,
      }, jobId: jobId);
      File(
        p.join(ctx.inputsDir.path, 'ep01.mkv'),
      ).writeAsBytesSync(<int>[1, 2]);
      await expectLater(
        runner(
          settings: _Settings(images: images),
          client: failing,
        ).run(ctx),
        throwsA(isA<VideoSubtitleJobPaused>()),
      );
      final File state = pipeline
          .listSync(recursive: true)
          .whereType<File>()
          .singleWhere((File f) => p.basename(f.path) == 'state.json');
      return (jsonDecode(state.readAsStringSync())
              as Map<String, Object?>)['frames'] ==
          true;
    }

    expect(await recordedFrames('f1', images: true, frames: true), isTrue);
    expect(await recordedFrames('f2', images: false, frames: true), isFalse);
    expect(await recordedFrames('f3', images: true, frames: false), isFalse);
  });

  test('audioTrack：交给管线按播放器当前音轨识别；不给按语言挑', () async {
    final Directory lib = Directory(p.join(tmp.path, 'lib', 'Show'))
      ..createSync(recursive: true);
    final File ep1 = File(p.join(lib.path, 'Show 01.mkv'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final File ep2 = File(p.join(lib.path, 'Show 02.mkv'))
      ..writeAsBytesSync(<int>[4, 5, 6]);
    Future<String?> resolve(String id, {int episodeIndex = 0}) async =>
        id == 'v1' ? (episodeIndex == 0 ? ep1.path : ep2.path) : null;
    final List<(String, int)> mapped = <(String, int)>[];
    // 音轨序号 → 流序号：第 N 条音轨在流 N + 1（流 0 是视频）。
    Future<int?> streams(String videoPath, int audioTrack) async {
      mapped.add((p.basename(videoPath), audioTrack));
      return audioTrack + 1;
    }

    final VideoSubtitleHostJobRunner r = runner(
      resolveVideo: resolve,
      resolveAudioStream: streams,
    );
    expect((await r.capability())['acceptsAudioTrack'], isTrue);
    final (HostJobContext ctx, _) = context(const <String, Object?>{
      'proofread': false,
      'videoId': 'v1',
      'episode': 1,
      'audioTrack': 1,
    });
    await r.run(ctx);
    expect(mapped, <(String, int)>[('Show 02.mkv', 1)]);
    expect(recognizer.streams, <(String, int?)>[('Show 02.mkv', 2)]);

    // 不带 audioTrack（批量 / 老客户端）：不换算，按识别语言挑（null）。
    final (HostJobContext plain, _) = context(const <String, Object?>{
      'proofread': false,
      'videoId': 'v1',
    }, jobId: 'j2');
    await r.run(plain);
    expect(mapped, hasLength(1));
    expect(recognizer.streams.last, ('Show 01.mkv', null));
  });

  test('capability 报能力位；没装 AI 时 proofreadAvailable = false', () async {
    final Map<String, Object?> cap = await runner().capability();
    expect(cap['proofreadAvailable'], isFalse);
    expect(cap['acceptsCollectionId'], isFalse);
    // 没接 resolveVideoPath 的 host 不认 videoId，自然也不认集下标。
    expect(cap['acceptsEpisode'], isFalse);
    expect(
      (await runner(
        resolveVideo: (String _, {int episodeIndex = 0}) async => null,
      ).capability())['acceptsEpisode'],
      isTrue,
    );
    // 没接 resolveDiscTitlePath 的 host 不认 discTitle（老 host 形状）。
    expect(cap['acceptsDiscTitle'], isFalse);
    expect(cap['acceptsDiscTitleAngle'], isFalse);
    expect(cap['acceptsDiscTitleDvd'], isFalse);
    expect(cap['acceptsDiscTitleDvdAngle'], isFalse);
    // 没接 resolveVideoPath：不认 videoId，也就不认 audioTrack。
    expect(cap['acceptsAudioTrack'], isFalse);
    expect(
      (await runner(
        resolveVideo: (String _, {int episodeIndex = 0}) async => null,
      ).capability())['acceptsDiscTitle'],
      isFalse,
    );
    expect(cap['segmenters'], <String>['auto', 'moss', 'window']);
    expect(
      (await runner(settings: _Settings()).capability())['proofreadAvailable'],
      isTrue,
    );
    expect(runner().kind, kVideoSubtitleJobKind);
    expect(
      runner().contentTypeFor('a.srt'),
      startsWith('application/x-subrip'),
    );
  });

  test('capability 的 MOSS 状态缓存按首次探测时刻过期，轮询不会把它续命', () async {
    DateTime now = DateTime(2026, 10, 19, 12);
    int probes = 0;
    final VideoSubtitleHostJobRunner r = VideoSubtitleHostJobRunner(
      resolveRecognizer:
          (
            VideoSubtitleSegmenterMode mode,
            MossBackendPreference b,
            VideoSubtitleLanguage _,
          ) async => VideoSubtitleRecognizerChoice(recognizer: recognizer),
      pipelineJobsRoot: Directory(p.join(tmp.path, 'pipeline')),
      mossStatus: (MossBackendPreference _) async {
        probes++;
        return const MossProvisionStatus(
          decision: MossBackendDecision.unavailable(
            MossUnavailableCode.noGpu,
            'no gpu',
          ),
        );
      },
      mossStatusCacheTtl: const Duration(minutes: 1),
      clock: () => now,
    );
    await r.capability();
    expect(probes, 1);
    // 每 30 秒轮询一次：第一次命中缓存；到 60 秒时缓存必须已经过期重探，
    // 而不是被上一次命中刷新了时间戳。
    now = now.add(const Duration(seconds: 30));
    await r.capability();
    expect(probes, 1);
    now = now.add(const Duration(seconds: 30));
    await r.capability();
    expect(probes, 2);
  });

  test('总进度按阶段区间折算', () {
    expect(
      videoSubtitleOverallProgress(
        const VideoSubtitleProgress(
          stage: VideoSubtitleStage.recognize,
          fraction: 0.5,
          message: '',
        ),
      ),
      closeTo(0.3, 1e-9),
    );
    expect(
      videoSubtitleOverallProgress(
        const VideoSubtitleProgress(
          stage: VideoSubtitleStage.export,
          fraction: 1,
          message: '',
        ),
      ),
      1,
    );
  });
}
