import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show TextDirection, TextStyle;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_library_query.dart';
import 'package:fushi/src/pages/implementations/games/galgame_home_blocks.dart';
import 'package:fushi/src/pages/implementations/games/galgame_item_menu.dart';
import 'package:fushi/src/pages/implementations/games/galgame_library_view_request.dart';
import 'package:fushi/src/utils/misc/reveal_in_file_manager.dart'
    show currentRevealHost;

/// 游戏首页拼贴块的纯函数：网格排行、状态计数、平均通关文案、库页视图请求、
/// 上下文菜单清单（与游戏库卡片同序同项）。
void main() {
  // 纯函数测试不走 testWidgets，切 slang 语言要先有 binding（setLocale 会碰
  // WidgetsBinding.instance）。
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  GalgameEntry entry(String id, GalgamePlayStatus status) => GalgameEntry(
    id: id,
    name: id,
    exePath: 'Z:\\$id.exe',
    workdir: r'Z:\',
    addedAt: DateTime(2026),
    playStatus: status,
  );

  group('packGalgameHomeRows', () {
    test('四列：首块 2 + 两个统计块一行，继续区一行，随机 + 时间线一行', () {
      expect(
        packGalgameHomeRows(<int>[2, 1, 1, 1, 1, 1, 1, 1, 3], 4),
        <List<int>>[
          <int>[0, 1, 2],
          <int>[3, 4, 5, 6],
          <int>[7, 8],
        ],
      );
    });

    test('放不下就换行，超过列数按列数算', () {
      expect(packGalgameHomeRows(<int>[2, 1, 1, 2, 3], 2), <List<int>>[
        <int>[0],
        <int>[1, 2],
        <int>[3],
        <int>[4],
      ]);
    });

    test('空输入返回空', () {
      expect(packGalgameHomeRows(const <int>[], 4), isEmpty);
    });
  });

  test('galgameHomeColumnsFor：960 起四列', () {
    expect(galgameHomeColumnsFor(959), 2);
    expect(galgameHomeColumnsFor(960), 4);
  });

  test('countGalgamePlayStatuses：6 档都有键', () {
    final Map<GalgamePlayStatus, int> counts =
        countGalgamePlayStatuses(<GalgameEntry>[
          entry('a', GalgamePlayStatus.playing),
          entry('b', GalgamePlayStatus.playing),
          entry('c', GalgamePlayStatus.dropped),
        ]);
    expect(counts.length, GalgamePlayStatus.values.length);
    expect(counts[GalgamePlayStatus.playing], 2);
    expect(counts[GalgamePlayStatus.dropped], 1);
    expect(counts[GalgamePlayStatus.unset], 0);
  });

  test('galgameAverageHoursLabel：只写文字，没有就不出现', () {
    expect(galgameAverageHoursLabel(null), isNull);
    expect(galgameAverageHoursLabel(0), isNull);
    expect(galgameAverageHoursLabel(6.0), '6');
    expect(galgameAverageHoursLabel(6.25), '6.3');
    expect(galgameAverageHoursLabel(61.4), '61');
  });

  test('kGalgameHomeStatusOrder 覆盖全部 6 档且不重复', () {
    expect(kGalgameHomeStatusOrder.toSet(), GalgamePlayStatus.values.toSet());
    expect(kGalgameHomeStatusOrder.length, GalgamePlayStatus.values.length);
  });

  group('GalgameLibraryViewRequest', () {
    const GalgameLibraryView base = GalgameLibraryView(
      search: 'abc',
      status: GalgamePlayStatus.onHold,
      hideNsfw: true,
    );

    test('「全部 ›」= 按最近游玩倒序、清状态筛选、保留 hideNsfw', () {
      final GalgameLibraryView v =
          const GalgameLibraryViewRequest.recentlyPlayed().applyTo(base);
      expect(v.sortField, GalgameSortField.lastPlayed);
      expect(v.ascending, isFalse);
      expect(v.status, isNull);
      expect(v.search, isEmpty);
      expect(v.hideNsfw, isTrue);
    });

    test('状态图例 = 只换状态筛选', () {
      final GalgameLibraryView v = const GalgameLibraryViewRequest.status(
        GalgamePlayStatus.played,
      ).applyTo(base);
      expect(v.status, GalgamePlayStatus.played);
      expect(v.sortField, base.sortField);
      expect(v.ascending, base.ascending);
    });
  });

  test('上下文菜单：与游戏库卡片同序同项（详情在前、移除进危险区）', () {
    final List<GalgameItemMenuItem> items = galgameItemMenuItems(
      entry('g', GalgamePlayStatus.unset),
    );
    final List<GalgameItemAction> expected = <GalgameItemAction>[
      GalgameItemAction.detail,
      GalgameItemAction.status,
      GalgameItemAction.stats,
      GalgameItemAction.rename,
      GalgameItemAction.cover,
      GalgameItemAction.autoCover,
      GalgameItemAction.scrape,
      GalgameItemAction.collect,
      GalgameItemAction.tags,
      GalgameItemAction.privacy,
      GalgameItemAction.language,
      if (Platform.isWindows) GalgameItemAction.upscaling,
      if (Platform.isWindows) GalgameItemAction.japaneseLocale,
      if (currentRevealHost() != null) GalgameItemAction.fileLocation,
      GalgameItemAction.remove,
    ];
    expect(items.map((GalgameItemMenuItem i) => i.action).toList(), expected);
    expect(
      items
          .where((GalgameItemMenuItem i) => i.danger)
          .map((GalgameItemMenuItem i) => i.action)
          .toList(),
      <GalgameItemAction>[GalgameItemAction.remove],
    );
    expect(items.first.label, t.game_view_detail);
  });

  group('GalgameHeroMetrics.buttonStartFor', () {
    GalgameHeroMetrics metrics(double width) => GalgameHeroMetrics.compute(
      base: const TextStyle(fontSize: 14),
      direction: TextDirection.ltr,
      width: width,
      title: 'Game',
      hasHours: false,
      hasAverage: false,
    );

    test('窄屏：封面底边在按钮行之上，按钮行从封面起始边排起（保住 48dp 命中区）', () {
      final GalgameHeroMetrics m = metrics(328);
      expect(m.buttonStartFor(m.height), m.artStart);
    });

    test('桌面宽块：封面压到按钮行高度，按钮行与文字列对齐', () {
      final GalgameHeroMetrics m = metrics(600);
      expect(m.buttonStartFor(m.height), m.textStart);
    });
  });
}
