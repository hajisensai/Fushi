import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_evidence.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_evidence_loader.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary_builder.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_proofreader.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer.dart';
import 'package:path/path.dart' as p;

import '../../../../helpers/fake_ai_text_completer.dart';

/// 识别器替身：按文件名给稿，记调用次数。
class _FakeRecognizer implements VideoSubtitleRecognizer {
  _FakeRecognizer(this.drafts);

  final Map<String, List<SubtitleDraftCue>> drafts;
  final List<String> calls = <String>[];

  /// 每次识别收到的音轨（全局流序号；null = 按语言挑）与工作目录。
  final List<int?> streams = <int?>[];
  final List<String> workDirs = <String>[];

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
    calls.add(p.basename(videoPath));
    streams.add(audioStreamIndex);
    workDirs.add(workDir.path);
    onProgress(0.5, 'half');
    return drafts[p.basename(videoPath)]!;
  }
}

/// 证据来源替身：给固定轨，记 load 次数。
class _FakeEvidence implements SubtitleEvidenceSource {
  _FakeEvidence(this.tracks, {this.key = 'v1'});

  final List<SubtitleEvidenceTrack> tracks;
  final String key;
  int loads = 0;

  /// 每次 sourceKey 时管线给的「是不是自己的产物」判据（测试拿它问具体路径）。
  final List<bool Function(String path)> ownChecks =
      <bool Function(String path)>[];

  @override
  Future<String> sourceKey(
    String videoPath, {
    required bool Function(String path) isOwnOutput,
  }) async {
    ownChecks.add(isOwnOutput);
    return key;
  }

  @override
  Future<List<SubtitleEvidenceTrack>> load(
    SubtitleEvidenceLoadRequest request,
  ) async {
    loads++;
    return tracks;
  }
}

/// 收集不完整的证据来源（某个来源读失败）：给出部分轨，但要求不缓存。
class _IncompleteEvidence implements SubtitleEvidenceSource {
  _IncompleteEvidence(this.tracks);

  final List<SubtitleEvidenceTrack> tracks;
  int loads = 0;

  @override
  Future<String> sourceKey(
    String videoPath, {
    required bool Function(String path) isOwnOutput,
  }) async => 'v1';

  @override
  Future<List<SubtitleEvidenceTrack>> load(
    SubtitleEvidenceLoadRequest request,
  ) async {
    loads++;
    throw SubtitleEvidenceIncomplete(tracks, 'burned-in OCR failed');
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
  if (prompt.startsWith('あなたは日本語アニメ「')) {
    return replyForIds(prompt, (int id) => '唯が来た!');
  }
  if (prompt.contains('特典映像・短編')) {
    return <String>[
      for (final RegExpMatch m in _kClipId.allMatches(prompt))
        '${m.group(1)!}\tsong',
      kAiLineReplyEnd,
    ].join('\n');
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
    SubtitleEvidenceSource? evidence,
  }) => VideoSubtitlePipeline(
    recognizer: recognizer,
    jobsRoot: jobs,
    styleReference: null,
    evidence: evidence,
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

  test('exportDirFor：同名媒体各进各的目录，不互判「已有同名字幕」', () async {
    // 曲库里大量同名 01.flac：共用一个 exportDir 时第二个会被当成「已有别人的字幕」
    // 落到 .asr 退路；按路径给目录则两份都正常导出。
    final Directory a = Directory(p.join(tmp.path, 'albumA'))..createSync();
    final Directory b = Directory(p.join(tmp.path, 'albumB'))..createSync();
    final String fa = p.join(a.path, 'ep01.mkv');
    final String fb = p.join(b.path, 'ep01.mkv');
    File(fa).writeAsBytesSync(List<int>.filled(11, 1));
    File(fb).writeAsBytesSync(List<int>.filled(13, 1));
    final Directory shared = Directory(p.join(tmp.path, 'out'));

    VideoSubtitlePipeline build({
      Directory? Function(String mediaPath)? exportDirFor,
    }) => VideoSubtitlePipeline(
      recognizer: _FakeRecognizer(drafts),
      jobsRoot: jobs,
      styleReference: null,
      evidence: null,
      exportDir: shared,
      exportDirFor: exportDirFor,
      probeDurationMs: duration,
    );

    final VideoSubtitlePipelineResult sharedRun = await build().run(
      videoPaths: <String>[fa, fb],
      work: work,
    );
    expect(
      sharedRun.episodes.map((VideoSubtitleEpisodeResult e) => e.status),
      <VideoSubtitleEpisodeStatus>[
        VideoSubtitleEpisodeStatus.exported,
        VideoSubtitleEpisodeStatus.exportedAsAsr,
      ],
      reason: '旧行为：单目录撞名',
    );

    await jobs.delete(recursive: true);
    final VideoSubtitlePipeline perPath = build(
      exportDirFor: (String path) =>
          Directory(p.join(tmp.path, 'per', p.basename(p.dirname(path)))),
    );
    final VideoSubtitlePipelineResult r = await perPath.run(
      videoPaths: <String>[fa, fb],
      work: work,
    );
    expect(
      r.episodes.map((VideoSubtitleEpisodeResult e) => e.status),
      everyElement(VideoSubtitleEpisodeStatus.exported),
    );
    expect(
      r.episodes.first.outputPath,
      p.join(tmp.path, 'per', 'albumA', 'ep01.ja.srt'),
    );
    expect(
      r.episodes.last.outputPath,
      p.join(tmp.path, 'per', 'albumB', 'ep01.ja.srt'),
    );
    expect(perPath.subtitlePathFor(fa), r.episodes.first.outputPath);
    // 回调给 null 的路径照旧落 exportDir。
    expect(
      build(exportDirFor: (String _) => null).subtitlePathFor(fa),
      p.join(shared.path, 'ep01.ja.srt'),
    );
  });

  test('原盘成员：默认落点在任务根的 disc_out 下，按成员分目录，不写进盘里', () async {
    // 蓝光的「媒体旁」是 BDMV/PLAYLIST：挂载的 ISO / 光驱写不进，写得进也是污染盘结构。
    final Directory disc = Directory(p.join(tmp.path, 'DiscA'));
    final Directory playlist = Directory(p.join(disc.path, 'BDMV', 'PLAYLIST'))
      ..createSync(recursive: true);
    Directory(p.join(disc.path, 'BDMV', 'STREAM')).createSync();
    final String mpls = p.join(playlist.path, '00001.mpls');
    File(mpls).writeAsBytesSync(List<int>.filled(8, 1));
    List<String> discFiles() => <String>[
      for (final FileSystemEntity e in disc.listSync(recursive: true)) e.path,
    ]..sort();
    final List<String> before = discFiles();

    final VideoSubtitlePipeline pl = VideoSubtitlePipeline(
      recognizer: _FakeRecognizer(<String, List<SubtitleDraftCue>>{
        '00001.mpls': _lines(<String>['結衣が来た', 'こんにちは', 'ありがとう', 'またね']),
      }),
      jobsRoot: jobs,
      styleReference: null,
      evidence: null,
      probeDurationMs: duration,
    );
    final VideoSubtitlePipelineResult r = await pl.run(
      videoPaths: <String>[mpls],
      work: work,
    );
    final String expected = p.join(
      jobs.path,
      'disc_out',
      videoSubtitleJobId(mpls),
      '00001.ja.srt',
    );
    expect(r.episodes.single.status, VideoSubtitleEpisodeStatus.exported);
    expect(r.episodes.single.outputPath, expected);
    expect(File(expected).existsSync(), isTrue);
    expect(pl.subtitlePathFor(mpls), expected);
    expect(discFiles(), before, reason: '盘目录里不能多出任何文件');

    // 别的盘上同名 title、蓝光虚拟分集、DVD title 各进各的目录；普通文件仍在媒体旁。
    final String otherDisc = p.join(
      tmp.path,
      'DiscB',
      'BDMV',
      'PLAYLIST',
      '00001.mpls',
    );
    final String episode = p.join(playlist.path, '00001.p02.mpls');
    final String dvd = p.join(
      tmp.path,
      'DiscC',
      'VIDEO_TS',
      'TITLE_01.dvdtitle',
    );
    final Set<String> dirs = <String>{
      p.dirname(expected),
      for (final String member in <String>[otherDisc, episode, dvd])
        videoSubtitleDiscExportDir(jobs, member)!.path,
    };
    expect(dirs, hasLength(4));
    for (final String dir in dirs) {
      expect(p.isWithin(p.join(jobs.path, 'disc_out'), dir), isTrue);
    }
    expect(videoSubtitleDiscExportDir(jobs, video('ep01.mkv')), isNull);
    expect(videoSubtitleDefaultExportDir(jobs, video('ep01.mkv')), videos.path);

    // 显式给了导出目录（CLI --out-dir / host 上传任务）照旧写那里。
    final Directory out = Directory(p.join(tmp.path, 'out'));
    expect(
      VideoSubtitlePipeline(
        recognizer: _FakeRecognizer(drafts),
        jobsRoot: jobs,
        styleReference: null,
        evidence: null,
        exportDir: out,
        probeDurationMs: duration,
      ).subtitlePathFor(mpls),
      p.join(out.path, '00001.ja.srt'),
    );
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

  test('既存字幕证据：补回 ASR 漏的行、证据进 S3 提示词；证据变了从校对重跑', () async {
    List<SubtitleEvidenceTrack> tracks(String gap) => <SubtitleEvidenceTrack>[
      SubtitleEvidenceTrack(
        label: 'ep01.ja.srt',
        kind: SubtitleEvidenceKind.text,
        language: 'ja',
        cues: <SubtitleEvidenceCue>[
          const SubtitleEvidenceCue(startMs: 1000, endMs: 3000, text: '唯が来た'),
          SubtitleEvidenceCue(startMs: 20000, endMs: 22000, text: gap),
        ],
      ),
      const SubtitleEvidenceTrack(
        label: 'ep01.en.srt',
        kind: SubtitleEvidenceKind.text,
        language: 'en',
        cues: <SubtitleEvidenceCue>[
          SubtitleEvidenceCue(startMs: 1000, endMs: 3000, text: 'Yui is here'),
        ],
      ),
    ];
    String srt() => File(p.join(videos.path, 'ep01.ja.srt')).readAsStringSync();
    String s3Of(FakeAiCompleter ai) =>
        ai.prompts.firstWhere((String s) => s.startsWith('あなたは日本語アニメ字幕の校正者'));

    final FakeAiCompleter ai = FakeAiCompleter(_answer);
    final _FakeEvidence ev = _FakeEvidence(tracks('先生、待って'));
    final VideoSubtitlePipelineResult r = await pipeline(
      _FakeRecognizer(drafts),
      ai: ai,
      evidence: ev,
    ).run(videoPaths: <String>[video('ep01.mkv')], work: work);
    final VideoSubtitleEpisodeResult e = r.episodes.single;
    expect(e.gapFilledCount, 1);
    expect(e.evidenceLabels, <String>['ep01.ja.srt', 'ep01.en.srt']);
    expect(srt(), contains('先生、待って'));
    final String s3 = s3Of(ai);
    expect(s3, contains(kSubtitleProofreadEvidenceRules));
    expect(s3, contains('    同言語字幕[字幕]: 唯が来た'));
    expect(s3, contains('    他言語字幕(en): Yui is here'));
    expect(s3, contains('主(既存字幕から補完): 先生、待って'));

    // 证据没变：evidence.json 复用、全部阶段走缓存，不发请求。
    final ExplodingAiCompleter none = ExplodingAiCompleter();
    await pipeline(
      _FakeRecognizer(drafts),
      ai: none,
      evidence: ev,
    ).run(videoPaths: <String>[video('ep01.mkv')], work: work);
    expect(ev.loads, 1);
    expect(none.calls, 0);

    // 证据变了（来源身份变）：重收证据，从校对起重跑。
    final FakeAiCompleter ai2 = FakeAiCompleter(_answer);
    final _FakeEvidence ev2 = _FakeEvidence(tracks('先生、待ってよ'), key: 'v2');
    await pipeline(
      _FakeRecognizer(drafts),
      ai: ai2,
      evidence: ev2,
    ).run(videoPaths: <String>[video('ep01.mkv')], work: work);
    expect(ev2.loads, 1);
    expect(s3Of(ai2), contains('主(既存字幕から補完): 先生、待ってよ'));
    expect(srt(), contains('先生、待ってよ'));
  });

  test('自己的产物判据：认内容不认路径；.asr 退路名任务目录没了也认', () async {
    final String ja = p.join(videos.path, 'ep01.ja.srt');
    final String asr = p.join(videos.path, 'ep01.ja.asr.srt');
    final _FakeEvidence ev = _FakeEvidence(const <SubtitleEvidenceTrack>[]);
    Future<void> runOnce() => pipeline(
      _FakeRecognizer(drafts),
      evidence: ev,
    ).run(videoPaths: <String>[video('ep01.mkv')], work: work);

    await runOnce();
    expect(File(ja).existsSync(), isTrue);
    // 第二轮：.ja.srt 还是本管线写的那份 → 是自己的产物。
    await runOnce();
    expect(ev.ownChecks.last(ja), isTrue);

    // 用户把它换成自己的字幕（同一路径、内容变了）：是别人的文件，照常当证据。
    File(ja).writeAsStringSync('1\n00:00:01,000 --> 00:00:02,000\n人工の字幕\n');
    await runOnce();
    expect(ev.ownChecks.last(ja), isFalse);
    expect(File(asr).existsSync(), isTrue, reason: '被占着就写 .asr 退路');

    // 任务目录被清掉（换 jobsRoot 同理）：.asr 退路名仍认作自己的产物。
    jobs.deleteSync(recursive: true);
    await runOnce();
    expect(ev.ownChecks.last(asr), isTrue);
    expect(ev.ownChecks.last(ja), isFalse);
  });

  test('不开 AI：画面硬字幕（OCR 证据）与识别行只差几个字时换成画面写法（d-fO4eGxKx）', () async {
    final _FakeEvidence ev = _FakeEvidence(const <SubtitleEvidenceTrack>[
      SubtitleEvidenceTrack(
        label: 'burned-in subtitles OCR',
        kind: SubtitleEvidenceKind.ocr,
        language: 'ja',
        cues: <SubtitleEvidenceCue>[
          // 识别「結衣が来た」，画面写的是「唯が来た」：同一句，换。
          SubtitleEvidenceCue(startMs: 1000, endMs: 3000, text: '唯が来た'),
          // 同时段画面是另一句：不换。
          SubtitleEvidenceCue(startMs: 7000, endMs: 9000, text: 'さようなら'),
        ],
      ),
    ]);
    final VideoSubtitlePipelineResult r = await pipeline(
      _FakeRecognizer(drafts),
      evidence: ev,
    ).run(videoPaths: <String>[video('ep01.mkv')], work: work);
    expect(r.episodes.single.status, VideoSubtitleEpisodeStatus.exported);
    final String srt = File(
      p.join(videos.path, 'ep01.ja.srt'),
    ).readAsStringSync();
    expect(srt, contains('唯が来た'));
    expect(srt, isNot(contains('結衣が来た')));
    expect(srt, contains('ありがとう'));
    expect(srt, isNot(contains('さようなら')));
  });

  SubtitleEvidenceTrack burnedIn(List<SubtitleEvidenceCue> cues) =>
      SubtitleEvidenceTrack(
        label: 'burned-in subtitles OCR',
        kind: SubtitleEvidenceKind.ocr,
        language: 'ja',
        cues: cues,
      );

  test('开着 AI：不做确定性替换，画面硬字幕原样当证据交给 S3（d-fO4eGxKx）', () async {
    final FakeAiCompleter ai = FakeAiCompleter(_answer);
    await pipeline(
      _FakeRecognizer(drafts),
      ai: ai,
      evidence: _FakeEvidence(<SubtitleEvidenceTrack>[
        burnedIn(const <SubtitleEvidenceCue>[
          SubtitleEvidenceCue(startMs: 1000, endMs: 3000, text: '唯が来た'),
        ]),
      ]),
    ).run(videoPaths: <String>[video('ep01.mkv')], work: work);
    final String s3 = ai.prompts.firstWhere(
      (String s) => s.startsWith('あなたは日本語アニメ字幕の校正者'),
    );
    expect(s3, contains('主: 結衣が来た'));
    expect(s3, contains(']: 唯が来た'));
  });

  test('不开 AI：画面硬字幕只差标点时不换，识别稿的标点留着（d-fO4eGxKx）', () async {
    await pipeline(
      _FakeRecognizer(drafts),
      evidence: _FakeEvidence(<SubtitleEvidenceTrack>[
        burnedIn(const <SubtitleEvidenceCue>[
          SubtitleEvidenceCue(startMs: 4000, endMs: 6000, text: 'こんにちは'),
        ]),
      ]),
    ).run(videoPaths: <String>[video('ep01.mkv')], work: work);
    final String srt = File(
      p.join(videos.path, 'ep01.ja.srt'),
    ).readAsStringSync();
    expect(srt, matches(RegExp('こんにちは[?？]')));
  });

  test('证据收集不完整（硬字幕 OCR 读失败）：这次照用，但不落 evidence.json，下次重收', () async {
    final _IncompleteEvidence ev = _IncompleteEvidence(<SubtitleEvidenceTrack>[
      burnedIn(const <SubtitleEvidenceCue>[
        SubtitleEvidenceCue(startMs: 1000, endMs: 3000, text: '唯が来た'),
      ]),
    ]);
    await pipeline(
      _FakeRecognizer(drafts),
      evidence: ev,
    ).run(videoPaths: <String>[video('ep01.mkv')], work: work);
    expect(
      File(p.join(videos.path, 'ep01.ja.srt')).readAsStringSync(),
      contains('唯が来た'),
    );
    final List<File> caches = jobs
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => p.basename(f.path) == VideoSubtitleJobFiles.evidence)
        .toList();
    expect(caches, isEmpty);
    await pipeline(
      _FakeRecognizer(drafts),
      evidence: ev,
    ).run(videoPaths: <String>[video('ep01.mkv')], work: work);
    expect(ev.loads, 2);
  });

  test('播放器当前音轨：识别那条轨、按轨分识别目录；换轨作废下游，换回来续用', () async {
    final _FakeRecognizer rec = _FakeRecognizer(drafts);
    final List<(String, int)> asked = <(String, int)>[];
    // 播放器第 N 条音轨 → 流 N + 10；第 0 条与按语言挑的同一条（null）。
    VideoSubtitlePipeline withTracks() => VideoSubtitlePipeline(
      recognizer: rec,
      jobsRoot: jobs,
      styleReference: null,
      evidence: null,
      probeDurationMs: duration,
      resolveAudioStream: (String path, int track) async {
        asked.add((p.basename(path), track));
        return track == 0 ? null : track + 10;
      },
    );
    final String ep = video('ep01.mkv');
    final Directory job = withTracks().jobDirFor(ep);

    // 批量 / 没有播放上下文：按语言挑，不换算，识别目录就是任务目录。
    await withTracks().run(videoPaths: <String>[ep], work: work);
    expect(asked, isEmpty);
    expect(rec.streams, <int?>[null]);
    expect(rec.workDirs.single, job.path);
    final File finalCues = File(
      p.join(job.path, VideoSubtitleJobFiles.finalCues),
    );
    expect(finalCues.existsSync(), isTrue);

    // 从播放页发起、当前是第 2 条音轨：识别流 12，放进按轨的子目录。
    await withTracks().run(
      videoPaths: <String>[ep],
      work: work,
      audioTracks: <String, int>{ep: 2},
    );
    expect(asked, <(String, int)>[('ep01.mkv', 2)]);
    expect(rec.streams, <int?>[null, 12]);
    expect(rec.workDirs.last, videoSubtitleRecognizeDir(job, 12).path);
    expect(
      File(
        p.join(
          videoSubtitleRecognizeDir(job, 12).path,
          VideoSubtitleJobFiles.drafts('fake'),
        ),
      ).existsSync(),
      isTrue,
    );
    final Map<String, Object?> state =
        jsonDecode(
              File(
                p.join(job.path, VideoSubtitleJobFiles.state),
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    expect(state['audioStream'], 12);

    // 只重跑写法统一：沿用上次的轨，不换算、不重识别。
    await withTracks().run(
      videoPaths: <String>[ep],
      work: work,
      keepRecordedAudio: true,
    );
    expect(asked, hasLength(1));
    expect(rec.calls, hasLength(2));

    // 当前音轨就是按语言挑的那条：回到任务目录里的那份稿，不重识别。
    await withTracks().run(
      videoPaths: <String>[ep],
      work: work,
      audioTracks: <String, int>{ep: 0},
    );
    expect(rec.calls, hasLength(2), reason: '按语言挑的稿还在，换回来续用');
    expect(finalCues.existsSync(), isTrue);
    final String srt = File(
      p.join(videos.path, 'ep01.ja.srt'),
    ).readAsStringSync();
    expect(srt, contains('結衣が来た'));
  });
}
