import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/discovery/discovery_download_queue.dart';
import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/media_discovery_service.dart';
import 'package:fushi/src/media/discovery/media_discovery_source.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/media_discovery_page.dart';
import 'package:fushi/utils.dart';

import '../helpers/test_platform_services.dart';

/// 统一发现页的「不发请求」契约（BUG-1711）。
///
/// 用户在游戏发现页选「全部来源」时，页面曾把空搜索框当成目录浏览，扇出请求
/// 又被服务层按 `supportsBrowse` 筛成唯一一个目录型源，于是「全部来源」列出的
/// 其实是 alist.erogame.space 的根目录（两个文件夹）。修复后空查询在聚合模式下
/// 一个请求都不发，改成让用户先选来源；只支持搜索的单源同理（发出去只会换回
/// 一块 unsupported 牌坊）。
///
/// 断言点全部落在**真实行为**上：源上的调用计数必须是 0，而不是只看文案。

class _FakeSource extends MediaDiscoverySource {
  _FakeSource({
    required this.id,
    required this.displayName,
    required this.priority,
    required DiscoveryCapabilities capabilities,
  }) : _capabilities = capabilities;

  @override
  final String id;

  @override
  final String displayName;

  @override
  final int priority;

  final DiscoveryCapabilities _capabilities;

  int searchCalls = 0;
  int browseCalls = 0;

  @override
  DiscoveryCapabilities get capabilities => _capabilities;

  @override
  Future<ProviderBatchResult<DiscoveryResultPage>> search(
    DiscoveryRequest request,
  ) async {
    searchCalls++;
    return _page(<DiscoveryEntry>[
      DiscoveryResourceItem(
        sourceId: id,
        title: '$id-hit',
        id: '$id-1',
        kind: request.kind,
        payloadKind: DiscoveryPayloadKind.httpFile,
      ),
    ]);
  }

  @override
  Future<ProviderBatchResult<DiscoveryResultPage>> browse(
    DiscoveryRequest request,
  ) async {
    browseCalls++;
    return _page(<DiscoveryEntry>[
      DiscoveryFolder(sourceId: id, title: '$id-folder', path: '/f'),
    ]);
  }

  ProviderBatchResult<DiscoveryResultPage> _page(List<DiscoveryEntry> items) {
    return ProviderBatchResult<DiscoveryResultPage>.success(
      <DiscoveryResultPage>[
        DiscoveryResultPage(entries: items, page: 1, hasMore: false),
      ],
    );
  }
}

class _FakeAppModel extends AppModel {
  _FakeAppModel(this._service) : super(testPlatformServices());

  final MediaDiscoveryService _service;

  @override
  MediaDiscoveryService get mediaDiscoveryService => _service;

  @override
  Set<String> get discoveryDisabledSourceIds => const <String>{};

  @override
  DiscoveryDownloadQueue get discoveryDownloadQueue => _queue;

  late final DiscoveryDownloadQueue _queue = DiscoveryDownloadQueue(
    resolvePayload: (DiscoveryResourceItem item) async =>
        throw UnimplementedError(),
    importer: (DiscoveryDownloadTask task, File file) async =>
        const DiscoveryImportOutcome(),
  );
}

void main() {
  late _FakeSource searchOnly;
  late _FakeSource browsable;
  late MediaDiscoveryService service;
  late _FakeAppModel appModel;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    searchOnly = _FakeSource(
      id: 'search-only',
      displayName: 'SearchOnly',
      priority: 1,
      capabilities: DiscoveryCapabilities(
        kinds: <DiscoveryMediaKind>{DiscoveryMediaKind.game},
      ),
    );
    browsable = _FakeSource(
      id: 'browsable',
      displayName: 'Browsable',
      priority: 2,
      capabilities: DiscoveryCapabilities(
        kinds: <DiscoveryMediaKind>{DiscoveryMediaKind.game},
        supportsBrowse: true,
      ),
    );
    service = MediaDiscoveryService(
      sources: <MediaDiscoverySource>[searchOnly, browsable],
    );
    appModel = _FakeAppModel(service);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((_) => appModel)],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: const MediaDiscoveryPage(
                kinds: <DiscoveryMediaKind>[DiscoveryMediaKind.game],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('「全部来源」+ 空查询：列出来源、一个请求都不发', (WidgetTester tester) async {
    await pumpPage(tester);

    expect(find.text(t.discovery_source_pick_hint), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('discovery_source_pick_search-only')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('discovery_source_pick_browsable')),
      findsOneWidget,
    );
    // 真行为断言：目录型源的根目录绝不能被冒充成「全部来源」的聚合结果。
    expect(browsable.browseCalls, 0);
    expect(browsable.searchCalls, 0);
    expect(searchOnly.searchCalls, 0);
    expect(find.text('browsable-folder'), findsNothing);
  });

  testWidgets('头部走共享组件：来源下拉与搜索框同时在场', (WidgetTester tester) async {
    await pumpPage(tester);

    expect(
      find.byKey(const ValueKey<String>('discovery_source_menu')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('discovery_search_field')),
      findsOneWidget,
    );
  });

  testWidgets('选只支持搜索的来源：提示要关键词，仍不发请求', (WidgetTester tester) async {
    await pumpPage(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('discovery_source_pick_search-only')),
    );
    await tester.pumpAndSettle();

    expect(find.text(t.discovery_source_query_required), findsOneWidget);
    expect(searchOnly.searchCalls, 0);
    expect(searchOnly.browseCalls, 0);
  });

  testWidgets('选目录型来源：才真的发 browse，并在条目上标出来源名', (WidgetTester tester) async {
    await pumpPage(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('discovery_source_pick_browsable')),
    );
    await tester.pumpAndSettle();

    expect(browsable.browseCalls, 1);
    expect(find.text('browsable-folder'), findsOneWidget);
    // 目录条目必须带来源名副标题，否则用户看不出这是哪个站的目录。
    // 只找条目内部的来源名——下拉本身也显示 'Browsable'，宽松匹配会假绿。
    expect(
      find.descendant(
        of: find.widgetWithText(FushiListItem, 'browsable-folder'),
        matching: find.text('Browsable'),
      ),
      findsOneWidget,
    );
  });

  // BUG-1768：搜索命中一个**同名目录**后点进去，旧实现仍带着关键词发请求
  // （`query` 压过 `path`，`DiscoveryRequest.isSearch` 为真 → `path` 被丢弃），
  // 于是又收到同一个目录，可以无限点下去，面包屑变成
  // 「WHITE ALBUM2 / WHITE ALBUM2 / …」。
  //
  // 这里用真实站点的行为建模：`search` 是**全站递归**的，无论 path 给什么都
  // 会把那个同名目录再吐一遍——所以「没有无限嵌套」唯一可能的原因就是这次
  // 请求真的走了 browse。断言落在源上的调用种类与收到的 path 上，不看文案。
  testWidgets('搜到同名目录后点进去：走 browse 且带路径，不再自嵌套', (WidgetTester tester) async {
    final _RecursiveSearchSource site = _RecursiveSearchSource();
    service = MediaDiscoveryService(sources: <MediaDiscoverySource>[site]);
    appModel = _FakeAppModel(service);
    await pumpPage(tester);

    // 选中该源 → 提交搜索。
    await tester.tap(
      find.byKey(const ValueKey<String>('discovery_source_pick_site')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('discovery_search_field')),
      'WHITE ALBUM2',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    // 搜索框里也有 'WHITE ALBUM2'，断言必须限定在列表条目里，否则恒真。
    final Finder folderItem =
        find.widgetWithText(FushiListItem, 'WHITE ALBUM2');
    expect(site.searchCalls, 1);
    expect(folderItem, findsOneWidget);
    // 选中目录型源时已经 browse 过一次根目录，基线从这里取。
    final int browseBefore = site.browseCalls;

    // 点进那个同名目录。
    await tester.tap(folderItem);
    await tester.pumpAndSettle();

    // 核心断言：这次是 browse，而且带上了目录路径。
    expect(site.browseCalls, browseBefore + 1);
    expect(site.searchCalls, 1, reason: '进目录不该重发搜索');
    expect(site.lastBrowsePath, '/games/WHITE ALBUM2');
    // 列表换成了目录真实内容，同名目录不再作为自己的子项出现。
    expect(find.widgetWithText(FushiListItem, 'disc1.rar'), findsOneWidget);
    expect(folderItem, findsNothing);

    // 返回：回到那次搜索的结果，而不是退到源根目录。
    await tester.tap(
      find.byKey(const ValueKey<String>('discovery_breadcrumb_up')),
    );
    await tester.pumpAndSettle();
    expect(site.searchCalls, 2);
    expect(site.browseCalls, browseBefore + 1, reason: '返回不该再 browse 一次');
    expect(folderItem, findsOneWidget);
  });

  // BUG-1770：整源失败不得显示成「无结果」。失败徽标原先只挂在非空列表分支上，
  // 空列表直接返回 discovery_empty，于是「请求全挂了」和「真的没东西」在界面上
  // 长得一模一样——实例是 erogame.space 的 fs/list 对匿名访问恒返回
  // object not found，点进任何目录都只看到「无结果」。
  testWidgets('唯一来源整个失败：显示不可用而不是「无结果」', (WidgetTester tester) async {
    final _FailingSource dead = _FailingSource();
    service = MediaDiscoveryService(sources: <MediaDiscoverySource>[dead]);
    appModel = _FakeAppModel(service);
    await pumpPage(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('discovery_source_pick_dead')),
    );
    await tester.pumpAndSettle();

    expect(dead.browseCalls, 1);
    expect(
        find.textContaining(t.discovery_sources_unavailable), findsOneWidget);
    expect(find.text(t.discovery_empty), findsNothing);
  });

  // 反向：源成功了但确实没条目，仍然是「无结果」——别把上面那条修成一律报错。
  testWidgets('来源成功但结果为空：仍是「无结果」', (WidgetTester tester) async {
    final _EmptySource empty = _EmptySource();
    service = MediaDiscoveryService(sources: <MediaDiscoverySource>[empty]);
    appModel = _FakeAppModel(service);
    await pumpPage(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('discovery_source_pick_empty')),
    );
    await tester.pumpAndSettle();

    expect(empty.browseCalls, 1);
    expect(find.text(t.discovery_empty), findsOneWidget);
    expect(find.textContaining(t.discovery_sources_unavailable), findsNothing);
  });
}

/// browse/search 一律失败的源（模拟站点 API 整体不可用）。
class _FailingSource extends MediaDiscoverySource {
  int browseCalls = 0;

  @override
  String get id => 'dead';

  @override
  String get displayName => 'Dead';

  @override
  int get priority => 1;

  @override
  DiscoveryCapabilities get capabilities => DiscoveryCapabilities(
        kinds: <DiscoveryMediaKind>{DiscoveryMediaKind.game},
        supportsBrowse: true,
      );

  @override
  Future<ProviderBatchResult<DiscoveryResultPage>> search(
    DiscoveryRequest request,
  ) async =>
      throw StateError('down');

  @override
  Future<ProviderBatchResult<DiscoveryResultPage>> browse(
    DiscoveryRequest request,
  ) async {
    browseCalls++;
    throw StateError('down');
  }
}

/// 成功但零条目的源。
class _EmptySource extends MediaDiscoverySource {
  int browseCalls = 0;

  @override
  String get id => 'empty';

  @override
  String get displayName => 'Empty';

  @override
  int get priority => 1;

  @override
  DiscoveryCapabilities get capabilities => DiscoveryCapabilities(
        kinds: <DiscoveryMediaKind>{DiscoveryMediaKind.game},
        supportsBrowse: true,
      );

  @override
  Future<ProviderBatchResult<DiscoveryResultPage>> search(
    DiscoveryRequest request,
  ) async =>
      _page();

  @override
  Future<ProviderBatchResult<DiscoveryResultPage>> browse(
    DiscoveryRequest request,
  ) async {
    browseCalls++;
    return _page();
  }

  ProviderBatchResult<DiscoveryResultPage> _page() {
    return ProviderBatchResult<DiscoveryResultPage>.success(
      <DiscoveryResultPage>[
        DiscoveryResultPage(
          entries: const <DiscoveryEntry>[],
          page: 1,
          hasMore: false,
        ),
      ],
    );
  }
}

/// 建模 AList 那类**全站递归搜索**的源：`search` 忽略位置、恒从根递归，命中集
/// 里天然包含与关键词同名的目录本身；`browse` 才按 path 返回该目录的真实子项。
class _RecursiveSearchSource extends MediaDiscoverySource {
  int searchCalls = 0;
  int browseCalls = 0;
  String? lastBrowsePath;

  @override
  String get id => 'site';

  @override
  String get displayName => 'Site';

  @override
  int get priority => 1;

  @override
  DiscoveryCapabilities get capabilities => DiscoveryCapabilities(
        kinds: <DiscoveryMediaKind>{DiscoveryMediaKind.game},
        supportsBrowse: true,
      );

  @override
  Future<ProviderBatchResult<DiscoveryResultPage>> search(
    DiscoveryRequest request,
  ) async {
    searchCalls++;
    return _page(<DiscoveryEntry>[
      DiscoveryFolder(
        sourceId: id,
        title: 'WHITE ALBUM2',
        path: '/games/WHITE ALBUM2',
      ),
    ]);
  }

  @override
  Future<ProviderBatchResult<DiscoveryResultPage>> browse(
    DiscoveryRequest request,
  ) async {
    browseCalls++;
    lastBrowsePath = request.path;
    return _page(<DiscoveryEntry>[
      DiscoveryResourceItem(
        sourceId: id,
        title: 'disc1.rar',
        id: '${request.path}/disc1.rar',
        kind: request.kind,
        payloadKind: DiscoveryPayloadKind.httpFile,
      ),
    ]);
  }

  ProviderBatchResult<DiscoveryResultPage> _page(List<DiscoveryEntry> items) {
    return ProviderBatchResult<DiscoveryResultPage>.success(
      <DiscoveryResultPage>[
        DiscoveryResultPage(entries: items, page: 1, hasMore: false),
      ],
    );
  }
}
