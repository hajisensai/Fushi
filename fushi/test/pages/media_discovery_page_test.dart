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
}
