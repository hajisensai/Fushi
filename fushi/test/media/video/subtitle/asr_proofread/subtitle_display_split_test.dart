import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_asr_core/asr_core.dart' show AsrCueTokenTiming;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_display_split.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary_builder.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_work_context_loader.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer.dart';
import 'package:path/path.dart' as p;

import '../../../../helpers/fake_ai_text_completer.dart';

/// 一条 9 秒、三句的长条，逐字 token：第 i 个字 [i*300, i*300+250]。
SubtitleDraftCue _longCue() {
  const String text = 'おはよう。今日はいい天気だね。どこに行く?';
  final List<String> chars = text.split('');
  return SubtitleDraftCue(
    startMs: 10000,
    endMs: 19000,
    text: text,
    speaker: '1:S01',
    alternatives: const <String>['候補'],
    tokenTiming: AsrCueTokenTiming(
      tokens: chars,
      offsetsMs: <int>[for (int i = 0; i < chars.length; i++) i * 300],
      endOffsetsMs: <int>[for (int i = 0; i < chars.length; i++) i * 300 + 250],
    ),
  );
}

class _OneCueRecognizer implements VideoSubtitleRecognizer {
  _OneCueRecognizer([this.id = 'fake']);

  @override
  final String id;

  @override
  Future<List<SubtitleDraftCue>> recognize({
    required String videoPath,
    required Directory workDir,
    required VideoSubtitleRecognizeProgress onProgress,
    required SubtitleCancelToken cancel,
  }) async => <SubtitleDraftCue>[
    const SubtitleDraftCue(startMs: 0, endMs: 1000, text: 'はい!'),
    const SubtitleDraftCue(startMs: 2000, endMs: 3000, text: 'うん'),
    _longCue(),
  ];
}

void main() {
  test('长条在句末拆开、切点取下一句首字开始减 0.1 s；token 按片分配且偏移改成相对片起点', () {
    final List<SubtitleDraftCue> out = splitSubtitleDraftCuesForDisplay(
      <SubtitleDraftCue>[_longCue()],
    );
    expect(out.map((SubtitleDraftCue c) => c.text), <String>[
      'おはよう。',
      '今日はいい天気だね。',
      'どこに行く？',
    ]);
    // 「今」是第 5 个字：开始 1500 ms，减 0.1 s，不早于前一字终点 1450。
    expect(out[1].startMs, 10000 + 1450);
    expect(out[0].endMs, out[1].startMs);
    expect(out.last.endMs, 19000);
    expect(out.every((SubtitleDraftCue c) => c.speaker == '1:S01'), isTrue);
    expect(out.every((SubtitleDraftCue c) => c.alternatives.isEmpty), isTrue);
    expect(out[1].tokenTiming!.tokens.first, '今');
    expect(out[1].tokenTiming!.offsetsMs.first, 1500 - 1450);
    expect(out[1].tokenTiming!.endOffsetsMs!.first, 1750 - 1450);
  });

  test('不长的条目原样保留（只统一全角）', () {
    const SubtitleDraftCue short = SubtitleDraftCue(
      startMs: 0,
      endMs: 2000,
      text: 'え?本当!',
      alternatives: <String>['候補'],
    );
    final List<SubtitleDraftCue> out = splitSubtitleDraftCuesForDisplay(
      <SubtitleDraftCue>[short],
    );
    expect(out.single.text, 'え？本当！');
    expect(out.single.alternatives, <String>['候補']);
  });

  test('管线默认就带拆分；拆分后的 token 时间（含终点）写进 final.json，SRT 旁不写 sidecar', () async {
    final Directory tmp = Directory.systemTemp.createTempSync('vsds_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final File video = File(p.join(tmp.path, 'ep01.mkv'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final VideoSubtitlePipeline pipeline = VideoSubtitlePipeline(
      recognizer: _OneCueRecognizer(),
      jobsRoot: Directory(p.join(tmp.path, 'jobs')),
      probeDurationMs: (String _) async => 1440000,
      styleReference: null,
    );
    final VideoSubtitlePipelineResult r = await pipeline.run(
      videoPaths: <String>[video.path],
      work: SubtitleWorkContext(
        workKey: fallbackSubtitleWorkKey(title: 'x'),
        title: 'x',
      ),
    );
    expect(r.episodes.single.cueCount, 5);
    final Map<String, Object?> finalJson =
        jsonDecode(
              File(
                p.join(
                  pipeline.jobDirFor(video.path).path,
                  VideoSubtitleJobFiles.finalCues,
                ),
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    final List<SubtitleDraftCue> cues = decodeSubtitleDraftCues(
      jsonEncode(finalJson),
    );
    expect(cues.first.text, 'はい！');
    expect(cues[2].text, 'おはよう。');
    expect(cues[3].tokenTiming!.endOffsetsMs, isNotNull);
    expect(
      File(pipeline.subtitlePathFor(video.path)).readAsStringSync(),
      contains('どこに行く？'),
    );
    expect(
      tmp
          .listSync()
          .whereType<File>()
          .map((File f) => p.basename(f.path))
          .where((String n) => n.endsWith('.jsonl')),
      isEmpty,
    );
  });

  test('阶段缓存认识别器与校对开关：先不校对再开 AI 会真校对；换识别器作废校对缓存', () async {
    final Directory tmp = Directory.systemTemp.createTempSync('vsdk_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final File video = File(p.join(tmp.path, 'ep01.mkv'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final Directory jobs = Directory(p.join(tmp.path, 'jobs'));
    final SubtitleGlossaryFileStore store = SubtitleGlossaryFileStore(
      Directory(p.join(tmp.path, 'g')),
    );
    final SubtitleWorkContext work = SubtitleWorkContext(
      workKey: fallbackSubtitleWorkKey(title: 'x'),
      title: 'x',
    );
    VideoSubtitlePipeline pipeline(String id, AiTextCompleter? ai) =>
        VideoSubtitlePipeline(
          recognizer: _OneCueRecognizer(id),
          jobsRoot: jobs,
          probeDurationMs: (String _) async => 1440000,
          styleReference: null,
          ai: ai == null
              ? null
              : VideoSubtitleAiConfig(completer: ai, glossaryStore: store),
        );

    await pipeline(
      'fake',
      null,
    ).run(videoPaths: <String>[video.path], work: work);
    final FakeAiCompleter ai = FakeAiCompleter(
      (String prompt, int call) => prompt.startsWith('日本のアニメ')
          ? '[{"ja": "唯", "reading": "ゆい", "kind": "人名"}]'
          : replyForIds(prompt, (int id) => '校正$id'),
    );
    await pipeline(
      'fake',
      ai,
    ).run(videoPaths: <String>[video.path], work: work);
    expect(ai.bodies.where((String b) => b.contains('id=0 ')), isNotEmpty);
    expect(
      File(
        pipeline('fake', null).subtitlePathFor(video.path),
      ).readAsStringSync(),
      contains('校正0'),
    );

    // 同一识别器、同一开关：全走缓存。
    await pipeline(
      'fake',
      ExplodingAiCompleter(),
    ).run(videoPaths: <String>[video.path], work: work);
    // 换识别器：旧稿派生的校对缓存作废，必须重新问。
    await expectLater(
      pipeline(
        'other',
        ExplodingAiCompleter(),
      ).run(videoPaths: <String>[video.path], work: work),
      throwsA(isA<SubtitleAiRequestFailure>()),
    );
  });

  group('失败时带出这次已花的 AI 用量', () {
    late Directory tmp;
    late File video;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('vsdu_');
      video = File(p.join(tmp.path, 'ep01.mkv'))..writeAsBytesSync(<int>[1, 2]);
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    VideoSubtitlePipeline pipeline(AiTextCompleter ai) => VideoSubtitlePipeline(
      recognizer: _OneCueRecognizer(),
      jobsRoot: Directory(p.join(tmp.path, 'jobs')),
      probeDurationMs: (String _) async => 1440000,
      styleReference: null,
      ai: VideoSubtitleAiConfig(
        completer: ai,
        glossaryStore: SubtitleGlossaryFileStore(
          Directory(p.join(tmp.path, 'g')),
        ),
      ),
    );
    final SubtitleWorkContext bare = SubtitleWorkContext(
      workKey: fallbackSubtitleWorkKey(title: 'x'),
      title: 'x',
    );

    test('专名表校验失败：生成 + 两次重做共 3 次调用照实上报', () async {
      // 4 个人名一个都没在识别稿里出现、也没有片假名证据 → 无刮削路径硬失败。
      final FakeAiCompleter ai = FakeAiCompleter(
        (String prompt, int call) =>
            '[{"ja":"別人甲","kind":"人名"},{"ja":"別人乙","kind":"人名"},'
            '{"ja":"別人丙","kind":"人名"},{"ja":"別人丁","kind":"人名"}]',
        usage: const AiChatUsage(inputTokens: 100, outputTokens: 10),
      );
      await expectLater(
        pipeline(ai).run(videoPaths: <String>[video.path], work: bare),
        throwsA(
          isA<SubtitleGlossaryValidationFailure>().having(
            (SubtitleGlossaryValidationFailure e) =>
                (e.usage?.calls, e.usage?.inputTokens, e.usage?.outputTokens),
            'usage',
            (3, 300, 30),
          ),
        ),
      );
    });

    test('AI 请求失败：失败之前成功的调用照实上报（不是 0 次）', () async {
      final FakeAiCompleter glossary = FakeAiCompleter(
        (String prompt, int call) =>
            '[{"ja": "唯", "reading": "ゆい", "kind": "人名"}]',
        usage: const AiChatUsage(inputTokens: 50, outputTokens: 5),
      );
      final _FailAfter ai = _FailAfter(glossary, okCalls: 1);
      await expectLater(
        pipeline(ai).run(videoPaths: <String>[video.path], work: bare),
        throwsA(
          isA<SubtitleAiRequestFailure>()
              .having(
                (SubtitleAiRequestFailure e) => e.reason,
                'reason',
                'quota_exhausted',
              )
              .having(
                (SubtitleAiRequestFailure e) =>
                    (e.usage?.calls, e.usage?.inputTokens),
                'usage',
                (1, 50),
              ),
        ),
      );
    });
  });
}

/// 前 [okCalls] 次交给 [inner]，之后一律额度用尽。
class _FailAfter implements AiTextCompleter {
  _FailAfter(this.inner, {required this.okCalls});

  final AiTextCompleter inner;
  final int okCalls;
  int _calls = 0;

  @override
  Future<AiChatCompletion> complete(String prompt, {String stablePrefix = ''}) {
    if (_calls++ < okCalls) {
      return inner.complete(prompt, stablePrefix: stablePrefix);
    }
    throw const SubtitleAiRequestFailure('quota_exhausted');
  }
}
