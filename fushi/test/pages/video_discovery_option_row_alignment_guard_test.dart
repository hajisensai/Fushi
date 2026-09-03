import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-1765：资源/订阅面板的「默认受管视频来源 / 附带字幕」两个下拉并排，
/// 左侧带 helperText（BUG-1713 加的）而右侧没有。Row 默认居中对齐时右框会被
/// 往下挤半个 helper 高度，两个输入框底边错位（用户 2026-08-21 截图）。
///
/// 守卫钉死：包着 `video-resource-source` 的那个 Row 必须显式顶对齐。
/// 用源码扫描而不是 widget 测试，因为该 Row 埋在需要完整 registry/sources
/// 装配的 surface 深处，而回归形态就是「有人删掉那一行 crossAxisAlignment」。
void main() {
  test('来源/字幕下拉的 Row 顶对齐（helperText 不再挤歪右框）', () {
    final File f = File(
      'lib/src/pages/implementations/video_discovery_acquisition_dialogs.dart',
    );
    expect(f.existsSync(), isTrue,
        reason: '找不到 video_discovery_acquisition_dialogs.dart'
            '（路径变了要同步本守卫）');
    final String code = maskCommentsAndScriptLines(f.readAsStringSync());

    final int keyIndex = code.indexOf("'video-resource-source'");
    expect(keyIndex, greaterThan(0), reason: '来源下拉的 ValueKey 变了要同步本守卫');
    final int rowIndex = code.lastIndexOf('Row(', keyIndex);
    expect(rowIndex, greaterThan(0));
    final String rowHead = code.substring(rowIndex, keyIndex);
    expect(
      rowHead,
      contains('crossAxisAlignment: CrossAxisAlignment.start'),
      reason: '左侧下拉带 helperText、右侧没有：Row 不顶对齐时两个输入框底边'
          '错位（BUG-1765）。删这行前先想清 helper 高度差怎么消。',
    );
  });
}
