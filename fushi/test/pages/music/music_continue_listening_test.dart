import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_session.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/music/music_library_page.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart' show MusicPluginManager;
import 'package:material_ui/material_ui.dart';

import '../../helpers/popup_mining_target_overrides.dart';
import '../../helpers/test_platform_services.dart';

/// 记下每次整队打开（[openPair]）的假后端：重建队列 = 多一次 openPair。
class _Backend implements MusicOutputBackend {
  final StreamController<MusicBackendEvent> controller =
      StreamController<MusicBackendEvent>.broadcast(sync: true);
  final List<String> opened = <String>[];
  int plays = 0;

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
  }) async {
    opened.add(current.trackUid);
  }

  @override
  Future<void> replaceNext(
    MusicPlayItem? next, {
    bool crossfadeNext = false,
  }) async {}

  @override
  Future<void> play() async {
    plays++;
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setAbLoop(Duration? a, Duration? b) async {}

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

class _AppModel extends AppModel {
  _AppModel({
    required this.db,
    required PreferencesRepository prefs,
    required Directory dir,
    required this.backend,
  }) : super(testPlatformServices()) {
    wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: dir);
    wireDatabaseForTesting(db);
    wireMusicPluginManagerForTesting(
      MusicPluginManager(
        rootDir: Directory('${dir.path}/no-plugins'),
        httpClientFactory: HttpClient.new,
        log: (_, _, _) {},
      ),
    );
  }

  final FushiDatabase db;
  final _Backend backend;

  late final MusicSession _session = MusicSession(
    engine: MusicPlayerEngine(backendFactory: () => backend),
    audio: audioCtrl,
    hasSystemMediaSession: platformServices.hasSystemMediaSession,
    audiobook: audiobookSession,
    database: () => db,
    showMediaNotification: () => false,
  );

  @override
  MusicSession get musicSession => _session;

  // 播放页（BaseSourcePage）的查词层读界面缩放；测试替身没跑 initialise、没有主题。
  @override
  double get appUiScale => 1.0;
}

MusicTracksCompanion _track(String uid, int no) => MusicTracksCompanion.insert(
  trackUid: uid,
  path: '/m/$uid.flac',
  title: 'Song $uid',
  albumUid: const Value<String?>('al'),
  artistCredit: const Value<String?>('Singer'),
  discNo: const Value<int?>(1),
  trackNo: Value<int?>(no),
  durationMs: const Value<int?>(185000),
  fileMtimeAt: 1,
  fileSize: 1,
  addedAt: 1,
);

/// 建曲库（专辑 al：t1、t2；最近听过 t2）+ 假后端，挂上音乐库页。[before] 在挂页前
/// 拿引擎做准备（模拟迷你条上已经在放的那首）。
Future<({MusicPlayerEngine engine, _Backend backend})> _pumpLibrary(
  WidgetTester tester, {
  Future<void> Function(MusicPlayerEngine engine)? before,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1400, 900);
  addTearDown(tester.view.reset);
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final Directory dir = Directory.systemTemp.createTempSync(
    'fushi_music_continue_',
  );
  addTearDown(() => dir.deleteSync(recursive: true));
  final _Backend backend = _Backend();
  late final _AppModel app;
  await tester.runAsync(() async {
    await db.writeMusicScanBatch(
      MusicScanBatchWrite(
        tracks: <MusicTracksCompanion>[_track('t1', 1), _track('t2', 2)],
        albums: <MusicAlbumsCompanion>[
          MusicAlbumsCompanion.insert(
            albumUid: 'al',
            title: 'Night Album',
            albumArtistCredit: const Value<String?>('Singer'),
            addedAt: 1,
            updatedAt: 1,
          ),
        ],
        artists: const <MusicArtistsCompanion>[],
        credits: const <MusicTrackCreditsCompanion>[],
      ),
    );
    await db.startMusicPlayEvent(trackUid: 't2', startedAt: 1);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    app = _AppModel(db: db, prefs: prefs, dir: dir, backend: backend);
    await before?.call(app.musicSession.engine);
  });

  LocaleSettings.setLocale(AppLocale.en);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => app),
        ...popupMiningTargetTestOverrides(),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: const Scaffold(body: MusicLibraryPage()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (engine: app.musicSession.engine, backend: backend);
}

/// 让真 IO（数据库、播放页读歌词）落地，再推几帧走完转场。
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

final Finder _hero = find.byKey(const ValueKey<String>('music-continue-hero'));

void main() {
  testWidgets('「继续收听」主卡：引擎空闲时从专辑那一首起播并进播放页（BUG-5259）', (
    WidgetTester tester,
  ) async {
    final (:MusicPlayerEngine engine, :_Backend backend) = await _pumpLibrary(
      tester,
    );
    expect(_hero, findsOneWidget);

    await tester.tap(_hero);
    await _settle(tester);
    expect(find.byType(MusicLyricsPage), findsOneWidget, reason: '点卡进播放页');
    expect(backend.opened, <String>['t2']);
    expect(engine.current?.trackUid, 't2');
    expect(engine.queue.map((MusicPlayItem i) => i.trackUid), <String>[
      't1',
      't2',
    ]);

    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester);
  });

  testWidgets('「继续收听」主卡：当前曲已是这首时不重建队列、暂停着就接着放，并进播放页（BUG-5259）', (
    WidgetTester tester,
  ) async {
    // 迷你条上已经是这首：随机播放的队列（t2 排第一），暂停着。
    final (:MusicPlayerEngine engine, :_Backend backend) = await _pumpLibrary(
      tester,
      before: (MusicPlayerEngine engine) async {
        await engine.playQueue(
          <MusicPlayItem>[
            MusicPlayItem(trackUid: 't1', path: '/m/t1.flac', title: 'Song t1'),
            MusicPlayItem(trackUid: 't2', path: '/m/t2.flac', title: 'Song t2'),
          ],
          startIndex: 1,
          shuffle: true,
        );
        await engine.pause();
      },
    );
    expect(engine.current?.trackUid, 't2');
    expect(engine.isPlaying, isFalse);
    final List<String> queueBefore = <String>[
      for (final MusicPlayItem i in engine.queue) i.trackUid,
    ];

    await tester.tap(_hero);
    await _settle(tester);
    expect(find.byType(MusicLyricsPage), findsOneWidget, reason: '点卡进播放页');
    expect(backend.opened, <String>['t2'], reason: '没有再整队打开、从头重放');
    expect(engine.shuffled, isTrue, reason: '原队列原样保留');
    expect(<String>[
      for (final MusicPlayItem i in engine.queue) i.trackUid,
    ], queueBefore);
    expect(engine.current?.trackUid, 't2');
    expect(backend.plays, 1, reason: '暂停着就接着放');
    expect(engine.isPlaying, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester);
  });
}
