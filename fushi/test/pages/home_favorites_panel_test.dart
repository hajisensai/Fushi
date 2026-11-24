// 首页「收藏句子」小组件（HomeWidgetKind.favorites）：数据挑选（总数 / 今日 / 上锁过滤 /
// 未制卡）的纯函数，与按格子尺寸变化的渲染（1×1 数字、2×1 最新一句、两行以上列表、
// 够宽才出「制卡（N）」、空态），MD3 与 Apple 两套设计系统各跑一遍。
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/favorites/favorite_mining_item.dart';
import 'package:fushi/src/media/privacy/media_visibility.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/collections_page.dart'
    show favoriteHiddenByLock;
import 'package:fushi/src/pages/implementations/home_favorites_panel.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show FushiGlassMaterial;
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_audio/fushi_audio.dart';
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
    ProviderScope(
      overrides: <Override>[
        homeFavoritesSnapshotProvider.overrideWith(
          (_) => Stream<HomeFavoritesSnapshot>.value(snapshot),
        ),
      ],
      child: MaterialApp(
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
    test('总数 / 今日 / 新的在前 / 最多 N 句', () {
      final HomeFavoritesSelection s = selectHomeFavorites(
        favorites: <FavoriteSentence>[
          _fav('old', minutesAgo: 300, dateKey: '2026-11-22'),
          _fav('new', minutesAgo: 1, dateKey: '2026-11-23'),
          _fav('mid', minutesAgo: 30, dateKey: '2026-11-23'),
          _fav('legacy', minutesAgo: 900),
        ],
        hidden: (_) => false,
        todayKey: '2026-11-23',
        minedKeys: const <String>{},
        recentLimit: 3,
      );
      expect(s.total, 4);
      expect(s.today, 2);
      expect(s.recent.map((FavoriteSentence f) => f.text), <String>[
        'new',
        'mid',
        'old',
      ]);
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
        todayKey: 'd',
        minedKeys: const <String>{},
      );
      expect(s.total, 1);
      expect(s.today, 1);
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
        todayKey: 'd',
        minedKeys: const <String>{},
      );
      expect(s.total, 0);
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
        todayKey: 'd',
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
