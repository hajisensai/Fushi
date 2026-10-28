import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/app_video_subtitle_service.dart';
import 'package:fushi/src/media/video/video_playback_remote.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart';
import 'package:path/path.dart' as p;

import '../../../helpers/fake_ai_text_completer.dart';
import '../../../helpers/fake_video_subtitle.dart';

void main() {
  late FushiDatabase db;
  late Directory tmp;
  late Directory jobs;
  late FakeVideoSubtitleSettings settings;
  late MemoryGlossaryStore store;
  late VideoRemoteJobRegistry registry;
  late FakeVideoRecognizer recognizer;
  AiTextCompleter completer = FakeAiCompleter(answerAll);

  AppVideoSubtitleService buildService({
    Future<VideoSubtitleRecognizerChoice> Function()? resolve,
  }) => AppVideoSubtitleService(
    database: db,
    settings: settings,
    glossaryStore: store,
    jobRegistry: registry,
    jobsRoot: () async => jobs,
    probeDurationMs: (String _) async => 24 * 60 * 1000,
    mossPort: const ReadyModels(),
    asrModelPort: const ReadyModels(),
    nowMs: () => 4242,
    recognizerResolver:
        ({
          required VideoSubtitleSegmenterMode mode,
          MossBackendPreference mossBackend = MossBackendPreference.auto,
        }) =>
            resolve?.call() ??
            Future<VideoSubtitleRecognizerChoice>.value(
              VideoSubtitleRecognizerChoice(
                recognizer: recognizer,
                mossUnavailableReason: mode == VideoSubtitleSegmenterMode.auto
                    ? 'no nvidia'
                    : null,
              ),
            ),
    completerFactory: (AiProviderConfig _) =>
        (completer: completer, close: () {}),
  );

  String video(String name) {
    final File f = File(p.join(tmp.path, 'videos', name))
      ..createSync(recursive: true)
      ..writeAsBytesSync(List<int>.filled(16 + name.length, 1));
    return f.path;
  }

  Future<void> addBook(
    String uid,
    String path, {
    String? subtitleSource,
    String? playlistJson,
  }) => db.upsertVideoBook(
    VideoBooksCompanion(
      bookUid: Value<String>(uid),
      title: Value<String>(uid),
      videoPath: Value<String>(path),
      subtitleSource: Value<String?>(subtitleSource),
      playlistJson: Value<String?>(playlistJson),
    ),
  );

  Future<int> addCollection(List<String> uids) async {
    final int id = await db
        .into(db.mediaCollections)
        .insert(MediaCollectionsCompanion.insert(name: 'K-ON', createdAt: 1));
    for (final String uid in uids) {
      await db
          .into(db.mediaCollectionItems)
          .insert(
            MediaCollectionItemsCompanion.insert(
              collectionId: id,
              mediaType: 'video',
              entryKey: uid,
            ),
          );
    }
    return id;
  }

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    tmp = Directory.systemTemp.createTempSync('app_vsub_');
    jobs = Directory(p.join(tmp.path, 'jobs'));
    settings = FakeVideoSubtitleSettings();
    store = MemoryGlossaryStore();
    registry = VideoRemoteJobRegistry();
    recognizer = FakeVideoRecognizer();
    completer = FakeAiCompleter(answerAll);
  });
  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  group('目标解析', () {
    test('本机文件 → 一集；不存在 / 远端 → 跳过原因；没刮削按目录兜底作品键', () async {
      final String ep1 = video('ep01.mkv');
      await addBook('a', ep1);
      await addBook('b', p.join(tmp.path, 'videos', 'gone.mkv'));
      await addBook('c', 'https://host.invalid/v.mkv');
      final int collection = await addCollection(<String>['a', 'b', 'c']);
      final AppVideoSubtitleService service = buildService();

      final AppVideoSubtitleTarget single = await service.resolveBook('a');
      expect(single.videoPaths, <String>[ep1]);
      expect(single.wholeSeason, isFalse);
      expect(single.work.workKey, startsWith('collection:'));

      final AppVideoSubtitleTarget season = await service.resolveCollection(
        collection,
      );
      expect(season.wholeSeason, isTrue);
      expect(season.videoPaths, <String>[ep1]);
      expect(
        <AppVideoSubtitleUnavailableReason>[
          for (final AppVideoSubtitleUnavailable u in season.unavailable)
            u.reason,
        ],
        <AppVideoSubtitleUnavailableReason>[
          AppVideoSubtitleUnavailableReason.missingFile,
          AppVideoSubtitleUnavailableReason.remote,
        ],
      );
      await expectLater(
        service.resolveBook('nope'),
        throwsA(isA<AppVideoSubtitleTargetNotFound>()),
      );
    });

    test('播放列表条目：各集都处理，但不替整行登记字幕选择', () async {
      final String ep1 = video('p01.mkv');
      final String ep2 = video('p02.mkv');
      await addBook(
        'pl',
        ep1,
        playlistJson: jsonEncode(<Map<String, String>>[
          <String, String>{'title': '1', 'path': ep1},
          <String, String>{'title': '2', 'path': ep2},
        ]),
      );
      final AppVideoSubtitleTarget target = await buildService().resolveBook(
        'pl',
      );
      expect(target.videoPaths, <String>[ep1, ep2]);
      expect(
        target.episodes.map(
          (AppVideoSubtitleEpisode e) => e.registersSubtitleSource,
        ),
        everyElement(isFalse),
      );
      final AppVideoSubtitleTarget only = await buildService().resolveBook(
        'pl',
        videoPath: ep2,
      );
      expect(only.videoPaths, <String>[ep2]);
    });
  });

  group('任务', () {
    test('开了 AI 校对却没指派提供商：拒绝，一个请求都不发', () async {
      await addBook('a', video('ep01.mkv'));
      final AppVideoSubtitleService service = buildService();
      final AppVideoSubtitleTarget target = await service.resolveBook('a');
      final FakeAiCompleter ai = FakeAiCompleter(answerAll);
      completer = ai;
      expect(
        () => service.start(
          target,
          const AppVideoSubtitleOptions(proofread: true),
        ),
        throwsA(
          isA<AppVideoSubtitleStartRefused>().having(
            (AppVideoSubtitleStartRefused r) => r.problem,
            'problem',
            AppVideoSubtitleStartProblem.noProvider,
          ),
        ),
      );
      expect(ai.calls, 0);
      expect(registry.recent, isEmpty);
    });

    test('不校对：导出 .ja.srt，登记到没有字幕选择的条目；镜像任务可查', () async {
      final String ep1 = video('ep01.mkv');
      final String ep2 = video('ep02.mkv');
      await addBook('a', ep1);
      await addBook('b', ep2, subtitleSource: '/user/picked.srt');
      final int collection = await addCollection(<String>['a', 'b']);
      final AppVideoSubtitleService service = buildService();
      final AppVideoSubtitleTarget target = await service.resolveCollection(
        collection,
      );
      final AppVideoSubtitleJob job = service.start(
        target,
        const AppVideoSubtitleOptions(),
      );
      expect(job.mirror.kind, VideoRemoteJobKind.subtitleGenerate);
      expect(registry[job.mirror.id], same(job.mirror));
      await job.done;

      expect(job.status, AppVideoSubtitleJobStatus.succeeded);
      expect(job.mossProblem?.reason, 'no nvidia');
      final String srt1 = p.join(p.dirname(ep1), 'ep01.ja.srt');
      expect(File(srt1).existsSync(), isTrue);
      expect(
        (await db.getVideoBookByBookUid('a'))!.subtitleSource,
        srt1,
        reason: '没有字幕选择的条目登记新字幕',
      );
      expect(
        (await db.getVideoBookByBookUid('b'))!.subtitleSource,
        '/user/picked.srt',
        reason: '用户自己选过的字幕不覆盖',
      );
      expect(job.registeredBookUids, <String>['a']);
      expect(job.mirror.status, VideoRemoteJobStatus.succeeded);
      final List<Object?> episodes = job.mirror.result['episodes']! as List;
      expect(episodes, hasLength(2));
      expect(service.activeJob, isNull);
      expect(service.latestJobFor(target), same(job));
    });

    // DEStBY5I66：视频页对当前这一集点「生成日语字幕」后退出播放页，任务结束时
    // 页面已不在；条目原本选着别的字幕时，生成的字幕必须替换掉原选择（连同库里旧源
    // 的 cue 缓存），重进播放页才用得上。整季 / CLI（不带 videoPath）仍不覆盖。
    test('视频页单集入口：替换已有字幕选择并清掉旧 cue 缓存', () async {
      final String ep1 = video('ep01.mkv');
      await addBook('a', ep1, subtitleSource: 'embedded:2');
      await db.replaceCuesForBook('a', <AudioCuesCompanion>[
        AudioCuesCompanion.insert(
          bookKey: 'a',
          chapterHref: '',
          sentenceIndex: 0,
          textFragmentId: '',
          cueText: 'old embedded line',
          startMs: 0,
          endMs: 1000,
          audioFileIndex: 0,
        ),
      ]);
      final AppVideoSubtitleService service = buildService();

      final AppVideoSubtitleTarget cli = await service.resolveBook('a');
      expect(
        cli.episodes.single.replacesSubtitleSelection,
        isFalse,
        reason: 'CLI / 库页入口不覆盖用户选择',
      );

      final AppVideoSubtitleTarget target = await service.resolveBook(
        'a',
        videoPath: ep1,
      );
      expect(target.episodes.single.replacesSubtitleSelection, isTrue);
      final AppVideoSubtitleJob job = service.start(
        target,
        const AppVideoSubtitleOptions(),
      );
      await job.done;

      expect(job.status, AppVideoSubtitleJobStatus.succeeded);
      final String srt = p.join(p.dirname(ep1), 'ep01.ja.srt');
      expect(File(srt).existsSync(), isTrue);
      expect((await db.getVideoBookByBookUid('a'))!.subtitleSource, srt);
      expect(
        await db.getCuesForBook('a'),
        isEmpty,
        reason: '旧源的 cue 缓存清掉，重进时按新字幕档案重解析',
      );
      expect(job.registeredBookUids, <String>['a']);
    });

    test('上次登记的是本管线的 .ja.ass、这次没参考：删掉旧 ASS，登记切回 .ja.srt', () async {
      final String ep1 = video('ep01.mkv');
      final String zhAss = p.join(p.dirname(ep1), 'ep01.zh.ass');
      final StringBuffer zh = StringBuffer()
        ..writeln('[Script Info]')
        ..writeln('PlayResX: 1920')
        ..writeln('PlayResY: 1080')
        ..writeln('[V4+ Styles]')
        ..writeln('Format: Name, Fontname, Fontsize, PrimaryColour, Alignment')
        ..writeln('Style: Top,Noto Sans,70,&H0000FFFF,8')
        ..writeln('[Events]')
        ..writeln(
          'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, '
          'Effect, Text',
        );
      for (int i = 0; i < 12; i++) {
        final String s = (i * 2).toString().padLeft(2, '0');
        zh.writeln('Dialogue: 0,0:00:$s.00,0:00:$s.90,Top,,0,0,0,,{\\an8}第$i句');
      }
      File(zhAss).writeAsStringSync('$zh');
      await addBook('a', ep1);
      final AppVideoSubtitleService service = buildService();
      final AppVideoSubtitleTarget target = await service.resolveBook('a');
      final String srt = p.join(p.dirname(ep1), 'ep01.ja.srt');
      final String ass = p.join(p.dirname(ep1), 'ep01.ja.ass');

      final AppVideoSubtitleJob first = service.start(
        target,
        const AppVideoSubtitleOptions(),
      );
      await first.done;
      expect(first.status, AppVideoSubtitleJobStatus.succeeded);
      expect((await db.getVideoBookByBookUid('a'))!.subtitleSource, ass);

      // 参考字幕没了：这次只出 SRT。
      File(zhAss).deleteSync();
      final AppVideoSubtitleJob second = service.start(
        target,
        const AppVideoSubtitleOptions(),
      );
      await second.done;
      expect(second.status, AppVideoSubtitleJobStatus.succeeded);
      expect(File(ass).existsSync(), isFalse, reason: '过期的本管线 ASS 不留');
      expect(File(srt).existsSync(), isTrue);
      expect(
        (await db.getVideoBookByBookUid('a'))!.subtitleSource,
        srt,
        reason: '库里选着的旧 ASS 被删了，切到本轮的 SRT',
      );
      expect(second.registeredBookUids, <String>['a']);
    });

    test('同时只跑一个：第二个任务被拒（busy）', () async {
      await addBook('a', video('ep01.mkv'));
      final AppVideoSubtitleService service = buildService();
      final AppVideoSubtitleTarget target = await service.resolveBook('a');
      final AppVideoSubtitleJob first = service.start(
        target,
        const AppVideoSubtitleOptions(),
      );
      expect(
        () => service.start(target, const AppVideoSubtitleOptions()),
        throwsA(
          isA<AppVideoSubtitleStartRefused>()
              .having(
                (AppVideoSubtitleStartRefused r) => r.problem,
                'problem',
                AppVideoSubtitleStartProblem.busy,
              )
              .having(
                (AppVideoSubtitleStartRefused r) => r.activeJob,
                'activeJob',
                same(first),
              ),
        ),
      );
      await first.done;
    });

    test('AI 请求失败 → 暂停（缓存保留）；额度恢复后同一目标再跑即续，不重识别', () async {
      settings.provider = testProvider();
      await addBook('a', video('ep01.mkv'));
      final AppVideoSubtitleService service = buildService();
      final AppVideoSubtitleTarget target = await service.resolveBook('a');
      completer = ExplodingAiCompleter('quota_exhausted');
      final AppVideoSubtitleJob paused = service.start(
        target,
        const AppVideoSubtitleOptions(proofread: true),
      );
      await paused.done;
      expect(paused.status, AppVideoSubtitleJobStatus.pausedAiFailure);
      expect(paused.aiFailure?.reason, 'quota_exhausted');
      expect(paused.mirror.errorCode, 'ai_failure');
      expect(recognizer.calls, <String>['ep01.mkv']);

      completer = FakeAiCompleter(answerAll);
      final AppVideoSubtitleJob resumed = service.start(
        target,
        const AppVideoSubtitleOptions(proofread: true),
      );
      await resumed.done;
      expect(resumed.status, AppVideoSubtitleJobStatus.succeeded);
      expect(recognizer.calls, <String>['ep01.mkv'], reason: '识别稿走缓存');
      expect(store.rows[target.work.workKey]!.entries.single.ja, '唯');
    });

    test('取消 → cancelled，镜像同步', () async {
      await addBook('a', video('ep01.mkv'));
      final AppVideoSubtitleService service = buildService();
      final AppVideoSubtitleTarget target = await service.resolveBook('a');
      final AppVideoSubtitleJob job = service.start(
        target,
        const AppVideoSubtitleOptions(),
      );
      expect(job.mirror.cancel(), isTrue);
      await job.done;
      expect(job.status, AppVideoSubtitleJobStatus.cancelled);
      expect(job.mirror.status, VideoRemoteJobStatus.cancelled);
    });

    test('只重跑写法统一：没跑过校对的集不重跑；跑过的删 S4 后重跑并覆盖自己写的字幕', () async {
      settings.provider = testProvider();
      final String ep1 = video('ep01.mkv');
      await addBook('a', ep1);
      final AppVideoSubtitleService service = buildService();
      final AppVideoSubtitleTarget target = await service.resolveBook('a');
      await expectLater(
        service.startConsistencyRerun(target),
        throwsA(
          isA<AppVideoSubtitleStartRefused>().having(
            (AppVideoSubtitleStartRefused r) => r.problem,
            'problem',
            AppVideoSubtitleStartProblem.nothingToRerun,
          ),
        ),
      );

      final AppVideoSubtitleJob full = service.start(
        target,
        const AppVideoSubtitleOptions(proofread: true),
      );
      await full.done;
      expect(full.status, AppVideoSubtitleJobStatus.succeeded);
      final FakeAiCompleter ai = FakeAiCompleter(answerAll);
      completer = ai;
      final AppVideoSubtitleJob rerun = await service.startConsistencyRerun(
        target,
      );
      await rerun.done;
      expect(rerun.status, AppVideoSubtitleJobStatus.succeeded);
      expect(
        rerun.result!.episodes.single.status,
        VideoSubtitleEpisodeStatus.exported,
        reason: '上次是本管线写的 .ja.srt，覆盖而不是另存 .asr.srt',
      );
      expect(recognizer.calls, <String>['ep01.mkv']);
    });
  });

  group('专名表', () {
    const SubtitleWorkContext work = SubtitleWorkContext(
      workKey: 'collection:9',
      title: 'K-ON',
    );

    test('保存：改过 / 新增的条目标 userEdited，没动的不标；记 userEditedAt 与指纹', () async {
      final AppVideoSubtitleService service = buildService();
      const SubtitleGlossary previous = SubtitleGlossary(
        entries: <SubtitleGlossaryEntry>[
          SubtitleGlossaryEntry(ja: '唯', reading: 'ゆい', kind: '人名'),
          SubtitleGlossaryEntry(ja: '澪', reading: 'みお', kind: '人名'),
        ],
        sourceFingerprint: 'fp-old',
        generatedAt: 100,
      );
      final SubtitleGlossary saved = await service.saveGlossary(
        work,
        <SubtitleGlossaryEntry>[
          previous.entries[0],
          previous.entries[1].copyWith(misrecognitions: <String>['美緒']),
          const SubtitleGlossaryEntry(ja: 'ムギ', kind: '人名(愛称)'),
        ],
        previous: previous,
      );
      expect(
        saved.entries.map((SubtitleGlossaryEntry e) => e.userEdited),
        <bool>[false, true, true],
      );
      expect(saved.userEditedAt, 4242);
      expect(saved.sourceFingerprint, 'fp-old');
      expect(saved.generatedAt, 100);
      expect(store.rows[work.workKey]!.entries, hasLength(3));
    });

    test('保存候选表（没有原表）：取当前资料指纹，下次运行直接复用不重新生成', () async {
      final AppVideoSubtitleService service = buildService();
      final SubtitleGlossary saved = await service.saveGlossary(
        work,
        const <SubtitleGlossaryEntry>[SubtitleGlossaryEntry(ja: '唯')],
      );
      expect(saved.sourceFingerprint, isNotEmpty);
      expect(saved.entries.single.userEdited, isTrue);
    });

    test('重新生成：没指派提供商拒绝；有则保留用户条目', () async {
      final AppVideoSubtitleService service = buildService();
      final String ep1 = video('ep01.mkv');
      await addBook('a', ep1);
      final AppVideoSubtitleTarget target = await service.resolveBook('a');
      await expectLater(
        service.regenerateGlossary(target),
        throwsA(isA<AppVideoSubtitleStartRefused>()),
      );
      settings.provider = testProvider();
      await service.saveGlossary(target.work, const <SubtitleGlossaryEntry>[
        SubtitleGlossaryEntry(ja: 'あずにゃん', kind: '人名(愛称)'),
      ]);
      final SubtitleGlossary regenerated = await service.regenerateGlossary(
        target,
      );
      expect(
        regenerated.entries.map((SubtitleGlossaryEntry e) => e.ja),
        containsAll(<String>['あずにゃん', '唯']),
      );
    });
  });

  group('费用预估', () {
    test('没识别过按时长粗估；识别过按字幕稿；全部完成 = nothing', () async {
      settings.provider = testProvider();
      await addBook('a', video('ep01.mkv'));
      final AppVideoSubtitleService service = buildService();
      final AppVideoSubtitleTarget target = await service.resolveBook('a');
      final AppVideoSubtitleCostEstimate rough = await service.estimateCost(
        target,
      );
      expect(rough.basis, AppVideoSubtitleEstimateBasis.duration);
      expect(rough.cost.batches, (24 * 12 / 30).ceil());
      expect(rough.cost.inputTokens, greaterThan(0));

      completer = ExplodingAiCompleter('quota_exhausted');
      await service
          .start(target, const AppVideoSubtitleOptions(proofread: true))
          .done;
      final AppVideoSubtitleCostEstimate byDrafts = await service.estimateCost(
        target,
      );
      expect(byDrafts.basis, AppVideoSubtitleEstimateBasis.drafts);
      expect(byDrafts.cost.batches, 1);

      completer = FakeAiCompleter(answerAll);
      await service
          .start(target, const AppVideoSubtitleOptions(proofread: true))
          .done;
      final AppVideoSubtitleCostEstimate done = await service.estimateCost(
        target,
      );
      expect(done.basis, AppVideoSubtitleEstimateBasis.nothing);
    });
  });
}
