import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：锁定「标签管理页每行长按 + 右键弹上下文菜单（编辑 + 删除）」，防止
/// 回归到桌面端鼠标无删除入口（此前删除仅 swipe / gamepad X，鼠标只能 tap→编辑）。
///
/// 用源码扫描而非整页 widget pump：[TagManagementPage] 依赖完整 AppModel + DB，
/// 整页启动成本高且脆弱；这里的不变式（长按 / 右键指向同一菜单构建器、菜单同时含
/// 编辑与删除动作）正是用户报的「只能编辑不能删除」的精确反面，源码扫描足以守住。
String _read(String relative) {
  final File f = File(relative);
  if (!f.existsSync()) {
    throw StateError(
        'missing source: $relative (cwd=${Directory.current.path})');
  }
  return f.readAsStringSync();
}

String _methodBody(String source, String signature) {
  final int start = source.indexOf(signature);
  if (start < 0) {
    throw StateError('missing method signature: $signature');
  }
  final int bodyStart = source.indexOf('{', start);
  if (bodyStart < 0) {
    throw StateError('missing method body: $signature');
  }
  int depth = 0;
  for (int i = bodyStart; i < source.length; i++) {
    final String ch = source[i];
    if (ch == '{') depth++;
    if (ch == '}') {
      depth--;
      if (depth == 0) return source.substring(start, i + 1);
    }
  }
  throw StateError('unterminated method body: $signature');
}

void main() {
  final String src =
      _read('lib/src/pages/implementations/tag_management_page.dart');

  group('标签管理页长按 / 右键上下文菜单', () {
    test('标签行同时绑定长按与右键，都指向 _showTagMenu', () {
      expect(src.contains('onLongPressStart:'), isTrue,
          reason: '长按必须弹菜单');
      expect(src.contains('onSecondaryTapDown:'), isTrue,
          reason: '右键必须弹菜单');
      // 两个触发器都换算真实坐标喂给同一菜单构建器。
      expect(src.contains('_showTagMenu(tag, d.globalPosition)'), isTrue,
          reason: '长按 / 右键共用同一菜单入口');
    });

    test('菜单同时提供编辑与删除动作', () {
      final String menuBody = _methodBody(
        src,
        'Future<void> _showTagMenu(BookTagRow tag, Offset globalPosition)',
      );
      expect(menuBody.contains('_TagMenuAction.edit'), isTrue);
      expect(menuBody.contains('_TagMenuAction.delete'), isTrue);
      expect(menuBody.contains('_editTag(tag)'), isTrue,
          reason: '编辑动作接回既有 _editTag');
      expect(menuBody.contains('_deleteTag(tag)'), isTrue,
          reason: '删除动作接回既有 _deleteTag（含确认弹窗）');
    });

    test('tap 仍是快捷编辑，删除既有 swipe / gamepad 入口保留', () {
      expect(src.contains('onTap: () => _editTag(tag)'), isTrue,
          reason: 'tap→编辑保持不变（向后兼容）');
      // swipe 删除与 gamepad X 删除的既有入口不得被本次改动移除。
      expect(src.contains('confirmDismiss:'), isTrue,
          reason: 'swipe 删除入口保留');
      expect(src.contains('GamepadButton.x'), isTrue,
          reason: 'gamepad X 删除入口保留');
    });
  });
}
