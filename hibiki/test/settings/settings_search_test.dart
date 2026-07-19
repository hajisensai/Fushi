import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_search.dart';

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
