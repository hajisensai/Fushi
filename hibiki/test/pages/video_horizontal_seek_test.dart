import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_seek_indicator_label.dart';

import 'video_hibiki_page_source_corpus.dart';

/// TODO-916 症状①：视频横滑改进度（横拖 seek + 居中绝对时间 HUD）。
///
/// 真实手势 seek 在 headless widget 测试里驱动不了（与 `video_double_tap_seek_guard`
/// 同范式），故分两层守住：
///  1. 纯函数 [VideoSeekIndicatorLabel] 的目标/增量标签与边界 clamp 直接单测。
///  2. 源码守卫：`_mobileControlsTheme` 启用 `seekGesture: true` + 灵敏度常量 +
///     `seekIndicatorBuilder`，桌面 `_desktopControlsTheme` 不含横滑字段（仅移动端，
///     诚实降级），改回旧值即红。
void main() {
  group('TODO-916 s1: VideoSeekIndicatorLabel 纯函数', () {
    test('clock：不足 1 小时省小时段，满 1 小时带小时', () {
      expect(VideoSeekIndicatorLabel.clock(const Duration(seconds: 5)), '0:05');
      expect(
        VideoSeekIndicatorLabel.clock(const Duration(minutes: 9, seconds: 5)),
        '9:05',
      );
      expect(
        VideoSeekIndicatorLabel.clock(
          const Duration(hours: 1, minutes: 2, seconds: 3),
        ),
        '1:02:03',
      );
    });

    test('target：位置 + 增量，clamp 到 [0, duration]', () {
      const Duration duration = Duration(minutes: 24);
      // 普通：12:19 + 15s = 12:34
      expect(
        VideoSeekIndicatorLabel.target(
          const Duration(minutes: 12, seconds: 19),
          const Duration(seconds: 15),
          duration,
        ),
        '12:34',
      );
      // 向后拖到负数：clamp 到 0
      expect(
        VideoSeekIndicatorLabel.target(
          const Duration(seconds: 10),
          const Duration(seconds: -30),
          duration,
        ),
        '0:00',
      );
      // 向前拖越界：clamp 到 duration
      expect(
        VideoSeekIndicatorLabel.target(
          const Duration(minutes: 23, seconds: 50),
          const Duration(seconds: 30),
          duration,
        ),
        '24:00',
      );
    });

    test('deltaSigned：带正负号，增量绝对值格式化', () {
      expect(
        VideoSeekIndicatorLabel.deltaSigned(const Duration(seconds: 15)),
        '+0:15',
      );
      expect(
        VideoSeekIndicatorLabel.deltaSigned(
          const Duration(minutes: 1, seconds: 20),
        ),
        '+1:20',
      );
      expect(
        VideoSeekIndicatorLabel.deltaSigned(const Duration(seconds: -80)),
        '-1:20',
      );
      // 拖回原点（增量 0）= fork 的 onHorizontalDragEnd 自动取消 seek 的判据。
      expect(
        VideoSeekIndicatorLabel.deltaSigned(Duration.zero),
        '+0:00',
      );
    });
  });

  group('TODO-916 s1: 控制条主题源码守卫', () {
    late String corpus;
    late String shellSrc;

    setUpAll(() {
      corpus = readVideoHibikiSource();
      shellSrc = File('lib/src/pages/implementations/video_hibiki_page.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
    });

    String methodBody(String source, String namePrefix) {
      final int start = source.indexOf(namePrefix);
      expect(start, greaterThanOrEqualTo(0), reason: '找不到方法名前缀: $namePrefix');
      final int braceStart = source.indexOf('{', start);
      int depth = 0;
      for (int i = braceStart; i < source.length; i++) {
        final String ch = source[i];
        if (ch == '{') depth++;
        if (ch == '}') {
          depth--;
          if (depth == 0) return source.substring(start, i + 1);
        }
      }
      fail('方法体大括号未闭合: $namePrefix');
    }

    test('横滑灵敏度常量存在且沿用 fork 默认（>0）', () {
      final RegExp re = RegExp(
        r'static const double _videoHorizontalGestureSensitivity\s*=\s*([\d.]+)',
      );
      final Match? m = re.firstMatch(shellSrc);
      expect(m, isNotNull, reason: '缺常量 _videoHorizontalGestureSensitivity');
      expect(double.parse(m!.group(1)!), greaterThan(0.0));
    });

    test('_mobileControlsTheme 启用 seekGesture + 灵敏度 + seekIndicatorBuilder',
        () {
      final String body = methodBody(
        corpus,
        'MaterialVideoControlsThemeData _mobileControlsTheme(',
      );
      expect(body.contains('seekGesture: true'), isTrue,
          reason: '移动控制条必须启用横滑 seek（TODO-916），改回 false 即红');
      expect(
        body.contains('horizontalGestureSensitivity:') &&
            body.contains(
              '_VideoHibikiPageState._videoHorizontalGestureSensitivity',
            ),
        isTrue,
        reason: '移动控制条必须把横滑灵敏度常量传给 media_kit',
      );
      expect(body.contains('seekIndicatorBuilder:'), isTrue,
          reason: '必须注入自定义 HUD builder（显目标绝对时间）');
      expect(body.contains('_buildSeekIndicator('), isTrue,
          reason: 'seekIndicatorBuilder 必须接到 _buildSeekIndicator');
    });

    test('_buildSeekIndicator 经 VideoSeekIndicatorLabel 算目标/增量', () {
      final String body = methodBody(corpus, 'Widget _buildSeekIndicator(');
      expect(body.contains('VideoSeekIndicatorLabel.target('), isTrue,
          reason: 'HUD 必须显目标绝对时间（非纯增量）');
      expect(body.contains('VideoSeekIndicatorLabel.deltaSigned('), isTrue,
          reason: 'HUD 必须显带符号增量');
    });

    test('桌面 _desktopControlsTheme 不接横滑 seek（仅移动端，诚实降级）', () {
      final String body = methodBody(
        corpus,
        'MaterialDesktopVideoControlsThemeData _desktopControlsTheme(',
      );
      expect(body.contains('seekGesture'), isFalse,
          reason: '桌面用鼠标拖进度条 + 键盘 seek 键，不应接横滑 seek');
      expect(body.contains('horizontalGestureSensitivity'), isFalse,
          reason: '桌面无横滑手势，不应设 horizontalGestureSensitivity');
    });
  });
}
