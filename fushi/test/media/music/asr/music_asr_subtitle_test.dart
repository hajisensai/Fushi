import 'dart:convert';
import 'dart:io';

import 'package:fushi_asr_core/asr_core.dart' show AsrAudioProfile;
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/asr/music_asr_subtitle_sink.dart';
import 'package:fushi/src/media/music/asr/music_subtitle_target.dart';
import 'package:fushi/src/media/music/lyrics/lrclib_client.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_sources.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart';
import 'package:fushi/src/media/video/subtitle/app_video_subtitle_service.dart';
import 'package:fushi/src/media/video/video_playback_remote.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_language.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart';
import 'package:fushi_engine/media/music/server/music_server.dart'
    show MusicServerKind, musicServerAlbumUid, musicServerTrackUid;
import 'package:fushi_engine/media/music/server/music_server_loudness.dart'
    show MusicServerTrackRef;
import 'package:fushi_music/fushi_music.dart';
import 'package:path/path.dart' as p;

import '../../../helpers/fake_ai_text_completer.dart';
import '../../../helpers/fake_video_subtitle.dart';

/// 音乐库「生成日语字幕」：目标解析（按文件去重、远端 / 缺文件、批量跳过已生成）、经同一个
/// 字幕服务跑完后产物进 `asr` 歌词行（CUE 按曲目切片）、导出在应用目录不碰音频旁、远控
/// 镜像单独一种、与视频生成共用单活跃任务。识别器是替身（每个文件 4 句：1–3 s、4–6 s、
/// 7–9 s、10–12 s），歌词解析 / 切片走真 Rust 库。
Future<LyricTimeline> _parse(Uint8List b, String hint, int? d) async =>
    FushiLyrics.parse(b, hint: hint, durationMs: d);

void main() {
  late FushiDatabase db;
  late Directory tmp;
  late Directory out;
  late MusicLyricsService lyrics;
  late VideoRemoteJobRegistry registry;
  late FakeVideoRecognizer recognizer;

  MusicSubtitleTargets targets() => MusicSubtitleTargets(
    database: db,
    lyrics: lyrics,
    outRoot: () async => out,
  );

  /// 每次挑识别器时收到的素材（音乐库歌词应为 `song`，手机内存不够时 `mixedAudio`）。
  final List<AsrAudioProfile> resolvedProfiles = <AsrAudioProfile>[];

  AppVideoSubtitleService service({
    AsrAudioProfile musicProfile = AsrAudioProfile.song,
    FakeVideoSubtitleSettings? settings,
  }) => AppVideoSubtitleService(
    database: db,
    settings: settings ?? FakeVideoSubtitleSettings(),
    glossaryStore: MemoryGlossaryStore(),
    jobRegistry: registry,
    jobsRoot: () async => Directory(p.join(tmp.path, 'jobs')),
    probeDurationMs: (String _) async => 12 * 60 * 1000,
    mossPort: const ReadyModels(),
    asrModelPort: const ReadyModels(),
    recognizerResolver:
        ({
          required VideoSubtitleSegmenterMode mode,
          MossBackendPreference mossBackend = MossBackendPreference.auto,
          VideoSubtitleLanguage language = VideoSubtitleLanguage.japanese,
          AsrAudioProfile audioProfile = AsrAudioProfile.mixedAudio,
        }) async {
          resolvedProfiles.add(audioProfile);
          return VideoSubtitleRecognizerChoice(recognizer: recognizer);
        },
    musicAudioProfile: (VideoSubtitleLanguage _) async => musicProfile,
    completerFactory: (AiProviderConfig _) =>
        (completer: FakeAiCompleter(answerAll), close: () {}),
  );

  String audio(String rel, {int bytes = 32}) {
    final File f = File(p.join(tmp.path, 'music', rel))
      ..createSync(recursive: true)
      ..writeAsBytesSync(List<int>.filled(bytes, 1));
    return f.path;
  }

  Future<void> addAlbum(String uid, String title) => db
      .into(db.musicAlbums)
      .insert(
        MusicAlbumsCompanion.insert(
          albumUid: uid,
          title: title,
          addedAt: 1,
          updatedAt: 1,
        ),
      );

  Future<void> addTrack(
    String uid,
    String path, {
    String? albumUid = 'alb',
    int? trackNo,
    int? cueStartMs,
    int? cueEndMs,
  }) => db
      .into(db.musicTracks)
      .insert(
        MusicTracksCompanion.insert(
          trackUid: uid,
          path: path,
          title: 'Track $uid',
          albumUid: Value<String?>(albumUid),
          trackNo: Value<int?>(trackNo),
          cueStartMs: Value<int?>(cueStartMs),
          cueEndMs: Value<int?>(cueEndMs),
          fileMtimeAt: 1,
          fileSize: 1,
          addedAt: 1,
        ),
      );

  Future<MusicLyricRow?> asrRow(String uid) =>
      (db.select(db.musicLyrics)..where(
            ($MusicLyricsTable l) =>
                l.trackUid.equals(uid) & l.source.equals(MusicLyricsSource.asr),
          ))
          .getSingleOrNull();

  setUp(() async {
    resolvedProfiles.clear();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    tmp = Directory.systemTemp.createTempSync('music_asr_');
    out = Directory(p.join(tmp.path, 'support', 'asr_jobs', 'music_subtitles'));
    registry = VideoRemoteJobRegistry();
    recognizer = FakeVideoRecognizer();
    lyrics = MusicLyricsService(
      database: () => db,
      lrclib: LrclibClient(transport: (Uri _) async => (status: 404, body: '')),
      onlineEnabled: () => false,
      readEmbedded: (String _, int? _) async => const <EmbeddedLyrics>[],
      parse: _parse,
    );
    await addAlbum('alb', 'ドラマCD 第1巻');
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  group('目标解析', () {
    test('专辑：CUE 多曲按文件去重成一集；远端 / 缺文件进不可处理；批量；专名表键', () async {
      final String image = audio('cd/image.flac');
      await addTrack('c1', image, trackNo: 1, cueStartMs: 0, cueEndMs: 6500);
      await addTrack('c2', image, trackNo: 2, cueStartMs: 6500);
      await addTrack('net', 'https://srv.invalid/a.flac', trackNo: 3);
      await addTrack(
        'gone',
        p.join(tmp.path, 'music', 'gone.flac'),
        trackNo: 4,
      );
      final AppVideoSubtitleTarget t = await targets().forAlbum('alb');
      expect(t.isMusic, isTrue);
      expect(t.wholeSeason, isTrue);
      expect(t.key, 'music:album:alb');
      expect(t.work.workKey, 'album:alb');
      expect(t.missingScrapedData, isFalse, reason: '音乐不提示「先刮削」');
      expect(t.videoPaths, <String>[image]);
      expect(t.episodes.single.bookUid, isNull);
      expect(
        t.unavailable.map((AppVideoSubtitleUnavailable u) => u.reason),
        <AppVideoSubtitleUnavailableReason>[
          AppVideoSubtitleUnavailableReason.remote,
          AppVideoSubtitleUnavailableReason.missingFile,
        ],
      );
      final MusicAsrSubtitleSink sink = t.sink! as MusicAsrSubtitleSink;
      expect(
        sink.slotsOf(image).map((MusicAsrTrackSlot s) => s.trackUid),
        <String>['c1', 'c2'],
      );
    });

    test('批量跳过已有生成字幕的曲目；单曲入口照样重新生成', () async {
      final String a = audio('a.flac');
      final String b = audio('b.flac', bytes: 40);
      await addTrack('a', a, trackNo: 1);
      await addTrack('b', b, trackNo: 2);
      final Uint8List raw = utf8.encode(
        '1\n00:00:01,000 --> 00:00:02,000\n既に\n',
      );
      await lyrics.saveGenerated(
        'a',
        format: 'srt',
        raw: raw,
        timeline: await _parse(raw, 'srt', null),
      );
      expect((await targets().forAlbum('alb')).videoPaths, <String>[b]);
      final AppVideoSubtitleTarget single = await targets().forTrack('a');
      expect(single.videoPaths, <String>[a]);
      expect(single.wholeSeason, isFalse);
      expect(single.key, 'music:track:a');
    });
  });

  test('跑完：CUE 两曲各得切好的 asr 行；导出在应用目录、不碰音频旁；镜像单独一种', () async {
    final String image = audio('cd/image.flac');
    await addTrack('c1', image, trackNo: 1, cueStartMs: 0, cueEndMs: 6500);
    await addTrack('c2', image, trackNo: 2, cueStartMs: 6500);
    final List<String> updates = <String>[];
    lyrics.generatedUpdates.listen(updates.add);
    final AppVideoSubtitleService svc = service();
    final AppVideoSubtitleTarget target = await targets().forAlbum('alb');
    final AppVideoSubtitleJob job = svc.start(
      target,
      const AppVideoSubtitleOptions(),
    );
    await job.done;
    expect(
      job.status,
      AppVideoSubtitleJobStatus.succeeded,
      reason: '${job.errorMessage}',
    );
    expect(recognizer.calls, <String>['image.flac'], reason: '整轨只转写一次');
    expect(job.registeredBookUids, <String>['c1', 'c2']);
    expect(updates, <String>['c1', 'c2']);

    // 产物在 <out>/<任务键>/image.ja.srt，音频目录里没有新文件。
    final String srt = await svc.subtitlePathFor(target, image);
    expect(p.isWithin(out.path, srt), isTrue);
    expect(File(srt).existsSync(), isTrue);
    expect(
      Directory(
        p.dirname(image),
      ).listSync().map((FileSystemEntity e) => p.basename(e.path)),
      <String>['image.flac'],
    );

    final MusicLyricsResolution? first = await lyrics.resolve(
      const MusicLyricsTrackRef(
        trackUid: 'c1',
        path: '/x/image.flac',
        title: 'c1',
        cueStartMs: 0,
      ),
    );
    expect(first?.source, MusicLyricsSource.asr);
    expect(
      <(int, int)>[
        for (final LyricLine l in first!.timeline.lines) (l.startMs, l.endMs),
      ],
      <(int, int)>[(1000, 3000), (4000, 6000)],
    );
    final MusicLyricRow second = (await asrRow('c2'))!;
    expect(second.format, 'ttml', reason: 'CUE 切片后的原文存 TTML');
    final LyricTimeline t2 = decodeLyricTimeline(second.timelineCache!);
    expect(
      <(int, int, String)>[
        for (final LyricLine l in t2.lines) (l.startMs, l.endMs, l.text),
      ],
      <(int, int, String)>[(500, 2500, 'ありがとう'), (3500, 5500, 'またね')],
    );

    expect(job.mirror.kind, VideoRemoteJobKind.musicSubtitleGenerate);
    expect(job.mirror.bookUid, 'music:album:alb');
    expect(await db.select(db.videoBooks).get(), isEmpty);

    // 批量重开：已有 asr 行全部跳过；已导出的文件在面板里也算「已有」。
    final AppVideoSubtitleTarget again = await targets().forAlbum('alb');
    expect(again.episodes, isEmpty);
    expect(await svc.existingSubtitleEpisodes(target), <String>{image});
    final AppVideoSubtitleCostEstimate estimate = await svc.estimateCost(
      target,
    );
    expect(estimate.basis, AppVideoSubtitleEstimateBasis.nothing);
  });

  test('CUE 单曲入口只登记那一首；之后专辑批量不重转写，用已有导出给其余曲目补登；面板与'
      '结束按曲目计数', () async {
    final String image = audio('cd/image.flac');
    await addTrack('c1', image, trackNo: 1, cueStartMs: 0, cueEndMs: 6500);
    await addTrack('c2', image, trackNo: 2, cueStartMs: 6500);
    final AppVideoSubtitleService svc = service();
    final AppVideoSubtitleJob single = svc.start(
      await targets().forTrack('c1'),
      const AppVideoSubtitleOptions(),
    );
    await single.done;
    expect(single.registeredBookUids, <String>['c1']);
    expect(await asrRow('c2'), isNull);

    final AppVideoSubtitleTarget batch = await targets().forAlbum('alb');
    expect(batch.videoPaths, <String>[image]);
    expect(batch.trackCounts, (pending: 1, skipped: 1));
    final AppVideoSubtitleJob job = svc.start(
      batch,
      const AppVideoSubtitleOptions(),
    );
    await job.done;
    expect(
      job.status,
      AppVideoSubtitleJobStatus.succeeded,
      reason: '${job.errorMessage}',
    );
    expect(recognizer.calls, <String>['image.flac'], reason: '已导出的整轨不再转写');
    expect(job.registeredBookUids, <String>['c2']);
    final LyricTimeline t2 = decodeLyricTimeline(
      (await asrRow('c2'))!.timelineCache!,
    );
    expect(<(int, String)>[
      for (final LyricLine l in t2.lines) (l.startMs, l.text),
    ], isNotEmpty);
    expect(t2.lines.first.startMs, lessThan(6500), reason: '按曲内时间平移过');
  });

  test('同名 01.flac 各进各的导出目录（不互判「已有同名字幕」）', () async {
    final String a = audio('disc1/01.flac', bytes: 30);
    final String b = audio('disc2/01.flac', bytes: 31);
    await addTrack('a', a, trackNo: 1);
    await addTrack('b', b, trackNo: 2);
    final AppVideoSubtitleService svc = service();
    final AppVideoSubtitleJob job = svc.start(
      await targets().forAlbum('alb'),
      const AppVideoSubtitleOptions(),
    );
    await job.done;
    expect(job.status, AppVideoSubtitleJobStatus.succeeded);
    expect(job.registeredBookUids, <String>['a', 'b']);
    expect((await asrRow('a'))!.format, 'srt');
    expect((await asrRow('b'))!.format, 'srt');
  });

  test('插件曲目（反馈 NXOjldMQZd）：按取到本机的副本转写，登记成插件曲目 uid 的 asr 行；'
      '解析时生成字幕优先于插件自带歌词；登记后删副本', () async {
    final String pluginPath = musicPluginTrackPath('asmr', 'RJ01');
    final String uid = musicPluginTrackUid('asmr', 'RJ01');
    final String albumUid = musicPluginAlbumUid('asmr', 'RJ01-album');
    final MusicPlayItem item = MusicPlayItem(
      trackUid: uid,
      path: pluginPath,
      title: 'トラック1',
      album: '同人音声',
      albumUid: albumUid,
      durationMs: 12 * 60 * 1000,
    );
    final File staged = File(audio('plugin_audio/$uid.wav', bytes: 64));
    final AppVideoSubtitleTarget target = await targets().forPluginTrack(
      item,
      staged,
    );
    expect(target.isMusic, isTrue);
    expect(target.wholeSeason, isFalse);
    expect(target.key, 'music:track:$uid');
    expect(target.work.workKey, 'album:$albumUid');
    expect(target.videoPaths, <String>[staged.path]);
    expect(target.unavailable, isEmpty);
    expect(target.trackCounts, (pending: 1, skipped: 0));

    final AppVideoSubtitleService svc = service();
    final AppVideoSubtitleJob job = svc.start(
      target,
      const AppVideoSubtitleOptions(),
    );
    await job.done;
    expect(
      job.status,
      AppVideoSubtitleJobStatus.succeeded,
      reason: '${job.errorMessage}',
    );
    expect(recognizer.calls, <String>['$uid.wav']);
    expect(job.registeredBookUids, <String>[uid]);
    expect(staged.existsSync(), isFalse, reason: '副本只是转写输入，登记完删掉');
    expect(
      p.isWithin(out.path, await svc.subtitlePathFor(target, staged.path)),
      isTrue,
    );

    final MusicLyricsResolution? r = await lyrics.resolve(
      MusicLyricsTrackRef(trackUid: uid, path: pluginPath, title: 'トラック1'),
    );
    expect(r?.source, MusicLyricsSource.asr);
    expect(r!.timeline.lines.map((LyricLine l) => l.text), <String>[
      '結衣が来た',
      'こんにちは',
      'ありがとう',
      'またね',
    ]);
  });

  test('媒体服务器曲目（Jellyfin / Subsonic）：专辑批量按取到本机的副本 / 离线副本转写，'
      '登记成服务器曲目 uid 的 asr 行（从服务器页与音乐库播都是这个 uid）；'
      '取到本机的副本登记后删，离线副本不删', () async {
    const MusicServerTrackRef ref1 = MusicServerTrackRef(
      kind: MusicServerKind.jellyfin,
      serverId: 'src-1',
      trackId: 'jf-t1',
      albumId: 'jf-a1',
    );
    const MusicServerTrackRef ref2 = MusicServerTrackRef(
      kind: MusicServerKind.jellyfin,
      serverId: 'src-1',
      trackId: 'jf-t2',
      albumId: 'jf-a1',
    );
    final String uid1 = musicServerTrackUid('src-1', 'jf-t1');
    final String uid2 = musicServerTrackUid('src-1', 'jf-t2');
    final String albumUid = musicServerAlbumUid('src-1', 'jf-a1');
    MusicPlayItem item(MusicServerTrackRef ref, String uid, String title) =>
        MusicPlayItem(
          trackUid: uid,
          // 播放路径是带凭据的流地址：生成字幕不碰它。
          path: 'http://nas:8096/Audio/${ref.trackId}/universal?api_key=tok',
          title: title,
          album: '初恋テスト',
          albumUid: albumUid,
          durationMs: 3 * 60 * 1000,
          serverTrack: ref,
        );
    final File staged = File(audio('plugin_audio/$uid1.wav', bytes: 64));
    final File offline = File(audio('offline/02.flac', bytes: 64));
    final AppVideoSubtitleTarget target = await targets().forRemoteTracks(
      tracks: <MusicRemoteAsrTrack>[
        (item: item(ref1, uid1, 'Track 1'), audio: staged, staged: true),
        (item: item(ref2, uid2, 'Track 2'), audio: offline, staged: false),
      ],
      title: '初恋テスト',
      key: 'music:server-album:src-1:jf-a1',
      skipped: 1,
    );
    expect(target.isMusic, isTrue);
    expect(target.wholeSeason, isTrue, reason: '多首 = 专辑批量');
    expect(target.work.workKey, 'album:$albumUid');
    expect(target.videoPaths, <String>[staged.path, offline.path]);
    expect(target.trackCounts, (pending: 2, skipped: 1));

    final AppVideoSubtitleService svc = service();
    final AppVideoSubtitleJob job = svc.start(
      target,
      const AppVideoSubtitleOptions(),
    );
    await job.done;
    expect(
      job.status,
      AppVideoSubtitleJobStatus.succeeded,
      reason: '${job.errorMessage}',
    );
    expect(job.registeredBookUids, unorderedEquals(<String>[uid1, uid2]));
    expect(staged.existsSync(), isFalse, reason: '取到本机的副本登记完删掉');
    expect(offline.existsSync(), isTrue, reason: '离线副本是用户的文件，不删');

    final MusicLyricsResolution? r = await lyrics.resolve(
      MusicLyricsTrackRef(
        trackUid: uid1,
        path: 'http://nas:8096/Audio/jf-t1/universal?api_key=other',
        title: 'Track 1',
      ),
    );
    expect(r?.source, MusicLyricsSource.asr);
  });

  group('歌曲素材（人声分离，拍板 I9ici7ZmKd）', () {
    test('音乐目标按 song 挑识别器；面板查模型用同一个判定', () async {
      final String song = audio('a/01.flac');
      await addTrack('t1', song, trackNo: 1);
      final AppVideoSubtitleService svc = service();
      final AppVideoSubtitleTarget target = await targets().forTrack('t1');
      expect(
        await svc.asrAudioProfileFor(target, VideoSubtitleLanguage.japanese),
        AsrAudioProfile.song,
      );
      final AppVideoSubtitleJob job = svc.start(
        target,
        const AppVideoSubtitleOptions(),
      );
      await job.done;
      expect(job.status, AppVideoSubtitleJobStatus.succeeded);
      expect(resolvedProfiles, <AsrAudioProfile>[AsrAudioProfile.song]);
    });

    test('手机内存放不下分离：判定退回 mixedAudio，任务按混音跑', () async {
      final String song = audio('a/01.flac');
      await addTrack('t1', song, trackNo: 1);
      final AppVideoSubtitleService svc = service(
        musicProfile: AsrAudioProfile.mixedAudio,
      );
      final AppVideoSubtitleJob job = svc.start(
        await targets().forTrack('t1'),
        const AppVideoSubtitleOptions(),
      );
      await job.done;
      expect(job.status, AppVideoSubtitleJobStatus.succeeded);
      expect(resolvedProfiles, <AsrAudioProfile>[AsrAudioProfile.mixedAudio]);
    });

    test('面板定下的素材写进选项：开跑不再重判（两次判定之间内存变了也一致）', () async {
      final String song = audio('a/01.flac');
      await addTrack('t1', song, trackNo: 1);
      // 开跑时的判定会说 song，但面板查 / 下模型时定的是 mixedAudio。
      final AppVideoSubtitleService svc = service();
      final AppVideoSubtitleJob job = svc.start(
        await targets().forTrack('t1'),
        const AppVideoSubtitleOptions(audioProfile: AsrAudioProfile.mixedAudio),
      );
      await job.done;
      expect(job.status, AppVideoSubtitleJobStatus.succeeded);
      expect(resolvedProfiles, <AsrAudioProfile>[AsrAudioProfile.mixedAudio]);
    });
    test('只重跑写法统一：按上次记的识别器（sliding_song）沿用歌曲素材，不随此刻判定换成混音', () async {
      final String song = audio('a/01.flac');
      await addTrack('t1', song, trackNo: 1);
      recognizer = FakeVideoRecognizer(id: 'sliding_song');
      final FakeVideoSubtitleSettings settings = FakeVideoSubtitleSettings()
        ..provider = testProvider();
      final AppVideoSubtitleTarget target = await targets().forTrack('t1');
      final AppVideoSubtitleJob full = service(settings: settings).start(
        target,
        const AppVideoSubtitleOptions(
          proofread: true,
          audioProfile: AsrAudioProfile.song,
        ),
      );
      await full.done;
      expect(full.status, AppVideoSubtitleJobStatus.succeeded);
      resolvedProfiles.clear();

      // 内存变紧，此刻判定会退回混音；但重跑必须沿用 song，否则换识别器、整首重新识别。
      final AppVideoSubtitleService rerunSvc = service(
        musicProfile: AsrAudioProfile.mixedAudio,
        settings: settings,
      );
      final AppVideoSubtitleJob rerun = await rerunSvc.startConsistencyRerun(
        target,
      );
      await rerun.done;
      expect(rerun.status, AppVideoSubtitleJobStatus.succeeded);
      expect(resolvedProfiles, <AsrAudioProfile>[AsrAudioProfile.song]);
      expect(recognizer.calls, hasLength(1), reason: '识别稿走缓存');
    });
  });

  test('与视频生成共用单活跃任务：音乐任务在跑时视频目标被拒（busy）', () async {
    final String a = audio('a.flac');
    await addTrack('a', a, trackNo: 1);
    final String video = audio('v/ep01.mkv');
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('v1'),
        title: const Value<String>('v1'),
        videoPath: Value<String>(video),
      ),
    );
    final AppVideoSubtitleService svc = service();
    final AppVideoSubtitleTarget videoTarget = await svc.resolveBook('v1');
    final AppVideoSubtitleTarget musicTarget = await targets().forTrack('a');
    // 两个目标都先解析好再起任务：替身识别器是瞬时的，中间再 await 任务可能已结束。
    final AppVideoSubtitleJob music = svc.start(
      musicTarget,
      const AppVideoSubtitleOptions(),
    );
    expect(
      () => svc.start(videoTarget, const AppVideoSubtitleOptions()),
      throwsA(
        isA<AppVideoSubtitleStartRefused>().having(
          (AppVideoSubtitleStartRefused e) => e.problem,
          'problem',
          AppVideoSubtitleStartProblem.busy,
        ),
      ),
    );
    await music.done;
  });
}
