import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/collection_episode_slot.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/video/disc/disc_session_entry.dart';
import 'package:fushi/src/media/video/disc/remote_disc_actions.dart';
import 'package:fushi/src/sync/remote_disc_share.dart';
import 'package:fushi_engine/media/video/disc/disc_format.dart';
import 'package:fushi_engine/media/video/disc/disc_share_manifest.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import '../helpers/test_platform_services.dart';

/// BD/DVD 原盘交互改造第 5 项：原盘合集详情页的主按钮是「播放原盘」，次按钮
/// 「继续观看 xx:xx」/「直接播放正片」，多盘给「选盘」；开不了菜单时主按钮退回普通
/// 播放并写明原因。原盘入口由详情页自己提供（不再靠调用方传回调），所以「相关作品」
/// 等任何路径进来的详情页都有它。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late int collectionId;
  late List<String> opened;

  String mpls(String disc) =>
      p.join('/box', disc, 'BDMV', 'PLAYLIST', '00001.mpls');

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    opened = <String>[];
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    collectionId = await db.createMediaCollection(
      'Box',
      collectionType: 'playlist',
    );
  });

  tearDown(() => db.close());

  Future<void> addMember(
    String uid,
    String path, {
    int? playedAt,
    int positionMs = 0,
  }) async {
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: Value(uid),
        title: Value(uid),
        videoPath: Value(path),
        lastPlayedAt: Value(playedAt),
        lastPositionMs: Value(positionMs),
      ),
    );
    await db.addToCollection(collectionId, MediaKind.video, uid);
  }

  Future<List<CollectionEpisodeSlot>> loadSlots() async =>
      <CollectionEpisodeSlot>[
        for (final MediaCollectionItemRow item in await db.getCollectionItems(
          collectionId,
        ))
          if (await db.getVideoBookByBookUid(item.entryKey)
              case final VideoBookRow row)
            CollectionEpisodeSlot.local(row),
      ];

  // 与 `_openRelatedCollection` 同形：只给库与成员，不给任何原盘回调。
  Widget buildApp({DiscMenuUnavailableReason? probe}) => TranslationProvider(
    child: MaterialApp(
      home: MediaCollectionDetailPage(
        database: db,
        collection: MediaCollectionRow(
          origin: 'user',
          organizeAliases: '',
          id: collectionId,
          name: 'Box',
          collectionType: 'playlist',
          coverSource: null,
          sortOrder: 0,
          createdAt: 0,
          orderUpdatedAt: 0,
        ),
        loadEpisodes: loadSlots,
        onOpenEpisode: (VideoBookRow row) => opened.add(row.bookUid),
        onChanged: () {},
        discMenuProbe: (DiscRef _) async => probe,
      ),
    ),
  );

  void useSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Finder heroPlay() =>
      find.byKey(const ValueKey<String>('collection-hero-play'));

  testWidgets('multi-disc box: play disc, play main title, choose disc', (
    WidgetTester tester,
  ) async {
    useSurface(tester);
    await addMember('d1', mpls('Disc 1'), playedAt: 100);
    await addMember('d2', mpls('Disc 2'), playedAt: 500);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(
      find.descendant(of: heroPlay(), matching: find.text(t.video_disc_play)),
      findsOneWidget,
    );
    // 主按钮开最近看过的那张。
    expect(find.text('${t.video_disc_play}  ·  Disc 2'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('collection-disc-choose')),
      findsOneWidget,
    );
    // 选集标题上方那排「进入原盘菜单 · 盘名」描边按钮已删除。
    expect(find.text('${t.video_disc_open_menu} · Disc 1'), findsNothing);

    final Finder mainTitle = find.byKey(
      const ValueKey<String>('collection-disc-main-title'),
    );
    expect(mainTitle, findsOneWidget);
    await tester.tap(mainTitle);
    await tester.pumpAndSettle();
    expect(opened, hasLength(1), reason: '「直接播放正片」走普通播放');
  });

  testWidgets('started disc offers "continue watching xx:xx"', (
    WidgetTester tester,
  ) async {
    useSurface(tester);
    await addMember('d1', mpls('Disc 1'), playedAt: 100, positionMs: 754000);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    // 窄 hero 下次按钮是只露图标的 tonal 钮（文案进 tooltip），按组件读文案。
    expect(
      find.byWidgetPredicate(
        (Widget w) =>
            w is MediaDetailSecondaryButton &&
            w.buttonKey == const ValueKey<String>('collection-disc-continue') &&
            w.label == t.video_disc_continue_at(time: '12:34'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('collection-disc-choose')),
      findsNothing,
      reason: '单盘不给选盘',
    );
  });

  for (final DiscMenuUnavailableReason reason in <DiscMenuUnavailableReason>[
    DiscMenuUnavailableReason.mobileBdj,
    DiscMenuUnavailableReason.missingBdjComponent,
  ]) {
    testWidgets('menu unavailable ($reason): plain play with the reason', (
      WidgetTester tester,
    ) async {
      useSurface(tester);
      await addMember('d1', mpls('Disc 1'));
      await addMember('d2', mpls('Disc 2'));
      await tester.pumpWidget(buildApp(probe: reason));
      await tester.pumpAndSettle();

      expect(
        find.descendant(of: heroPlay(), matching: find.text(t.video_disc_play)),
        findsNothing,
      );
      final String text = switch (reason) {
        DiscMenuUnavailableReason.remote =>
          t.video_disc_menu_unavailable_remote,
        DiscMenuUnavailableReason.mobileBdj =>
          t.video_disc_menu_unavailable_mobile_bdj,
        DiscMenuUnavailableReason.missingBdjComponent =>
          t.video_disc_menu_unavailable_missing_bdj,
        DiscMenuUnavailableReason.remoteHostTooOld =>
          t.video_disc_menu_unavailable_remote_host_old,
        DiscMenuUnavailableReason.remoteDvdFolder =>
          t.video_disc_menu_unavailable_remote_dvd_folder,
        DiscMenuUnavailableReason.remoteUnreachable =>
          t.remote_video_unavailable,
      };
      expect(find.text(text), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('collection-disc-choose')),
        findsNothing,
      );
      await tester.tap(heroPlay());
      await tester.pumpAndSettle();
      expect(opened, hasLength(1), reason: '退回普通播放');
    });
  }

  testWidgets(
    'setting "open disc menu by default" off: main button plays the title, '
    'the disc menu stays a secondary entry',
    (WidgetTester tester) async {
      useSurface(tester);
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final PreferencesRepository prefs = PreferencesRepository(db);
      await tester.runAsync(prefs.loadFromDb);
      await tester.runAsync(() => prefs.setVideoDiscOpenMenuByDefault(false));
      final Directory store = Directory.systemTemp.createTempSync(
        'fushi_disc_entry',
      );
      addTearDown(() => store.deleteSync(recursive: true));
      final AppModel appModel = AppModel(testPlatformServices())
        ..wireDatabaseForTesting(db)
        ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: store);
      expect(appModel.videoDiscOpenMenuByDefault, isFalse);
      await addMember('d1', mpls('Disc 1'), playedAt: 100);
      await addMember('d2', mpls('Disc 2'), playedAt: 500);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            platformServicesProvider.overrideWithValue(testPlatformServices()),
            appProvider.overrideWith((Ref ref) => appModel),
          ],
          child: buildApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(of: heroPlay(), matching: find.text(t.video_disc_play)),
        findsNothing,
        reason: '主按钮变回直接播正片',
      );
      expect(
        find.byKey(const ValueKey<String>('collection-disc-open-menu')),
        findsOneWidget,
        reason: '菜单可开，入口留在次按钮',
      );
      expect(
        find.byKey(const ValueKey<String>('collection-disc-main-title')),
        findsNothing,
      );
      await tester.tap(heroPlay());
      await tester.pumpAndSettle();
      expect(opened, hasLength(1), reason: '主按钮走普通播放');
    },
  );

  testWidgets('plain collections keep the normal play button', (
    WidgetTester tester,
  ) async {
    useSurface(tester);
    await addMember('e1', '/v/Show 01.mkv');
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: heroPlay(), matching: find.text(t.video_disc_play)),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('collection-disc-main-title')),
      findsNothing,
    );
  });

  // 远端原盘（第二期）：成员只在对端时，能流式就「播放原盘」，给「在 PC 上打开」；
  // 开不了时主按钮退回普通播放并写明确切原因。
  group('remote disc', () {
    RemoteDiscShare share({
      DiscFormat format = DiscFormat.bluray,
      DiscShareLayout layout = DiscShareLayout.directory,
    }) => RemoteDiscShare(
      baseUrl: Uri.parse('http://host:1/api/library/disc/tok/'),
      manifest: DiscShareManifest(
        discKey: 'c' * 40,
        name: 'Disc 1',
        format: format,
        layout: layout,
        aacs: false,
        files: <DiscShareFile>[
          DiscShareFile(
            path: layout == DiscShareLayout.image
                ? 'DISC.iso'
                : format == DiscFormat.dvd
                ? 'VIDEO_TS/VIDEO_TS.IFO'
                : 'BDMV/index.bdmv',
            size: 1,
            modifiedAt: 0,
          ),
        ],
      ),
    );

    late List<String> openedOnHost;
    setUp(() => openedOnHost = <String>[]);

    Widget buildRemote({
      required Future<RemoteDiscShare> Function(String id) openShare,
      bool hostCanOpen = true,
      String fileName = '00001.mpls',
    }) {
      final RemoteVideoInfo info = RemoteVideoInfo(
        id: 'host/title1',
        title: 'Title 1',
        fileName: fileName,
      );
      return TranslationProvider(
        child: MaterialApp(
          home: MediaCollectionDetailPage(
            database: db,
            collection: MediaCollectionRow(
              origin: 'user',
              organizeAliases: '',
              id: collectionId,
              name: 'Box',
              collectionType: 'playlist',
              coverSource: null,
              sortOrder: 0,
              createdAt: 0,
              orderUpdatedAt: 0,
            ),
            loadEpisodes: () async => <CollectionEpisodeSlot>[
              CollectionEpisodeSlot.remote(info),
            ],
            onOpenEpisode: (VideoBookRow row) => opened.add(row.bookUid),
            onChanged: () {},
            remote: CollectionRemoteContext(
              loadRemoteVideos: () async => <RemoteVideoInfo>[info],
              openEpisode:
                  (
                    RemoteVideoInfo episode,
                    List<RemoteVideoInfo> members,
                    int index,
                  ) => opened.add(episode.id),
              discActions: RemoteDiscActions(
                openShare: openShare,
                readFile: (RemoteDiscShare _, String _, int _) async => null,
                hostCanOpenDisc: () async => hostCanOpen,
                openOnHost: (String id) async => openedOnHost.add(id),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('streamable: play disc + open on PC', (
      WidgetTester tester,
    ) async {
      useSurface(tester);
      await tester.pumpWidget(
        buildRemote(openShare: (String _) async => share()),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: heroPlay(), matching: find.text(t.video_disc_play)),
        findsOneWidget,
      );
      expect(find.text(t.video_disc_menu_unavailable_remote), findsNothing);
      final Finder onHost = find.byKey(
        const ValueKey<String>('collection-disc-open-on-host'),
      );
      expect(onHost, findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (Widget w) =>
              w is MediaDetailSecondaryButton &&
              w.label == t.video_disc_open_on_host,
        ),
        findsOneWidget,
      );
      await tester.tap(onHost);
      await tester.pumpAndSettle();
      expect(openedOnHost, <String>['host/title1']);
    });

    testWidgets('host without disc shares: plain play, says the host is old', (
      WidgetTester tester,
    ) async {
      useSurface(tester);
      await tester.pumpWidget(
        buildRemote(
          openShare: (String _) async =>
              throw const RemoteDiscShareUnsupported(),
          hostCanOpen: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: heroPlay(), matching: find.text(t.video_disc_play)),
        findsNothing,
      );
      expect(
        find.text(t.video_disc_menu_unavailable_remote_host_old),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('collection-disc-open-on-host')),
        findsNothing,
      );
      await tester.tap(heroPlay());
      await tester.pumpAndSettle();
      expect(opened, <String>['host/title1'], reason: '退回普通播放远端标题');
    });

    testWidgets('VIDEO_TS folder DVD: plain play, says folders cannot stream', (
      WidgetTester tester,
    ) async {
      useSurface(tester);
      await tester.pumpWidget(
        buildRemote(
          fileName: 'TITLE_01.dvdtitle',
          openShare: (String _) async => share(format: DiscFormat.dvd),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(t.video_disc_menu_unavailable_remote_dvd_folder),
        findsOneWidget,
      );
      expect(
        find.descendant(of: heroPlay(), matching: find.text(t.video_disc_play)),
        findsNothing,
      );
      // 菜单开不了，但 host 那边能开：「在 PC 上打开」仍在。
      expect(
        find.byKey(const ValueKey<String>('collection-disc-open-on-host')),
        findsOneWidget,
      );
    });

    testWidgets('DVD image streams', (WidgetTester tester) async {
      useSurface(tester);
      await tester.pumpWidget(
        buildRemote(
          fileName: 'TITLE_01.dvdtitle',
          openShare: (String _) async =>
              share(format: DiscFormat.dvd, layout: DiscShareLayout.image),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: heroPlay(), matching: find.text(t.video_disc_play)),
        findsOneWidget,
      );
    });

    testWidgets('host unreachable: plain play with the reason', (
      WidgetTester tester,
    ) async {
      useSurface(tester);
      await tester.pumpWidget(
        buildRemote(
          openShare: (String _) async => throw const SocketException('down'),
          hostCanOpen: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(t.remote_video_unavailable), findsOneWidget);
    });
  });

  test('every route into the detail page gets the disc entry', () {
    // 原盘入口是详情页自身能力：没有可漏传的回调参数。
    final String lib = <String>[
      for (final FileSystemEntity f in Directory(
        'lib',
      ).listSync(recursive: true))
        if (f is File && f.path.endsWith('.dart')) f.readAsStringSync(),
    ].join('\n');
    expect(lib, isNot(contains('onOpenDiscMenu')));
    final String page = File(
      'lib/src/pages/implementations/media_collection_detail_page.dart',
    ).readAsStringSync();
    expect(page, contains('collectDiscRefs('));
    expect(page, isNot(contains('_buildDiscMenuEntries')));
  });
}
