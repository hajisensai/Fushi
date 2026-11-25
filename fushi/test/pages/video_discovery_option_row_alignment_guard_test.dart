import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-1765：资源/订阅面板的「默认受管视频来源 / 附带字幕」两个下拉并排，
/// 左侧带 helperText（BUG-1713 加的）而右侧没有，Row 居中对齐时右框被往下
/// 挤半个 helper 高度，两个输入框底边错位（用户 2026-08-21 截图）。
///
/// 2026-11 起落地选项改成同高的 M3E 菜单 chip（`_ResourceMenuSelect`），排在
/// 一个 `Wrap` 里；BUG-1713 要的说明进 tooltip，不再有 helperText。守卫钉死：
/// 来源选择挂在选项 Wrap 里，且这一段不再出现 helperText（高度差的来源）。
/// 用源码扫描而不是 widget 测试，因为该选项行埋在需要完整 registry/sources
/// 装配的 surface 深处。
void main() {
  test('来源/字幕选择是同高 chip，不再有 helperText 挤歪并排控件', () {
    final File f = File(
      'lib/src/pages/implementations/video_discovery_acquisition_dialogs.dart',
    );
    expect(
      f.existsSync(),
      isTrue,
      reason:
          '找不到 video_discovery_acquisition_dialogs.dart'
          '（路径变了要同步本守卫）',
    );
    final String code = maskCommentsAndScriptLines(f.readAsStringSync());

    final int keyIndex = code.indexOf("'video-resource-source'");
    expect(keyIndex, greaterThan(0), reason: '来源选择的 ValueKey 变了要同步本守卫');
    final int wrapIndex = code.lastIndexOf('Wrap(', keyIndex);
    expect(wrapIndex, greaterThan(0));
    expect(
      code.lastIndexOf('Row(', keyIndex),
      lessThan(wrapIndex),
      reason: '来源选择应直接排在选项 Wrap 里，而不是并排 Row',
    );
    final int policyIndex = code.indexOf(
      "'video-resource-subtitle-policy'",
      keyIndex,
    );
    expect(policyIndex, greaterThan(keyIndex));
    final String options = code.substring(wrapIndex, policyIndex);
    expect(options, contains('_ResourceMenuSelect<'));
    expect(
      options,
      isNot(contains('helperText')),
      reason: '并排选项里带 helperText 会让控件高度不一、底边错位（BUG-1765）',
    );
  });
}
