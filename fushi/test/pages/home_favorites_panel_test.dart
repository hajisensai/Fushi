// 首页「收藏句子」小组件（HomeWidgetKind.favorites）：数据挑选（总数 / 今日 / 上锁过滤 /
// 未制卡）的纯函数，与按格子尺寸变化的渲染（1×1 数字、2×1 最新一句、两行以上列表、
// 够宽才出「制卡（N）」、空态），MD3 与 Apple 两套设计系统各跑一遍。
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/favorites/favorite_mining_item.dart';
import 'package:fushi/src/media/favorites/favorite_visibility.dart';
import 'package:fushi/src/media/privacy/media_visibility.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/home_favorites_panel.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show FushiGlassMaterial;
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

FavoriteSentence _fav(
  String text, {
  required int minutesAgo,
  String? expression,
  String? dateKey,
  String bookKey = 'hoshi://book/a',
  String title = 'Book A',
  String source = kFavoriteSentenceSourceBook,
}) => FavoriteSentence(
  text: text,
  bookTitle: title,
  createdAt: DateTime(2026, 11, 23, 12).subtract(Duration(minutes: minutesAgo)),
  bookKey: bookKey,
  expression: expression,
  dateKey: dateKey,
  source: source,
);

HomeFavoritesSnapshot _snapshot({
  int count = 5,
  int today = 2,
  int unmined = 3,
}) {
  final List<FavoriteSentence> favs = <FavoriteSentence>[
    for (int i = 0; i < count; i++)
      _fav(
        '文$iの例文です。もう二度と会えないなんて信じたくなかった。',
        minutesAgo: i,
        expression: i.isEven ? '信じる' : null,
      ),
  ];
  return HomeFavoritesSnapshot(
    total: count,
    today: today,
    recent: <HomeFavoriteEntry>[
      for (final FavoriteSentence f in favs)
        HomeFavoriteEntry(favorite: f, title: 'Frieren'),
    ],
    unmined: favs.take(unmined).toList(),
  );
}

class _Harness {
  int openedCollections = 0;
  final List<HomeFavoriteEntry> opened = <HomeFavoriteEntry>[];
  final List<List<FavoriteSentence>> created = <List<FavoriteSentence>>[];
}

Future<_Harness> _pump(
  WidgetTester tester, {
  required Size size,
  required HomeFavoritesSnapshot snapshot,
  required bool apple,
  bool canCreate = true,
  bool reachable = true,
}) async {
  tester.view.physicalSize = const Size(1000, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final _Harness h = _Harness();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFushiThemeData(
        scheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        textTheme: Typography.material2021().black,
        glass: FushiGlassMaterial.off,
        glassDesign: apple,
      ),
      home: FushiGlassScope(
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: HomeFavoritesPanel(
                data: snapshot,
                onOpenCollections: () => h.openedCollections++,
                onOpenFavorite: h.opened.add,
                canOpenFavorite: (_) => reachable,
                onCreateCards: canCreate ? h.created.add : null,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

/// 把焦点交给 [target]（点按目标本身）里的控件并按 Enter 激活：Focus 在 InkWell /
/// 按钮内部，所以从它的第一个文字子孙往上找。
Future<void> _activate(WidgetTester tester, Finder target) async {
  final Finder inner = find
      .descendant(of: target, matching: find.byType(Text))
      .first;
  Focus.of(tester.element(inner)).requestFocus();
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pumpAndSettle();
}

Finder _rows() => find.byWidgetPredicate(
  (Widget w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('home-favorites-row/'),
);

void main() {
  group('selectHomeFavorites', () {
    test('最多 N 句，保持传入的新→旧顺序', () {
      final HomeFavoritesSelection s = selectHomeFavorites(
        favorites: <FavoriteSentence>[
          _fav('new', minutesAgo: 1),
          _fav('mid', minutesAgo: 30),
          _fav('old', minutesAgo: 300),
          _fav('legacy', minutesAgo: 900),
        ],
        hidden: (_) => false,
        minedKeys: const <String>{},
        recentLimit: 3,
      );
      expect(s.recent.map((FavoriteSentence f) => f.text), <String>[
        'new',
        'mid',
        'old',
      ]);
    });

    test('有上锁时的计数：总数 / 今日都不算上锁作品', () {
      final ({int total, int today}) c = countHomeFavorites(
        rows: <FavoriteSentenceLockRow>[
          (bookKey: 'a', bookTitle: 'A', source: 'book', dateKey: 'd'),
          (bookKey: 'a', bookTitle: 'A', source: 'book', dateKey: 'old'),
          (bookKey: 'a', bookTitle: 'A', source: 'book', dateKey: null),
          (bookKey: 'locked', bookTitle: 'L', source: 'book', dateKey: 'd'),
        ],
        hidden: (FavoriteSentenceLockRow r) => r.bookKey == 'locked',
        todayKey: 'd',
      );
      expect(c.total, 3);
      expect(c.today, 1);
    });

    test('上锁作品的句子不计数、不列、不进制卡（与收藏夹同一判据）', () {
      final List<FavoriteSentence> favs = <FavoriteSentence>[
        _fav('public', minutesAgo: 1, expression: '公', dateKey: 'd'),
        _fav(
          'secret',
          minutesAgo: 2,
          expression: '秘',
          dateKey: 'd',
          bookKey: 'hoshi://book/locked',
        ),
      ];
      final HomeFavoritesSelection s = selectHomeFavorites(
        favorites: favs,
        hidden: (FavoriteSentence f) => f.bookKey == 'hoshi://book/locked',
        minedKeys: const <String>{},
      );
      expect(s.recent.single.text, 'public');
      expect(s.unmined.single.text, 'public');
    });

    test('上锁快照没读完（pending）时一句都不出现（fail-closed）', () {
      final FavoriteSentence f = _fav('x', minutesAgo: 1);
      final HomeFavoritesSelection s = selectHomeFavorites(
        favorites: <FavoriteSentence>[f],
        hidden: (FavoriteSentence f) => favoriteHiddenByLock(
          MediaVisibility.pending,
          bookKey: f.bookKey,
          title: f.bookTitle,
          source: f.source,
        ),
        minedKeys: const <String>{},
      );
      expect(s.recent, isEmpty);
      // 已解锁：照常显示。
      expect(
        favoriteHiddenByLock(
          MediaVisibility.all,
          bookKey: f.bookKey,
          title: f.bookTitle,
          source: f.source,
        ),
        isFalse,
      );
    });

    test('未制卡 = 有查词词头且没有同句同作品的制卡历史', () {
      final List<FavoriteSentence> favs = <FavoriteSentence>[
        _fav('carded', minutesAgo: 1, expression: '一'),
        _fav('fresh', minutesAgo: 2, expression: '二'),
        _fav('no headword', minutesAgo: 3),
        _fav(
          'carded',
          minutesAgo: 4,
          expression: '一',
          bookKey: 'hoshi://book/other',
        ),
      ];
      final HomeFavoritesSelection s = selectHomeFavorites(
        favorites: favs,
        hidden: (_) => false,
        minedKeys: <String>{homeFavoriteMinedKey(' carded ', 'hoshi://book/a')},
      );
      expect(
        s.unmined.map((FavoriteSentence f) => '${f.text}@${f.bookKey}'),
        <String>['fresh@hoshi://book/a', 'carded@hoshi://book/other'],
      );
    });

    test('收藏句 → 制卡输入：没有词头的不进', () {
      expect(favoriteMiningItemOfSentence(_fav('a', minutesAgo: 1)), isNull);
      final FavoriteMiningItem? item = favoriteMiningItemOfSentence(
        _fav('文', minutesAgo: 1, expression: '語'),
      );
      expect(item?.expression, '語');
      expect(item?.sentence, '文');
      expect(item?.bookKey, 'hoshi://book/a');
      expect(item?.bookTitle, 'Book A');
    });
  });

  group('loadHomeFavorites（真库）', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<void> add(FavoriteSentence f) =>
        FavoriteSentenceRepository(db).add(f);

    String titleOf(FavoriteSentence f, VideoBookRow? row) =>
        row != null ? 'row:${row.title}' : 'raw:${f.bookTitle}';

    test('计数走全表，句子只取最近 N 条，制卡判定只看这 N 条，视频标题批量取', () async {
      for (int i = 0; i < 20; i++) {
        await add(
          _fav(
            's$i',
            minutesAgo: i,
            expression: '語',
            dateKey: i < 5 ? '2026-11-23' : '2026-11-01',
          ),
        );
      }
      await add(
        _fav(
          'video line',
          minutesAgo: -1,
          bookKey: 'vid-1',
          title: 'snapshot title',
          source: kFavoriteSentenceSourceVideo,
        ),
      );
      await db
          .into(db.videoBooks)
          .insert(
            VideoBooksCompanion.insert(
              bookUid: 'vid-1',
              title: 'Library title',
              videoPath: '/v/vid-1.mkv',
              importedAt: const Value<int?>(0),
            ),
          );
      // 列出的句子里 s0 制过卡（制卡历史里原句带首尾空白也认）。
      await db.addMinedSentence(
        source: kFavoriteSentenceSourceBook,
        dateKey: '2026-11-23',
        sentence: ' s0 ',
        bookKey: 'hoshi://book/a',
      );

      final HomeFavoritesSnapshot snap = await loadHomeFavorites(
        db,
        MediaVisibility.nothingLocked,
        todayKey: '2026-11-23',
        titleOf: titleOf,
        recentLimit: 4,
      );
      expect(snap.total, 21);
      expect(snap.today, 5);
      expect(
        snap.recent.map((HomeFavoriteEntry e) => e.favorite.text),
        <String>['video line', 's0', 's1', 's2'],
      );
      expect(snap.recent.first.title, 'row:Library title');
      expect(snap.recent[1].title, 'raw:Book A');
      expect(snap.unmined.map((FavoriteSentence f) => f.text), <String>[
        's1',
        's2',
      ], reason: '没有词头的视频句不进；s0 制过卡；只看列出来的 4 句');
    });

    test('上锁口径没读完（pending）：一句不列、计数为 0（fail-closed）', () async {
      await add(_fav('x', minutesAgo: 1, dateKey: '2026-11-23'));
      final HomeFavoritesSnapshot snap = await loadHomeFavorites(
        db,
        MediaVisibility.pending,
        todayKey: '2026-11-23',
        titleOf: titleOf,
      );
      expect(snap.total, 0);
      expect(snap.recent, isEmpty);
    });

    test('空表：空快照', () async {
      final HomeFavoritesSnapshot snap = await loadHomeFavorites(
        db,
        MediaVisibility.all,
        todayKey: 'd',
        titleOf: titleOf,
      );
      expect(identical(snap, HomeFavoritesSnapshot.empty), isTrue);
    });
  });

  for (final bool apple in <bool>[false, true]) {
    final String design = apple ? 'Apple' : 'MD3';
    group('渲染（$design）', () {
      testWidgets('1×1：心形 + 总数 + 今日 +N，没有标题行与句子', (WidgetTester tester) async {
        await _pump(
          tester,
          size: const Size(150, 110),
          snapshot: _snapshot(count: 128, today: 3),
          apple: apple,
        );
        expect(
          find.byKey(const ValueKey<String>('home-favorites-count')),
          findsOneWidget,
        );
        expect(find.text('128'), findsOneWidget);
        expect(find.text(t.home_favorites_today(n: 3)), findsOneWidget);
        expect(find.text(t.home_widget_favorites), findsNothing);
        expect(_rows(), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('2×1：最新一句 + 词头 + 来源；点句子跳回原处', (WidgetTester tester) async {
        final _Harness h = await _pump(
          tester,
          size: const Size(360, 120),
          snapshot: _snapshot(),
          apple: apple,
        );
        expect(
          find.byKey(const ValueKey<String>('home-favorites-newest')),
          findsOneWidget,
        );
        expect(find.text('信じる'), findsOneWidget);
        expect(find.text('Frieren'), findsOneWidget);
        expect(_rows(), findsOneWidget);
        // 不够 4 列宽：不出制卡按钮。
        expect(
          find.byKey(const ValueKey<String>('home-favorites-create-cards')),
          findsNothing,
        );
        await _activate(
          tester,
          find.byKey(const ValueKey<String>('home-favorites-row/0')),
        );
        expect(h.opened.single.favorite.text, startsWith('文0'));
        expect(h.openedCollections, 0);
      });

      testWidgets('两行以上：列表行数跟高度走，越高越多', (WidgetTester tester) async {
        await _pump(
          tester,
          size: const Size(170, 240),
          snapshot: _snapshot(),
          apple: apple,
        );
        final int short = tester.widgetList(_rows()).length;
        expect(short, greaterThanOrEqualTo(1));
        expect(tester.takeException(), isNull);
        await _pump(
          tester,
          size: const Size(170, 500),
          snapshot: _snapshot(),
          apple: apple,
        );
        final int tall = tester.widgetList(_rows()).length;
        expect(tall, greaterThan(short));
        expect(tall, lessThanOrEqualTo(5));
        expect(tester.takeException(), isNull);
      });

      testWidgets('够宽且制卡模块开着：「制卡（N）」把未制卡的收藏交给批量制卡', (
        WidgetTester tester,
      ) async {
        final _Harness h = await _pump(
          tester,
          size: const Size(600, 260),
          snapshot: _snapshot(unmined: 3),
          apple: apple,
        );
        final Finder button = find.byKey(
          const ValueKey<String>('home-favorites-create-cards'),
        );
        expect(button, findsOneWidget);
        expect(find.text(t.home_favorites_create_cards(n: 3)), findsOneWidget);
        await _activate(tester, button);
        expect(h.created.single, hasLength(3));
      });

      testWidgets('制卡模块关着：不出按钮', (WidgetTester tester) async {
        await _pump(
          tester,
          size: const Size(600, 260),
          snapshot: _snapshot(),
          apple: apple,
          canCreate: false,
        );
        expect(
          find.byKey(const ValueKey<String>('home-favorites-create-cards')),
          findsNothing,
        );
      });

      testWidgets('没有未制卡的收藏：不出按钮', (WidgetTester tester) async {
        await _pump(
          tester,
          size: const Size(600, 260),
          snapshot: _snapshot(unmined: 0),
          apple: apple,
        );
        expect(
          find.byKey(const ValueKey<String>('home-favorites-create-cards')),
          findsNothing,
        );
      });

      testWidgets('目的地模块关着的句子：点了进收藏夹，不跳', (WidgetTester tester) async {
        final _Harness h = await _pump(
          tester,
          size: const Size(360, 120),
          snapshot: _snapshot(),
          apple: apple,
          reachable: false,
        );
        await _activate(
          tester,
          find.byKey(const ValueKey<String>('home-favorites-row/0')),
        );
        expect(h.opened, isEmpty);
        expect(h.openedCollections, 1);
      });

      testWidgets('空态：提示怎么收藏；1×1 显示 0', (WidgetTester tester) async {
        await _pump(
          tester,
          size: const Size(360, 240),
          snapshot: HomeFavoritesSnapshot.empty,
          apple: apple,
        );
        expect(find.text(t.home_favorites_empty), findsOneWidget);
        await _pump(
          tester,
          size: const Size(150, 110),
          snapshot: HomeFavoritesSnapshot.empty,
          apple: apple,
        );
        expect(find.text('0'), findsOneWidget);
      });
    });
  }
}
