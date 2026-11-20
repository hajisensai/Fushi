import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/links/media_link_editor_dialog.dart';
import 'package:fushi/src/media/links/media_link_entries.dart';
import 'package:fushi/src/media/links/work_graph_store.dart';
import 'package:fushi/src/pages/implementations/work_network_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../media/links/work_links_test_seed.dart';

/// 关系网页（AI 库管家 spec §4.4）：节点 / 边 / 建议态渲染、焦点驱动的确认与打开、
/// 空态、窄屏与宽屏不溢出。交互一律经焦点遍历 + Enter，不点坐标。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    WorkGraphStore.debounce = Duration.zero;
  });

  tearDown(() async {
    WorkGraphStore.debounce = const Duration(milliseconds: 400);
    await db.close();
  });

  Future<void> pumpPage(
    WidgetTester tester,
    MediaLinkEndpoint endpoint, {
    Size size = const Size(1400, 900),
    List<MediaLinkEntry>? opened,
    Future<int> Function()? onInfer,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: WorkNetworkPage(
            database: db,
            endpoint: endpoint,
            onOpen: (MediaLinkEntry e) => opened?.add(e),
            onInfer: onInfer,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 主焦点是否落在 [target] 子树里。
  bool focusedWithin(Finder target) {
    final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) return false;
    for (final Element e in target.evaluate()) {
      if (identical(focused, e)) return true;
      bool hit = false;
      focused.visitAncestorElements((Element a) {
        if (identical(a, e)) {
          hit = true;
          return false;
        }
        return true;
      });
      if (hit) return true;
    }
    return false;
  }

  /// 按 Tab 走焦点直到落进 [target]（最多 [limit] 步）。
  Future<void> tabTo(
    WidgetTester tester,
    Finder target, {
    int limit = 60,
  }) async {
    for (int i = 0; i < limit; i++) {
      if (focusedWithin(target)) return;
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
    }
    fail('Tab $limit 步内没走到 $target');
  }

  Finder node(String id) =>
      find.byKey(ValueKey<String>('work-network-node-$id'));

  testWidgets('节点按分栏画出（合集折叠、卫星、建议态），边带关系标签', (WidgetTester tester) async {
    final WorkLinksSeed seed = (await tester.runAsync(
      () => WorkLinksSeed.create(db),
    ))!;
    await pumpPage(tester, seed.anime);

    final String animeId =
        'video_collection-${collectionTagEntryKey(seed.animeId)}';
    for (final String id in <String>[
      'series-${seed.novelSeriesId}',
      'book-m1',
      animeId,
      'music_track-t1',
      'game-g',
    ]) {
      expect(node(id), findsOneWidget, reason: id);
    }
    expect(find.text('某小说 2'), findsNothing, reason: '同一合集的各卷折成一个节点');
    expect(
      find.byKey(const ValueKey<String>('work-network-edges')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        ValueKey<String>(
          'work-network-edge-series-${seed.novelSeriesId}-adaptation-$animeId',
        ),
      ),
      findsOneWidget,
      reason: '第 1 卷 → 动画的改编边折到合集节点上',
    );
    expect(find.text(t.media_link_relation_adaptation), findsOneWidget);
    expect(find.text(t.music_theme_song_role_op), findsOneWidget);
    // 栏名
    expect(find.text('可能相关'), findsOneWidget);
    expect(find.text('主题曲 · 原声 · 配音'), findsOneWidget);
    expect(find.text('小说'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('建议边：焦点走到「确认」按 Enter，连接写成已确认', (WidgetTester tester) async {
    final WorkLinksSeed seed = (await tester.runAsync(
      () => WorkLinksSeed.create(db),
    ))!;
    await pumpPage(tester, seed.anime);

    final String animeId =
        'video_collection-${collectionTagEntryKey(seed.animeId)}';
    final Finder confirm = find.byKey(
      ValueKey<String>('work-network-confirm-game-g-$animeId'),
    );
    expect(confirm, findsOneWidget);
    await tabTo(tester, confirm);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    final MediaLinkRow row = (await tester.runAsync<MediaLinkRow?>(
      () => db.mediaLinkById(
        mediaLinkIdFor(
          MediaLinkRelation.sameWork,
          seed.anime,
          WorkLinksSeed.game,
        ),
      ),
    ))!;
    expect(mediaLinkStateOf(row), MediaLinkState.confirmed);
    await tester.pumpAndSettle();
    expect(confirm, findsNothing, reason: '确认后不再是建议边');
    expect(node('game-g'), findsOneWidget, reason: '游戏转成作品成员');
  });

  testWidgets('建议边：「不相关」写墓碑，节点消失', (WidgetTester tester) async {
    final WorkLinksSeed seed = (await tester.runAsync(
      () => WorkLinksSeed.create(db),
    ))!;
    await pumpPage(tester, seed.anime);
    final String animeId =
        'video_collection-${collectionTagEntryKey(seed.animeId)}';
    final Finder reject = find.byKey(
      ValueKey<String>('work-network-reject-game-g-$animeId'),
    );
    await tabTo(tester, reject);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    expect(node('game-g'), findsNothing);
  });

  testWidgets('节点可聚焦，Enter 经 onOpen 打开对应条目（合集节点开代表卷）', (
    WidgetTester tester,
  ) async {
    final WorkLinksSeed seed = (await tester.runAsync(
      () => WorkLinksSeed.create(db),
    ))!;
    final List<MediaLinkEntry> opened = <MediaLinkEntry>[];
    await pumpPage(tester, seed.anime, opened: opened);

    await tabTo(tester, node('series-${seed.novelSeriesId}'));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(opened.single.endpoint, WorkLinksSeed.vol1);
    expect(opened.single.title, '某小说系列');
  });

  testWidgets('空态：只有自己一个节点时给说明与查找 / 手动添加入口', (WidgetTester tester) async {
    int inferred = 0;
    await pumpPage(tester, (
      kind: MediaLinkKind.game,
      key: 'lonely',
    ), onInfer: () async => ++inferred);
    expect(
      find.byKey(const ValueKey<String>('work-network-empty')),
      findsOneWidget,
    );
    expect(find.text(t.media_link_network_empty), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('work-network-add')),
      findsOneWidget,
    );
    final Finder infer = find.byKey(
      const ValueKey<String>('work-network-infer'),
    );
    await tabTo(tester, infer);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(inferred, 1);
  });

  testWidgets('顶栏常驻「添加相关条目」与「查找相关作品」：节点多时也在，Enter 打开 / 触发', (
    WidgetTester tester,
  ) async {
    final WorkLinksSeed seed = (await tester.runAsync(
      () => WorkLinksSeed.create(db),
    ))!;
    int inferred = 0;
    await pumpPage(tester, seed.anime, onInfer: () async => ++inferred);
    expect(
      find.byKey(const ValueKey<String>('work-network-empty')),
      findsNothing,
    );
    final Finder infer = find.byKey(
      const ValueKey<String>('work-network-action-infer'),
    );
    final Finder add = find.byKey(
      const ValueKey<String>('work-network-action-add'),
    );
    expect(add, findsOneWidget);
    expect(infer, findsOneWidget);

    await tabTo(tester, infer);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(inferred, 1);

    await tabTo(tester, add);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(MediaLinkEditorDialog), findsOneWidget);
    // 关系里有续作 / 外传（任意本机条目都能连成系列）。
    expect(find.text(t.media_link_relation_sequel), findsOneWidget);
    expect(find.text(t.media_link_relation_side_story), findsOneWidget);
  });

  testWidgets('系列栏：刮削的相关作品画出来，未入库的标「未入库」，边标续作', (WidgetTester tester) async {
    final WorkLinksSeed seed = (await tester.runAsync(
      () => WorkLinksSeed.create(db),
    ))!;
    await tester.runAsync(
      () => db.replaceSourceCollectionRelations(
        seed.animeId,
        'anidb',
        <CollectionRelationsCompanion>[
          CollectionRelationsCompanion.insert(
            collectionId: seed.animeId,
            relationType: 'sequel',
            source: 'anidb',
            subjectId: '9001',
            title: '某动画 第二季',
          ),
        ],
      ),
    );
    await pumpPage(tester, seed.anime);
    expect(node('web-anidb-9001'), findsOneWidget);
    expect(find.text('某动画 第二季'), findsOneWidget);
    expect(find.text(t.media_link_group_series), findsOneWidget);
    final String animeId =
        'video_collection-${collectionTagEntryKey(seed.animeId)}';
    expect(
      find.byKey(
        ValueKey<String>(
          'work-network-edge-$animeId-series_sequel-web-anidb-9001',
        ),
      ),
      findsOneWidget,
    );
    expect(find.text(t.media_link_relation_sequel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final Size size in <Size>[
    const Size(360, 640),
    const Size(1600, 1000),
  ]) {
    testWidgets('${size.width.toInt()}×${size.height.toInt()} 下不溢出，可两向滚动', (
      WidgetTester tester,
    ) async {
      final WorkLinksSeed seed = (await tester.runAsync(
        () => WorkLinksSeed.create(db),
      ))!;
      await pumpPage(tester, seed.anime, size: size);
      expect(tester.takeException(), isNull);
      expect(node('music_track-t1'), findsOneWidget);
      if (size.width < 600) {
        // 窄屏画布比视口宽：横向可滚，焦点走到靠右一栏的动画节点时滚进视口
        // （未入库的节点不可打开、不进焦点遍历）。
        final Finder anime = node(
          'video_collection-${collectionTagEntryKey(seed.animeId)}',
        );
        await tabTo(tester, anime);
        final Rect r = tester.getRect(anime);
        expect(r.right, lessThanOrEqualTo(size.width + 1));
        expect(r.left, greaterThanOrEqualTo(-1));
      }
      expect(tester.takeException(), isNull);
    });
  }
}
