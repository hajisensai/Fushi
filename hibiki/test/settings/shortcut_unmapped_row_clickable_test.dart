import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-944：快捷键设置列表里「未映射」（当前无任何按键绑定）的行也必须能点击
/// 进入分配流程。历史上 [_ActionTile] 只在 trailing 挂了一个小小的编辑图标按钮，
/// 整行没有 onTap，未映射行只显示一行灰字（原文是 `shortcut_none`「None」），
/// 既没有可见入口也不可焦点导航，用户无法给它分配按键。
///
/// 根因修复后整行通过 `onTap: onEdit` 走与已映射行同一条 `_editBinding` →
/// updateBindingWithReassignments → saveShortcutRegistry 写穿路径，并且未映射
/// 行的占位文案改用 `shortcut_tap_to_assign`（「点击设置」）。
///
/// 这是源码守卫：撤销修复（整行 onTap 丢失 / 占位文案回退）即转红。
void main() {
  late final String source;

  setUpAll(() {
    source = File('lib/src/pages/implementations/shortcut_settings_page.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
  });

  // 截取 `_ActionTile` 类体，断言只针对这张行 widget。
  String actionTileBody() {
    const String marker = 'class _ActionTile';
    final int start = source.indexOf(marker);
    expect(start, isNonNegative, reason: '应能定位到 _ActionTile 类');
    // 下一个顶层 class 之前都算 _ActionTile 体。
    final int next = source.indexOf('\nclass ', start + marker.length);
    return next < 0 ? source.substring(start) : source.substring(start, next);
  }

  test('_ActionTile 整行 onTap 走 onEdit（已映射 + 未映射同一入口）', () {
    final String body = actionTileBody();
    expect(
      body,
      contains('onTap: onEdit'),
      reason: '整行必须挂 onTap: onEdit，未映射行才可点击/可焦点导航并进入分配流程',
    );
    // HibikiListItem 必须收到 onTap（不是只有 trailing 图标按钮可点）。
    expect(
      RegExp(r'return HibikiListItem\(\s*\n\s*onTap: onEdit').hasMatch(body),
      isTrue,
      reason: 'HibikiListItem 必须在构造时传入 onTap: onEdit',
    );
  });

  test('未映射行占位文案用 shortcut_tap_to_assign（不再是裸 None）', () {
    final String body = actionTileBody();
    expect(
      body,
      contains('t.shortcut_tap_to_assign'),
      reason: '未映射行应显示「点击设置」占位文案，明确告诉用户此行可点',
    );
    expect(
      body,
      isNot(contains('t.shortcut_none')),
      reason: '未映射行不应再退回静默的 shortcut_none 文案',
    );
  });
}
