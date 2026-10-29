import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/music/lyrics/lrclib_client.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_live.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_session.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi/src/media/music/music_study_tracker.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_page.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/popup_mining_target_overrides.dart';
import '../helpers/test_platform_services.dart';

/// 歌词页（音乐 P1，设计 §6 / §12）的 widget 测试：真 `MusicPlayerEngine`（替身输出后端）、
/// 真 `MusicLyricsService`（内存库 + 临时目录 sidecar，解析走真 Rust 库）、真弹窗宿主。
class _Backend implements MusicOutputBackend {
  final StreamController<MusicBackendEvent> controller =
      StreamController<MusicBackendEvent>.broadcast(sync: true);
  final List<String> log = <String>[];

  @override
  Stream<MusicBackendEvent> get events => controller.stream;

  @override
  Future<void> applySettings(MusicOutputSettings settings) async {}

  @override
  Future<void> openPair(
    MusicPlayItem current,
    MusicPlayItem? next, {
    required bool play,
    bool crossfadeNext = false,
  }) async => log.add('open:${current.trackUid}');

  @override
  Future<void> replaceNext(
    MusicPlayItem? next, {
    bool crossfadeNext = false,
  }) async {}

  @override
  Future<void> play() async => log.add('play');

  @override
  Future<void> pause() async => log.add('pause');

  @override
  Future<void> seek(Duration position) async =>
      log.add('seek:${position.inMilliseconds}');

  @override
  Future<void> setAbLoop(Duration? a, Duration? b) async =>
      log.add('ab:${a?.inMilliseconds}-${b?.inMilliseconds}');

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() => controller.close();

  @override
  Future<MusicSignalPathSnapshot?> readSignalPath() async => null;

  @override
  Future<List<MusicAudioDevice>> listAudioDevices() async =>
      const <MusicAudioDevice>[];
}

class _NoDesktop implements MusicDesktopLyricsSurface {
  @override
  bool get isSupported => false;

  @override
  Future<bool> show() async => false;

  @override
  Future<void> hide() async {}

  @override
  Future<void> showBlock(
    String text,
    int currentStart,
    int currentLength,
  ) async {}

  @override
  Future<void> highlight(int start, int length) async {}

  @override
  Future<void> setPlaying(bool playing) async {}
}

class _RecordingAnki extends FakeAnkiRepository {
  final List<AnkiMiningContext> mined = <AnkiMiningContext>[];

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    mined.add(context);
    return const MineOutcome.success(noteId: 77);
  }
}

class _LyricsAppModel extends AppModel {
  _LyricsAppModel({
    required this.db,
    required this.backend,
    required PreferencesRepository prefs,
    required Directory dir,
  }) : super(testPlatformServices()) {
    wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: dir);
    wireDatabaseForTesting(db);
  }

  final FushiDatabase db;
  final _Backend backend;
  final List<String> searches = <String>[];

  late final MusicPlayerEngine _engine = MusicPlayerEngine(
    backendFactory: () => backend,
  );

  late final MusicSession _session = MusicSession(
    engine: _engine,
    audio: audioCtrl,
    audiobook: audiobookSession,
    database: () => db,
    showMediaNotification: () => false,
  );

  late final MusicLyricsService _lyrics = MusicLyricsService(
    database: () => db,
    lrclib: LrclibClient(transport: (Uri _) async => (status: 404, body: '')),
    onlineEnabled: () => false,
    readEmbedded: (String _, int? _) async => const <EmbeddedLyrics>[],
    parse: (Uint8List b, String h, int? d) async =>
        FushiLyrics.parse(b, hint: h, durationMs: d),
  );

  late final MusicLyricsLive _live = MusicLyricsLive(
    engine: _engine,
    service: _lyrics,
    desktop: _NoDesktop(),
    desktopEnabled: () => false,
    mediaSessionEnabled: () => false,
    sessionOwnerChanged: audioCtrl.sessionOwner,
    musicOwnsSession: () => true,
  );

  int learningActions = 0;

  late final MusicStudyTracker _study = _CountingTracker(this);

  @override
  MusicSession get musicSession => _session;

  @override
  MusicLyricsService get musicLyrics => _lyrics;

  @override
  MusicLyricsLive get musicLyricsLive => _live;

  @override
  MusicStudyTracker get musicStudy => _study;

  @override
  bool get musicLyricsLookupPause => true;

  @override
  bool get popupBottomDocked => false;

  @override
  double get appUiScale => 1.0;

  @override
  List<String> get enabledAudioSources => const <String>[];

  @override
  void addToDictionaryHistory({required DictionarySearchResult result}) {}

  @override
  Future<DictionarySearchResult> searchDictionary({
    required String searchTerm,
    required bool searchWithWildcards,
    int? overrideMaximumTerms,
    bool useCache = true,
    bool allowRemoteLookup = true,
  }) async {
    searches.add(searchTerm);
    return DictionarySearchResult(searchTerm: searchTerm);
  }
}

class _CountingTracker extends MusicStudyTracker {
  _CountingTracker(this.app)
    : super(
        engine: app._engine,
        database: () => null,
        listeningCountsAsStudy: () => false,
        idleTimeout: () => const Duration(minutes: 10),
      );

  final _LyricsAppModel app;

  @override
  void noteLearningAction() {
    app.learningActions++;
    super.noteLearningAction();
  }
}

void main() {
  final MusicLyricsClipExtractor ffmpegClip = musicLyricsClipExtractor;
  late FushiDatabase db;
  late Directory dir;
  late _Backend backend;
  late _LyricsAppModel app;
  late _RecordingAnki anki;

  MusicPlayItem item() => MusicPlayItem(
    trackUid: 'uid-1',
    path: '${dir.path}${Platform.pathSeparator}song.flac',
    title: 'Night Run',
    artist: 'YOASOBI',
    durationMs: 60000,
  );

  Future<void> pumpPage(WidgetTester tester) async {
    LocaleSettings.setLocale(AppLocale.en);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((Ref ref) => app),
          ...popupMiningTargetTestOverrides(),
          ankiRepositoryProvider.overrideWith((Ref ref) => anki),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(useMaterial3: true),
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: const MusicLyricsPage(),
          ),
        ),
      ),
    );
    // sidecar 读文件 / 解析是真 IO：在真异步区里等它落地，再推帧。
    for (int i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    dir = Directory.systemTemp.createTempSync('fushi_lyrics_page_');
    File(
      '${dir.path}${Platform.pathSeparator}song.flac',
    ).writeAsBytesSync(<int>[0]);
    File(
      '${dir.path}${Platform.pathSeparator}song.lrc',
    ).writeAsStringSync('[00:01.00]夜に駆ける\n[00:04.00]沈むように\n[00:08.00]溶けていく\n');
    backend = _Backend();
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    app = _LyricsAppModel(db: db, backend: backend, prefs: prefs, dir: dir);
    anki = _RecordingAnki();
    await app.musicSession.engine.playQueue(<MusicPlayItem>[item()]);
    // 暂停态：歌词视图不挂逐帧 Ticker，pumpAndSettle 能停下来。
    await app.musicSession.engine.pause();
  });

  tearDown(() async {
    musicLyricsClipExtractor = ffmpegClip;
    await db.close();
    dir.deleteSync(recursive: true);
  });

  testWidgets('sidecar 歌词渲染成逐行（语义标签）；整首偏移实时生效并落库', (WidgetTester tester) async {
    await pumpPage(tester);
    expect(find.bySemanticsLabel('夜に駆ける'), findsOneWidget);
    expect(find.bySemanticsLabel('沈むように'), findsOneWidget);
    expect(find.text(t.music_lyrics_offset_value(ms: 0)), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('music_lyrics_offset_later')),
    );
    await tester.pump();
    expect(find.text(t.music_lyrics_offset_value(ms: 100)), findsOneWidget);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    final MusicLyricRow row =
        await tester.runAsync(
              () =>
                  (db.select(db.musicLyrics)..where(
                        ($MusicLyricsTable r) => r.source.equals('sidecar'),
                      ))
                      .getSingle(),
            )
            as MusicLyricRow;
    expect(row.offsetMs, 100);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('宽屏歌词页有返回键（窄屏顶栏有关闭键，宽屏原本没有退出口）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1424, 951);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpPage(tester);
    expect(
      find.byKey(const ValueKey<String>('music_lyrics_back')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('AB 循环：当前行 → 再加一行 → 关；循环点是曲目时间', (WidgetTester tester) async {
    await pumpPage(tester);
    backend.controller.add(
      const MusicBackendPosition(Duration(milliseconds: 1500), null),
    );
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('music_lyrics_ab_loop')),
    );
    await tester.pump();
    // LRC 行级：第一行 [1 s, 4 s)（终点取下一行起点）。
    expect(backend.log, contains('ab:1000-4000'));
    expect(app.musicSession.engine.abLoop?.b, const Duration(seconds: 4));
    expect(app.learningActions, 1, reason: 'AB 循环算学习动作（D4）');

    await tester.pump(const Duration(milliseconds: 300));
    // 宽屏左栏（封面 + 标题 + 进度 + 按钮组 + 工具行）在 800×600 下超过一屏、本身可滚动；
    // 「再加一行」开 AB 后才出现在工具行里，先滚到可见再点（与用户操作一致）。
    final Finder extend = find.byKey(
      const ValueKey<String>('music_lyrics_ab_loop_extend'),
    );
    await tester.ensureVisible(extend);
    await tester.pump();
    await tester.tap(extend);
    await tester.pump();
    expect(backend.log, contains('ab:1000-8000'));

    await tester.tap(
      find.byKey(const ValueKey<String>('music_lyrics_ab_loop')),
    );
    await tester.pump();
    expect(backend.log.last, 'ab:null-null');
    expect(app.musicSession.engine.abLoop, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('长按查词：查行内起点文本、按设置暂停；制卡带音乐出处与行时间窗', (WidgetTester tester) async {
    final List<({String input, int startMs, int endMs})> clips =
        <({String input, int startMs, int endMs})>[];
    musicLyricsClipExtractor =
        ({
          required String inputPath,
          required int startMs,
          required int endMs,
          required String outputPath,
          required int audioChannels,
          required String audioBitrate,
          required void Function(String summary) onFailure,
        }) async {
          clips.add((input: inputPath, startMs: startMs, endMs: endMs));
          File(outputPath).writeAsBytesSync(<int>[1, 2, 3]);
          return outputPath;
        };
    await pumpPage(tester);
    await app.musicSession.engine.play();
    backend.controller.add(
      const MusicBackendPosition(Duration(milliseconds: 4200), null),
    );
    await tester.pump();

    backend.log.clear(); // setUp 里那次暂停不算
    // 长按落在行首第一个字上（行是整宽的，中心点可能落在字外）。
    final Rect row = tester.getRect(find.bySemanticsLabel('沈むように'));
    await tester.longPressAt(row.centerLeft + const Offset(14, 0));
    await tester.pump();
    expect(app.searches, isNotEmpty);
    expect(app.searches.first, startsWith('沈'));
    expect(backend.log, contains('pause'), reason: '查词时自动暂停');
    expect(app.learningActions, 1);

    final State<StatefulWidget> state = tester.state(
      find.byType(MusicLyricsPage),
    );
    await tester.runAsync(
      () =>
          (state as dynamic).onMineFromPopup(<String, String>{
                'expression': '沈む',
                'reading': 'しずむ',
                'glossary': 'sink',
              })
              as Future<Object?>,
    );
    expect(clips.single.startMs, 3500, reason: '行 [4 s, 8 s) 前后各扩 0.5 s');
    expect(clips.single.endMs, 8500);
    final AnkiMiningContext ctx = anki.mined.single;
    expect(ctx.sentence, '沈むように');
    expect(ctx.sentenceAudioPath, isNotNull);
    expect(ctx.clipStartMs, 4000);
    expect(ctx.clipEndMs, 8000);
    expect(ctx.sourceLink?.toUri().toString(), contains('kind=music'));

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    final List<MinedSentenceRow> mined =
        await tester.runAsync(() => db.select(db.minedSentences).get())
            as List<MinedSentenceRow>;
    expect(mined.single.source, 'music');
    expect(mined.single.bookKey, 'uid-1');
    expect(mined.single.positionMs, 4000);
    expect(mined.single.durationMs, 4000);
    expect(mined.single.sentence, '沈むように');
    expect(mined.single.noteId, 77);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
