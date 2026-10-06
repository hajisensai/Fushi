// 视频画面中央控制行的形态守卫（shishamo 反馈「m3e 播放器中间这个太挡视野」）：
// 桌面主题（含桌面触屏模式）中央不挂任何键——底栏已有同一组 −10s / 播放暂停 /
// +10s；移动端只在暂停时画一个无底板的小播放图标，不再有 96dp 大圆块 + ±10s。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String source = File(
    'lib/src/pages/implementations/video_fushi/controls_theme.part.dart',
  ).readAsStringSync();

  String centerBarBody() {
    final int start = source.indexOf('List<Widget> _m3eCenterControlsBar(');
    expect(start, isNonNegative);
    final int end = source.indexOf('\n  }\n', start);
    return source.substring(start, end);
  }

  test('desktop theme passes desktop: true, mobile theme desktop: false', () {
    expect(
      'primaryButtonBar: _m3eCenterControlsBar(controller, desktop: true)'
          .allMatches(source)
          .length,
      1,
    );
    expect(
      'primaryButtonBar: _m3eCenterControlsBar(controller, desktop: false)'
          .allMatches(source)
          .length,
      1,
    );
  });

  test('desktop / Apple / mini density return an empty center row', () {
    final String body = centerBarBody();
    final int guard = body.indexOf('return const <Widget>[];');
    expect(guard, isNonNegative);
    final String condition = body.substring(0, guard);
    expect(condition, contains('desktop'));
    expect(condition, contains('_appleChrome'));
    expect(condition, contains('!_controlsDensity.showBottomButtonBar'));
  });

  test('mobile center row is the paused-only hint, no big plate or ±10s', () {
    final String body = centerBarBody();
    expect(body, contains('VideoCenterPausedHint('));
    expect(body, contains('if (controller.isPlaying) return'));
    expect(body, isNot(contains('VideoM3ePlayPauseButton(')));
    expect(body, isNot(contains('VideoM3eSeekButton(')));
    expect(body, isNot(contains('VideoM3ePlayButtonStyle.translucent')));
  });
}
