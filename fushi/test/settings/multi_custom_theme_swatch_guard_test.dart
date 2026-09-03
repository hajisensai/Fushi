import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// TODO-930 M1/M2 source-scan guards. A full widget test of the theme swatch row
// or the editor would need the whole AppModel/InAppWebView stack; the structure
// that matters (multi-swatch loop, +new swatch, per-id routing, name field,
// delete button, list-model apply path) is pinned by a source scan so reverting
// the work turns these red. Behaviour of the underlying data API is covered by
// test/models/multi_custom_theme_ui_test.dart.

void main() {
  final String actions =
      File('lib/src/settings/settings_actions.dart').readAsStringSync();
  final String page =
      File('lib/src/pages/implementations/custom_theme_page.dart')
          .readAsStringSync();

  group('M1 swatch row renders one swatch per custom theme', () {
    test('iterates appModel.customThemes into swatches', () {
      expect(actions.contains('appModel.customThemes.map('), isTrue,
          reason: 'swatch row no longer loops over the custom theme list');
    });

    test('tapping a swatch pins the theme by id (custom-theme:<id>)', () {
      expect(actions.contains(r'custom-theme:${e.id}'), isTrue,
          reason: 'swatch tap must write app_theme_key=custom-theme:<id>');
    });

    test('long-press a swatch edits that specific theme', () {
      expect(actions.contains('CustomThemePage(themeId: e.id)'), isTrue,
          reason: 'long-press must open the editor for that entry');
    });

    test('has a +new swatch that opens a draft editor (BUG-1841: no upsert)',
        () {
      expect(actions.contains('(_) => const CustomThemePage()'), isTrue,
          reason: 'missing the +new swatch draft-editor path');
      expect(actions.contains('Icons.add'), isTrue,
          reason: 'the +new swatch needs an add overlay icon');
      // BUG-1841：swatch 行任何入口都不得在进编辑页前写主题列表；只有编辑页
      // 「应用」才 upsert。行为层由 test/pages/custom_theme_page_draft_no_persist_test
      // 断言，这里守住源码不再长出预落库 helper。
      expect(actions.contains('upsertCustomTheme('), isFalse,
          reason:
              'swatch row must not persist a theme before the editor opens');
      expect(actions.contains('createBlankCustomTheme'), isFalse,
          reason: 'pre-persisting blank-theme helper must stay deleted');
    });

    test('keeps a focus-reachable edit button', () {
      expect(actions.contains('t.edit_custom_theme'), isTrue,
          reason: 'the focus/gamepad edit button was removed');
    });

    // BUG-1894: 编辑按钮曾在「当前活跃主题不是自定义主题」时回落到打开空草稿
    // 编辑页——与左邻「+」卡片逐字节等价，于是同一行两个按钮做同一件事，挂着
    // 「编辑」图标的那个却在新建。修法是禁用而不是回落。
    test('BUG-1894: edit button is disabled when there is nothing to edit', () {
      expect(actions.contains('enabled: activeCustomThemeId != null'), isTrue,
          reason: 'the edit button must be disabled with no active custom '
              'theme instead of falling back to a blank-draft editor');
    });

    test('BUG-1894: the edit target is resolved once, shared by onTap+enabled',
        () {
      // 门和目标必须读同一个值，否则又会长出「按钮亮着但没有目标」的状态。
      expect(
          RegExp(r'final String\? activeCustomThemeId =\s*\n?\s*'
                  r'appModel\.activeCustomThemeEntry\?\.id;')
              .hasMatch(actions),
          isTrue,
          reason: 'active custom theme id must be resolved once up front');
      expect(actions.contains('CustomThemePage(themeId: activeCustomThemeId)'),
          isTrue,
          reason: 'the edit button must route to the active entry');
      // 旧的行内解析（onTap 里现算一个 activeId）不得回来。
      expect(actions.contains('final String? activeId ='), isFalse,
          reason: 'the per-tap activeId fallback must stay deleted');
    });

    test('BUG-1894: the blank-draft editor has exactly one entry point (+)',
        () {
      // 关键守卫：任何让编辑按钮（或别的控件）重新回落到空草稿的改法都会让这个
      // 计数变成 2 而变红。「+」卡片是唯一的新建入口。
      expect(
        RegExp(r'const CustomThemePage\(\)').allMatches(actions).length,
        1,
        reason: 'blank-draft CustomThemePage() must have exactly one call '
            'site — the +new swatch',
      );
    });

    test(
        'TODO-1320: swatch row renders no name caption; Custom N default lives '
        'in the editor only', () {
      // TODO-1320: 主题卡片下方不再渲染主题名 caption——系统/预设/自定义所有主题
      // 统一只显示完整对角预览、无底部多余文字。swatch 行不再需要 display-name
      // 助手，settings_actions.dart 里 customThemeDisplayName 已删除。
      expect(actions.contains('customThemeDisplayName'), isFalse,
          reason: 'swatch row must not render a per-theme name caption');
      // 「Custom N」默认名仍在——但只作为编辑页名称输入框未命名时的 hint 占位。
      expect(page.contains('t.custom_theme_default_name(n:'), isTrue,
          reason: 'default Custom N fallback must remain in the editor hint');
    });
  });

  group('M2 editor edits a specific entry with name + delete', () {
    test('CustomThemePage accepts an optional themeId', () {
      expect(page.contains('this.themeId'), isTrue,
          reason: 'editor must accept a themeId to edit a specific entry');
      expect(page.contains('final String? themeId;'), isTrue);
    });

    test('renders a name field bound to the name controller', () {
      expect(page.contains('_buildNameField()'), isTrue,
          reason: 'name field builder missing');
      expect(page.contains('controller: _nameController'), isTrue);
      expect(page.contains('t.custom_theme_name'), isTrue);
    });

    test('apply routes through the list model (upsert + select + key)', () {
      expect(page.contains('appModel.upsertCustomTheme(entry)'), isTrue,
          reason: 'apply must persist into the list model');
      expect(page.contains('appModel.selectCustomTheme(entry.id)'), isTrue);
      expect(
          page.contains(r"appModel.setAppThemeKey('custom-theme:${entry.id}')"),
          isTrue);
    });

    test('has a delete button + confirm + post-delete fallback', () {
      expect(page.contains('t.delete_custom_theme'), isTrue,
          reason: 'delete button label missing');
      expect(page.contains('appModel.deleteCustomTheme(_entryId)'), isTrue);
      expect(page.contains('t.delete_custom_theme_confirm'), isTrue,
          reason: 'delete must show a confirm dialog');
      expect(page.contains('_resolveThemeKeyAfterDelete('), isTrue,
          reason: 'post-delete fallback (decision 1) missing');
      expect(page.contains("'system-theme'"), isTrue,
          reason: 'empty-list delete must fall back to system-theme');
    });

    test('share-code wire is unchanged (id/name not in the code)', () {
      // The share code is still hibiki-theme:<seed>:<mode>[:fc..]; no id/name
      // field was added (M3), so the encoder still starts with that prefix.
      expect(page.contains("var code = 'hibiki-theme:"), isTrue,
          reason: 'share-code wire format changed unexpectedly');
    });
  });
}
