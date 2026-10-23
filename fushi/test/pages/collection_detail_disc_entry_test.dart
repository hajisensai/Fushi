import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/collection_episode_slot.dart';
import 'package:fushi/src/media/video/disc/disc_session_entry.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

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

  Future<void> addMember(String uid, String path, {int? playedAt}) async {
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: Value(uid),
        title: Value(uid),
        videoPath: Value(path),
        lastPlayedAt: Value(playedAt),
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
    // 选集标题上方那排描边按钮已删除。
    expect(
      find.byKey(ValueKey<String>('bluray-menu-${p.join('/box', 'Disc 1')}')),
      findsNothing,
    );

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
    await addMember('d1', mpls('Disc 1'), playedAt: 100);
    await tester.runAsync(
      () => db.updateVideoBookPosition('d1', 754000, playedAt: 100),
    );
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    expect(find.text(t.video_disc_continue_at(time: '12:34')), findsOneWidget);
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
