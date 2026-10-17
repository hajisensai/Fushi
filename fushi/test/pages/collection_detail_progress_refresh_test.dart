import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/collection_detail_layout.dart';
import 'package:fushi/src/media/collections/collection_episode_slot.dart';
import 'package:fushi/src/media/video/video_duration_pref.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-3491（用户反馈：剧集页进度延迟 / 重看已打勾集续播跳下一集 / 想看百分比）：
/// ① 从播放页退回详情页，集卡进度立即刷新（不必退出详情页重进）；
/// ② 已打勾的集重看到一半退出，「继续看」停在它，不跳下一集；
/// ④ 状态行时间进度旁接观看百分比，已打勾的集仍保留时间进度。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const int episodeMs = 24 * 60 * 1000;
  late FushiDatabase db;
  late int collectionId;
  late int loads;
  final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    loads = 0;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    for (final (String uid, String title) in const <(String, String)>[
      ('video/e1', 'Show 01'),
      ('video/e2', 'Show 02'),
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
    await db.addToCollection(collectionId, MediaKind.video, 'video/e1');
    await db.addToCollection(collectionId, MediaKind.video, 'video/e2');
  });

  tearDown(() => db.close());

  Future<List<CollectionEpisodeSlot>> loadSlots() async {
    loads++;
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
      navigatorKey: navigator,
      home: MediaCollectionDetailPage(
        database: db,
        collection: MediaCollectionRow(
          id: collectionId,
          name: 'Show',
          collectionType: 'playlist',
          coverSource: null,
          sortOrder: 0,
          createdAt: 0,
          orderUpdatedAt: 0,
        ),
        loadEpisodes: loadSlots,
        // 播放页替身：压一页，测试里写进度后再 pop。
        onOpenEpisode: (VideoBookRow _) => navigator.currentState!.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('player')),
          ),
        ),
        onChanged: () {},
      ),
    ),
  );

  void useSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> setDuration(String uid, int ms) =>
      db.setPref(videoDurationPrefKey(uid), PrefCodec.encode(ms));

  testWidgets('① 播放页退回来，集卡进度立即刷新', (WidgetTester tester) async {
    useSurface(tester);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    expect(loads, 1);
    final String watched = collectionEpisodeWatchedLabel(
      positionMs: 9 * 60 * 1000,
    );
    expect(find.text(watched), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('collection-episode-row-video/e2')),
    );
    await tester.pumpAndSettle();
    expect(find.text('player'), findsOneWidget);

    // 播放页在播的时候写断点（真实播放页每秒落库）。
    await tester.runAsync(
      () => db.updateVideoBookPosition(
        'video/e2',
        9 * 60 * 1000,
        playedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    navigator.currentState!.pop();
    await tester.pumpAndSettle();

    expect(loads, 2, reason: '露出来那一刻重读一次');
    expect(find.text(watched), findsOneWidget);
  });

  testWidgets('打开过的对话框 / 菜单关掉不重读（只认派出去的播放）', (WidgetTester tester) async {
    useSurface(tester);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    navigator.currentState!.push<void>(
      MaterialPageRoute<void>(builder: (_) => const Scaffold()),
    );
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(loads, 1);
  });

  testWidgets('② 重看已打勾的第 1 集到一半：继续看停在第 1 集', (WidgetTester tester) async {
    useSurface(tester);
    final int now = DateTime.now().millisecondsSinceEpoch;
    await db.markVideoCompleted('video/e1', DateTime(2026));
    await db.updateVideoBookPosition('video/e1', 9 * 60 * 1000, playedAt: now);
    await setDuration('video/e1', episodeMs);

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(
      find.textContaining(t.collection_continue_progress(n: 1)),
      findsOneWidget,
    );
    expect(find.text(t.video_continue_watching), findsWidgets);
  });

  testWidgets('② 不知道片长（旧库）时照旧推进到下一集', (WidgetTester tester) async {
    useSurface(tester);
    final int now = DateTime.now().millisecondsSinceEpoch;
    await db.markVideoCompleted('video/e1', DateTime(2026));
    await db.updateVideoBookPosition('video/e1', 9 * 60 * 1000, playedAt: now);

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(
      find.textContaining(t.collection_continue_progress(n: 2)),
      findsOneWidget,
    );
  });

  testWidgets('④ 已打勾的集保留时间进度并给百分比', (WidgetTester tester) async {
    useSurface(tester);
    await db.markVideoCompleted('video/e1', DateTime(2026));
    await db.updateVideoBookPosition(
      'video/e1',
      9 * 60 * 1000,
      playedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await setDuration('video/e1', episodeMs);

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    final Finder card = find.byKey(
      const ValueKey<String>('collection-episode-row-video/e1'),
    );
    expect(
      find.descendant(
        of: card,
        matching: find.byKey(
          const ValueKey<String>('collection-episode-completed'),
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: card,
        matching: find.text(
          collectionEpisodeWatchedLabel(
            positionMs: 9 * 60 * 1000,
            progress: 9 / 24,
          ),
        ),
      ),
      findsOneWidget,
    );
    expect(
      collectionEpisodeWatchedLabel(
        positionMs: 9 * 60 * 1000,
        progress: 9 / 24,
      ),
      endsWith(' · 37%'),
    );
  });

  testWidgets('看到片尾区的集：不打勾，只显示进度 + 百分比 + 进度条；续播 / 计数等同看完', (
    WidgetTester tester,
  ) async {
    useSurface(tester);
    await db.updateVideoBookPosition(
      'video/e1',
      23 * 60 * 1000,
      playedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await setDuration('video/e1', episodeMs);

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    final Finder card = find.byKey(
      const ValueKey<String>('collection-episode-row-video/e1'),
    );
    expect(
      find.descendant(
        of: card,
        matching: find.byKey(
          const ValueKey<String>('collection-episode-completed'),
        ),
      ),
      findsNothing,
      reason: '播放不再自动打勾',
    );
    expect(
      find.descendant(
        of: card,
        matching: find.text(
          collectionEpisodeWatchedLabel(
            positionMs: 23 * 60 * 1000,
            progress: 23 / 24,
          ),
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: card,
        matching: find.byKey(
          const ValueKey<String>('collection-episode-progress'),
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(t.collection_continue_progress(n: 2)),
      findsOneWidget,
      reason: '续播推进到下一集',
    );
    expect(
      find.text(t.collection_watched_progress(done: 1, total: 2)),
      findsOneWidget,
      reason: '已看完计数认片尾区',
    );
  });
}
