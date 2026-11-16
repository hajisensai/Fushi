import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/extension_management_tile.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extensions_page.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi/src/pages/implementations/browse_online_sources_view.dart';
import 'package:fushi_core/fushi_core.dart';

/// 回归：「在线源 › 扩展」目录在宽屏打不开（2026-11-16 拼贴改版）。
///
/// 根因：[ExtensionCatalogSliver] 把同一显示行的卡片放进
/// `Table(defaultVerticalAlignment: TableCellVerticalAlignment.fill)`。fill 格不参与
/// 行高计算，整行全是 fill 时行高为 0——每个多列显示行都是 0 高，卡片被压扁、
/// 所有行叠在同一个 y 上，按钮命中区为 0，目录看起来是空的 / 点不动。漫画、视频
/// （Mihon）与小说（LNReader）三域共用这一个 sliver，宽度够排两列以上就中招。
void main() {
  Widget host(Widget sliver) => MaterialApp(
    theme: ThemeData.light(useMaterial3: true),
    home: Scaffold(body: CustomScrollView(slivers: <Widget>[sliver])),
  );

  testWidgets('多列显示行按最高的卡片等高，行不塌成 0、不互相重叠', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // 0 号表头；1..5 号卡片，高度各不相同。
    const List<double> heights = <double>[0, 40, 90, 60, 30, 70];
    await tester.pumpWidget(
      host(
        ExtensionCatalogSliver(
          isHeader: <bool>[for (int i = 0; i < heights.length; i++) i == 0],
          itemBuilder: (BuildContext context, int index) => index == 0
              ? const SizedBox(key: ValueKey<int>(0), height: 48)
              : LayoutBuilder(
                  // 卡片内部有 LayoutBuilder（拿不到固有尺寸）也要排得动。
                  key: ValueKey<int>(index),
                  builder: (BuildContext context, BoxConstraints c) => Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(height: heights[index]),
                  ),
                ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);

    Rect rectOf(int i) => tester.getRect(find.byKey(ValueKey<int>(i)));
    // 1400 宽排 3 列：第一行 1/2/3，第二行 4/5。
    expect(rectOf(1).top, rectOf(2).top);
    expect(rectOf(2).top, rectOf(3).top);
    // 等高 = 本行最高那张。
    for (final int i in <int>[1, 2, 3]) {
      expect(rectOf(i).height, 90, reason: '第一行第 $i 张');
    }
    for (final int i in <int>[4, 5]) {
      expect(rectOf(i).height, 70, reason: '第二行第 $i 张');
    }
    // 第二行排在第一行下面，不叠在同一个 y 上。
    expect(rectOf(4).top, greaterThanOrEqualTo(rectOf(1).bottom));
    // 同一行左右排开、互不重叠；未满的行从起始边排。
    expect(rectOf(2).left, greaterThan(rectOf(1).right));
    expect(rectOf(4).left, rectOf(1).left);
    expect(rectOf(5).left, rectOf(2).left);
  });

  testWidgets('RTL 下槽位从右往左排', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: CustomScrollView(
              slivers: <Widget>[
                ExtensionCatalogSliver(
                  isHeader: const <bool>[false, false],
                  itemBuilder: (BuildContext context, int index) =>
                      SizedBox(key: ValueKey<int>(index), height: 20),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    final Rect first = tester.getRect(find.byKey(const ValueKey<int>(0)));
    final Rect second = tester.getRect(find.byKey(const ValueKey<int>(1)));
    expect(first.left, greaterThan(second.right));
  });

  // 回归：标题行曾是 `Row(Flexible(标题), NSFW 徽标, 有更新徽标)`。多列目录里卡片
  // 窄、尾部开关 + 两颗按钮占去一大截，标题区只剩 ~150px，两枚定宽徽标塞不下就
  // 「RenderFlex overflowed」。从手机宽到桌面三列宽逐档扫，任何宽度都不许溢出。
  for (final double width in <double>[280, 360, 420, 480, 560, 900]) {
    testWidgets('卡片满配（长标题 + 两枚徽标 + 开关 + 两颗按钮）宽 $width 不溢出', (
      WidgetTester tester,
    ) async {
      LocaleSettings.setLocale(AppLocale.en);
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(useMaterial3: true),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: MangaExtensionManagementTile(
                  title: 'A rather long extension name for overflow checks',
                  contentWarning: true,
                  updateAvailable: true,
                  enabled: true,
                  onEnabledChanged: (_) {},
                  secondaryLabel: t.mihon_extension_uninstall,
                  onSecondary: () {},
                  primaryLabel: t.mihon_extension_update,
                  onPrimary: () {},
                  primaryStyle: ExtensionTileActionStyle.filled,
                  metaChips: const <String>['EN', 'v1.0.0', 'lib 1.6'],
                  downloadsLabel: '1.5k downloads',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey<String>('extension_tile_update_badge')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('extension_tile_nsfw_badge')),
        findsOneWidget,
      );
    });
  }

  group('扩展目录在二级页里真渲染', () {
    late Directory root;
    late FushiDatabase database;
    late MihonManager manager;

    setUp(() async {
      LocaleSettings.setLocale(AppLocale.en);
      root = await Directory.systemTemp.createTemp('fushi-ext-catalog-row-');
      database = FushiDatabase.forTesting(NativeDatabase.memory());
      await database.upsertMangaExtensionStore(
        MangaExtensionStoresCompanion.insert(
          indexUrl: 'https://repo.example/index.json',
          name: 'Fixture repository',
          format: MihonStoreFormat.currentJson.name,
          signingKey: const Value<String?>('aabb'),
        ),
      );
      manager = MihonManager(
        database: database,
        rootDirectory: root,
        runtime: _PageRuntime(),
      );
      await manager.reload();
      manager.available = <MihonAvailableExtension>[
        for (int i = 0; i < 5; i++) _extension(i),
      ];
    });

    tearDown(() async {
      manager.dispose();
      await database.close();
      if (await root.exists()) await root.delete(recursive: true);
    });

    testWidgets('Windows 宽屏：目录卡片逐行排开、行高非 0、按钮点得到', (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: ThemeData.light(useMaterial3: true),
            home: BrowseSubPage(
              title: 'Extensions',
              child: CustomScrollView(
                slivers: <Widget>[
                  MihonExtensionsPage(
                    manager: manager,
                    embedded: true,
                    sections: const <MihonExtensionsSection>[
                      MihonExtensionsSection.catalog,
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final Object? error = tester.takeException();
      final Finder ext0 = find.text('Extension 0');
      final Finder ext3 = find.text('Extension 3');
      final double top0 = tester.getBottomLeft(ext0).dy;
      final double top3 = tester.getTopLeft(ext3).dy;
      final int hits = find
          .text(t.mihon_extension_install)
          .hitTestable()
          .evaluate()
          .length;
      debugDefaultTargetPlatformOverride = null;

      expect(error, isNull);
      // 3 列：0 与 3 在相邻两行的同一列，3 必须排在 0 那一行下面（回归前两者
      // 的 y 完全相同——两行都塌成 0 高叠在一起）。
      expect(top3, greaterThan(top0));
      // 卡片有真实高度：每张卡的「安装」按钮都在命中测试里够得到。
      expect(hits, 5);
    });
  });
}

MihonAvailableExtension _extension(int i) => MihonAvailableExtension(
  storeUrl: 'https://repo.example/index.json',
  name: 'Extension $i',
  packageName: 'org.example.e$i',
  apkUrl: 'https://repo.example/e$i.apk',
  iconUrl: '',
  libVersion: '1.6',
  extensionVersionCode: 1,
  versionName: '1.6.1',
  language: 'ja',
  contentWarning: 0,
  // 源数不同 → 卡片高度不同（有的带「展开全部 N 个源」按钮）。
  sources: <MihonAvailableSource>[
    for (int s = 0; s < (i.isEven ? 1 : 5); s++)
      MihonAvailableSource(
        id: 'e$i-$s',
        name: 'Source $i-$s',
        language: 'ja',
        baseUrl: 'https://source.example/$i/$s',
      ),
  ],
);

class _PageRuntime extends Fake implements MihonRuntime {
  @override
  Future<void> dispose() async {}
}
