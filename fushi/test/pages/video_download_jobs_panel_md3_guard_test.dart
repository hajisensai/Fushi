import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-1766：任务卡「排队优先级」此前裸用 [PopupMenuButton]，弹出的菜单没有
/// MD3 圆角/浮层色/焦点可进（用户 2026-08-21 截图）。业务页面必须走共享原语
/// `FushiOverflowMenu`（内部统一 shape/color/animation，手柄焦点也接了）。
///
/// 守卫钉死：任务面板源码不再出现裸 `PopupMenuButton(` 构造。
/// `PopupMenuEntry` / `FushiPopupMenuItem` 类型引用不在禁用之列。
void main() {
  test('任务面板菜单走 FushiOverflowMenu，不裸用 PopupMenuButton', () {
    final File f = File(
      'lib/src/pages/implementations/video_download_jobs_panel.dart',
    );
    expect(f.existsSync(), isTrue,
        reason: '找不到 video_download_jobs_panel.dart（路径变了要同步本守卫）');
    final String code = maskCommentsAndScriptLines(f.readAsStringSync());

    // 裸构造带不带泛型都算（`PopupMenuButton(` / `PopupMenuButton<int>(`）；
    // 类型引用（PopupMenuEntry / PopupMenuButtonState）不在禁用之列。
    expect(
      RegExp(r'PopupMenuButton(<[^>]*>)?\s*\(').hasMatch(code),
      isFalse,
      reason: '裸 PopupMenuButton 菜单没走 MD3 设计令牌（BUG-1766），'
          '用共享原语 FushiOverflowMenu。',
    );
    expect(code, contains('FushiOverflowMenu<'),
        reason: '优先级/排序菜单应经共享 MD3 菜单原语渲染。');
  });
}
