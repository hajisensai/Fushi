import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary_builder.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer.dart';
import 'package:path/path.dart' as p;

import '../../../../helpers/fake_ai_text_completer.dart';

/// 识别器替身：按文件名给稿，记调用次数。
class _FakeRecognizer implements VideoSubtitleRecognizer {
  _FakeRecognizer(this.drafts);

  final Map<String, List<SubtitleDraftCue>> drafts;
  final List<String> calls = <String>[];

  @override
  String get id => 'fake';

  @override
  Future<List<SubtitleDraftCue>> recognize({
    required String videoPath,
    required Directory workDir,
    required VideoSubtitleRecognizeProgress onProgress,
    required SubtitleCancelToken cancel,
  }) async {
    calls.add(p.basename(videoPath));
    onProgress(0.5, 'half');
    return drafts[p.basename(videoPath)]!;
  }
}

List<SubtitleDraftCue> _lines(List<String> texts) => <SubtitleDraftCue>[
  for (int i = 0; i < texts.length; i++)
    SubtitleDraftCue(
      startMs: 1000 + i * 3000,
      endMs: 1000 + i * 3000 + 2000,
      text: texts[i],
    ),
];

final RegExp _kMain = RegExp(r'^id=(\d+) \[[^\]]*\] 主: (.*)$', multiLine: true);
final RegExp _kClipId = RegExp(r'^id=([0-9a-f]{40})$', multiLine: true);

/// 按提示词种类作答：S0 专名表 / S3 原样返回 / S4 结衣→唯 / 短片段一律 song。
String _answer(String prompt, int call) {
  if (prompt.contains('誤認識されやすい固有名詞の表')) {
    return jsonEncode(<Map<String, Object?>>[
      <String, Object?>{
        'ja': '唯',
        'reading': 'ゆい',
        'kind': '人名',
        'misrecognitions': <String>['結衣'],
      },
    ]);
  }
  if (prompt.startsWith('あなたは日本語アニメ字幕の校正者')) {
    return jsonEncode(<String, String>{
      for (final RegExpMatch m in _kMain.allMatches(prompt))
        m.group(1)!: m.group(2)!,
    });
  }
  if (prompt.startsWith('あなたは日本語アニメ「')) {
    return replyForIds(prompt, (int id) => '唯が来た!');
  }
  if (prompt.contains('特典映像・短編')) {
    return jsonEncode(<String, String>{
      for (final RegExpMatch m in _kClipId.allMatches(prompt))
        m.group(1)!: 'song',
    });
  }
  throw StateError('unexpected prompt: ${prompt.substring(0, 40)}');
}

void main() {
  late Directory tmp;
  late Directory videos;
  late Directory jobs;
  late SubtitleGlossaryFileStore store;

  const SubtitleWorkContext work = SubtitleWorkContext(
    workKey: 'collection:7',
    title: 'K-ON!!',
    originalTitle: 'けいおん!!',
  );

  final Map<String, List<SubtitleDraftCue>> drafts =
      <String, List<SubtitleDraftCue>>{
        'ep01.mkv': _lines(<String>['結衣が来た', 'こんにちは?', 'ありがとう', 'またね']),
        'ep02.mkv': _lines(<String>['今日は練習', 'お茶にしよう', 'そうだね', 'うん']),
        'op.mkv': _lines(<String>['ラララ', 'ルルル', 'Yeah', 'ラララ']),
      };

  String video(String name) => p.join(videos.path, name);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vsp_');
    videos = Directory(p.join(tmp.path, 'videos'))..createSync();
    jobs = Directory(p.join(tmp.path, 'jobs'));
    store = SubtitleGlossaryFileStore(Directory(p.join(tmp.path, 'glossary')));
    for (final String name in drafts.keys) {
      File(video(name)).writeAsBytesSync(List<int>.filled(name.length, 1));
    }
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<int?> duration(String path) async =>
      p.basename(path) == 'op.mkv' ? 90000 : 1440000;

  VideoSubtitlePipeline pipeline(
    _FakeRecognizer recognizer, {
    AiTextCompleter? ai,
    SubtitleDisplaySplitter? splitter,
  }) => VideoSubtitlePipeline(
    recognizer: recognizer,
    jobsRoot: jobs,
    styleReference: null,
    ai: ai == null
        ? null
        : VideoSubtitleAiConfig(completer: ai, glossaryStore: store),
    displaySplitter: splitter,
    probeDurationMs: duration,
  );

  final List<String> season = <String>['ep01.mkv', 'ep02.mkv', 'op.mkv'];

  test('AI 全流程：S0 → S3 → S4 → 歌曲判定 → 导出；各阶段产物落盘', () async {
    final FakeAiCompleter ai = FakeAiCompleter(
      _answer,
      usage: const AiChatUsage(inputTokens: 10),
    );
    final _FakeRecognizer rec = _FakeRecognizer(drafts);
    final List<VideoSubtitleProgress> progress = <VideoSubtitleProgress>[];
    final VideoSubtitlePipelineResult r = await pipeline(rec, ai: ai).run(
      videoPaths: season.map(video).toList(),
      work: work,
      wholeSeason: true,
      onProgress: progress.add,
    );
    expect(rec.calls, season);
    expect(
      r.episodes.map((VideoSubtitleEpisodeResult e) => e.status),
      <VideoSubtitleEpisodeStatus>[
        VideoSubtitleEpisodeStatus.exported,
        VideoSubtitleEpisodeStatus.exported,
        VideoSubtitleEpisodeStatus.skippedSong,
      ],
    );
    final String srt = File(
      p.join(videos.path, 'ep01.ja.srt'),
    ).readAsStringSync();
    expect(srt, contains('唯が来た！'));
    expect(srt, contains('こんにちは？'));
    expect(srt, startsWith('1\n00:00:01,000 --> 00:00:03,000\n'));
    expect(File(p.join(videos.path, 'op.ja.srt')).existsSync(), isFalse);

    final Directory dir = Directory(
      p.join(jobs.path, videoSubtitleJobId(video('ep01.mkv'))),
    );
    for (final String name in <String>[
      'drafts.fake.json',
      'proofread/00000.json',
      'consistency.json',
      'final.json',
      'state.json',
    ]) {
      expect(File(p.join(dir.path, name)).existsSync(), isTrue, reason: name);
    }
    expect(File(p.join(jobs.path, 'clip_kinds.json')).existsSync(), isTrue);
    expect((await store.load('collection:7'))!.entries.single.ja, '唯');
    expect(r.glossaryRegenerated, isTrue);
    expect(r.usage.calls, ai.calls);
    expect(r.usage.inputTokens, 10 * ai.calls);
    expect(
      progress.map((VideoSubtitleProgress e) => e.stage).toSet(),
      containsAll(<VideoSubtitleStage>[
        VideoSubtitleStage.recognize,
        VideoSubtitleStage.glossary,
        VideoSubtitleStage.proofread,
        VideoSubtitleStage.songCheck,
        VideoSubtitleStage.export,
      ]),
    );

    // 续跑：所有阶段都已落盘 → 不识别、不请求 AI；用量从缓存带出（专名表那次不计）。
    final _FakeRecognizer rec2 = _FakeRecognizer(drafts);
    final ExplodingAiCompleter none = ExplodingAiCompleter();
    final VideoSubtitlePipelineResult again = await pipeline(
      rec2,
      ai: none,
    ).run(videoPaths: season.map(video).toList(), work: work);
    expect(rec2.calls, isEmpty);
    expect(none.calls, 0);
    expect(again.episodes.first.status, VideoSubtitleEpisodeStatus.exported);
    expect(again.usage.calls, ai.calls - 1);
  });

  test('AI 请求失败（额度）：抛 SubtitleAiRequestFailure，缓存保留，重跑即续', () async {
    final FakeAiCompleter failing = FakeAiCompleter((String prompt, int call) {
      if (prompt.startsWith('あなたは日本語アニメ字幕の校正者')) {
        throw const SubtitleAiRequestFailure('quota_exhausted');
      }
      return _answer(prompt, call);
    });
    final _FakeRecognizer rec = _FakeRecognizer(drafts);
    await expectLater(
      pipeline(
        rec,
        ai: failing,
      ).run(videoPaths: <String>[video('ep01.mkv')], work: work),
      throwsA(
        isA<SubtitleAiRequestFailure>().having(
          (SubtitleAiRequestFailure f) => f.reason,
          'reason',
          'quota_exhausted',
        ),
      ),
    );
    expect(File(p.join(videos.path, 'ep01.ja.srt')).existsSync(), isFalse);

    final _FakeRecognizer rec2 = _FakeRecognizer(drafts);
    final FakeAiCompleter good = FakeAiCompleter(_answer);
    final VideoSubtitlePipelineResult r = await pipeline(
      rec2,
      ai: good,
    ).run(videoPaths: <String>[video('ep01.mkv')], work: work);
    expect(rec2.calls, isEmpty, reason: '识别稿已缓存');
    expect(
      good.prompts.where((String s) => s.contains('誤認識されやすい固有名詞の表')),
      isEmpty,
      reason: '专名表已存、资料没变',
    );
    expect(r.episodes.single.status, VideoSubtitleEpisodeStatus.exported);
  });

  test('AI 关闭：只识别 + 拆分 + 导出；不做歌曲判定', () async {
    final _FakeRecognizer rec = _FakeRecognizer(drafts);
    final VideoSubtitlePipelineResult r = await pipeline(
      rec,
      splitter: (List<SubtitleDraftCue> cues) => <SubtitleDraftCue>[
        for (final SubtitleDraftCue c in cues) ...<SubtitleDraftCue>[
          c.copyWith(endMs: c.startMs + 1000),
          c.copyWith(startMs: c.startMs + 1000, text: '${c.text}(後)'),
        ],
      ],
    ).run(videoPaths: season.map(video).toList(), work: work);
    expect(r.glossary, isNull);
    expect(r.usage.calls, 0);
    expect(
      r.episodes.every((VideoSubtitleEpisodeResult e) => e.exported),
      isTrue,
    );
    final String srt = File(
      p.join(videos.path, 'ep01.ja.srt'),
    ).readAsStringSync();
    expect(srt, contains('結衣が来た'), reason: '没有 AI 就没有校对');
    expect(r.episodes.first.cueCount, 8, reason: '拆分注入点生效');
    expect(srt, contains('結衣が来た(後)'));
  });

  test('≥60% 是 ♪ / 不足 3 行：不导出', () async {
    final _FakeRecognizer rec = _FakeRecognizer(
      <String, List<SubtitleDraftCue>>{
        'ep01.mkv': _lines(<String>['♪ラララ', '♪ルルル', '♪あああ', 'セリフ']),
        'ep02.mkv': _lines(<String>['はい', 'いいえ']),
      },
    );
    final VideoSubtitlePipelineResult r = await pipeline(rec).run(
      videoPaths: <String>[video('ep01.mkv'), video('ep02.mkv')],
      work: work,
    );
    expect(
      r.episodes.map((VideoSubtitleEpisodeResult e) => e.status),
      everyElement(VideoSubtitleEpisodeStatus.skippedNoDialogue),
    );
    expect(File(p.join(videos.path, 'ep01.ja.srt')).existsSync(), isFalse);
  });

  test('已有同名字幕不覆盖：改写 .ja.asr.srt；本管线写的 .asr.srt 重跑可更新', () async {
    final File userSrt = File(p.join(videos.path, 'ep01.ja.srt'))
      ..writeAsStringSync('user subtitle');
    final VideoSubtitlePipelineResult r = await pipeline(
      _FakeRecognizer(drafts),
    ).run(videoPaths: <String>[video('ep01.mkv')], work: work);
    expect(r.episodes.single.status, VideoSubtitleEpisodeStatus.exportedAsAsr);
    expect(userSrt.readAsStringSync(), 'user subtitle');
    final File asr = File(p.join(videos.path, 'ep01.ja.asr.srt'));
    expect(asr.readAsStringSync(), contains('結衣が来た'));

    final VideoSubtitlePipelineResult again = await pipeline(
      _FakeRecognizer(drafts),
    ).run(videoPaths: <String>[video('ep01.mkv')], work: work);
    expect(
      again.episodes.single.status,
      VideoSubtitleEpisodeStatus.exportedAsAsr,
    );
    expect(userSrt.readAsStringSync(), 'user subtitle');
  });

  test('.ja.srt 与 .ja.asr.srt 都已存在且都不是本管线写的：跳过并报原因', () async {
    File(p.join(videos.path, 'ep01.ja.srt')).writeAsStringSync('a');
    File(p.join(videos.path, 'ep01.ja.asr.srt')).writeAsStringSync('b');
    final VideoSubtitlePipelineResult r = await pipeline(
      _FakeRecognizer(drafts),
    ).run(videoPaths: <String>[video('ep01.mkv')], work: work);
    expect(
      r.episodes.single.status,
      VideoSubtitleEpisodeStatus.skippedBothExist,
    );
    expect(r.episodes.single.reason, contains('not written by this pipeline'));
    expect(
      File(p.join(videos.path, 'ep01.ja.asr.srt')).readAsStringSync(),
      'b',
    );
  });

  test('整季模式：已有 .ja.srt 的集直接跳过、不识别', () async {
    File(p.join(videos.path, 'ep01.ja.srt')).writeAsStringSync('mine');
    final _FakeRecognizer rec = _FakeRecognizer(drafts);
    final VideoSubtitlePipelineResult r = await pipeline(rec).run(
      videoPaths: <String>[video('ep01.mkv'), video('ep02.mkv')],
      work: work,
      wholeSeason: true,
    );
    expect(rec.calls, <String>['ep02.mkv']);
    expect(
      r.episodes.first.status,
      VideoSubtitleEpisodeStatus.skippedExistingSubtitle,
    );
    expect(r.episodes.last.status, VideoSubtitleEpisodeStatus.exported);
  });

  test('已取消：抛 SubtitlePipelineCancelled，不识别', () async {
    final SubtitleCancelSource cancel = SubtitleCancelSource()..cancel();
    final _FakeRecognizer rec = _FakeRecognizer(drafts);
    await expectLater(
      pipeline(rec).run(
        videoPaths: <String>[video('ep01.mkv')],
        work: work,
        cancel: cancel,
      ),
      throwsA(isA<SubtitlePipelineCancelled>()),
    );
    expect(rec.calls, isEmpty);
  });

  test('resetVideoSubtitleJobFrom：只删指定阶段及之后的产物', () async {
    final FakeAiCompleter ai = FakeAiCompleter(_answer);
    await pipeline(
      _FakeRecognizer(drafts),
      ai: ai,
    ).run(videoPaths: <String>[video('ep01.mkv')], work: work);
    final Directory dir = Directory(
      p.join(jobs.path, videoSubtitleJobId(video('ep01.mkv'))),
    );
    await resetVideoSubtitleJobFrom(dir, VideoSubtitleStage.consistency);
    expect(File(p.join(dir.path, 'drafts.fake.json')).existsSync(), isTrue);
    expect(Directory(p.join(dir.path, 'proofread')).existsSync(), isTrue);
    expect(File(p.join(dir.path, 'consistency.json')).existsSync(), isFalse);
    expect(File(p.join(dir.path, 'final.json')).existsSync(), isFalse);
  });

  test('费用预估：按 sin 七つの大罪 的量级（43 段 ~3.4k 句 + 3 候选稿）落在实测附近', () {
    final List<List<SubtitleDraftCue>> eps = <List<SubtitleDraftCue>>[
      for (int e = 0; e < 43; e++)
        <SubtitleDraftCue>[
          for (int i = 0; i < 78; i++)
            SubtitleDraftCue(
              startMs: i * 4000,
              endMs: i * 4000 + 3000,
              text: 'あ' * (15 + i % 2),
              alternatives: <String>[
                for (int k = 0; k < 3; k++) 'い' * (15 + (i + k) % 2),
              ],
            ),
        ],
    ];
    final SubtitleGlossary glossary = SubtitleGlossary(
      entries: <SubtitleGlossaryEntry>[
        for (int i = 0; i < 63; i++)
          SubtitleGlossaryEntry(
            ja: '名前$i',
            reading: 'なまえ',
            kind: '人名(主人公の名)',
            misrecognitions: const <String>['名前', 'ナマエ', '生前'],
          ),
      ],
    );
    final SubtitleProofreadCostEstimate est = estimateSubtitleProofreadCost(
      episodes: eps,
      title: 'sin 七つの大罪',
      glossary: glossary,
    );
    expect(est.batches, 129);
    // 实测：1,587,877 输入（缓存写入 + 读取）/ 124,189 输出。
    expect(est.inputTokens, inInclusiveRange(1270000, 1900000));
    expect(est.outputTokens, inInclusiveRange(100000, 150000));
  });
}
