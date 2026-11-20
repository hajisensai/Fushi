import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/collection_episode_slot.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-4921（应用内反馈 1fHQK9I4hL）：剧集页「继续看 第 N 集」的 N 用的是续播成员
/// 的列表顺位号。只导入了后半季（第 151 集起）时，集卡写「151」、续播行却写
/// 「第1集」。N 必须与集卡序号同一判据：文件名整批解析出的真实集号。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('collectionMemberEpisodeNumber', () {
    test('解析得出 → 真实集号；与下标无关', () {
      final List<String> names = <String>[
        '/v/[Grp] Show - 151.mkv',
        '/v/[Grp] Show - 152.mkv',
      ];
      expect(collectionMemberEpisodeNumber(names, 0), 151);
      expect(collectionMemberEpisodeNumber(names, 1), 152);
    });

    test('解析不出 → 回落顺位号', () {
      expect(
        collectionMemberEpisodeNumber(<String>['/v/foo.mkv', '/v/bar.mkv'], 1),
        2,
      );
    });
  });

  late FushiDatabase db;
  late int collectionId;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    for (final (String uid, String title) in const <(String, String)>[
      ('video/e151', '[Grp] Show - 151'),
      ('video/e152', '[Grp] Show - 152'),
    ]) {
      await db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: Value(uid),
          title: Value(title),
          videoPath: Value('/v/$title.mkv'),
        ),
      );
    }
    collectionId = await db.createMediaCollection(
      'Show',
      collectionType: 'playlist',
    );
    await db.addToCollection(collectionId, MediaKind.video, 'video/e151');
    await db.addToCollection(collectionId, MediaKind.video, 'video/e152');
  });

  tearDown(() => db.close());

  Future<List<CollectionEpisodeSlot>> loadSlots() async {
    final List<MediaCollectionItemRow> items = await db.getCollectionItems(
      collectionId,
    );
    return <CollectionEpisodeSlot>[
      for (final MediaCollectionItemRow item in items)
        if (await db.getVideoBookByBookUid(item.entryKey)
            case final VideoBookRow row)
          CollectionEpisodeSlot.local(row),
    ];
  }

  Widget buildApp() => TranslationProvider(
    child: MaterialApp(
      home: MediaCollectionDetailPage(
        database: db,
        collection: MediaCollectionRow(
          origin: 'user',
          organizeAliases: '',
          id: collectionId,
          name: 'Show',
          collectionType: 'playlist',
          coverSource: null,
          sortOrder: 0,
          createdAt: 0,
          orderUpdatedAt: 0,
        ),
        loadEpisodes: loadSlots,
        onOpenEpisode: (VideoBookRow _) async {},
        onChanged: () {},
      ),
    ),
  );

  testWidgets('续播行写续播那集的真实集号（152），不写顺位号（2）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await db.markVideoCompleted('video/e151', DateTime(2026));
    await db.updateVideoBookPosition(
      'video/e151',
      1000,
      playedAt: DateTime.now().millisecondsSinceEpoch,
    );

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(
      find.textContaining(t.collection_continue_progress(n: 152)),
      findsWidgets,
    );
    expect(
      find.textContaining(t.collection_continue_progress(n: 2)),
      findsNothing,
    );
  });
}
