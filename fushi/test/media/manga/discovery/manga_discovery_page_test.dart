import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/discovery/manga_discovery_page.dart';
import 'package:fushi/src/media/manga/discovery/manga_discovery_source_feeds.dart';
import 'package:fushi/src/media/manga/discovery/manga_source_catalog_section.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiCircularProgressIndicator;
import 'package:fushi_core/fushi_core.dart';

/// 发现页视图：正文只由已启用来源构成（MAL 元数据行已整体移除）。
///
/// 覆盖：来源热门行渲染 / 失败收起并汇总进来源失败横幅 / 全部失败可重试 /
/// 加载中占位；页首「浏览来源」快捷条；没有任何来源时的整页空态；选中单个来源
/// 后收窄成该源的热门网格（滚到底自动翻页、翻页失败可重试）；行头「查看全部」
/// 与页头刷新。
MangaDiscoverySourceItem _item(String title, {VoidCallback? onOpen}) =>
    MangaDiscoverySourceItem(
      title: title,
      buildCover: (BuildContext context) =>
          const ColoredBox(color: Color(0xFF808080)),
      open: (BuildContext context) => onOpen?.call(),
    );

const MangaOnlineSourceRow _mihonSource = MangaOnlineSourceRow(
  mediaKind: 'manga',
  extensionPackage: 'pkg',
  sourceId: '1',
  name: '某在线源',
  language: 'ja',
  baseUrl: 'https://example.com',
  enabled: true,
  pinned: false,
  sortOrder: 0,
);

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  Widget wrap(Widget child) => ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(home: Scaffold(body: child)),
        ),
      );

  testWidgets('来源热门行：有货的行渲染、可点开，失败的行整行收起', (WidgetTester tester) async {
    int opened = 0;
    await tester.pumpWidget(wrap(MangaDiscoveryPage(
      sourceFeedsOverride: <MangaDiscoverySourceFeed>[
        MangaDiscoverySourceFeed(
          id: 'ok',
          name: '好源',
          language: 'ja',
          loadPopular: () async => <MangaDiscoverySourceItem>[
            _item('源里的热门作品', onOpen: () => opened++),
          ],
        ),
        MangaDiscoverySourceFeed(
          id: 'broken',
          name: '坏源',
          language: 'ja',
          loadPopular: () async => throw StateError('Cloudflare'),
        ),
      ],
    )));
    await tester.pumpAndSettle();

    expect(
      find.text(t.manga_discovery_source_popular(source: '好源 (JA)')),
      findsOneWidget,
    );
    expect(find.text('源里的热门作品'), findsOneWidget);
    expect(
      find.text(t.manga_discovery_source_popular(source: '坏源 (JA)')),
      findsNothing,
      reason: '失败的来源行整行收起，不立错误牌坊',
    );
    // 但不再静默：页首横幅点名失败的来源（展示名，不是 feed id）。
    final Finder banner =
        find.byKey(const ValueKey<String>('manga_discovery_provider_warning'));
    expect(banner, findsOneWidget);
    expect(
      find.descendant(of: banner, matching: find.text('坏源 (JA)')),
      findsOneWidget,
    );
    expect(find.descendant(of: banner, matching: find.text('broken')),
        findsNothing);

    await tester.tap(find.text('源里的热门作品'));
    await tester.pump();
    expect(opened, 1, reason: '点卡片走 feed 的 open 动作（生产适配为直进源详情页）');
  });

  // 加载中的来源行此前是一条 2px 裸进度条：二十几个源就是二十几条无标签横线。
  // 现在加载中就渲染带源名的行头 + 行内小转圈，加载完卡片条在行头下面长出来。
  testWidgets('来源热门行加载中显示带源名的行头，而不是一条裸横线', (WidgetTester tester) async {
    final Completer<List<MangaDiscoverySourceItem>> pending =
        Completer<List<MangaDiscoverySourceItem>>();
    await tester.pumpWidget(wrap(MangaDiscoveryPage(
      sourceFeedsOverride: <MangaDiscoverySourceFeed>[
        MangaDiscoverySourceFeed(
          id: 'slow',
          name: '慢源',
          language: 'ja',
          loadPopular: () => pending.future,
        ),
      ],
    )));
    await tester.pump();
    await tester.pump();

    final Finder header =
        find.text(t.manga_discovery_source_popular(source: '慢源 (JA)'));
    expect(header, findsOneWidget, reason: '加载中就要能看出在等哪个源');
    expect(
      find.descendant(
        of: find.byType(MangaDiscoverySourceRow),
        matching: find.byType(FushiCircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);

    // 加载中就要把卡片条的高度占住，否则加载完成那一刻凭空插入一整条卡片高度，
    // 标题下方所有内容整体下移。`pumpAndSettle` 会跳过中间帧，钉不住这一条——
    // 必须在 pending 态直接量行高，再与 done 态比。
    final double pendingHeight =
        tester.getSize(find.byType(MangaDiscoverySourceRow)).height;

    pending.complete(<MangaDiscoverySourceItem>[_item('慢源的热门作品')]);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(MangaDiscoverySourceRow)).height,
      pendingHeight,
      reason: '加载完成不得改变行高（占位高度必须与卡片条一致）',
    );
    expect(header, findsOneWidget);
    expect(find.text('慢源的热门作品'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(MangaDiscoverySourceRow),
        matching: find.byType(FushiCircularProgressIndicator),
      ),
      findsNothing,
    );
  });

  // BUG-1710：合并前「发现」没有搜索框也没有来源筛选，来源清单在另一个同名
  // 「发现」tab 里。合并后这三样必须同处一页；重设计后来源清单挪到页首。
  testWidgets('头部有来源筛选下拉 + 搜索框，页首是「浏览来源」快捷条', (WidgetTester tester) async {
    await tester.pumpWidget(wrap(MangaDiscoveryPage(
      catalogOverride: const MangaSourceCatalog(
        mokuroEnabled: true,
        mihonSources: <MangaOnlineSourceRow>[_mihonSource],
      ),
      sourceFeedsOverride: <MangaDiscoverySourceFeed>[
        MangaDiscoverySourceFeed(
          id: MangaSourceCatalog.mihonSourceId(_mihonSource),
          name: '某在线源',
          language: 'ja',
          loadPopular: () async => <MangaDiscoverySourceItem>[
            _item('源里的热门作品'),
          ],
        ),
      ],
    )));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('discovery_source_menu')),
      findsOneWidget,
      reason: '用户口径：发现页缺来源筛选',
    );
    expect(
      find.byKey(const ValueKey<String>('discovery_search_field')),
      findsOneWidget,
      reason: '用户口径：发现页缺搜索栏',
    );
    final Finder browse = find.text(t.manga_discovery_sources_browse);
    expect(browse, findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('manga-source-mokuro')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('manga-mihon-mihon:pkg:1')),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(browse).dy,
      lessThan(
        tester
            .getTopLeft(find
                .text(t.manga_discovery_source_popular(source: '某在线源 (JA)')))
            .dy,
      ),
      reason: '来源快捷条在热门行之上，不必滚过全部热门行才找得到',
    );
    expect(
      find.byKey(const ValueKey<String>('manga_discovery_empty')),
      findsNothing,
    );
  });

  testWidgets('一个来源都没有时整页引导空态', (WidgetTester tester) async {
    await tester.pumpWidget(wrap(const MangaDiscoveryPage(
      catalogOverride: MangaSourceCatalog(),
      sourceFeedsOverride: <MangaDiscoverySourceFeed>[],
    )));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('manga_discovery_empty')),
      findsOneWidget,
    );
    expect(find.text(t.manga_discovery_empty_title), findsOneWidget);
    expect(
      find.text(t.manga_discovery_sources_browse),
      findsNothing,
      reason: '空态替代整个正文，不再叠一个空的来源节',
    );
    expect(
      find.byKey(const ValueKey<String>('manga_discovery_open_sources')),
      findsNothing,
      reason: '不在库页壳里时没有「来源」视图可去，不渲染点了没反应的按钮',
    );
  });

  testWidgets('选中具体来源后收窄：只留该源磁贴与它的热门网格', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(MangaDiscoveryPage(
      catalogOverride: const MangaSourceCatalog(
        mokuroEnabled: true,
        mihonSources: <MangaOnlineSourceRow>[_mihonSource],
      ),
      sourceFeedsOverride: <MangaDiscoverySourceFeed>[
        MangaDiscoverySourceFeed(
          id: MangaSourceCatalog.mihonSourceId(_mihonSource),
          name: '某在线源',
          language: 'ja',
          loadPopular: () async => <MangaDiscoverySourceItem>[
            for (int i = 0; i < 6; i++) _item('热门 $i'),
          ],
        ),
      ],
    )));
    await tester.pumpAndSettle();
    expect(find.byType(MangaDiscoverySourceRow), findsOneWidget);

    await tester
        .tap(find.byKey(const ValueKey<String>('discovery_source_menu')));
    await tester.pumpAndSettle();
    // DropdownMenu 会把条目渲染两遍（隐藏的一份只用来量宽度），可见的那份在后。
    await tester.tap(find.widgetWithText(MenuItemButton, '某在线源 (JA)').last);
    await tester.pumpAndSettle();

    expect(find.byType(MangaDiscoverySourceRow), findsNothing);
    expect(find.byType(MangaDiscoverySourceGrid), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('manga-source-mokuro')),
      findsNothing,
      reason: '没选中的来源磁贴跟着收起',
    );
    expect(
      find.byKey(const ValueKey<String>('manga-mihon-mihon:pkg:1')),
      findsOneWidget,
    );
    // 网格按宽度自适应列数：1200 宽下前两张并排、六张全部落在视口内。
    final double y0 = tester.getTopLeft(find.text('热门 0')).dy;
    final double y1 = tester.getTopLeft(find.text('热门 1')).dy;
    expect(y0, y1, reason: '网格同一行');
    expect(find.text('热门 5'), findsOneWidget);
  });

  testWidgets('网格加载失败给重试，重试真的重新拉取', (WidgetTester tester) async {
    int calls = 0;
    final String id = MangaSourceCatalog.mihonSourceId(_mihonSource);
    await tester.pumpWidget(wrap(MangaDiscoveryPage(
      catalogOverride: const MangaSourceCatalog(
        mihonSources: <MangaOnlineSourceRow>[_mihonSource],
      ),
      sourceFeedsOverride: <MangaDiscoverySourceFeed>[
        MangaDiscoverySourceFeed(
          id: id,
          name: '某在线源',
          language: 'ja',
          loadPopular: () async {
            calls++;
            if (calls <= 2) throw StateError('down');
            return <MangaDiscoverySourceItem>[_item('重试后出现')];
          },
        ),
      ],
    )));
    await tester.pumpAndSettle();
    expect(calls, 1);
    // 唯一的热门行也失败 = 全部失败：换成可重试的整块提示，而不是一条横幅。
    expect(
      find.byKey(const ValueKey<String>('manga_discovery_feeds_failed')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('manga_discovery_provider_warning')),
      findsNothing,
    );

    await tester
        .tap(find.byKey(const ValueKey<String>('discovery_source_menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, '某在线源 (JA)').last);
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text(t.manga_discovery_load_failed), findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey<String>('manga_discovery_retry')));
    await tester.pumpAndSettle();
    expect(calls, 3);
    expect(find.text('重试后出现'), findsOneWidget);
  });

  testWidgets('热门行全部失败：整块提示的重试让各行重新拉取', (WidgetTester tester) async {
    int calls = 0;
    await tester.pumpWidget(wrap(MangaDiscoveryPage(
      sourceFeedsOverride: <MangaDiscoverySourceFeed>[
        MangaDiscoverySourceFeed(
          id: 'flaky',
          name: '抖源',
          language: 'ja',
          loadPopular: () async {
            calls++;
            if (calls == 1) throw StateError('down');
            return <MangaDiscoverySourceItem>[_item('恢复后的作品')];
          },
        ),
      ],
    )));
    await tester.pumpAndSettle();
    expect(find.text(t.manga_discovery_load_failed), findsOneWidget);

    await tester
        .tap(find.byKey(const ValueKey<String>('manga_discovery_retry_all')));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('恢复后的作品'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('manga_discovery_feeds_failed')),
      findsNothing,
      reason: '重试成功后旧失败不得残留',
    );
  });

  group('单源网格翻页', () {
    Future<void> selectSource(WidgetTester tester) async {
      await tester
          .tap(find.byKey(const ValueKey<String>('discovery_source_menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, '某在线源 (JA)').last);
      await tester.pumpAndSettle();
    }

    MangaDiscoverySourceFeed pagedFeed(
      List<int> requested, {
      int pageSize = 40,
      int lastPage = 3,
      int? failOnPage,
    }) {
      return MangaDiscoverySourceFeed(
        id: MangaSourceCatalog.mihonSourceId(_mihonSource),
        name: '某在线源',
        language: 'ja',
        loadPopular: () async => <MangaDiscoverySourceItem>[_item('行首页')],
        loadPopularPage: (int page) async {
          requested.add(page);
          if (page == failOnPage) throw StateError('page $page down');
          return MangaDiscoverySourcePage(
            items: <MangaDiscoverySourceItem>[
              for (int i = 0; i < pageSize; i++) _item('第$page页 $i'),
            ],
            hasMore: page < lastPage,
          );
        },
      );
    }

    testWidgets('滚到离底 600 以内自动拉下一页，没有下一页就停', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final List<int> requested = <int>[];
      await tester.pumpWidget(wrap(MangaDiscoveryPage(
        catalogOverride: const MangaSourceCatalog(
          mihonSources: <MangaOnlineSourceRow>[_mihonSource],
        ),
        sourceFeedsOverride: <MangaDiscoverySourceFeed>[pagedFeed(requested)],
      )));
      await tester.pumpAndSettle();
      await selectSource(tester);
      expect(requested, <int>[1], reason: '首页撑满视口时不预取');
      expect(find.text('第1页 0'), findsOneWidget);

      final Finder scroll = find.byType(CustomScrollView);
      await tester.drag(scroll, const Offset(0, -3000));
      await tester.pumpAndSettle();
      expect(requested, <int>[1, 2], reason: '不用点「加载更多」');

      await tester.drag(scroll, const Offset(0, -6000));
      await tester.pumpAndSettle();
      expect(requested, <int>[1, 2, 3]);
      await tester.drag(scroll, const Offset(0, -6000));
      await tester.pumpAndSettle();
      expect(requested, <int>[1, 2, 3], reason: '第 3 页 hasMore=false');
      expect(find.text('第3页 39'), findsOneWidget);
    });

    testWidgets('首页不满一屏时自动接着拉，直到撑满或没有下一页', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final List<int> requested = <int>[];
      await tester.pumpWidget(wrap(MangaDiscoveryPage(
        catalogOverride: const MangaSourceCatalog(
          mihonSources: <MangaOnlineSourceRow>[_mihonSource],
        ),
        sourceFeedsOverride: <MangaDiscoverySourceFeed>[
          pagedFeed(requested, pageSize: 2),
        ],
      )));
      await tester.pumpAndSettle();
      await selectSource(tester);
      expect(requested, <int>[1, 2, 3], reason: '一屏两张时没有滚动事件可等');
    });

    testWidgets('翻页失败保留已有条目，页尾重试接着拉那一页', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final List<int> requested = <int>[];
      int? failOn = 2;
      await tester.pumpWidget(wrap(MangaDiscoveryPage(
        catalogOverride: const MangaSourceCatalog(
          mihonSources: <MangaOnlineSourceRow>[_mihonSource],
        ),
        sourceFeedsOverride: <MangaDiscoverySourceFeed>[
          MangaDiscoverySourceFeed(
            id: MangaSourceCatalog.mihonSourceId(_mihonSource),
            name: '某在线源',
            language: 'ja',
            loadPopular: () async => <MangaDiscoverySourceItem>[],
            loadPopularPage: (int page) async {
              requested.add(page);
              if (page == failOn) throw StateError('down');
              return MangaDiscoverySourcePage(
                items: <MangaDiscoverySourceItem>[
                  for (int i = 0; i < 24; i++) _item('第$page页 $i'),
                ],
                hasMore: page < 2,
              );
            },
          ),
        ],
      )));
      await tester.pumpAndSettle();
      await selectSource(tester);

      final Finder scroll = find.byType(CustomScrollView);
      await tester.drag(scroll, const Offset(0, -3000));
      await tester.pumpAndSettle();
      expect(requested, <int>[1, 2]);
      final Finder retry =
          find.byKey(const ValueKey<String>('manga_discovery_load_more_retry'));
      expect(retry, findsOneWidget);
      // 失败后继续滚动不会自己重打坏掉的那页。
      await tester.drag(scroll, const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(requested, <int>[1, 2]);

      failOn = null;
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(requested, <int>[1, 2, 2]);
      await tester.scrollUntilVisible(
        find.text('第2页 0'),
        300,
        scrollable: find
            .descendant(
              of: scroll,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('第2页 0'), findsOneWidget);
    });
  });

  testWidgets('行头「查看全部」打开来源目录；页头刷新重新拉取', (WidgetTester tester) async {
    int calls = 0;
    int catalogOpened = 0;
    await tester.pumpWidget(wrap(MangaDiscoveryPage(
      sourceFeedsOverride: <MangaDiscoverySourceFeed>[
        MangaDiscoverySourceFeed(
          id: 'ok',
          name: '好源',
          language: 'ja',
          loadPopular: () async {
            calls++;
            return <MangaDiscoverySourceItem>[_item('作品 $calls')];
          },
          openCatalog: (BuildContext context) => catalogOpened++,
        ),
      ],
    )));
    await tester.pumpAndSettle();
    expect(calls, 1);

    await tester.tap(
      find.byKey(const ValueKey<String>('manga_discovery_view_all_ok')),
    );
    await tester.pump();
    expect(catalogOpened, 1);

    await tester
        .tap(find.byKey(const ValueKey<String>('manga_discovery_refresh')));
    await tester.pumpAndSettle();
    expect(calls, 2, reason: '刷新让各热门行重新挂载、重新拉取');
    expect(find.text('作品 2'), findsOneWidget);
  });

  // PR #1707 审查：嵌进「浏览 › 发现」时页头不渲染，刷新曾随页头一起消失；
  // 「管理来源」引导只认库页壳，浏览页里空态没有去处。
  testWidgets('embedded 时刷新挪进搜索行，仍能重新拉取', (WidgetTester tester) async {
    int calls = 0;
    await tester.pumpWidget(wrap(MangaDiscoveryPage(
      embedded: true,
      sourceFeedsOverride: <MangaDiscoverySourceFeed>[
        MangaDiscoverySourceFeed(
          id: 'ok',
          name: '好源',
          language: 'ja',
          loadPopular: () async {
            calls++;
            return <MangaDiscoverySourceItem>[_item('作品 $calls')];
          },
        ),
      ],
    )));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text(t.library_view_discover), findsNothing);

    final Finder refresh =
        find.byKey(const ValueKey<String>('manga_discovery_refresh'));
    expect(refresh, findsOneWidget);
    await tester.tap(refresh);
    await tester.pumpAndSettle();
    expect(calls, 2);
  });

  testWidgets('宿主给了「管理来源」去处时空态出按钮并调用它', (WidgetTester tester) async {
    int opened = 0;
    await tester.pumpWidget(wrap(MangaDiscoveryPage(
      embedded: true,
      onOpenSources: () => opened++,
      catalogOverride: const MangaSourceCatalog(),
      sourceFeedsOverride: const <MangaDiscoverySourceFeed>[],
    )));
    await tester.pumpAndSettle();

    final Finder action =
        find.byKey(const ValueKey<String>('manga_discovery_open_sources'));
    expect(action, findsOneWidget);
    await tester.tap(action);
    await tester.pump();
    expect(opened, 1);
  });

  // PR #1707 审查：每行一个 SliverToBoxAdapter 会在进入本页时把全部来源的行一次
  // 建出来，对所有来源同时并发 loadPopular；行必须按可见范围懒建。
  testWidgets('热门行按可见范围懒建，不在进入时拉全部来源', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final Set<String> loaded = <String>{};
    await tester.pumpWidget(wrap(MangaDiscoveryPage(
      sourceFeedsOverride: <MangaDiscoverySourceFeed>[
        for (int i = 0; i < 30; i++)
          MangaDiscoverySourceFeed(
            id: 'feed$i',
            name: '源 $i',
            language: 'ja',
            loadPopular: () async {
              loaded.add('feed$i');
              return <MangaDiscoverySourceItem>[_item('源 $i 的作品')];
            },
          ),
      ],
    )));
    await tester.pumpAndSettle();

    expect(loaded, contains('feed0'));
    expect(loaded.length, lessThan(30), reason: '屏外的行不该在进入时就拉取');
  });
}
