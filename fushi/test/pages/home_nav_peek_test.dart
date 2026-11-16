import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/pages/implementations/home_nav_peek.dart';
import 'package:fushi/src/settings/settings_destination_id.dart';
import 'package:fushi/src/settings/settings_recent_destinations.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart'
    show AdaptiveNavPeekData, AdaptiveNavPeekEntry;
import 'package:fushi_core/fushi_core.dart' show MediaCollectionRow;

MediaCollectionRow _collection(int id, String name) => MediaCollectionRow(
  origin: 'user',
  organizeAliases: '',
  id: id,
  name: name,
  collectionType: 'collection',
  sortOrder: 0,
  coverSource: null,
  createdAt: 0,
  orderUpdatedAt: 0,
);

// 2026-10-25 用户「侧边栏预览给复习和浏览加一下」：侧栏速览卡的数据源。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  test('复习速览副行只列非零的计数，顺序新卡 · 学习中 · 到期', () {
    expect(
      srsNavPeekCountsLabel(newCount: 3, learnCount: 1, reviewCount: 20),
      '新卡 3 · 学习中 1 · 到期 20',
    );
    expect(
      srsNavPeekCountsLabel(newCount: 0, learnCount: 0, reviewCount: 5),
      '到期 5',
    );
    // 今天已复习完：没有副行。
    expect(
      srsNavPeekCountsLabel(newCount: 0, learnCount: 0, reviewCount: 0),
      isNull,
    );
  });

  // 2026-10-26 用户「之前有个 pr 支持了侧边预览，所有的都支持一下」。
  test('每个目的地都有速览：数据源不可为空、没有落空的 return null', () {
    final String source = File(
      'lib/src/pages/implementations/home_nav_peek.dart',
    ).readAsStringSync();
    expect(source, contains('AdaptiveNavPeek homeNavPeekFor('));
    for (final HomeTab tab in HomeTab.values) {
      expect(source, contains('case HomeTab.${tab.name}:'), reason: tab.name);
    }
  });

  test('首页速览：「继续」取各模块继续项里最近的，其余按时刻倒序混排', () {
    AdaptiveNavPeekEntry entry(String title) =>
        AdaptiveNavPeekEntry(title: title, onOpen: () {});
    NavPeekTimed timed(String title, int at) => (at: at, entry: entry(title));
    final AdaptiveNavPeekData data = mergeNavPeekFeeds(<NavPeekFeed>[
      NavPeekFeed(
        resume: timed('book', 50),
        recent: <NavPeekTimed>[timed('book2', 10)],
      ),
      NavPeekFeed(
        resume: timed('video', 90),
        recent: <NavPeekTimed>[timed('video2', 70), timed('video3', 5)],
      ),
      // 没玩过游戏：空的不影响。
      const NavPeekFeed(),
      NavPeekFeed(recent: <NavPeekTimed>[timed('game', 60), timed('g2', 1)]),
    ]);
    expect(data.resume?.title, 'video');
    expect(
      <String>[for (final AdaptiveNavPeekEntry e in data.recent) e.title],
      // 别的模块的继续项（book@50）也进「最近」，只取前四个。
      <String>['video2', 'game', 'book', 'book2'],
    );
    expect(mergeNavPeekFeeds(const <NavPeekFeed>[]).isEmpty, isTrue);
  });

  test('设置最近分类：挪到最前、去重、最多五个；坏值与不认识的名字跳过', () {
    List<SettingsDestinationId> ids = const <SettingsDestinationId>[];
    for (final SettingsDestinationId id in <SettingsDestinationId>[
      SettingsDestinationId.appearance,
      SettingsDestinationId.lookup,
      SettingsDestinationId.video,
      SettingsDestinationId.appearance,
    ]) {
      ids = pushSettingsRecentDestination(ids, id);
    }
    expect(ids, <SettingsDestinationId>[
      SettingsDestinationId.appearance,
      SettingsDestinationId.video,
      SettingsDestinationId.lookup,
    ]);
    for (final SettingsDestinationId id in SettingsDestinationId.values) {
      ids = pushSettingsRecentDestination(ids, id);
    }
    expect(ids, hasLength(kSettingsRecentDestinationLimit));

    expect(decodeSettingsRecentDestinations(''), isEmpty);
    expect(decodeSettingsRecentDestinations('{oops'), isEmpty);
    expect(decodeSettingsRecentDestinations('{"a":1}'), isEmpty);
    expect(
      decodeSettingsRecentDestinations('["lookup","gone",3,"music"]'),
      <SettingsDestinationId>[
        SettingsDestinationId.lookup,
        SettingsDestinationId.music,
      ],
    );
  });

  // 用户：「侧栏预览系列和合集好像没正确显示」——同一系列的几卷各占一格。
  test('同一合集只留最近的那一卷，散条目照常，顺序按各单元最近成员', () {
    final List<NavPeekUnit<String>> units = foldNavPeekByCollection<String>(
      recentFirst: <String>['vol3', 'loose', 'vol1', 'orphan', 'vol2'],
      compositeKeyOf: (String k) => 'epub|$k',
      primaryCollectionIdByEntry: <String, int>{
        'epub|vol1': 7,
        'epub|vol2': 7,
        'epub|vol3': 7,
        // 合集已删的孤儿引用：退回散条目。
        'epub|orphan': 99,
      },
      collectionsById: <int, MediaCollectionRow>{7: _collection(7, '無職転生')},
    );
    expect(
      <String>[for (final NavPeekUnit<String> u in units) u.item],
      <String>['vol3', 'loose', 'orphan'],
    );
    expect(units.first.collectionName, '無職転生');
    expect(units[1].collectionName, isNull);
    expect(units[2].collectionName, isNull);
  });
}
