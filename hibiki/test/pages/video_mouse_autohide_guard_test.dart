import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

/// 源码守卫（BUG-106）：控制条自动隐藏时，鼠标光标也应隐藏。
/// media_kit 的 `MaterialDesktopVideoControlsThemeData.hideMouseOnControlsRemoval`
/// 默认 false（光标常驻）；必须显式设 true。media_kit headless 不可跑视频 widget，
/// 故在源码层钉死。
///
/// 源码守卫（TODO-056）：无操作后控制条自动隐藏的延迟（media_kit
/// `controlsHoverDuration`，默认 3 秒偏长）必须显式设成 2 秒。桌面与移动两套主题
/// 都要钉，全屏路由复用窗口侧主题实例故一并生效。
void main() {
  test('desktop controls theme hides mouse on controls removal (BUG-106)', () {
    // TODO-590 batch11：两套 controls 主题已搬到 controls_theme.part.dart，改读合并语料。
    final String src = readVideoHibikiSource();
    expect(src.contains('hideMouseOnControlsRemoval: true'), isTrue,
        reason: '桌面控制条隐藏时必须一并隐藏鼠标光标');
  });

  test('controls auto-hide delay is 2 seconds in both themes (TODO-056)', () {
    // TODO-590 batch11：两套 controls 主题已搬到 controls_theme.part.dart，改读合并语料。
    final String src = readVideoHibikiSource();
    // 桌面 + 移动两套主题各显式设 controlsHoverDuration = 2 秒。
    final int count = RegExp(
      r'controlsHoverDuration: const Duration\(seconds: 2\)',
    ).allMatches(src).length;
    expect(count, 2, reason: '桌面与移动控制主题都必须把自动隐藏延迟设成 2 秒（TODO-056）');
  });
}
