import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_session.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/music/music_collection_view.dart';
import 'package:fushi/src/pages/implementations/music/music_track_list.dart';
import 'package:fushi/src/pages/implementations/music/music_track_row_surface.dart'
    show MusicTrackBlock, MusicTrackRowSurface;
import 'package:fushi/src/utils/adaptive/shell_style.dart'
    show ShellContentLayout;
import 'package:fushi/src/utils/components/fushi_cover_block.dart'
    show FushiCoverBlockSize;
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/shell_layout.dart';
import '../../helpers/test_platform_services.dart';

/// 反馈 Tj28bZywxp：外观里选「封面网格（原来的）」后，音乐模块的曲目 / 艺人 / 本地
/// 歌单仍排成大字封面色块。封面网格下色块排布本身不接（`fushi_cover_block_layout.dart`
/// 文件头），调用点要保留原有画法：有原有网格卡的排网格卡，没有的排单列行。分流
/// 统一走 [musicCoverBlocksActive]。

MusicTrackRow _track(String uid) => MusicTrackRow(
  trackUid: uid,
  path: '/music/$uid.flac',
  title: 'Title $uid',
  isLossless: true,
  hasEmbeddedCover: false,
  fileMtimeAt: 1,
  fileSize: 1,
  addedAt: 1,
);

class _Backend implements MusicOutputBackend {
  final StreamController<MusicBackendEvent> controller =
      StreamController<MusicBackendEvent>.broadcast(sync: true);

  @override
  Stream<MusicBackendEvent> get events => controller.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
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

Widget _app(ShellContentLayout layout, Widget home) => TranslationProvider(
  child: MaterialApp(
    theme: shellLayoutTheme(layout, base: ThemeData(useMaterial3: true)),
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    ),
    home: Scaffold(body: home),
  ),
);

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('musicCoverBlocksActive', () {
    Future<bool> probe(
      WidgetTester tester,
      ShellContentLayout layout,
      MusicViewStyle style,
    ) async {
      late bool active;
      // 每次换一棵新的 MaterialApp，并等主题动画走完再读（首帧读到的不一定是
      // 目标布局）。
      await tester.pumpWidget(
        KeyedSubtree(
          key: UniqueKey(),
          child: _app(
            layout,
            Builder(
              builder: (BuildContext context) {
                active = musicCoverBlocksActive(context, style);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return active;
    }

    testWidgets('封面网格下色块样式不排色块；拼贴下排；列表样式恒不排', (WidgetTester tester) async {
      expect(
        await probe(tester, ShellContentLayout.grid, MusicViewStyle.blocks),
        isFalse,
      );
      expect(
        await probe(tester, ShellContentLayout.collage, MusicViewStyle.blocks),
        isTrue,
      );
      expect(
        await probe(tester, ShellContentLayout.collage, MusicViewStyle.list),
        isFalse,
      );
    });
  });

  group('MusicStyledCollection 共用层', () {
    Widget collection({bool withGridCards = false}) => MusicStyledCollection(
      style: MusicViewStyle.blocks,
      itemCount: 3,
      rowBuilder: (BuildContext context, int i) =>
          SizedBox(key: ValueKey<String>('row-$i'), height: 40),
      blockBuilder: (BuildContext context, int i, FushiCoverBlockSize size) =>
          SizedBox(key: ValueKey<String>('block-$i'), height: 40),
      gridCardBuilder: withGridCards
          ? (BuildContext context, int i) =>
                SizedBox(key: ValueKey<String>('card-$i'), height: 40)
          : null,
      gridDelegate: withGridCards
          ? (BuildContext context, double width) =>
                const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                )
          : null,
    );

    testWidgets('封面网格、没有原有网格卡：排单列行，不排色块', (WidgetTester tester) async {
      await tester.pumpWidget(_app(ShellContentLayout.grid, collection()));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('row-0')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('block-0')), findsNothing);
    });

    testWidgets('封面网格、有原有网格卡：排网格卡', (WidgetTester tester) async {
      await tester.pumpWidget(
        _app(ShellContentLayout.grid, collection(withGridCards: true)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('card-0')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('row-0')), findsNothing);
      expect(find.byKey(const ValueKey<String>('block-0')), findsNothing);
    });

    testWidgets('拼贴：排封面色块', (WidgetTester tester) async {
      await tester.pumpWidget(_app(ShellContentLayout.collage, collection()));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('block-0')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('row-0')), findsNothing);
    });
  });

  group('MusicTrackList 色块样式（歌单详情的曲目区）', () {
    late FushiDatabase db;
    late Directory dir;
    late ProviderContainer container;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      dir = Directory.systemTemp.createTempSync('fushi_track_list_grid_');
      final PreferencesRepository prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      final _AppModel app = _AppModel(db: db, prefs: prefs, dir: dir);
      container = ProviderContainer(
        overrides: <Override>[appProvider.overrideWith((Ref ref) => app)],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
      dir.deleteSync(recursive: true);
    });

    Future<void> pump(WidgetTester tester, ShellContentLayout layout) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _app(
            layout,
            MusicTrackList(
              tracks: <MusicTrackRow>[_track('a'), _track('b')],
              albums: const <String, MusicAlbumRow>{},
              context: MusicQueueContext.mixed,
              style: MusicViewStyle.blocks,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('封面网格：曲目是原有的单列曲目行，不是大字色块', (WidgetTester tester) async {
      await pump(tester, ShellContentLayout.grid);
      expect(find.byType(MusicTrackBlock), findsNothing);
      expect(find.byType(MusicTrackRowSurface), findsNWidgets(2));
    });

    testWidgets('拼贴：曲目仍排成封面色块', (WidgetTester tester) async {
      await pump(tester, ShellContentLayout.collage);
      expect(find.byType(MusicTrackBlock), findsNWidgets(2));
      expect(find.byType(MusicTrackRowSurface), findsNothing);
    });
  });
}
