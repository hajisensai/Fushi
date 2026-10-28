import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/moss_provisioning.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_host_job_runner.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart';
import 'package:fushi_engine/sync/host_jobs/host_job_runner.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

class _Recognizer implements VideoSubtitleRecognizer {
  int calls = 0;

  @override
  String get id => 'fake';

  @override
  Future<List<SubtitleDraftCue>> recognize({
    required String videoPath,
    required Directory workDir,
    required VideoSubtitleRecognizeProgress onProgress,
    required SubtitleCancelToken cancel,
  }) async {
    calls++;
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
  _Settings({this.assigned = true});

  final bool assigned;

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
    Future<String?> Function(String)? resolveVideo,
  }) => VideoSubtitleHostJobRunner(
    resolveRecognizer:
        (VideoSubtitleSegmenterMode mode, MossBackendPreference backend) async {
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
    probeDurationMs: (String _) async => 1440000,
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
        resolveVideo: (String _) async => null,
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
      resolveVideo: (String id) async => id == 'v1' ? video.path : null,
    ).run(ctx);
    expect(File(p.join(lib.path, 'Show 01.ja.srt')).existsSync(), isTrue);
    expect(outcome.outputs, contains('Show 01.ja.srt'));
    expect(ctx.output('Show 01.ja.srt').existsSync(), isTrue);
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
      resolveVideo: (String id) async => id == 'v1' ? video.path : null,
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

  test('capability 报能力位；没装 AI 时 proofreadAvailable = false', () async {
    final Map<String, Object?> cap = await runner().capability();
    expect(cap['proofreadAvailable'], isFalse);
    expect(cap['acceptsCollectionId'], isFalse);
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
          (VideoSubtitleSegmenterMode mode, MossBackendPreference b) async =>
              VideoSubtitleRecognizerChoice(recognizer: recognizer),
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
