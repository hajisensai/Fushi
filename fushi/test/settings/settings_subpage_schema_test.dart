import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_widgets.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

import '../helpers/test_platform_services.dart';

/// C0（同步/互联 UI 排版重组的框架前置）：
/// * [SettingsNavigationItem.child] 子 schema 页——行是真正的 schema item，进搜索、
///   进覆盖遍历，不再靠 `bodySearchEntries` 手工登记（消掉那个特殊情况）。
/// * [SettingsStatusItem] 一等状态行——替换四处手拼的 `SettingsCustomItem`。
void main() {
  late SettingsContext sctx;
  int refreshes = 0;

  Future<void> pumpContext(WidgetTester tester, {Widget? child}) async {
    refreshes = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (BuildContext context, WidgetRef ref, _) {
                sctx = SettingsContext(
                  context: context,
                  appModel: _TestAppModel(),
                  ref: ref,
                  readerSource: ReaderFushiSource.instance,
                  refresh: () => refreshes++,
                );
                return child ?? const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );
  }

  SettingsDestination childPage({bool visible = true}) => SettingsDestination(
        id: SettingsDestinationId.syncBackup,
        title: '子页',
        icon: Icons.folder_outlined,
        visible: (_) => visible,
        sections: <SettingsSection>[
          SettingsSection(
            title: '分区',
            items: <SettingsItem>[
              SettingsSwitchItem(
                id: 'c.x',
                title: '子页开关',
                value: (_) => true,
                onChanged: (_, __) {},
              ),
            ],
          ),
          SettingsSection(
            items: <SettingsItem>[
              const SettingsStatusItem(
                id: 'c.status',
                title: '状态行',
                subtitle: '正在运行',
              ),
            ],
          ),
        ],
      );

  SettingsNavigationItem navTo(SettingsDestination Function() child) =>
      SettingsNavigationItem(id: 'p.sub', title: '进入子页', child: child);

  SettingsDestination parentPage(SettingsNavigationItem nav) =>
      SettingsDestination(
        id: SettingsDestinationId.syncBackup,
        title: 'Parent',
        icon: Icons.sync,
        sections: <SettingsSection>[
          SettingsSection(
            title: 'A',
            items: <SettingsItem>[
              SettingsSwitchItem(
                id: 'p.a',
                title: '父页开关',
                value: (_) => true,
                onChanged: (_, __) {},
              ),
              nav,
            ],
          ),
        ],
      );

  group('搜索索引递归进子页', () {
    testWidgets('子页的行进索引：destination 指顶层、subPagePath 记链、面包屑带子页名',
        (WidgetTester tester) async {
      await pumpContext(tester);
      final SettingsNavigationItem nav = navTo(childPage);
      final SettingsDestination parent = parentPage(nav);

      final List<SettingsSearchEntry> entries =
          flattenVisibleSettings(<SettingsDestination>[parent], sctx);

      expect(entries.map((SettingsSearchEntry e) => e.item.id),
          <String>['p.a', 'p.sub', 'c.x', 'c.status']);
      final SettingsSearchEntry cx =
          entries.firstWhere((SettingsSearchEntry e) => e.item.id == 'c.x');
      expect(identical(cx.destination, parent), isTrue);
      expect(cx.subPagePath, <SettingsNavigationItem>[nav]);
      expect(cx.sectionTitle, '子页 › 分区');
      expect(settingsSearchBreadcrumb(cx), 'Parent › 子页 › 分区');
      final SettingsSearchEntry status = entries
          .firstWhere((SettingsSearchEntry e) => e.item.id == 'c.status');
      expect(status.sectionTitle, '子页', reason: '无题分区只显示子页名');
      expect(status.title, '状态行', reason: '状态行默认可搜');
      // 顶层行的既有语义不变：无路径、分区名原样。
      final SettingsSearchEntry pa =
          entries.firstWhere((SettingsSearchEntry e) => e.item.id == 'p.a');
      expect(pa.subPagePath, isEmpty);
      expect(pa.sectionTitle, 'A');
    });

    testWidgets('子页 visible=false：导航行仍可搜，子页里的行不进索引',
        (WidgetTester tester) async {
      await pumpContext(tester);
      final SettingsDestination parent =
          parentPage(navTo(() => childPage(visible: false)));

      final List<String> ids =
          flattenVisibleSettings(<SettingsDestination>[parent], sctx)
              .map((SettingsSearchEntry e) => e.item.id)
              .toList();

      expect(ids, <String>['p.a', 'p.sub']);
    });

    testWidgets('子页里再套子页：路径按进入顺序累积', (WidgetTester tester) async {
      await pumpContext(tester);
      final SettingsNavigationItem inner = navTo(childPage);
      final SettingsNavigationItem outer = SettingsNavigationItem(
        id: 'p.mid',
        title: '中间页',
        child: () => SettingsDestination(
          id: SettingsDestinationId.syncBackup,
          title: '中间',
          icon: Icons.layers_outlined,
          sections: <SettingsSection>[
            SettingsSection(items: <SettingsItem>[inner]),
          ],
        ),
      );
      final SettingsDestination parent = parentPage(outer);

      final SettingsSearchEntry cx =
          flattenVisibleSettings(<SettingsDestination>[parent], sctx)
              .firstWhere((SettingsSearchEntry e) => e.item.id == 'c.x');

      expect(cx.subPagePath, <SettingsNavigationItem>[outer, inner]);
      expect(cx.sectionTitle, '中间 › 子页 › 分区');
    });
  });

  group('渲染', () {
    testWidgets('带 child 的导航行：点击推 SettingsDetailPage.subPage（不是 builder 页）',
        (WidgetTester tester) async {
      WidgetBuilder? pushed;
      await pumpContext(
        tester,
        child: Builder(
          builder: (BuildContext context) => SettingsSchemaItem(
            item: navTo(childPage),
            settingsContext: sctx,
            showIcons: false,
            routeBuilder: (BuildContext ctx, WidgetBuilder builder) {
              pushed = builder;
              return MaterialPageRoute<void>(
                  builder: (_) => const SizedBox.shrink());
            },
          ),
        ),
      );

      await tester.tap(find.text('进入子页'));
      await tester.pump();

      expect(pushed, isNotNull, reason: '导航行必须经 routeBuilder 推页');
      final Widget page = pushed!(tester.element(find.byType(Scaffold)));
      expect(page, isA<SettingsDetailPage>());
      final SettingsDetailPage detail = page as SettingsDetailPage;
      expect(detail.destination, isNull);
      expect(detail.subPageBuilder, isNotNull);
      expect(detail.subPageBuilder!().title, '子页');
    });

    testWidgets('状态行：标题 + 运行期副标题；无动作时不渲染按钮', (WidgetTester tester) async {
      int port = 41000;
      await pumpContext(
        tester,
        // sctx 在 Consumer 构建时才赋值：行必须在其之后的 Builder 里构造。
        child: Builder(
          builder: (BuildContext context) => SettingsSchemaItem(
            item: SettingsStatusItem(
              id: 's',
              title: '主机服务',
              subtitleBuilder: (_) => '端口 $port',
            ),
            settingsContext: sctx,
            showIcons: false,
            routeBuilder: (_, WidgetBuilder b) =>
                MaterialPageRoute<void>(builder: b),
          ),
        ),
      );

      expect(find.byType(AdaptiveSettingsRow), findsOneWidget);
      expect(find.text('主机服务'), findsOneWidget);
      expect(find.text('端口 41000'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets('状态行：有动作时渲染行尾按钮，点击调 onAction 并 refresh',
        (WidgetTester tester) async {
      int calls = 0;
      await pumpContext(
        tester,
        child: Builder(
          builder: (BuildContext context) => SettingsSchemaItem(
            item: SettingsStatusItem(
              id: 's',
              title: '账号',
              subtitle: 'user@example.com',
              actionLabel: '退出',
              onAction: (_) async => calls++,
            ),
            settingsContext: sctx,
            showIcons: false,
            routeBuilder: (_, WidgetBuilder b) =>
                MaterialPageRoute<void>(builder: b),
          ),
        ),
      );

      expect(find.widgetWithText(FilledButton, '退出'), findsOneWidget);
      await tester.tap(find.text('退出'));
      await tester.pump();
      expect(calls, 1);
      expect(refreshes, 1);
    });
  });

  group('源码守卫：子页与状态行走框架，不走逃生口', () {
    String read(String path) {
      final File f = File(path);
      expect(f.existsSync(), isTrue, reason: '$path 不存在（请从 fushi/ 包根跑测试）');
      return f.readAsStringSync();
    }

    test('渲染分发：状态行有专属分支；child 导航行推 SettingsDetailPage.subPage', () {
      final String widgets =
          read('lib/src/settings/settings_schema_widgets.dart');
      expect(widgets, contains('SettingsStatusItem status => _status(status)'));
      expect(widgets, contains('SettingsDetailPage.subPage(child)'));
    });

    test('搜索：索引递归进子页；命中后逐级推子页', () {
      expect(read('lib/src/settings/settings_search.dart'),
          contains('_flattenPageInto('));
      expect(read('lib/src/settings/settings_home_page.dart'),
          contains('entry.subPagePath'));
    });

    test('详情页：子页靠闭包取新鲜树，不按 id 到顶层找', () {
      final String page = read('lib/src/settings/settings_detail_page.dart');
      expect(page, contains('SettingsDetailPage.subPage('));
      expect(page, contains('if (subPage != null) return subPage();'));
    });
  });
}

class _TestAppModel extends AppModel {
  _TestAppModel() : super(testPlatformServices());
}
