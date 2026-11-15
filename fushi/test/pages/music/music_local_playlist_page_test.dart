import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
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
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/pages/implementations/music/music_track_list.dart'
    show MusicPlaylistDragHandle;
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
  late MusicPlaylistRow playlist;

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
    // 「missing」不在这台设备的曲库里：页面上不显示，重排时按原相对顺序留在最后。
    playlist = await db.createMusicPlaylist(
      'Road trip',
      at: 1,
      trackUids: <String>['a', 'b', 'missing', 'a'],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    LocaleSettings.setLocale(AppLocale.en);
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
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
            home: MusicLocalPlaylistPage(playlist: playlist),
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  Future<List<String>> order(WidgetTester tester) async => <String>[
    for (final MusicPlaylistEntryRow e
        in await tester.runAsync(
              () => db.listMusicPlaylistEntries(playlist.playlistUid),
            )
            as List<MusicPlaylistEntryRow>)
      e.trackUid,
  ];

  testWidgets('每行行尾有拖拽把手；把第一行拖到第二行之后，库里的顺序跟着改，解析不到的条目留在最后', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester);
    final Finder handles = find.byType(MusicPlaylistDragHandle);
    expect(handles, findsNWidgets(3));

    final Offset start = tester.getCenter(handles.at(0));
    final Offset next = tester.getCenter(handles.at(1));
    final TestGesture gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(Offset.lerp(start, next, 0.6)!);
    await tester.pump();
    await gesture.moveTo(next + const Offset(0, 8));
    await tester.pump();
    await gesture.up();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(await order(tester), <String>['b', 'a', 'a', 'missing']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('有曲目时「导出 .m3u8」可点', (WidgetTester tester) async {
    await pumpPage(tester);
    final Finder export = find.byKey(
      const ValueKey<String>('music_local_playlist_export'),
    );
    expect(export, findsOneWidget);
    expect(tester.widget<FushiFilledButton>(export).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
