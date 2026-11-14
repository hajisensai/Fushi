import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_evidence.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_evidence_loader.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_frame_reference.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary_builder.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_language.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_proofreader.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_prompts_zh.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer.dart';
import 'package:path/path.dart' as p;

import '../../../../helpers/fake_ai_text_completer.dart';

/// 「交给 AI 的参考」（spec `2026-11-11-video-subtitle-ai-reference`）：
/// - 画面：每批挑哪些时刻、取不到怎么办、图片与清单真的进了发给 AI 的那条消息、
///   开关一变校对缓存作废、费用预估把图片算进去；
/// - 用户指定的参考字幕（播放器里对照着的那条）：只收其它语言、压过自动找到的同
///   语言轨、内容变了缓存键跟着变。

class _FakeRecognizer implements VideoSubtitleRecognizer {
  _FakeRecognizer(this.drafts);

  final List<SubtitleDraftCue> drafts;

  @override
  String get id => 'fake';

  @override
  Future<List<SubtitleDraftCue>> recognize({
    required String videoPath,
    required Directory workDir,
    required VideoSubtitleRecognizeProgress onProgress,
    required SubtitleCancelToken cancel,
  }) async => drafts;
}

class _FixedEvidence implements SubtitleEvidenceSource {
  _FixedEvidence(this.tracks);

  final List<SubtitleEvidenceTrack> tracks;

  @override
  Future<String> sourceKey(
    String videoPath, {
    required bool Function(String path) isOwnOutput,
  }) async => 'fixed';

  @override
  Future<List<SubtitleEvidenceTrack>> load(
    SubtitleEvidenceLoadRequest request,
  ) async => tracks;
}

final RegExp _kMain = RegExp(r'^id=(\d+) \[[^\]]*\] 主: (.*)$', multiLine: true);

/// 管线各阶段的假回复：S0 给一条专名、S3 原样返回、S4 不改、短片段判 song。
String _pipelineAnswer(String prompt, int call) {
  if (prompt.contains('誤認識されやすい固有名詞の表')) {
    return glossaryReply(<Map<String, Object?>>[
      <String, Object?>{
        'ja': '唯',
        'reading': 'ゆい',
        'kind': '人名',
        'misrecognitions': <String>['結衣'],
      },
    ]);
  }
  if (prompt.startsWith('あなたは日本語アニメ字幕の校正者')) {
    return <String>[
      for (final RegExpMatch m in _kMain.allMatches(prompt))
        '${m.group(1)!}\t${m.group(2)!}',
      kAiLineReplyEnd,
    ].join('\n');
  }
  return kAiLineReplyEnd;
}

SubtitleDraftCue _cue(int startMs, int endMs, [String text = 'line']) =>
    SubtitleDraftCue(startMs: startMs, endMs: endMs, text: text);

Uint8List _jpeg(int marker) => Uint8List.fromList(<int>[0xFF, 0xD8, marker]);

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('sub_frames_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('planSubtitleReferenceFrames', () {
    test('每行取中点；挨得近的共用一张；空文本行不取', () {
      final List<SubtitleDraftCue> cues = <SubtitleDraftCue>[
        _cue(0, 2000), // 中点 1000
        _cue(2500, 3500), // 中点 3000：距上一张 2 s，跳过
        _cue(6000, 8000), // 中点 7000
        _cue(20000, 22000, '  '), // 空文本
        _cue(30000, 30000), // 零时长：取起点
      ];
      expect(planSubtitleReferenceFrames(cues, 0, cues.length), <int>[
        1000,
        7000,
        30000,
      ]);
      // 只看 [lo, hi)。
      expect(planSubtitleReferenceFrames(cues, 2, 3), <int>[7000]);
      expect(planSubtitleReferenceFrames(cues, 0, 0), isEmpty);
    });

    test('超过上限：按序号均匀抽稀，保留首尾、保持升序', () {
      final List<SubtitleDraftCue> cues = <SubtitleDraftCue>[
        for (int i = 0; i < 30; i++) _cue(i * 5000, i * 5000 + 2000),
      ];
      final List<int> picked = planSubtitleReferenceFrames(cues, 0, 30);
      expect(picked, hasLength(kSubtitleReferenceFramesPerBatch));
      expect(picked.first, 1000);
      expect(picked.last, 29 * 5000 + 1000);
      expect(picked, orderedEquals(<int>[...picked]..sort()));
      expect(picked.toSet(), hasLength(picked.length));
      expect(planSubtitleReferenceFrames(cues, 0, 30, maxFrames: 1), <int>[
        15 * 5000 + 1000,
      ]);
    });
  });

  test('loadSubtitleReferenceFrames：取不到 / 抛错的那张跳过，其余照收', () async {
    final List<int> asked = <int>[];
    final List<SubtitleReferenceFrame> frames =
        await loadSubtitleReferenceFrames(
          SubtitleProofreadFrames(
            videoPath: 'ep01.mkv',
            source: (String videoPath, int atMs) async {
              asked.add(atMs);
              if (atMs == 2000) return null;
              if (atMs == 3000) throw const FileSystemException('gone');
              return _jpeg(atMs ~/ 1000);
            },
          ),
          <int>[1000, 2000, 3000, 4000],
        );
    expect(asked, <int>[1000, 2000, 3000, 4000]);
    expect(
      <int>[for (final SubtitleReferenceFrame f in frames) f.atMs],
      <int>[1000, 4000],
    );
  });

  group('SubtitleProofreader + 画面', () {
    const SubtitleGlossary glossary = SubtitleGlossary(
      entries: <SubtitleGlossaryEntry>[],
    );
    List<SubtitleDraftCue> cues() => <SubtitleDraftCue>[
      for (int i = 0; i < 4; i++) _cue(i * 10000, i * 10000 + 2000, 'line$i'),
    ];

    test('画面随本批一起发给 AI：图片、时刻清单、补充规则都在', () async {
      final FakeAiCompleter ai = FakeAiCompleter(
        (String prompt, int call) => kAiLineReplyEnd,
      );
      final List<int> asked = <int>[];
      await SubtitleProofreader(completer: ai).proofread(
        cues: cues(),
        title: 'K-ON!!',
        glossary: glossary,
        cacheDir: Directory(p.join(tmp.path, 'proofread')),
        frames: SubtitleProofreadFrames(
          videoPath: 'ep01.mkv',
          source: (String videoPath, int atMs) async {
            asked.add(atMs);
            return _jpeg(asked.length);
          },
        ),
      );
      expect(asked, <int>[1000, 11000, 21000, 31000]);
      expect(ai.calls, 1);
      final List<AiChatImage> sent = ai.images.single;
      expect(sent, hasLength(4));
      expect(sent.every((AiChatImage i) => i.mimeType == 'image/jpeg'), isTrue);
      expect(sent.first.bytes, _jpeg(1));
      expect(ai.prefixes.single, contains(kSubtitleProofreadFrameRules));
      expect(
        ai.bodies.single,
        endsWith(
          '\n画面(添付画像、時刻順):\n'
          '  画像1 [00:01.00]\n'
          '  画像2 [00:11.00]\n'
          '  画像3 [00:21.00]\n'
          '  画像4 [00:31.00]',
        ),
      );
    });

    test('没开画面：提示词与改版前逐字相同，不带图', () async {
      final FakeAiCompleter ai = FakeAiCompleter(
        (String prompt, int call) => kAiLineReplyEnd,
      );
      await SubtitleProofreader(completer: ai).proofread(
        cues: cues(),
        title: 'K-ON!!',
        glossary: glossary,
        cacheDir: Directory(p.join(tmp.path, 'proofread')),
      );
      expect(ai.images.single, isEmpty);
      expect(
        ai.prompts.single,
        buildProofreadBatchPrompt(
          cues: cues(),
          lo: 0,
          hi: 4,
          title: 'K-ON!!',
          glossaryText: '',
        ),
      );
      expect(ai.prompts.single, isNot(contains('画面')));
    });

    test('一张都取不到：这一批按纯文字校对（规则仍在前缀里，各批前缀逐字相同）', () async {
      final FakeAiCompleter ai = FakeAiCompleter(
        (String prompt, int call) => kAiLineReplyEnd,
      );
      await SubtitleProofreader(completer: ai).proofread(
        cues: cues(),
        title: 'K-ON!!',
        glossary: glossary,
        cacheDir: Directory(p.join(tmp.path, 'proofread')),
        frames: SubtitleProofreadFrames(
          videoPath: 'ep01.mkv',
          source: (String videoPath, int atMs) async => null,
        ),
      );
      expect(ai.images.single, isEmpty);
      expect(ai.prefixes.single, contains(kSubtitleProofreadFrameRules));
      expect(ai.bodies.single, isNot(contains('画像1')));
    });

    test('补问没答到的行：同一组画面再带一次，不重新取帧', () async {
      int grabs = 0;
      // 第一次回复被截断（只答到 id 0），第二次写完。
      final FakeAiCompleter ai = FakeAiCompleter(
        (String prompt, int call) => call == 0 ? '0\tfixed0\n1\tfix' : 'END',
        stopReason: (int call) => call == 0 ? 'max_tokens' : 'end_turn',
      );
      final SubtitleProofreadResult result =
          await SubtitleProofreader(completer: ai).proofread(
            cues: cues(),
            title: 'K-ON!!',
            glossary: glossary,
            cacheDir: Directory(p.join(tmp.path, 'proofread')),
            frames: SubtitleProofreadFrames(
              videoPath: 'ep01.mkv',
              source: (String videoPath, int atMs) async {
                grabs++;
                return _jpeg(grabs);
              },
            ),
          );
      expect(result.cues.first.text, 'fixed0');
      expect(ai.calls, 2);
      expect(grabs, 4);
      expect(ai.images[1], hasLength(4));
      expect(ai.images[1].first.bytes, ai.images[0].first.bytes);
    });

    test('普通话：补充规则与清单用中文写法', () {
      expect(
        buildProofreadStablePrefix(
          title: '片名',
          glossaryText: '',
          withFrames: true,
          language: VideoSubtitleLanguage.mandarin,
        ),
        contains(kSubtitleProofreadFrameRulesZh),
      );
      expect(
        formatProofreadFrameLines(<int>[
          61500,
        ], language: VideoSubtitleLanguage.mandarin),
        <String>['\n画面(附图，按时间顺序):', '  图1 [01:01.50]'],
      );
    });
  });

  group('管线', () {
    late Directory videos;
    late Directory jobs;
    late SubtitleGlossaryFileStore store;
    late String video;

    const SubtitleWorkContext work = SubtitleWorkContext(
      workKey: 'collection:7',
      title: 'K-ON!!',
      originalTitle: 'けいおん!!',
    );
    final List<SubtitleDraftCue> drafts = <SubtitleDraftCue>[
      _cue(1000, 3000, '結衣が来た'),
      _cue(11000, 13000, 'こんにちは'),
      _cue(21000, 23000, 'ありがとう'),
      _cue(31000, 33000, 'またね'),
    ];

    setUp(() {
      videos = Directory(p.join(tmp.path, 'videos'))..createSync();
      jobs = Directory(p.join(tmp.path, 'jobs'));
      store = SubtitleGlossaryFileStore(
        Directory(p.join(tmp.path, 'glossary')),
      );
      video = p.join(videos.path, 'ep01.mkv');
      File(video).writeAsBytesSync(<int>[1, 2, 3]);
    });

    VideoSubtitlePipeline pipeline(
      AiTextCompleter ai, {
      SubtitleFrameSource? frames,
      SubtitleEvidenceSource? evidence,
    }) => VideoSubtitlePipeline(
      recognizer: _FakeRecognizer(drafts),
      jobsRoot: jobs,
      styleReference: null,
      evidence: evidence,
      ai: VideoSubtitleAiConfig(
        completer: ai,
        glossaryStore: store,
        frames: frames,
      ),
      probeDurationMs: (String path) async => 1440000,
    );

    List<AiChatImage> s3Images(FakeAiCompleter ai) {
      final int at = ai.prompts.indexWhere(
        (String s) => s.startsWith('あなたは日本語アニメ字幕の校正者'),
      );
      return ai.images[at];
    }

    test('画面参考开关一变，校对从头重跑；不变则全走缓存', () async {
      Future<Uint8List?> source(String videoPath, int atMs) async =>
          _jpeg(atMs ~/ 1000);

      // 先不带画面跑一遍。
      final FakeAiCompleter plain = FakeAiCompleter(_pipelineAnswer);
      await pipeline(plain).run(videoPaths: <String>[video], work: work);
      expect(s3Images(plain), isEmpty);

      // 打开画面参考：旧的校对缓存不能直接用，S3 重新发、带图。
      final FakeAiCompleter withFrames = FakeAiCompleter(_pipelineAnswer);
      await pipeline(
        withFrames,
        frames: source,
      ).run(videoPaths: <String>[video], work: work);
      expect(s3Images(withFrames), hasLength(4));
      expect(
        withFrames.prompts.where((String s) => s.contains('画像1 [')),
        hasLength(1),
      );

      // 开关没变：不发任何请求。
      final ExplodingAiCompleter none = ExplodingAiCompleter();
      await pipeline(
        none,
        frames: source,
      ).run(videoPaths: <String>[video], work: work);
      expect(none.calls, 0);

      // 再关掉：又要重新校对（看过画面的结果不冒充纯文字的）。
      final FakeAiCompleter off = FakeAiCompleter(_pipelineAnswer);
      await pipeline(off).run(videoPaths: <String>[video], work: work);
      expect(s3Images(off), isEmpty);
    });

    test('关 AI 跑一遍不清校对缓存：再开同一开关仍走缓存', () async {
      Future<Uint8List?> source(String videoPath, int atMs) async => _jpeg(1);
      await pipeline(
        FakeAiCompleter(_pipelineAnswer),
        frames: source,
      ).run(videoPaths: <String>[video], work: work);
      await VideoSubtitlePipeline(
        recognizer: _FakeRecognizer(drafts),
        jobsRoot: jobs,
        styleReference: null,
        evidence: null,
        probeDurationMs: (String path) async => 1440000,
      ).run(videoPaths: <String>[video], work: work);
      // final.json 要重做（AI 开关变了），但 S3 / S4 的批缓存都还在：S3 不再发请求。
      final FakeAiCompleter again = FakeAiCompleter(_pipelineAnswer);
      await pipeline(
        again,
        frames: source,
      ).run(videoPaths: <String>[video], work: work);
      expect(
        again.prompts.where((String s) => s.startsWith('あなたは日本語アニメ字幕の校正者')),
        isEmpty,
      );
    });

    test('用户指定的其它语言字幕进 S3 提示词，同语言的不收', () async {
      const SubtitleEvidenceTrack found = SubtitleEvidenceTrack(
        label: 'ep01.zh.srt',
        kind: SubtitleEvidenceKind.text,
        language: 'zh',
        cues: <SubtitleEvidenceCue>[
          SubtitleEvidenceCue(startMs: 1000, endMs: 3000, text: '自动找到的中文'),
          SubtitleEvidenceCue(startMs: 11000, endMs: 13000, text: '你好'),
        ],
      );
      const SubtitleEvidenceTrack pinnedZh = SubtitleEvidenceTrack(
        label: 'player-secondary',
        kind: SubtitleEvidenceKind.text,
        language: 'zh',
        cues: <SubtitleEvidenceCue>[
          SubtitleEvidenceCue(startMs: 1000, endMs: 3000, text: '唯来了'),
        ],
      );
      const SubtitleEvidenceTrack pinnedJa = SubtitleEvidenceTrack(
        label: 'player-primary',
        kind: SubtitleEvidenceKind.text,
        language: 'ja',
        cues: <SubtitleEvidenceCue>[
          SubtitleEvidenceCue(startMs: 40000, endMs: 42000, text: '上次的产物'),
        ],
      );
      final FakeAiCompleter ai = FakeAiCompleter(_pipelineAnswer);
      final VideoSubtitlePipelineResult result = await pipeline(
        ai,
        evidence: SubtitleEvidenceWithPinnedTracks(
          inner: _FixedEvidence(<SubtitleEvidenceTrack>[found]),
          pinned: <String, List<SubtitleEvidenceTrack>>{
            video: <SubtitleEvidenceTrack>[pinnedZh, pinnedJa],
          },
        ),
      ).run(videoPaths: <String>[video], work: work);
      final String s3 = ai.prompts.firstWhere(
        (String s) => s.startsWith('あなたは日本語アニメ字幕の校正者'),
      );
      // 行数更少的指定轨压过自动找到的同语言轨。
      expect(s3, contains('    他言語字幕(zh): 唯来了'));
      expect(s3, isNot(contains('自动找到的中文')));
      // 同语言的指定轨没进证据：没被当成漏识别的台词补进字幕稿。
      expect(result.episodes.single.gapFilledCount, 0);
      expect(s3, isNot(contains('上次的产物')));
      expect(result.episodes.single.evidenceLabels, <String>[
        'ep01.zh.srt',
        'player-secondary',
      ]);
    });
  });

  group('SubtitleEvidenceWithPinnedTracks', () {
    const SubtitleEvidenceTrack zh = SubtitleEvidenceTrack(
      label: 'player-secondary',
      kind: SubtitleEvidenceKind.text,
      language: 'zh',
      cues: <SubtitleEvidenceCue>[
        SubtitleEvidenceCue(startMs: 0, endMs: 1000, text: '你好'),
      ],
    );

    test('指定轨的内容进缓存键；没有指定轨时键不变', () async {
      final _FixedEvidence inner = _FixedEvidence(
        const <SubtitleEvidenceTrack>[],
      );
      bool own(String path) => false;
      final String bare = await SubtitleEvidenceWithPinnedTracks(
        inner: inner,
        pinned: const <String, List<SubtitleEvidenceTrack>>{},
      ).sourceKey('a.mkv', isOwnOutput: own);
      expect(bare, 'fixed');
      final String withTrack = await SubtitleEvidenceWithPinnedTracks(
        inner: inner,
        pinned: const <String, List<SubtitleEvidenceTrack>>{
          'a.mkv': <SubtitleEvidenceTrack>[zh],
        },
      ).sourceKey('a.mkv', isOwnOutput: own);
      expect(withTrack, isNot(bare));
      // 别的视频的指定轨不影响这一集。
      expect(
        await SubtitleEvidenceWithPinnedTracks(
          inner: inner,
          pinned: const <String, List<SubtitleEvidenceTrack>>{
            'b.mkv': <SubtitleEvidenceTrack>[zh],
          },
        ).sourceKey('a.mkv', isOwnOutput: own),
        bare,
      );
    });

    test('他言語名额：指定轨排在英 / 中之前', () {
      SubtitleEvidenceTrack track(String language, {bool pinned = false}) =>
          SubtitleEvidenceTrack(
            label: language,
            kind: SubtitleEvidenceKind.text,
            language: language,
            pinned: pinned,
            cues: const <SubtitleEvidenceCue>[
              SubtitleEvidenceCue(startMs: 0, endMs: 1000, text: 'x'),
            ],
          );
      final SubtitleEvidenceIndex index = SubtitleEvidenceIndex(
        <SubtitleEvidenceTrack>[
          track('en'),
          track('zh'),
          track('ko', pinned: true),
        ],
        targetLanguage: 'ja',
      );
      expect(
        <String?>[for (final SubtitleEvidenceTrack t in index.others) t.label],
        <String>['ko', 'en'],
      );
    });
  });

  test('费用预估：开了画面参考，图片张数与 token 都算进去', () {
    final List<SubtitleDraftCue> cues = <SubtitleDraftCue>[
      for (int i = 0; i < 60; i++) _cue(i * 5000, i * 5000 + 3000, 'セリフ$i'),
    ];
    final SubtitleProofreadCostEstimate plain = estimateSubtitleProofreadCost(
      episodes: <List<SubtitleDraftCue>>[cues],
    );
    final SubtitleProofreadCostEstimate withFrames =
        estimateSubtitleProofreadCost(
          episodes: <List<SubtitleDraftCue>>[cues],
          frames: true,
        );
    expect(plain.frames, 0);
    expect(withFrames.batches, 2);
    expect(withFrames.frames, 2 * kSubtitleReferenceFramesPerBatch);
    expect(
      withFrames.inputTokens - plain.inputTokens,
      withFrames.frames * kSubtitleReferenceFrameTokens,
    );
    expect(withFrames.outputTokens, plain.outputTokens);
  });
}
