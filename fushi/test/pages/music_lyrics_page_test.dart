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
import 'package:fushi/src/media/music/lyrics/lrclib_client.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_live.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_session.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi/src/media/music/music_study_tracker.dart';
import 'package:fushi/src/media/playback_route_marks.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_page.dart';
import 'package:fushi/src/pages/implementations/music/music_queue_panel.dart';
import 'package:fushi/src/pages/implementations/music/music_subtitle_actions.dart';
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
    hasSystemMediaSession: platformServices.hasSystemMediaSession,
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

  testWidgets('宽屏：右侧常驻队列侧栏默认展开，功能行「队列」按钮收起 / 展开', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1424, 951);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpPage(tester);
    final Finder sidebar = find.byKey(
      const ValueKey<String>('music_lyrics_queue_sidebar'),
    );
    expect(sidebar, findsOneWidget);
    expect(tester.getSize(sidebar).width, kMusicQueueSidebarWidth);
    expect(find.byType(MusicQueuePanel), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('music_lyrics_queue')));
    await settle(tester, rounds: 30);
    expect(tester.getSize(sidebar).width, 0);

    await tester.tap(find.byKey(const ValueKey<String>('music_lyrics_queue')));
    await settle(tester, rounds: 30);
    expect(tester.getSize(sidebar).width, kMusicQueueSidebarWidth);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('窄屏：功能行「队列」按钮弹出队列（不挂侧栏）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpPage(tester);
    expect(
      find.byKey(const ValueKey<String>('music_lyrics_queue_sidebar')),
      findsNothing,
    );
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

    await tester.pumpWidget(const SizedBox.shrink());
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
