import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/pages/implementations/home_nav_peek.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart'
    show kNavPeekRecentGap, kNavPeekRecentMinHeight, navPeekRecentLayout;
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

  test('复习与浏览都接了速览（此前只有四个库页有）', () {
    final String source = File(
      'lib/src/pages/implementations/home_nav_peek.dart',
    ).readAsStringSync();
    for (final HomeTab tab in <HomeTab>[HomeTab.srs, HomeTab.browse]) {
      expect(
        RegExp(
          r'case HomeTab\.' + tab.name + r':\s*return AdaptiveNavPeek\(',
        ).hasMatch(source),
        isTrue,
        reason: '${tab.name} 应返回速览数据源，而不是落到 return null 那组',
      );
    }
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

  // 用户：「视频预览要自适应横屏，都要显示全并且等高」「预览有点小，视频横屏
  // 看着难受」。
  test('「最近」封面等高、按各自比例整张显示；横版挤成一排太矮时换成两排', () {
    const double width = 336;
    List<double> heightsOf(List<List<double>> rows, List<double> aspects) {
      final List<double> widths = rows.expand((List<double> r) => r).toList();
      return <double>[
        for (int i = 0; i < aspects.length; i++) widths[i] / aspects[i],
      ];
    }

    void expectFits(List<List<double>> rows) {
      for (final List<double> row in rows) {
        final double total =
            row.fold<double>(0, (double a, double b) => a + b) +
            kNavPeekRecentGap * (row.length - 1);
        expect(total, lessThanOrEqualTo(width + 0.001));
      }
    }

    // 四张横版视频：2 × 2，够高、等高、放得下。
    const List<double> videos = <double>[16 / 9, 16 / 9, 16 / 9, 16 / 9];
    final List<List<double>> videoRows = navPeekRecentLayout(
      aspects: videos,
      maxWidth: width,
    );
    expect(videoRows.map((List<double> r) => r.length), <int>[2, 2]);
    final List<double> videoHeights = heightsOf(videoRows, videos);
    for (final double h in videoHeights) {
      expect(h, moreOrLessEquals(videoHeights.first));
      expect(h, greaterThanOrEqualTo(kNavPeekRecentMinHeight));
    }
    expectFits(videoRows);

    // 四本竖版书封：一排，与原先四等分同尺寸。
    final List<List<double>> bookRows = navPeekRecentLayout(
      aspects: const <double>[2 / 3, 2 / 3, 2 / 3, 2 / 3],
      maxWidth: width,
    );
    expect(bookRows, hasLength(1));
    expect(
      bookRows.single.first,
      moreOrLessEquals((width - kNavPeekRecentGap * 3) / 4),
    );

    // 只有一本时不放大成巨图：仍按四本时的尺寸。
    final List<List<double>> one = navPeekRecentLayout(
      aspects: const <double>[2 / 3],
      maxWidth: width,
    );
    expect(one.single.single, moreOrLessEquals(bookRows.single.first));
  });
}
