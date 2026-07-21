import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_search.dart';

import '../helpers/test_platform_services.dart';

/// 设置搜索（T4）：纯过滤函数的行为契约 + 主页/行渲染接线的源码守卫。
/// 过滤不求值任何 visibility/value 谓词，故可用手工构造的 schema 片段直接测。
void main() {
  SettingsDestination dest(String title, {String? section}) {
    return SettingsDestination(
      id: SettingsDestinationId.reading,
      title: title,
      icon: Icons.settings,
      sections: const <SettingsSection>[],
    );
  }

  SettingsSearchEntry entry({
    required String destTitle,
    String? sectionTitle,
    required String id,
    required String title,
    String? subtitle,
  }) {
    return SettingsSearchEntry(
      destination: dest(destTitle),
      sectionTitle: sectionTitle,
      item: SettingsActionItem(
        id: id,
        title: title,
        subtitle: subtitle,
        onTap: (_) {},
      ),
    );
  }

  final List<SettingsSearchEntry> corpus = <SettingsSearchEntry>[
    entry(
      destTitle: '阅读',
      sectionTitle: '排版',
      id: 'reading.font_size',
      title: '字号',
    ),
    entry(
      destTitle: '查词',
      sectionTitle: '弹窗窗口',
      id: 'lookup.popup_max_width',
      title: '弹窗最大宽度',
    ),
    entry(
      destTitle: '查词',
      sectionTitle: '词条内容',
      id: 'lookup.font',
      title: '词典字号',
      subtitle: '弹窗内文字大小',
    ),
    entry(
      destTitle: '系统',
      sectionTitle: '更新',
      id: 'system.channel',
      title: 'Update channel',
    ),
  ];

  test('empty / blank query yields no results', () {
    expect(filterSettingsEntries(corpus, ''), isEmpty);
    expect(filterSettingsEntries(corpus, '   '), isEmpty);
  });

  test('title prefix ranks before title-contains, then metadata matches', () {
    final List<String> ids = filterSettingsEntries(corpus, '字号')
        .map((SettingsSearchEntry e) => e.item.id)
        .toList();
    // 「字号」标题前缀命中排最前；「词典字号」标题包含其次；副标题/分区不含
    // 「字号」的不出现。
    expect(ids, <String>['reading.font_size', 'lookup.font']);
  });

  test('matches section title and destination title as metadata', () {
    final List<String> ids = filterSettingsEntries(corpus, '弹窗')
        .map((SettingsSearchEntry e) => e.item.id)
        .toList();
    // 标题命中（弹窗最大宽度）排最前；副标题/分区命中（词典字号）随后。
    expect(ids, <String>['lookup.popup_max_width', 'lookup.font']);
  });

  test('query is case-insensitive for latin text', () {
    final List<String> ids = filterSettingsEntries(corpus, 'update')
        .map((SettingsSearchEntry e) => e.item.id)
        .toList();
    expect(ids, <String>['system.channel']);
  });

  test('maxResults caps the list', () {
    final List<SettingsSearchEntry> many = List<SettingsSearchEntry>.generate(
      60,
      (int i) => entry(
        destTitle: 'D',
        id: 'x.$i',
        title: 'same title $i',
      ),
    );
    expect(filterSettingsEntries(many, 'same title'), hasLength(50));
  });

  test('text/number items are searchable by their titles', () {
    final List<SettingsSearchEntry> entries = <SettingsSearchEntry>[
      SettingsSearchEntry(
        destination: dest('查词'),
        sectionTitle: '词典服务',
        item: SettingsTextItem(
          id: 'lookup.proxy',
          title: '更新代理地址',
          value: (_) => '',
          onChanged: (_, __) {},
        ),
      ),
      SettingsSearchEntry(
        destination: dest('查词'),
        sectionTitle: '词典服务',
        item: SettingsNumberItem(
          id: 'lookup.debounce',
          title: '搜索防抖延迟',
          value: (_) => 0,
          onChanged: (_, __) {},
        ),
      ),
    ];
    expect(
      filterSettingsEntries(entries, '代理')
          .map((SettingsSearchEntry e) => e.item.id),
      <String>['lookup.proxy'],
    );
    expect(
      filterSettingsEntries(entries, '防抖')
          .map((SettingsSearchEntry e) => e.item.id),
      <String>['lookup.debounce'],
    );
  });

  test('custom item opts into search via searchTitle', () {
    final SettingsCustomItem optedIn = SettingsCustomItem(
      id: 'appearance.theme_picker',
      searchTitle: '主题',
      builder: (_) => const SizedBox.shrink(),
    );
    final SettingsCustomItem optedOut = SettingsCustomItem(
      id: 'appearance.mystery',
      builder: (_) => const SizedBox.shrink(),
    );
    // 可搜索标题：opt-in 用 searchTitle，未声明保持空（= 不可搜）。
    expect(settingsItemSearchTitle(optedIn), '主题');
    expect(settingsItemSearchTitle(optedOut), '');

    final List<SettingsSearchEntry> entries = <SettingsSearchEntry>[
      SettingsSearchEntry(destination: dest('外观'), item: optedIn),
    ];
    final List<SettingsSearchEntry> hits = filterSettingsEntries(entries, '主题');
    expect(hits.map((SettingsSearchEntry e) => e.item.id),
        <String>['appearance.theme_picker']);
    // 打分/展示用的 entry.title 与 searchTitle 同源（结果行不显示空标题）。
    expect(hits.single.title, '主题');
  });

  testWidgets(
      'flattenVisibleSettings indexes titled new kinds and opted-in custom '
      'rows, skips untitled custom rows', (WidgetTester tester) async {
    late SettingsContext sctx;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              sctx = SettingsContext(
                context: context,
                appModel: _SearchTestAppModel(),
                ref: ref,
                readerSource: ReaderHibikiSource.instance,
                refresh: () {},
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    final List<SettingsDestination> destinations = <SettingsDestination>[
      SettingsDestination(
        id: SettingsDestinationId.lookup,
        title: '查词',
        icon: Icons.search,
        sections: <SettingsSection>[
          SettingsSection(
            title: '服务',
            items: <SettingsItem>[
              SettingsTextItem(
                id: 'lookup.proxy',
                title: '更新代理地址',
                value: (_) => '',
                onChanged: (_, __) {},
              ),
              SettingsNumberItem(
                id: 'lookup.debounce',
                title: '搜索防抖延迟',
                value: (_) => 0,
                onChanged: (_, __) {},
              ),
              SettingsCustomItem(
                id: 'lookup.theme_picker',
                searchTitle: '主题',
                builder: (_) => const SizedBox.shrink(),
              ),
              SettingsCustomItem(
                id: 'lookup.untitled_custom',
                builder: (_) => const SizedBox.shrink(),
              ),
            ],
          ),
        ],
      ),
    ];

    final List<String> ids = flattenVisibleSettings(destinations, sctx)
        .map((SettingsSearchEntry e) => e.item.id)
        .toList();
    expect(ids, <String>[
      'lookup.proxy',
      'lookup.debounce',
      'lookup.theme_picker',
    ]);
  });

  test('home page wires search field, results and reveal hook', () {
    final String home =
        File('lib/src/settings/settings_home_page.dart').readAsStringSync();
    expect(home, contains('t.settings_search_hint'));
    expect(home, contains('filterSettingsEntries('));
    expect(home, contains('flattenVisibleSettings('));
    expect(home, contains('SettingsSearchReveal.pendingItemId'));
    // 宽屏选中分类、窄屏 push 详情两条路径都要接。
    expect(
        home, contains('SettingsDetailPage(destination: entry.destination)'));
  });

  test('schema item consumes the reveal hook exactly once', () {
    final String widgets = File('lib/src/settings/settings_schema_widgets.dart')
        .readAsStringSync();
    expect(widgets,
        contains('if (SettingsSearchReveal.pendingItemId == item.id)'));
    expect(widgets, contains('SettingsSearchReveal.pendingItemId = null'));
    expect(widgets, contains('SettingsRevealTarget(child: row)'));
  });

  test('reveal target scrolls into view after the first frame', () {
    final String search =
        File('lib/src/settings/settings_search.dart').readAsStringSync();
    // 滚动必须委托 HibikiFocusScroll（焦点架构守卫禁止 lib/src 自持
    // Scrollable.ensureVisible，见 focus_architecture_static_test）。
    expect(search, contains('HibikiFocusScroll.ensureVisible('));
    expect(search, contains('addPostFrameCallback'));
  });
}

/// flatten 只求值 visibility 谓词（本测试全为 null），appModel 永不被触碰；
/// 轻量构造即可。
class _SearchTestAppModel extends AppModel {
  _SearchTestAppModel() : super(testPlatformServices());
}
