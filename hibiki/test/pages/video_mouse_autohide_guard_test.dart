import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（BUG-106）：桌面控制条 3s 后自动隐藏时，鼠标光标也应隐藏。
/// media_kit 的 `MaterialDesktopVideoControlsThemeData.hideMouseOnControlsRemoval`
/// 默认 false（光标常驻）；必须显式设 true。media_kit headless 不可跑视频 widget，
/// 故在源码层钉死。
void main() {
  test('desktop controls theme hides mouse on controls removal (BUG-106)', () {
    final String src =
        File('lib/src/pages/implementations/video_hibiki_page.dart')
            .readAsStringSync();
    expect(src.contains('hideMouseOnControlsRemoval: true'), isTrue,
        reason: '桌面控制条隐藏时必须一并隐藏鼠标光标');
  });
}
