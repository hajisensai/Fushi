import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/app_video_subtitle_service.dart';
import 'package:fushi/src/media/video/video_playback_remote.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/media/video/bluray/bluray_angle.dart'
    show blurayAnglePath;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_language.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_work_context_loader.dart'
    show fallbackSubtitleWorkKey;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer.dart';
import 'package:fushi_engine/media/video/dvd/dvd_angle.dart'
    show dvdTitleAnglePath;
import 'package:fushi_engine/media/video/dvd/dvd_title_path.dart'
    show dvdTitlePath;
import 'package:fushi_engine/media/video/video_duration_probe.dart'
    show AudioTrackFacts;
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
    AppVideoSubtitleAudioTrackProbe? probeAudioTracks,
    AppVideoSubtitleDurationProbe? probeDurationMs,
  }) => AppVideoSubtitleService(
    database: db,
    probeAudioTracks: probeAudioTracks,
    settings: settings,
    glossaryStore: store,
    jobRegistry: registry,
    jobsRoot: () async => jobs,
    probeDurationMs: probeDurationMs ?? (String _) async => 24 * 60 * 1000,
    mossPort: const ReadyModels(),
    asrModelPort: const ReadyModels(),
    nowMs: () => 4242,
    recognizerResolver:
        ({
          required VideoSubtitleSegmenterMode mode,
          MossBackendPreference mossBackend = MossBackendPreference.auto,
          VideoSubtitleLanguage language = VideoSubtitleLanguage.japanese,
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

  /// 一张蓝光盘的目录结构（盘根 / BDMV / PLAYLIST 下一条真实的 `.mpls`）。返回 `.mpls`。
  String blurayTitle(String discName, [String playlist = '00001.mpls']) {
    final String root = p.join(tmp.path, 'discs', discName);
    Directory(p.join(root, 'BDMV', 'STREAM')).createSync(recursive: true);
    final File f = File(p.join(root, 'BDMV', 'PLAYLIST', playlist))
      ..createSync(recursive: true)
      ..writeAsBytesSync(List<int>.filled(32, 7));
    return f.path;
  }

  List<String> filesUnder(String dir) => <String>[
    for (final FileSystemEntity e in Directory(dir).listSync(recursive: true))
      e.path,
  ]..sort();

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

    test('没入库的文件：按文件解析，作品身份按所在文件夹兜底，不登记库条目', () async {
      final String ep1 = video('loose01.mkv');
      final String ep2 = video('loose02.mkv');
      final AppVideoSubtitleService service = buildService();

      final AppVideoSubtitleTarget a = await service.resolveFile(
        ep1,
        title: 'loose01',
      );
      expect(a.videoPaths, <String>[ep1]);
      expect(a.bookUid, isNull);
      expect(a.wholeSeason, isFalse);
      expect(a.episodes.single.bookUid, isNull);
      expect(a.episodes.single.registersSubtitleSource, isFalse);
      // 同一文件夹里的各集共用一份作品身份（专名表 / 缓存），任务键各不相同。
      final AppVideoSubtitleTarget b = await service.resolveFile(
        ep2,
        title: 'loose02',
      );
      expect(b.work.workKey, a.work.workKey);
      expect(b.key, isNot(a.key));
      // 互联镜像任务的主体：没有库条目也没有合集时用目标自己的键，不是 collection:null。
      expect(VideoBookSubtitleSink(db).mirrorSubject(a), a.key);

      await expectLater(
        service.resolveFile(
          p.join(tmp.path, 'videos', 'gone.mkv'),
          title: 'gone',
        ),
        throwsA(isA<AppVideoSubtitleTargetNotFound>()),
      );
      await expectLater(
        service.resolveFile('https://host.invalid/v.mkv', title: 'remote'),
        throwsA(isA<AppVideoSubtitleTargetNotFound>()),
      );
    });

    test('在线流：作品身份按来源给的作品名兜底，同一部作品各集共用；副本不在就报找不到', () async {
      final AppVideoSubtitleService service = buildService();
      final Directory exportDir = Directory(p.join(tmp.path, 'generated'));
      String staged(String name) =>
          (File(p.join(tmp.path, 'sa', name))
                ..createSync(recursive: true)
                ..writeAsBytesSync(<int>[1, 2, 3]))
              .path;
      final AppVideoSubtitleTarget ep1 = await service.resolveStream(
        audioPath: staged('ep1.m4a'),
        title: 'Episode 1',
        key: 'a',
        exportDir: exportDir,
        workTitle: 'Fixture Show',
      );
      final AppVideoSubtitleTarget ep2 = await service.resolveStream(
        audioPath: staged('ep2.m4a'),
        title: 'Episode 2',
        key: 'b',
        exportDir: exportDir,
        workTitle: 'Fixture Show',
      );
      expect(ep1.work.workKey, fallbackSubtitleWorkKey(title: 'Fixture Show'));
      expect(ep2.work.workKey, ep1.work.workKey);
      expect(ep1.work.title, 'Fixture Show');
      expect(ep1.key, isNot(ep2.key));
      expect(
        ep1.sink!.exportDirFor(ep1.videoPaths.single)?.path,
        exportDir.path,
      );
      // 没有作品名（单条粘贴的流）：按这一集的标题。
      final AppVideoSubtitleTarget loose = await service.resolveStream(
        audioPath: staged('loose.m4a'),
        title: 'Some Clip',
        key: 'c',
        exportDir: exportDir,
      );
      expect(loose.work.workKey, fallbackSubtitleWorkKey(title: 'Some Clip'));
      await expectLater(
        service.resolveStream(
          audioPath: p.join(tmp.path, 'sa', 'gone.m4a'),
          title: 'gone',
          key: 'd',
          exportDir: exportDir,
        ),
        throwsA(isA<AppVideoSubtitleTargetNotFound>()),
      );
    });

    test('播放页当前集：库里有就按库解析，没有就按文件解析', () async {
      final String inLibrary = video('lib01.mkv');
      final String loose = video('loose03.mkv');
      await addBook('lib', inLibrary);
      final AppVideoSubtitleService service = buildService();

      final AppVideoSubtitleTarget fromBook = await service.resolvePlaying(
        'lib',
        videoPath: inLibrary,
        title: 'ignored',
      );
      expect(fromBook.bookUid, 'lib');

      final AppVideoSubtitleTarget fromFile = await service.resolvePlaying(
        'not-in-library',
        videoPath: loose,
        title: 'loose03',
      );
      expect(fromFile.bookUid, isNull);
      expect(fromFile.videoPaths, <String>[loose]);
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

    test('蓝光 title：整卷与分集 .mpls 都是一集并登记库条目，作品按盘根兜底', () async {
      final String mpls = blurayTitle('Show Vol.1');
      final String discRoot = p.join(tmp.path, 'discs', 'Show Vol.1');
      // 按集展开的虚拟分集：磁盘上没有这个文件，背后是整卷 00001.mpls。
      final String episode = p.join(p.dirname(mpls), '00001.p02.mpls');
      final String gone = p.join(
        tmp.path,
        'discs',
        'Gone',
        'BDMV',
        'PLAYLIST',
        '00001.mpls',
      );
      await addBook('bd', mpls);
      await addBook('bd-ep2', episode);
      await addBook('bd-gone', gone);
      final AppVideoSubtitleService service = buildService();

      final AppVideoSubtitleTarget whole = await service.resolveBook('bd');
      expect(whole.videoPaths, <String>[mpls]);
      expect(whole.unavailable, isEmpty);
      expect(whole.episodes.single.registersSubtitleSource, isTrue);
      expect(
        whole.work.workKey,
        fallbackSubtitleWorkKey(folderPath: discRoot, title: 'bd'),
        reason: '没刮削的盘按盘根兜底作品身份，不按每张盘都同名的 BDMV/PLAYLIST',
      );

      final AppVideoSubtitleTarget split = await service.resolveBook('bd-ep2');
      expect(split.videoPaths, <String>[episode]);
      expect(split.episodes.single.registersSubtitleSource, isTrue);

      final int collection = await addCollection(<String>[
        'bd',
        'bd-ep2',
        'bd-gone',
      ]);
      final AppVideoSubtitleTarget season = await service.resolveCollection(
        collection,
      );
      expect(season.videoPaths, <String>[mpls, episode]);
      expect(
        season.unavailable.map((AppVideoSubtitleUnavailable u) => u.reason),
        <AppVideoSubtitleUnavailableReason>[
          AppVideoSubtitleUnavailableReason.missingFile,
        ],
      );

      // 播放页当前 title（库里有这一行）走库解析；没入库的 `.mpls` 按文件解析，作品名
      // 取盘根目录名。
      final AppVideoSubtitleTarget playing = await service.resolvePlaying(
        'bd',
        videoPath: mpls,
        title: 'ignored',
      );
      expect(playing.bookUid, 'bd');
      expect(playing.episodes.single.registersSubtitleSource, isTrue);
      final String loose = blurayTitle('Loose Disc', '00800.mpls');
      final AppVideoSubtitleTarget file = await service.resolveFile(
        loose,
        title: '00800',
      );
      expect(file.videoPaths, <String>[loose]);
      expect(file.work.title, 'Loose Disc');
    });
  });

  group('任务', () {
    test('在线流：整集音频副本走完整管线，产物落 app 目录，按集记住选择后删副本', () async {
      final Directory staged = Directory(
        p.join(tmp.path, 'subs', 'stream_audio'),
      )..createSync(recursive: true);
      final File audio = File(p.join(staged.path, 'Ep 1 [k1].m4a'))
        ..writeAsBytesSync(List<int>.filled(64, 3));
      final Directory exportDir = Directory(
        p.join(tmp.path, 'subs', 'generated'),
      );
      final List<String> remembered = <String>[];
      final AppVideoSubtitleService service = buildService();
      final AppVideoSubtitleTarget target = await service.resolveStream(
        audioPath: audio.path,
        title: 'Ep 1',
        key: 'k1',
        exportDir: exportDir,
        workTitle: 'Fixture Show',
        contentLanguage: 'jpn',
        remember: (String path) async => remembered.add(path),
      );
      expect(target.videoPaths, <String>[audio.path]);
      expect(target.bookUid, isNull);
      expect(target.wholeSeason, isFalse);
      expect(target.isMusic, isFalse);
      expect(target.key, 'stream:k1');
      expect(target.episodes.single.registersSubtitleSource, isFalse);
      expect(target.episodes.single.contentLanguage, 'jpn');
      // 互联镜像任务的主体是目标自己的键。
      expect(target.sink!.mirrorSubject(target), 'stream:k1');
      expect(target.sink!.mirrorKind, VideoRemoteJobKind.subtitleGenerate);
      expect(target.sink!.usesStyleReference, isFalse);

      final AppVideoSubtitleJob job = service.start(
        target,
        const AppVideoSubtitleOptions(),
      );
      await job.done;
      expect(
        job.status,
        AppVideoSubtitleJobStatus.succeeded,
        reason: '${job.errorMessage}',
      );
      final String expected = p.join(exportDir.path, 'Ep 1 [k1].ja.srt');
      final VideoSubtitleEpisodeResult result = job.result!.episodes.single;
      expect(result.exported, isTrue);
      expect(result.outputPath, expected);
      expect(File(expected).existsSync(), isTrue);
      expect(await service.subtitlePathFor(target, audio.path), expected);
      expect(remembered, <String>[expected]);
      expect(audio.existsSync(), isFalse, reason: '副本只是转写输入，登记后删掉');
      expect(job.registeredBookUids, isEmpty);
    });

    test('在线流：参考画面向目标给的取帧要（副本只有音频，画面从流里抽）', () async {
      settings.provider = AiProviderConfig(
        id: 'p1',
        presetId: 'openai',
        name: 'Test AI',
        baseUrl: Uri.parse('https://example.invalid/v1'),
        model: 'm1',
        acceptsImages: true,
      );
      final File audio = File(p.join(tmp.path, 'sa', 'Ep 2 [k2].m4a'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(List<int>.filled(64, 5));
      final List<String> asked = <String>[];
      final AppVideoSubtitleService service = buildService();
      final AppVideoSubtitleTarget target = await service.resolveStream(
        audioPath: audio.path,
        title: 'Ep 2',
        key: 'k2',
        exportDir: Directory(p.join(tmp.path, 'generated')),
        frameSource: (String videoPath, int atMs) async {
          asked.add('$videoPath@$atMs');
          return null;
        },
      );
      final AppVideoSubtitleJob job = service.start(
        target,
        const AppVideoSubtitleOptions(proofread: true, frames: true),
      );
      await job.done;
      expect(
        job.status,
        AppVideoSubtitleJobStatus.succeeded,
        reason: '${job.errorMessage}',
      );
      expect(asked, isNotEmpty);
      expect(asked.first, startsWith('${audio.path}@'));
    });

    test('蓝光 title：产物落在任务根的 disc_out，登记到这一行，盘里不多任何文件', () async {
      final String mpls = blurayTitle('Show Vol.1');
      final String discRoot = p.join(tmp.path, 'discs', 'Show Vol.1');
      await addBook('bd', mpls, subtitleSource: 'embedded:3');
      final List<String> before = filesUnder(discRoot);
      final AppVideoSubtitleService service = buildService();
      // 原盘会话里播放页给的就是当前 title 的 `.mpls`（视频页单集入口）。
      final AppVideoSubtitleTarget target = await service.resolvePlaying(
        'bd',
        videoPath: mpls,
        title: 'ignored',
      );
      final AppVideoSubtitleJob job = service.start(
        target,
        const AppVideoSubtitleOptions(),
      );
      await job.done;

      expect(
        job.status,
        AppVideoSubtitleJobStatus.succeeded,
        reason: '${job.errorMessage}',
      );
      final String expected = p.join(
        jobs.path,
        'disc_out',
        videoSubtitleJobId(mpls),
        '00001.ja.srt',
      );
      final VideoSubtitleEpisodeResult result = job.result!.episodes.single;
      expect(result.exported, isTrue);
      expect(result.outputPath, expected);
      expect(File(expected).existsSync(), isTrue);
      expect(await service.subtitlePathFor(target, mpls), expected);
      expect(filesUnder(discRoot), before, reason: '盘结构里不能写字幕');
      // 登记进这个 title 行（替换原盘内嵌轨的旧选择）：重进这张盘时字幕菜单按库里的
      // subtitleSource 把它列成候选。
      expect((await db.getVideoBookByBookUid('bd'))!.subtitleSource, expected);
      expect(job.registeredBookUids, <String>['bd']);
    });

    test('多角度 title：按当前角度的抽取路径跑，产物登记到不带角度的 title 行', () async {
      final String mpls = blurayTitle('Multi Angle');
      final String discRoot = p.join(tmp.path, 'discs', 'Multi Angle');
      await addBook('bd', mpls, subtitleSource: 'embedded:3');
      final List<String> before = filesUnder(discRoot);
      final AppVideoSubtitleService service = buildService();
      // 原盘会话正放第 2 个角度：播放页给的是角度成员路径（盘上没有这个文件）。
      final String angle = blurayAnglePath(mpls, 1);
      final AppVideoSubtitleTarget target = await service.resolvePlaying(
        'bd',
        videoPath: angle,
        title: 'ignored',
      );
      expect(target.bookUid, 'bd');
      expect(target.videoPaths, <String>[angle]);
      expect(target.unavailable, isEmpty);
      expect(target.episodes.single.registersSubtitleSource, isTrue);
      expect(target.episodes.single.replacesSubtitleSelection, isTrue);

      final AppVideoSubtitleJob job = service.start(
        target,
        const AppVideoSubtitleOptions(),
      );
      await job.done;

      expect(
        job.status,
        AppVideoSubtitleJobStatus.succeeded,
        reason: '${job.errorMessage}',
      );
      final VideoSubtitleEpisodeResult result = job.result!.episodes.single;
      expect(result.videoPath, angle);
      expect(result.exported, isTrue);
      final String output = result.outputPath!;
      expect(
        p.isWithin(
          p.join(jobs.path, 'disc_out', videoSubtitleJobId(angle)),
          output,
        ),
        isTrue,
        reason: output,
      );
      expect(File(output).existsSync(), isTrue);
      expect(filesUnder(discRoot), before, reason: '盘结构里不能写字幕');
      expect((await db.getVideoBookByBookUid('bd'))!.subtitleSource, output);
      expect(job.registeredBookUids, <String>['bd']);
    });

    test('播放页发起：识别播放器当前音轨；批量与只重跑写法统一不换轨', () async {
      final String ep = video('dual.mkv');
      await addBook('dual', ep);
      final List<String> probed = <String>[];
      // 第 0 条英语（流 1）、第 1 条日语（流 2）：按日语挑的是流 2。
      final AppVideoSubtitleService service = buildService(
        probeAudioTracks: (String path) async {
          probed.add(path);
          return const <AudioTrackFacts>[
            AudioTrackFacts(index: 1, language: 'eng'),
            AudioTrackFacts(index: 2, language: 'jpn'),
          ];
        },
      );
      final AppVideoSubtitleTarget playing = await service.resolvePlaying(
        'dual',
        videoPath: ep,
        title: 'dual',
        audioTrack: 0,
      );
      expect(playing.episodes.single.audioTrack, 0);
      final AppVideoSubtitleJob job = service.start(
        playing,
        const AppVideoSubtitleOptions(),
      );
      await job.done;
      expect(
        job.status,
        AppVideoSubtitleJobStatus.succeeded,
        reason: '${job.errorMessage}',
      );
      expect(recognizer.audioStreams, <int?>[1], reason: '正在听的是英语轨');
      expect(probed, <String>[ep]);

      // 没入库的文件同口径。
      final String loose = video('loose_dual.mkv');
      final AppVideoSubtitleTarget file = await service.resolvePlaying(
        'missing',
        videoPath: loose,
        title: 'loose',
        audioTrack: 0,
      );
      expect(file.episodes.single.audioTrack, 0);

      // 批量（合集）：没有播放上下文，按语言挑（不换算、不探测）。
      final AppVideoSubtitleTarget season = await service.resolveCollection(
        await addCollection(<String>['dual']),
      );
      expect(season.episodes.single.audioTrack, isNull);
      expect(
        (await service.resolveBook('dual')).episodes.single.audioTrack,
        isNull,
      );
    });

    test('DVD title：经 dvdvideo 按 title 读，解析成一集，产物落 disc_out 并登记到这一行', () async {
      final String discRoot = p.join(tmp.path, 'discs', 'Show DVD');
      File(p.join(discRoot, 'VIDEO_TS', 'VIDEO_TS.IFO'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(List<int>.filled(16, 1));
      final String title = dvdTitlePath(discRoot, 2);
      await addBook('dvd', title, subtitleSource: 'embedded:1');
      final List<String> before = filesUnder(discRoot);
      final AppVideoSubtitleService service = buildService();

      // 播放页（原盘会话里当前 title）与合集整季都认得这一条。
      final AppVideoSubtitleTarget target = await service.resolvePlaying(
        'dvd',
        videoPath: title,
        title: 'ignored',
      );
      expect(target.videoPaths, <String>[title]);
      expect(target.unavailable, isEmpty);
      expect(target.episodes.single.registersSubtitleSource, isTrue);
      expect(
        target.work.workKey,
        fallbackSubtitleWorkKey(folderPath: discRoot, title: 'dvd'),
        reason: '没刮削的盘按盘根兜底作品身份',
      );
      expect(
        (await service.resolveCollection(
          await addCollection(<String>['dvd']),
        )).videoPaths,
        <String>[title],
      );

      final AppVideoSubtitleJob job = service.start(
        target,
        const AppVideoSubtitleOptions(),
      );
      await job.done;
      expect(
        job.status,
        AppVideoSubtitleJobStatus.succeeded,
        reason: '${job.errorMessage}',
      );
      final String output = job.result!.episodes.single.outputPath!;
      expect(
        p.isWithin(
          p.join(jobs.path, 'disc_out', videoSubtitleJobId(title)),
          output,
        ),
        isTrue,
        reason: output,
      );
      expect(filesUnder(discRoot), before, reason: '盘结构里不能写字幕');
      expect((await db.getVideoBookByBookUid('dvd'))!.subtitleSource, output);

      // 盘不在了：照常报文件不在，不进管线。
      File(p.join(discRoot, 'VIDEO_TS', 'VIDEO_TS.IFO')).deleteSync();
      final AppVideoSubtitleTarget gone = await service.resolveBook('dvd');
      expect(gone.episodes, isEmpty);
      expect(
        gone.unavailable.single.reason,
        AppVideoSubtitleUnavailableReason.missingFile,
      );
    });

    test('DVD 多角度 title：按当前角度的抽取路径跑，产物分角度落 disc_out、登记到不带角度的行', () async {
      final String discRoot = p.join(tmp.path, 'discs', 'Angle DVD');
      File(p.join(discRoot, 'VIDEO_TS', 'VIDEO_TS.IFO'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(List<int>.filled(16, 1));
      final String title = dvdTitlePath(discRoot, 2);
      await addBook('dvd', title, subtitleSource: 'embedded:1');
      final List<String> before = filesUnder(discRoot);
      final AppVideoSubtitleService service = buildService();
      // 原盘会话正放第 2 个角度：播放页给的是角度成员路径（虚拟，盘上没有这个文件）。
      final String angle = dvdTitleAnglePath(title, 1);
      final AppVideoSubtitleTarget target = await service.resolvePlaying(
        'dvd',
        videoPath: angle,
        title: 'ignored',
      );
      expect(target.bookUid, 'dvd');
      expect(target.videoPaths, <String>[angle]);
      expect(target.unavailable, isEmpty);
      expect(target.episodes.single.registersSubtitleSource, isTrue);

      final AppVideoSubtitleJob job = service.start(
        target,
        const AppVideoSubtitleOptions(),
      );
      await job.done;
      expect(
        job.status,
        AppVideoSubtitleJobStatus.succeeded,
        reason: '${job.errorMessage}',
      );
      final VideoSubtitleEpisodeResult result = job.result!.episodes.single;
      expect(result.videoPath, angle);
      final String output = result.outputPath!;
      expect(
        p.isWithin(
          p.join(jobs.path, 'disc_out', videoSubtitleJobId(angle)),
          output,
        ),
        isTrue,
        reason: output,
      );
      expect(videoSubtitleJobId(angle), isNot(videoSubtitleJobId(title)));
      expect(filesUnder(discRoot), before, reason: '盘结构里不能写字幕');
      expect((await db.getVideoBookByBookUid('dvd'))!.subtitleSource, output);
      expect(job.registeredBookUids, <String>['dvd']);
    });

    test('没入库的多角度 title 也按角度成员路径解析成一集', () async {
      final String loose = blurayTitle('Loose Angle', '00800.mpls');
      final String angle = blurayAnglePath(loose, 2);
      final AppVideoSubtitleTarget file = await buildService().resolvePlaying(
        'missing',
        videoPath: angle,
        title: '00800',
      );
      expect(file.videoPaths, <String>[angle]);
      expect(file.work.title, 'Loose Angle');
    });

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
    test('BUG-4993：重估不重复探测时长；探测失败的下次重探', () async {
      settings.provider = testProvider();
      final String ep1 = video('ep01.mkv');
      final String ep2 = video('ep02.mkv');
      await addBook('a', ep1);
      await addBook('b', ep2);
      final Map<String, int> probes = <String, int>{};
      bool ep2Fails = true;
      final AppVideoSubtitleService service = buildService(
        probeDurationMs: (String path) async {
          probes[path] = (probes[path] ?? 0) + 1;
          if (path == ep2 && ep2Fails) return null;
          return 24 * 60 * 1000;
        },
      );
      final AppVideoSubtitleTarget a = await service.resolveBook('a');
      final AppVideoSubtitleTarget b = await service.resolveBook('b');
      // 面板切开关 / 换语言：同一目标连估三次，外加两次并发。
      await service.estimateCost(a);
      await service.estimateCost(a, frames: true);
      await service.estimateCost(a, language: VideoSubtitleLanguage.mandarin);
      await Future.wait(<Future<AppVideoSubtitleCostEstimate>>[
        service.estimateCost(a),
        service.estimateCost(a),
      ]);
      expect(probes[ep1], 1);

      final AppVideoSubtitleCostEstimate failed = await service.estimateCost(b);
      expect(failed.unknownDurationEpisodes, 1);
      ep2Fails = false;
      final AppVideoSubtitleCostEstimate retried = await service.estimateCost(
        b,
      );
      expect(retried.unknownDurationEpisodes, 0);
      expect(retried.basis, AppVideoSubtitleEstimateBasis.duration);
      expect(probes[ep2], 2);
    });

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

  group('BUG-5008 生成管线的失败隔离', () {
    test('一集登记抛错不连带后面的集；任务仍按第一处错误判失败', () async {
      final String ep1 = video('ep01.mkv');
      final String ep2 = video('ep02.mkv');
      await addBook('a', ep1);
      await addBook('b', ep2);
      final int collection = await addCollection(<String>['a', 'b']);
      final AppVideoSubtitleService service = buildService();
      final AppVideoSubtitleTarget season = await service.resolveCollection(
        collection,
      );
      final _FlakySink sink = _FlakySink(
        failOn: ep1,
        exportDir: Directory(p.join(tmp.path, 'out')),
      );
      final AppVideoSubtitleTarget target = AppVideoSubtitleTarget(
        title: season.title,
        work: season.work,
        episodes: season.episodes,
        collectionId: season.collectionId,
        sink: sink,
      );
      final AppVideoSubtitleJob job = service.start(
        target,
        const AppVideoSubtitleOptions(),
      );
      await job.done;
      expect(sink.attempted, <String>[ep1, ep2]);
      expect(job.registeredBookUids, <String>['b']);
      expect(job.status, AppVideoSubtitleJobStatus.failed);
      expect(job.errorMessage, contains('db locked'));
    });

    test('S0 还没完成时，同作品同语言的专名表拒绝保存 / 重新生成；别的语言照常', () async {
      settings.provider = testProvider();
      final String ep1 = video('ep01.mkv');
      await addBook('a', ep1);
      final _GatedRecognizer gated = _GatedRecognizer(recognizer);
      final AppVideoSubtitleService service = buildService(
        resolve: () async => VideoSubtitleRecognizerChoice(recognizer: gated),
      );
      final AppVideoSubtitleTarget target = await service.resolveBook('a');
      final AppVideoSubtitleJob job = service.start(
        target,
        const AppVideoSubtitleOptions(proofread: true),
      );
      await gated.entered.future;
      expect(service.glossaryWriterFor(target.work), same(job));
      const List<SubtitleGlossaryEntry> entries = <SubtitleGlossaryEntry>[
        SubtitleGlossaryEntry(ja: '梓', kind: '人名'),
      ];
      await expectLater(
        service.saveGlossary(target.work, entries),
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
                same(job),
              ),
        ),
      );
      await expectLater(
        service.regenerateGlossary(target),
        throwsA(isA<AppVideoSubtitleStartRefused>()),
      );
      // 普通话的表与这次任务无关。
      await service.saveGlossary(
        target.work,
        entries,
        language: VideoSubtitleLanguage.mandarin,
      );

      gated.release.complete();
      await job.done;
      expect(service.glossaryWriterFor(target.work), isNull);
      final SubtitleGlossary saved = await service.saveGlossary(
        target.work,
        entries,
        previous: await service.loadGlossary(target.work),
      );
      expect(
        saved.entries.map((SubtitleGlossaryEntry e) => e.ja),
        contains('梓'),
      );
    });

    test('HBK-AUDIT-039：单独重新生成在飞时，同作品同语言的生成任务 / 保存 / 再次重新生成都拒绝；'
        '完成后当前表是重新生成的结果', () async {
      settings.provider = testProvider();
      await addBook('a', video('ep01.mkv'));
      final _GatedCompleter gated = _GatedCompleter(FakeAiCompleter(answerAll));
      completer = gated;
      final AppVideoSubtitleService service = buildService();
      final AppVideoSubtitleTarget target = await service.resolveBook('a');
      await service.saveGlossary(target.work, const <SubtitleGlossaryEntry>[
        SubtitleGlossaryEntry(ja: 'あずにゃん', kind: '人名(愛称)'),
      ]);
      final Future<SubtitleGlossary> regen = service.regenerateGlossary(target);
      await gated.entered.future;

      Matcher refusedByRegen() => throwsA(
        isA<AppVideoSubtitleStartRefused>().having(
          (AppVideoSubtitleStartRefused r) => r.problem,
          'problem',
          AppVideoSubtitleStartProblem.glossaryRegenerating,
        ),
      );
      // 主任务后起：S0 会读整表、生成、整表写回，与重新生成互相覆盖。
      expect(
        () => service.start(
          target,
          const AppVideoSubtitleOptions(proofread: true),
        ),
        refusedByRegen(),
      );
      await expectLater(
        service.saveGlossary(target.work, const <SubtitleGlossaryEntry>[
          SubtitleGlossaryEntry(ja: '梓', kind: '人名'),
        ]),
        refusedByRegen(),
      );
      await expectLater(service.regenerateGlossary(target), refusedByRegen());
      // 不校对的任务不碰专名表；别的语言是另一张表。
      final AppVideoSubtitleJob plain = service.start(
        target,
        const AppVideoSubtitleOptions(),
      );
      await plain.done;
      await service.saveGlossary(target.work, const <SubtitleGlossaryEntry>[
        SubtitleGlossaryEntry(ja: '梓'),
      ], language: VideoSubtitleLanguage.mandarin);

      gated.release.complete();
      final SubtitleGlossary regenerated = await regen;
      expect(
        store.rows[VideoSubtitleLanguage.japanese.glossaryKey(
          target.work.workKey,
        )],
        same(regenerated),
      );
      expect(
        regenerated.entries.map((SubtitleGlossaryEntry e) => e.ja),
        contains('あずにゃん'),
      );
      // 重新生成结束即放开。
      final AppVideoSubtitleJob job = service.start(
        target,
        const AppVideoSubtitleOptions(proofread: true),
      );
      await job.done;
      expect(job.status, AppVideoSubtitleJobStatus.succeeded);
    });

    test('HBK-AUDIT-039：重新生成失败 / 取消也放开写方登记', () async {
      settings.provider = testProvider();
      await addBook('a', video('ep01.mkv'));
      completer = ExplodingAiCompleter('quota_exhausted');
      final AppVideoSubtitleService service = buildService();
      final AppVideoSubtitleTarget target = await service.resolveBook('a');
      await expectLater(
        service.regenerateGlossary(target),
        throwsA(isNot(isA<AppVideoSubtitleStartRefused>())),
      );
      completer = FakeAiCompleter(answerAll);
      await service.saveGlossary(target.work, const <SubtitleGlossaryEntry>[
        SubtitleGlossaryEntry(ja: '梓'),
      ]);
      // 取消：停在 AI 请求中间时取消，同样放开。
      final _GatedCompleter gated = _GatedCompleter(FakeAiCompleter(answerAll));
      completer = gated;
      final SubtitleCancelSource cancel = SubtitleCancelSource();
      final Future<SubtitleGlossary> cancelled = service.regenerateGlossary(
        target,
        cancel: cancel,
      );
      await gated.entered.future;
      cancel.cancel();
      gated.release.complete();
      await expectLater(cancelled, throwsA(isA<SubtitlePipelineCancelled>()));
      completer = FakeAiCompleter(answerAll);
      await service.saveGlossary(target.work, const <SubtitleGlossaryEntry>[
        SubtitleGlossaryEntry(ja: '梓'),
      ]);
      await service.regenerateGlossary(target);
    });

    test('S0 进行中仍拒绝；S0 一完成、任务还在跑就放开编辑', () async {
      settings.provider = testProvider();
      await addBook('a', video('ep01.mkv'));
      final AppVideoSubtitleService service = buildService();
      final AppVideoSubtitleTarget target = await service.resolveBook('a');
      final AppVideoSubtitleJob job = service.start(
        target,
        const AppVideoSubtitleOptions(proofread: true),
      );
      // 每次进度回报时（同步）看一眼：S0 的 0 与 1 两次回报、以及之后的阶段。
      final List<(VideoSubtitleStage, double, bool)> seen =
          <(VideoSubtitleStage, double, bool)>[];
      job.addListener(() {
        final VideoSubtitleProgress? p = job.progress;
        if (p == null || !job.isRunning) return;
        seen.add((
          p.stage,
          p.fraction,
          service.glossaryWriterFor(target.work) != null,
        ));
      });
      await job.done;
      expect(job.status, AppVideoSubtitleJobStatus.succeeded);
      final Iterable<(VideoSubtitleStage, double, bool)> s0 = seen.where(
        ((VideoSubtitleStage, double, bool) e) =>
            e.$1 == VideoSubtitleStage.glossary,
      );
      expect(
        s0.where(((VideoSubtitleStage, double, bool) e) => e.$2 < 1),
        <(VideoSubtitleStage, double, bool)>[
          (VideoSubtitleStage.glossary, 0.0, true),
        ],
      );
      expect(
        s0.where(((VideoSubtitleStage, double, bool) e) => e.$2 >= 1),
        <(VideoSubtitleStage, double, bool)>[
          (VideoSubtitleStage.glossary, 1.0, false),
        ],
      );
      final Iterable<(VideoSubtitleStage, double, bool)> after = seen.where(
        ((VideoSubtitleStage, double, bool) e) =>
            e.$1.index > VideoSubtitleStage.glossary.index,
      );
      expect(after, isNotEmpty);
      expect(
        after.every(((VideoSubtitleStage, double, bool) e) => !e.$3),
        isTrue,
      );
    });
  });
}

/// 指定一集登记时抛错，其余照常记下（模拟写库失败）。
class _FlakySink implements AppSubtitleOutputSink {
  _FlakySink({required this.failOn, required this.exportDir});

  final String failOn;
  final Directory exportDir;
  final List<String> attempted = <String>[];

  @override
  AppSubtitleTargetDomain get domain => AppSubtitleTargetDomain.video;

  @override
  Directory? exportDirFor(String mediaPath) => exportDir;

  @override
  bool get usesStyleReference => false;

  @override
  VideoRemoteJobKind get mirrorKind => VideoRemoteJobKind.subtitleGenerate;

  @override
  String mirrorSubject(AppVideoSubtitleTarget target) => target.key;

  @override
  Future<List<String>> extraEvidenceFiles(
    AppVideoSubtitleEpisode episode,
  ) async => const <String>[];

  @override
  bool get registersSkippedExisting => false;

  @override
  Future<List<String>> register(
    AppVideoSubtitleEpisode episode,
    VideoSubtitleEpisodeResult result,
  ) async {
    attempted.add(episode.videoPath);
    if (episode.videoPath == failOn) throw StateError('db locked');
    return <String>[?episode.bookUid];
  }
}

/// 第一次请求停在 [release] 上：让「单独重新生成」停在异步生成中间。
class _GatedCompleter implements AiTextCompleter {
  _GatedCompleter(this.inner);

  final AiTextCompleter inner;
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<AiChatCompletion> complete(
    String prompt, {
    String stablePrefix = '',
    List<AiChatImage> images = const <AiChatImage>[],
  }) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return inner.complete(prompt, stablePrefix: stablePrefix, images: images);
  }
}

/// 识别停在半路，直到测试放行（任务停在 S0 之前）。
class _GatedRecognizer implements VideoSubtitleRecognizer {
  _GatedRecognizer(this.inner);

  final VideoSubtitleRecognizer inner;
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  String get id => inner.id;

  @override
  Future<List<SubtitleDraftCue>> recognize({
    required String videoPath,
    required Directory workDir,
    required VideoSubtitleRecognizeProgress onProgress,
    required SubtitleCancelToken cancel,
    int? audioStreamIndex,
  }) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return inner.recognize(
      videoPath: videoPath,
      workDir: workDir,
      onProgress: onProgress,
      cancel: cancel,
      audioStreamIndex: audioStreamIndex,
    );
  }
}
