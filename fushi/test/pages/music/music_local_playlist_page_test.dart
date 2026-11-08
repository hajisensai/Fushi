import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryMouseButton;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_session.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/music/music_local_playlist_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_platform_services.dart';

class _Backend implements MusicOutputBackend {
  final StreamController<MusicBackendEvent> controller =
      StreamController<MusicBackendEvent>.broadcast(sync: true);

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
  }) async {}

  @override
  Future<void> replaceNext(
    MusicPlayItem? next, {
    bool crossfadeNext = false,
  }) async {}

  @override
  Future<void> play() async {}

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
  }) : super(testPlatformServices()) {
    wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: dir);
    wireDatabaseForTesting(db);
  }

  final FushiDatabase db;

  late final MusicSession _session = MusicSession(
    engine: MusicPlayerEngine(backendFactory: _Backend.new),
    audio: audioCtrl,
    hasSystemMediaSession: platformServices.hasSystemMediaSession,
    audiobook: audiobookSession,
    database: () => db,
    showMediaNotification: () => false,
  );

  @override
  MusicSession get musicSession => _session;
}

MusicTracksCompanion _track(String uid) => MusicTracksCompanion.insert(
  trackUid: uid,
  path: '/m/$uid.flac',
  title: 'Title $uid',
  artistCredit: const Value<String?>('Singer'),
  durationMs: const Value<int?>(90000),
  fileMtimeAt: 1,
  fileSize: 1,
  addedAt: 1,
);

void main() {
  late FushiDatabase db;
  late Directory dir;
  late _AppModel app;
  late ProviderContainer container;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    dir = Directory.systemTemp.createTempSync('fushi_local_playlist_');
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    app = _AppModel(db: db, prefs: prefs, dir: dir);
    container = ProviderContainer(
      overrides: <Override>[appProvider.overrideWith((Ref ref) => app)],
    );
    await db.batch((b) {
      b.insertAll(db.musicTracks, <MusicTracksCompanion>[
        _track('a'),
        _track('b'),
      ]);
    });
    // 「missing」不在曲库（文件暂时不在）：不显示，底部注明。
    await db.createMusicPlaylist(
      playlistUid: 'p',
      name: 'Road trip',
      trackUids: <String>['a', 'b', 'missing', 'a'],
      now: 1,
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    LocaleSettings.setLocale(AppLocale.en);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(useMaterial3: true),
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: const MusicLocalPlaylistPage(playlistUid: 'p'),
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  Finder rowsOf() => find.byWidgetPredicate(
    (Widget w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('music-playlist-row-') &&
        !(w.key! as ValueKey<String>).value.contains('menu'),
  );

  testWidgets('列出在库条目（同一首两次是两行），缺失的注明条数；整单播放按歌单顺序', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester);
    expect(find.text('Road trip'), findsWidgets);
    expect(rowsOf(), findsNWidgets(3));
    expect(
      find.byKey(const ValueKey<String>('music_local_playlist_missing')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('music_local_playlist_play')),
    );
    await tester.pumpAndSettle();
    final MusicPlayerEngine engine = app.musicSession.engine;
    expect(engine.current?.title, 'Title a');
    expect(engine.queue.map((MusicPlayItem i) => i.trackUid), <String>[
      'a',
      'b',
      'a',
    ]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('右键一行「从歌单移除」只删那一条', (WidgetTester tester) async {
    await pumpPage(tester);
    final List<MusicPlaylistEntryRow> before =
        await tester.runAsync(() => db.listMusicPlaylistEntries('p'))
            as List<MusicPlaylistEntryRow>;
    final int lastA = before.last.id;
    await tester.tap(
      find.byKey(ValueKey<String>('music-playlist-row-$lastA')),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('music-menu-action-remove')),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    final List<MusicPlaylistEntryRow> after =
        await tester.runAsync(() => db.listMusicPlaylistEntries('p'))
            as List<MusicPlaylistEntryRow>;
    expect(after.map((MusicPlaylistEntryRow e) => e.trackUid), <String>[
      'a',
      'b',
      'missing',
    ]);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
