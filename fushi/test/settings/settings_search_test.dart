import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_appearance.dart';
import 'package:fushi/src/settings/settings_search.dart';

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
                readerSource: ReaderFushiSource.instance,
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

  test('appearance theme and language selectors are now searchable (阶段C)', () {
    // 主题/语言等是 SettingsCustomItem（自绘行），阶段 C 给它们补 searchTitle
    // （复用各自既有标题），此前空标题=不可搜，现在应能被搜索命中。
    final SettingsDestination appearance = buildAppearanceDestination();
    final Map<String, SettingsItem> byId = <String, SettingsItem>{
      for (final SettingsSection s in appearance.sections)
        for (final SettingsItem i in s.items) i.id: i,
    };
    final SettingsItem theme = byId['appearance.theme']!;
    final SettingsItem language = byId['appearance.language']!;
    // 声明了 searchTitle → 可搜（非空）。
    expect(settingsItemSearchTitle(theme), isNotEmpty);
    expect(settingsItemSearchTitle(language), isNotEmpty);

    final List<SettingsSearchEntry> entries = <SettingsSearchEntry>[
      SettingsSearchEntry(destination: appearance, item: theme),
      SettingsSearchEntry(destination: appearance, item: language),
    ];
    // 用各自的 searchTitle 精确检索都能命中（与本机 locale 无关）。
    expect(
      filterSettingsEntries(entries, settingsItemSearchTitle(theme))
          .map((SettingsSearchEntry e) => e.item.id),
      contains('appearance.theme'),
    );
    expect(
      filterSettingsEntries(entries, settingsItemSearchTitle(language))
          .map((SettingsSearchEntry e) => e.item.id),
      contains('appearance.language'),
    );
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
    // 滚动必须委托 FushiFocusScroll（焦点架构守卫禁止 lib/src 自持
    // Scrollable.ensureVisible，见 focus_architecture_static_test）。
    expect(search, contains('FushiFocusScroll.ensureVisible('));
    expect(search, contains('addPostFrameCallback'));
  });

  test('阶段F：搜索「快捷键」同时命中快捷键设置导航项与剪贴板查词行（标题命中优先于摘要命中）', () {
    // 术语统一（热键→快捷键）后：快捷键设置导航项标题含「快捷键」（标题命中，
    // 排前）；剪贴板查词行标题不含、但摘要「…全局快捷键…」含（摘要命中，排后）。
    // 摘要参与打分本就在 filterSettingsEntries 的元数据层（e.item.subtitle），
    // 故根因是术语不一致而非打分缺失——本测试锁住修好后两行都能被搜到。
    final List<SettingsSearchEntry> entries = <SettingsSearchEntry>[
      entry(
        destTitle: '系统',
        sectionTitle: '通用',
        id: 'system.keyboard_shortcuts',
        title: '快捷键设置',
      ),
      entry(
        destTitle: '查词',
        sectionTitle: '剪贴板与全局查词',
        id: 'lookup.desktop_clipboard',
        title: '监听剪贴板弹出查词窗',
        subtitle: '监听剪贴板 + 全局快捷键弹出查词窗（桌面·实验性）',
      ),
    ];
    final List<String> ids = filterSettingsEntries(entries, '快捷键')
        .map((SettingsSearchEntry e) => e.item.id)
        .toList();
    expect(
        ids, <String>['system.keyboard_shortcuts', 'lookup.desktop_clipboard']);
  });

  test('阶段F：zh-CN 设置文案已把「热键」统一为「快捷键」', () {
    final String zh =
        File('lib/i18n/strings_zh-CN.i18n.json').readAsStringSync();
    // 剪贴板查词 hint 现含「全局快捷键」，可被搜索命中。
    expect(zh, contains('全局快捷键弹出查词窗'));
    // 三处旧「热键」全部改掉，zh-CN 不得残留。
    expect(zh, isNot(contains('热键')));
  });

  test('阶段F/G：搜索面包屑在分区与分类同名时去重', () {
    SettingsSearchEntry make(String dest, String? section) {
      return SettingsSearchEntry(
        destination: SettingsDestination(
          id: SettingsDestinationId.system,
          title: dest,
          icon: Icons.settings,
          sections: const <SettingsSection>[],
        ),
        sectionTitle: section,
        item: SettingsActionItem(id: 'x', title: 'x', onTap: (_) {}),
      );
    }

    // 分区名为空 / 与分类同名 → 只显示分类（消灭「系统 › 系统」整类重复）。
    expect(settingsSearchBreadcrumb(make('系统', '系统')), '系统');
    expect(settingsSearchBreadcrumb(make('系统', null)), '系统');
    expect(settingsSearchBreadcrumb(make('系统', '')), '系统');
    // 分区名有独立含义 → 拼成「分类 › 分区」。
    expect(settingsSearchBreadcrumb(make('系统', '更新')), '系统 › 更新');
  });
}

/// flatten 只求值 visibility 谓词（本测试全为 null），appModel 永不被触碰；
/// 轻量构造即可。
class _SearchTestAppModel extends AppModel {
  _SearchTestAppModel() : super(testPlatformServices());
}
