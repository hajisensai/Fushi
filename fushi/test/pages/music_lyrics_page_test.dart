import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show GestureSettings;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kMiddleMouseButton;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_lyrics_view.dart';
import 'package:fushi/src/media/music/lyrics/lrclib_client.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_live.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi/src/media/music/music_disc_art.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_session.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi/src/media/music/music_study_tracker.dart';
import 'package:fushi/src/media/playback_route_marks.dart';
import 'package:fushi/src/media/range_playback.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show MinePopupResult;
import 'package:fushi/src/pages/implementations/music/music_lyrics_page.dart';
import 'package:fushi/src/pages/implementations/music/music_queue_panel.dart';
import 'package:fushi/src/pages/implementations/music/music_subtitle_actions.dart';
import 'package:fushi/src/second_screen/companion/companion_context.dart';
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
    Duration startAt = Duration.zero,
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

  /// 覆写（点 ✓ 选「覆盖这张」）收到的 (noteId, 上下文)。
  final List<({int noteId, AnkiMiningContext context})> updated =
      <({int noteId, AnkiMiningContext context})>[];

  @override
  Future<MineOutcome> updateMinedNote({
    required int noteId,
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    updated.add((noteId: noteId, context: context));
    return MineOutcome.success(noteId: noteId);
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
    // 同正式 initialise：偏好变了经 AppModel 转发，watch appProvider 的页面跟着重建。
    prefs.addListener(notifyListeners);
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
    hasSystemMediaSession: platformServices.hasSystemMediaSession,
    audiobook: audiobookSession,
    database: () => db,
    showMediaNotification: () => false,
  );

  /// 歌词页发出的 LRCLIB 请求（在线自动解析是关的，只有用户主动搜索会发）。
  final List<Uri> lrclibCalls = <Uri>[];

  /// 非 null 时 LRCLIB 请求挂在这里直到 complete（测搜索进行中的界面）。
  Completer<void>? lrclibGate;

  late final MusicLyricsService _lyrics = MusicLyricsService(
    database: () => db,
    lrclib: LrclibClient(
      transport: (Uri uri) async {
        lrclibCalls.add(uri);
        await lrclibGate?.future;
        return uri.path == '/api/search'
            ? (status: 200, body: '[]')
            : (status: 404, body: '');
      },
    ),
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
    desktopSpan: () => (before: 0, after: 1),
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

  /// 「查词时暂停」设置（用例可关）。
  bool lookupPause = true;

  @override
  bool get musicLyricsLookupPause => lookupPause;

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
    // sidecar 读文件 / 解析、后台 isolate 找 .cdg 都是真 IO：交替让真异步区跑一拍、推一帧，
    // 至少 10 拍，且推到页面报告这首的歌词已落地为止——不按真实时长猜（原先固定 10 × 20 ms，
    // 满载的慢 worker 上歌词还没出来，后面按语义标签找行就扑空）。
    final State<StatefulWidget> state = tester.state(
      find.byType(MusicLyricsPage),
    );
    bool settled() => (state as dynamic).lyricsLoadSettled as bool;
    for (int i = 0; i < 10 || !settled(); i++) {
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
    app.shortcutRegistry.loadDefaults(TargetPlatform.windows);
    anki = _RecordingAnki();
    await app.musicSession.engine.playQueue(<MusicPlayItem>[item()]);
    // 暂停态：歌词视图不挂逐帧 Ticker，pumpAndSettle 能停下来。
    await app.musicSession.engine.pause();
  });

  // 系统媒体会话判据来自平台服务（假服务 = 没有）：setUp 里已经放过一首，也不该去起
  // audio_service——macOS 宿主上它会连带调 path_provider、在测试绑定里抛
  // MissingPluginException。宿主平台无关：判据只看注入的平台服务。
  test(
    'playing music under fake platform services never starts audio_service',
    () {
      expect(app.platformServices.hasSystemMediaSession, isFalse);
      expect(app.audioCtrl.audioHandler, isNull);
    },
  );

  final bool Function() asrGate = musicSubtitleAsrSupported;

  Future<void> settle(WidgetTester tester, {int rounds = 10}) async {
    for (int i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  tearDown(() async {
    musicSubtitleAsrSupported = asrGate;
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

  // 拍板台 left3645（方案 B）：QRC 自带注音轨和正文对不上时整首不挂，歌词页说一句「已隐藏」；
  // 对得上的不提示。
  const String qrcBody =
      '[1000,2000]夜(1000,500)に(1500,500)駆(2000,500)け(2500,500)';
  const ValueKey<String> rubyDroppedNotice = ValueKey<String>(
    'music_lyrics_ruby_dropped_notice',
  );
  void useQrcSidecar(String kana) {
    final String sep = Platform.pathSeparator;
    File('${dir.path}${sep}song.lrc').deleteSync();
    File('${dir.path}${sep}song.qrc').writeAsStringSync('$kana\n$qrcBody\n');
  }

  testWidgets('QRC 注音轨对不上：歌词照常显示，并提示注音已隐藏', (WidgetTester tester) async {
    useQrcSidecar('[kana:1よる]');
    await pumpPage(tester);
    expect(find.bySemanticsLabel(RegExp('夜に駆け')), findsWidgets);
    expect(find.byKey(rubyDroppedNotice), findsOneWidget);
    expect(find.text(t.music_lyrics_ruby_dropped_notice), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('QRC 注音轨对得上：不提示注音已隐藏', (WidgetTester tester) async {
    useQrcSidecar('[kana:1よる1か]');
    await pumpPage(tester);
    expect(find.bySemanticsLabel(RegExp('夜に駆け')), findsWidgets);
    expect(find.byKey(rubyDroppedNotice), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // GitHub #3354：设置 › 音乐 › 「模糊非当前行」接到歌词视图，改了即时生效。
  testWidgets('「模糊非当前行」偏好接到歌词视图并即时生效', (WidgetTester tester) async {
    bool viewBlurs() => tester
        .widget<KaraokeLyricsView>(find.byType(KaraokeLyricsView))
        .appearance
        .blurInactive;

    await pumpPage(tester);
    expect(viewBlurs(), isTrue, reason: '默认开（保持原观感）');

    await tester.runAsync(() => app.setMusicLyricsBlurInactive(false));
    await tester.pump();
    expect(viewBlurs(), isFalse);
    expect(app.prefsRepo.musicLyricsBlurInactive, isFalse);

    await tester.runAsync(() => app.setMusicLyricsBlurInactive(true));
    await tester.pump();
    expect(viewBlurs(), isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  // BUG-4084 追加（用户 2026-11-05）：音乐播放页也是「播放页」，盖住浏览器时浏览页要让
  // 网页停下。
  testWidgets('音乐播放页把自己的路由登记成播放页，关掉即撤登记', (WidgetTester tester) async {
    await pumpPage(tester);
    final Route<dynamic> route = ModalRoute.of(
      tester.element(find.byType(MusicLyricsPage)),
    )!;
    expect(playbackRouteMarks.isPlayback(route), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(playbackRouteMarks.isPlayback(route), isFalse);
  });

  testWidgets('唱片模式：专辑有盘面扫描图就转真盘面，没有才画黑胶 + 封面贴标', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1424, 951);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await app.prefsRepo.setMusicLyricsLayout(MusicLyricsLayout.disc.prefValue);
    final String disc = '${dir.path}${Platform.pathSeparator}disc.png';
    File(disc).writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
      ),
    );
    addTearDown(
      () => MusicDiscArtIndex.instance.publish(const <String, String>{}),
    );
    MusicDiscArtIndex.instance.publish(<String, String>{'al-1': disc});
    await app.musicSession.engine.playQueue(<MusicPlayItem>[
      MusicPlayItem(
        trackUid: 'uid-1',
        path: '${dir.path}${Platform.pathSeparator}song.flac',
        title: 'Night Run',
        albumUid: 'al-1',
        durationMs: 60000,
      ),
    ]);
    await app.musicSession.engine.pause();
    await pumpPage(tester);
    const ValueKey<String> realDisc = ValueKey<String>(
      'music-player-real-disc',
    );
    expect(find.byKey(realDisc), findsOneWidget);
    // 中心轴孔挖空（扫描图孔里的底板白不再露出来）。
    final ClipPath hole = tester.widget<ClipPath>(
      find
          .descendant(of: find.byKey(realDisc), matching: find.byType(ClipPath))
          .first,
    );
    final Path clip = hole.clipper!.getClip(const Size(400, 400));
    expect(clip.contains(const Offset(200, 200)), isFalse);
    expect(clip.contains(const Offset(200, 20)), isTrue);

    // 盘面图映射里没有这张专辑：回退黑胶。
    MusicDiscArtIndex.instance.publish(const <String, String>{});
    await tester.pump();
    expect(find.byKey(realDisc), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('分栏布局：唱片压在封面上（有盘面扫描图转真盘面，没有转银色 CD）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1424, 951);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await app.prefsRepo.setMusicLyricsLayout(MusicLyricsLayout.split.prefValue);
    final String disc = '${dir.path}${Platform.pathSeparator}disc.png';
    File(disc).writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
      ),
    );
    addTearDown(
      () => MusicDiscArtIndex.instance.publish(const <String, String>{}),
    );
    MusicDiscArtIndex.instance.publish(<String, String>{'al-1': disc});
    await app.musicSession.engine.playQueue(<MusicPlayItem>[
      MusicPlayItem(
        trackUid: 'uid-1',
        path: '${dir.path}${Platform.pathSeparator}song.flac',
        title: 'Night Run',
        albumUid: 'al-1',
        durationMs: 60000,
      ),
    ]);
    await app.musicSession.engine.pause();
    await pumpPage(tester);
    const ValueKey<String> sleeve = ValueKey<String>(
      'music-player-sleeve-disc',
    );
    expect(find.byKey(sleeve), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(sleeve),
        matching: find.byKey(const ValueKey<String>('music-player-real-disc')),
      ),
      findsOneWidget,
    );

    // 没有盘面扫描图：转银色 CD 盘，不是黑胶。
    MusicDiscArtIndex.instance.publish(const <String, String>{});
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(sleeve),
        matching: find.byKey(const ValueKey<String>('music-player-silver-cd')),
      ),
      findsOneWidget,
    );
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

  testWidgets('宽屏：「队列」图标打开右下角浮层卡片（不挤压播放页），点外面收起', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1424, 951);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpPage(tester);
    expect(find.byType(MusicQueuePanel), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('music_lyrics_queue')));
    await settle(tester, rounds: 30);
    final Finder card = find.byKey(
      const ValueKey<String>('music_queue_floating'),
    );
    expect(card, findsOneWidget);
    expect(tester.getSize(card).width, kMusicQueuePanelWidth);
    // 停在右下角：卡片右边缘贴近窗口右侧，且在下半屏。
    final Rect r = tester.getRect(card);
    expect(r.right, greaterThan(1424 - 80));
    expect(r.bottom, greaterThan(951 / 2));

    await tester.tapAt(const Offset(40, 40));
    await settle(tester, rounds: 30);
    expect(find.byType(MusicQueuePanel), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('窄屏：「队列」图标弹出底部弹层', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpPage(tester);
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('music_lyrics_queue')),
    );
    await tester.tap(find.byKey(const ValueKey<String>('music_lyrics_queue')));
    await settle(tester, rounds: 30);
    expect(find.byType(MusicQueuePanel), findsOneWidget);
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

  testWidgets('与有声书同一套交互：空格播放暂停、点字外 / 中键跳到该行、点字查词', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester);
    backend.log.clear(); // setUp 里那次暂停不算

    // 空格 = 播放 / 暂停（打开歌词页即可收键，不用先点哪里）。
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(backend.log, <String>['play']);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(backend.log, <String>['play', 'pause']);
    backend.log.clear();

    final Rect row = tester.getRect(find.bySemanticsLabel('沈むように'));
    // 点在行内、字形之外（行是整宽的，右端是空白）= 跳到这一行，不查词。
    await tester.tapAt(row.centerRight - const Offset(4, 0));
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      backend.log.where((String l) => l.startsWith('seek:')),
      hasLength(1),
    );
    expect(app.searches, isEmpty, reason: '字外不查词');

    // 中键点在字上 = 跳转（与有声书「点句跳转」同一个绑定），不查词。
    backend.log.clear();
    await tester.tapAt(
      row.centerLeft + const Offset(14, 0),
      buttons: kMiddleMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      backend.log.where((String l) => l.startsWith('seek:')),
      hasLength(1),
    );
    expect(app.searches, isEmpty, reason: '中键不查词');

    // 左键点在字上 = 查词（从点中的字起查）。
    backend.log.clear();
    await tester.tapAt(row.centerLeft + const Offset(14, 0));
    await tester.pump(const Duration(milliseconds: 500));
    expect(app.searches, isNotEmpty);
    expect(app.searches.first, startsWith('沈'));
    expect(
      backend.log.where((String l) => l.startsWith('seek:')),
      isEmpty,
      reason: '点字查词不跳转',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('长按查词：查行内起点文本、按设置暂停；制卡带音乐出处与行时间窗', (WidgetTester tester) async {
    final List<({String input, int startMs, int endMs})> clips =
        <({String input, int startMs, int endMs})>[];
    musicLyricsClipExtractor =
        ({
          required String inputPath,
          required Map<String, String> httpHeaders,
          required int startMs,
          required int endMs,
          required String outputPath,
          required int audioChannels,
          required String audioBitrate,
          required void Function(String summary) onFailure,
        }) async {
          clips.add((input: inputPath, startMs: startMs, endMs: endMs));
          expect(httpHeaders, isEmpty, reason: '本机文件不带请求头');
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
    expect(clips.single.input, item().path, reason: '本机文件原样交给 ffmpeg');
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

    // BUG-4933：点 ✓ 选「覆盖这张」真的按 id 覆写那张卡（此前落到基类空实现，静默
    // 不写），上下文与新制同一口径（句子 / 句子音频 / 出处）；覆写不新建卡、不进制卡历史。
    final Object? overwrite = await tester.runAsync<Object?>(
      () =>
          (state as dynamic).onUpdateFromPopup(41, <String, String>{
                'expression': '沈む',
                'reading': 'しずむ',
                'glossary': 'sink',
              })
              as Future<Object?>,
    );
    final MinePopupResult overwriteResult = overwrite! as MinePopupResult;
    expect(overwriteResult.ankiConnect, isTrue);
    expect(overwriteResult.noteId, 41);
    expect(anki.mined, hasLength(1), reason: '覆写不走 mineEntry 新建卡');
    final ({int noteId, AnkiMiningContext context}) update =
        anki.updated.single;
    expect(update.noteId, 41);
    expect(update.context.sentence, '沈むように');
    expect(update.context.sentenceAudioPath, isNotNull);
    expect(
      update.context.sourceLink?.toUri().toString(),
      contains('kind=music'),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    final List<MinedSentenceRow> afterOverwrite =
        await tester.runAsync(() => db.select(db.minedSentences).get())
            as List<MinedSentenceRow>;
    expect(afterOverwrite, hasLength(1), reason: '覆写不计入制卡历史');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  // 反馈 l8XrV_IfXH：音乐高级制卡能选前后文行，句子与音频片段跟着合并；起止微调与
  // 试听经同一个区间，关窗把播放头放回查词位置。
  testWidgets('高级制卡：前后文行合成句子与合并区间，微调进片段，试听后放回播放头', (WidgetTester tester) async {
    File('${dir.path}${Platform.pathSeparator}song.lrc').writeAsStringSync(
      '[00:01.00]夜に駆ける\n[00:04.00]沈むように\n[00:08.00]溶けていく\n[00:12.00]月の光\n',
    );
    final List<({int startMs, int endMs})> clips =
        <({int startMs, int endMs})>[];
    musicLyricsClipExtractor =
        ({
          required String inputPath,
          required Map<String, String> httpHeaders,
          required int startMs,
          required int endMs,
          required String outputPath,
          required int audioChannels,
          required String audioBitrate,
          required void Function(String summary) onFailure,
        }) async {
          clips.add((startMs: startMs, endMs: endMs));
          File(outputPath).writeAsBytesSync(<int>[1, 2, 3]);
          return outputPath;
        };
    await pumpPage(tester);
    backend.controller.add(
      const MusicBackendPosition(Duration(milliseconds: 4200), null),
    );
    await tester.pump();
    final Rect row = tester.getRect(find.bySemanticsLabel('沈むように'));
    await tester.longPressAt(row.centerLeft + const Offset(14, 0));
    await tester.pump();

    final dynamic state = tester.state(find.byType(MusicLyricsPage));
    final AdvancedMiningSections sections =
        await tester.runAsync(
              () =>
                  state.buildAdvancedMiningSections(matched: '沈む')
                      as Future<AdvancedMiningSections>,
            )
            as AdvancedMiningSections;
    final AdvancedMiningSentenceSection sentence = sections.sentence!;
    final AdvancedMiningAudioSection audio = sections.audio!;

    // 单行：区间就是这一行（前后各扩 0.5 s）。
    AdvancedMiningAudioWindow? window = await tester
        .runAsync<AdvancedMiningAudioWindow?>(() => audio.describe(0, 0));
    expect((window!.startMs, window.endMs), (3500, 8500));

    // 上 1 行 + 下 1 行。
    expect(await tester.runAsync(() => sentence.setContext(1, 1)), 2);
    final Map<String, Object?> preview = (await tester.runAsync(
      sentence.fetchPreview,
    ))!;
    expect(preview['prev'], <String>['夜に駆ける']);
    expect(preview['current'], '沈むように');
    expect(preview['next'], <String>['溶けていく']);
    // 合并 [1 s, 12 s) → 留白 [0.5 s, 12.5 s) → 微调 [0.3 s, 12.8 s)。
    window = await tester.runAsync(() => audio.describe(-200, 300));
    expect((window!.startMs, window.endMs), (300, 12800));

    // 试听与写卡同一段；关窗停试听、播放头回到查词时的位置（打开时没在播：保持暂停）。
    backend.log.clear();
    final RangePlayback? playback = await tester.runAsync<RangePlayback?>(
      () => audio.preview(-200, 300),
    );
    expect(playback, isNotNull);
    expect(backend.log, <String>['seek:300', 'play']);
    await tester.runAsync(() => sections.onClosed!());
    // ended 的 Completer 是在 runAsync（真实 zone）里建的，在 fake-async 测试体里
    // 直接 await 它，回调永远排不上队（实测卡满 10 分钟超时）；同样包进 runAsync。
    expect(
      await tester.runAsync(() => playback!.ended),
      RangePlaybackEnd.interrupted,
    );
    expect(backend.log, <String>['seek:300', 'play', 'pause', 'seek:4200']);

    // 确认制卡：覆盖项里的起止微调进片段，句子按「上 → 本行 → 下」合成。
    await tester.runAsync(
      () =>
          state.onMineFromPopup(
                MiningRequestOverrides.attach(
                  <String, String>{
                    'expression': '沈む',
                    'reading': 'しずむ',
                    'glossary': 'sink',
                  },
                  const MiningRequestOverrides(
                    audioStartDeltaMs: -200,
                    audioEndDeltaMs: 300,
                  ),
                ),
              )
              as Future<Object?>,
    );
    expect(clips.single, (startMs: 300, endMs: 12800));
    final AnkiMiningContext ctx = anki.mined.single;
    expect(ctx.sentence, '夜に駆ける\n沈むように\n溶けていく');
    expect(ctx.sentenceAudioPath, isNotNull);
    expect((ctx.clipStartMs, ctx.clipEndMs), (1000, 12000));

    // 制卡成功后前后文清空：下一次「+」回到单行；「不要音频」不截片段。
    await tester.runAsync(
      () =>
          state.onMineFromPopup(
                MiningRequestOverrides.attach(<String, String>{
                  'expression': '沈む',
                }, const MiningRequestOverrides(omitAudio: true)),
              )
              as Future<Object?>,
    );
    expect(clips, hasLength(1), reason: '不要音频：不截片段');
    expect(anki.mined.last.sentence, '沈むように');
    expect(anki.mined.last.sentenceAudioPath, isNull);

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // 双屏副屏：查词显示在副屏「查词」页时，「查词时暂停」仍按设置生效（与页内弹窗同一入口），
  // 副屏关掉查词时续播；副屏随屏幕 / 顶屏 stop 消失时只撤标记、不自己播起来。
  group('pause on lookup with the dual-screen companion', () {
    late List<String> routed;

    setUp(() {
      routed = <String>[];
      companionContexts
        ..setLookupsOnCompanion(true)
        ..bindLookupSink(({
          required String text,
          int charIndex = -1,
          String? sentence,
        }) async {
          routed.add(text);
          return true;
        })
        ..setActive(true);
    });

    tearDown(() {
      companionContexts
        ..lookupClosed(resume: false)
        ..setActive(false)
        ..bindLookupSink(null)
        ..setLookupsOnCompanion(true);
    });

    Future<void> playAndLongPressLine(WidgetTester tester) async {
      await pumpPage(tester);
      await app.musicSession.engine.play();
      await tester.pump();
      backend.log.clear();
      final Rect row = tester.getRect(find.bySemanticsLabel('沈むように'));
      await tester.longPressAt(row.centerLeft + const Offset(14, 0));
      await tester.pump();
    }

    testWidgets('setting on: a routed lookup pauses, closing it on the '
        'companion resumes', (WidgetTester tester) async {
      await playAndLongPressLine(tester);
      expect(routed, <String>['沈むように']);
      expect(app.searches, isEmpty, reason: '副屏接手，本页不弹窗');
      expect(backend.log, <String>['pause']);
      // The panel reports the lookup open (repeats the pause: idempotent).
      companionContexts.lookupOpened();
      await tester.pump();
      expect(backend.log, <String>['pause']);

      companionContexts.lookupClosed(resume: true);
      await tester.pump();
      expect(backend.log, <String>['pause', 'play']);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('setting off: a routed lookup neither pauses nor resumes', (
      WidgetTester tester,
    ) async {
      app.lookupPause = false;
      await playAndLongPressLine(tester);
      expect(routed, hasLength(1));
      companionContexts.lookupClosed(resume: true);
      await tester.pump();
      expect(backend.log, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a lookup started on the panel (its lyrics) pauses too; the '
        'companion going away keeps it paused', (WidgetTester tester) async {
      await pumpPage(tester);
      await app.musicSession.engine.play();
      await tester.pump();
      backend.log.clear();
      companionContexts.lookupOpened();
      await tester.pump();
      expect(backend.log, <String>['pause']);
      companionContexts.lookupClosed(resume: false);
      await tester.pump();
      expect(backend.log, <String>['pause'], reason: '无人操作时不自己播起来');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('"Lookups open on: Top screen": the in-page popup path pauses '
        'as before', (WidgetTester tester) async {
      companionContexts.setLookupsOnCompanion(false);
      await playAndLongPressLine(tester);
      expect(routed, isEmpty);
      expect(app.searches, isNotEmpty);
      expect(backend.log, <String>['pause']);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  // 音乐库生成字幕（Feedback QAondMh4M5）：没歌词的本机曲目就地给「生成日语字幕」，入口按
  // 本机转录能力（isAsrSupported）门控——不支持的平台不出入口，而不是点了才报错。
  // 每个用例只挂一次页面：ProviderScope 卸载会 dispose AppModel，同一用例里再挂会用到已
  // dispose 的模型。
  for (final bool supported in <bool>[false, true]) {
    testWidgets('没歌词：本机${supported ? '能' : '不能'}转录时'
        '${supported ? '出' : '不出'}「生成日语字幕」入口', (WidgetTester tester) async {
      File('${dir.path}${Platform.pathSeparator}song.lrc').deleteSync();
      musicSubtitleAsrSupported = () => supported;
      await pumpPage(tester);
      expect(
        find.byKey(const ValueKey<String>('music_lyrics_find')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('music_lyrics_generate')),
        supported ? findsOneWidget : findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('生成字幕写进当前这首：打开着的歌词页立即重载显示', (WidgetTester tester) async {
    File('${dir.path}${Platform.pathSeparator}song.lrc').deleteSync();
    await pumpPage(tester);
    expect(find.bySemanticsLabel('ドラマの台詞'), findsNothing);

    final Uint8List srt = Uint8List.fromList(
      utf8.encode('1\n00:00:02,000 --> 00:00:04,000\nドラマの台詞\n'),
    );
    await tester.runAsync(
      () async => app.musicLyrics.saveGenerated(
        'uid-1',
        format: 'srt',
        raw: srt,
        timeline: FushiLyrics.parse(srt, hint: 'srt'),
      ),
    );
    await settle(tester);
    expect(find.bySemanticsLabel('ドラマの台詞'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // 拍板台 D48CgzHUok：「搜索在线歌词」先弹关键词框（默认填曲目元数据），按用户改过的
  // 标题 / 艺人去搜。
  testWidgets('搜索在线歌词：关键词框默认填曲目元数据，按改过的关键词搜', (WidgetTester tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey<String>('music_lyrics_more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.music_lyrics_search_online));
    await tester.pumpAndSettle();
    Finder field(int i) => find.descendant(
      of: find.byKey(ValueKey<String>('fushi_form_field_$i')),
      matching: find.byType(EditableText),
    );
    expect(tester.widget<EditableText>(field(0)).controller.text, 'Night Run');
    expect(tester.widget<EditableText>(field(1)).controller.text, 'YOASOBI');
    expect(app.lrclibCalls, isEmpty, reason: '确认前不搜');
    await tester.enterText(field(0), '夜に駆ける');
    await tester.enterText(field(1), '');
    await tester.tap(find.byKey(const ValueKey<String>('fushi_form_confirm')));
    await settle(tester);
    final Uri search = app.lrclibCalls.single;
    expect(search.path, '/api/search');
    expect(search.queryParameters['track_name'], '夜に駆ける');
    expect(search.queryParameters['artist_name'], isNull);
    expect(find.text(t.music_lyrics_no_candidates), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // 搜索要串行走 LRCLIB + 各歌词插件，可能好几秒：进行中要有进度，且不能再触发第二次搜索
  // （否则用户以为没反应重复点，叠出多个候选框）。
  testWidgets('搜索在线歌词进行中：显示进度，「搜索在线歌词」不能再次触发', (WidgetTester tester) async {
    app.lrclibGate = Completer<void>();
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey<String>('music_lyrics_more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.music_lyrics_search_online));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('fushi_form_confirm')));
    await settle(tester);
    expect(app.lrclibCalls, hasLength(1));
    expect(
      find.byKey(const ValueKey<String>('music_lyrics_online_searching')),
      findsOneWidget,
    );
    expect(find.text(t.music_lyrics_no_candidates), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('music_lyrics_more')));
    await settle(tester);
    await tester.tap(find.text(t.music_lyrics_search_online));
    await settle(tester);
    expect(
      find.byKey(const ValueKey<String>('fushi_form_field_0')),
      findsNothing,
      reason: '搜索进行中再点不弹关键词框',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    app.lrclibGate!.complete();
    await settle(tester);
    expect(app.lrclibCalls, hasLength(1));
    expect(
      find.byKey(const ValueKey<String>('music_lyrics_online_searching')),
      findsNothing,
    );
    expect(find.text(t.music_lyrics_no_candidates), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('曲内搜索：搜到的行点一下跳到那一行的时间', (WidgetTester tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey<String>('music_lyrics_search')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey<String>('music_lyrics_search_field')),
        matching: find.byType(EditableText),
      ),
      '沈む',
    );
    await tester.pump(const Duration(milliseconds: 250));
    await settle(tester);
    final Finder hit = find.byKey(
      const ValueKey<String>('music_lyrics_search_result_0'),
    );
    expect(hit, findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('music_lyrics_search_result_1')),
      findsNothing,
    );
    backend.log.clear();
    await tester.tap(hit);
    await settle(tester, rounds: 3);
    expect(backend.log, contains('seek:4000'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // #358s4Ae_fn（Android 荣耀 369x820@3.25）：「进度条只能拖、点按不跳转」。窄屏播放页
  // 的真实布局 + Android 设备手势参数（系统 touch slop 8dp，比 Flutter 默认 18 小：
  // 横向拖动识别器在手指抖 8dp 时就会赢过点按）下，点按和带抖动的点按都必须提交 seek。
  Future<Rect> pumpPhone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(369 * 3.25, 820 * 3.25);
    tester.view.devicePixelRatio = 3.25;
    tester.view.gestureSettings = const GestureSettings(
      physicalTouchSlop: 8 * 3.25,
    );
    addTearDown(tester.view.reset);
    await pumpPage(tester);
    backend.controller.add(
      const MusicBackendPosition(Duration(seconds: 5), Duration(seconds: 60)),
    );
    await tester.pump();
    final Finder seek = find.byKey(const ValueKey<String>('music_lyrics_seek'));
    expect(seek, findsOneWidget);
    return tester.getRect(
      find.descendant(of: seek, matching: find.byType(GestureDetector)).first,
    );
  }

  List<int> seeks() => <int>[
    for (final String e in backend.log)
      if (e.startsWith('seek:')) int.parse(e.substring(5)),
  ];

  testWidgets('窄屏播放页：点按进度条提交 seek（Android 手势参数）', (WidgetTester tester) async {
    final Rect bar = await pumpPhone(tester);
    await tester.tapAt(bar.center);
    await tester.pump(const Duration(milliseconds: 50));
    expect(seeks(), hasLength(1));
    expect(seeks().single, closeTo(30000, 1500));

    // 长一点的按压（超过 kPressTimeout，onTapDown 先于抬起触发）同样提交。
    final TestGesture press = await tester.startGesture(
      Offset(bar.left + bar.width * 0.75, bar.center.dy),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await press.up();
    await tester.pump(const Duration(milliseconds: 50));
    expect(seeks(), hasLength(2));
    expect(seeks().last, closeTo(45000, 1500));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('窄屏播放页：带手指抖动（越过 8dp 横向 slop）的点按也提交 seek', (
    WidgetTester tester,
  ) async {
    final Rect bar = await pumpPhone(tester);
    final Offset start = Offset(bar.left + bar.width * 0.25, bar.center.dy);
    final TestGesture g = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 16));
    await g.moveBy(const Offset(10, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await g.up();
    await tester.pump(const Duration(milliseconds: 50));
    expect(seeks(), hasLength(1));
    expect(seeks().single, closeTo(15000 + 10 / bar.width * 60000, 1500));

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
