import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_seek_indicator_label.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// TODO-916 症状①：视频横滑改进度（横拖 seek + 居中绝对时间 HUD）。
///
/// 真实手势 seek 在 headless widget 测试里驱动不了（与 `video_double_tap_seek_guard`
/// 同范式），故分两层守住：
///  1. 纯函数 [VideoSeekIndicatorLabel] 的目标/增量标签与边界 clamp 直接单测。
///  2. 源码守卫：`_mobileControlsTheme` 启用 `seekGesture: true` +
///     `seekIndicatorBuilder`，桌面 `_desktopControlsTheme` 不含横滑字段（仅移动端，
///     诚实降级），改回旧值即红。
///
/// BUG-1485：像素→时间的换算已从 fork 内建的「按总时长比例」公式换成 Hibiki 侧纯函数
/// [VideoHorizontalSeekGesture]（换算本身的数值单测在
/// `test/media/video/video_horizontal_seek_gesture_test.dart`）。本文件补三层守卫：
/// 旧常量已删、移动 theme 接上 resolver + 用户档位、fork 的注入点没被 re-vendor 抹掉。
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
      corpus = readVideoFushiSource();
      shellSrc = File('lib/src/pages/implementations/video_fushi_page.dart')
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

    // 判据一律走 source_guard 的剥注释版：裸 `contains` 会被注释里的同名字面量喂成
    // 假绿（本条守卫在变异实测里就是这么被骗过一次的——把实现改成写死档位、注释里
    // 还留着 `_asbConfig.dragSeekSensitivity` 就照样通过）。
    test('BUG-1485：按总时长比例换算的旧灵敏度常量已彻底移除', () {
      expect(
        containsIdentifier(shellSrc, '_videoHorizontalGestureSensitivity'),
        isFalse,
        reason: 'BUG-1485：换算已交给 VideoHorizontalSeekGesture，'
            '重新引入按总时长比例换算的灵敏度常量即回归',
      );
    });

    test('_mobileControlsTheme 启用 seekGesture + seekIndicatorBuilder', () {
      final String body = methodBody(
        corpus,
        'MaterialVideoControlsThemeData _mobileControlsTheme(',
      );
      expect(body.contains('seekGesture: true'), isTrue,
          reason: '移动控制条必须启用横滑 seek（TODO-916），改回 false 即红');
      expect(body.contains('seekIndicatorBuilder:'), isTrue,
          reason: '必须注入自定义 HUD builder（显目标绝对时间）');
      expect(body.contains('_buildSeekIndicator('), isTrue,
          reason: 'seekIndicatorBuilder 必须接到 _buildSeekIndicator');
    });

    test('BUG-1485：_mobileControlsTheme 把换算接到纯函数 + 用户档位，且不再传 fork 灵敏度', () {
      final String body = methodBody(
        corpus,
        'MaterialVideoControlsThemeData _mobileControlsTheme(',
      );
      expect(containsCodeLine(body, 'horizontalSeekResolver:'), isTrue,
          reason: 'BUG-1485：必须注入 resolver 接管 fork 的比例制换算');
      expect(
        containsCodeLine(body, 'VideoHorizontalSeekGesture.resolveDelta('),
        isTrue,
        reason: 'BUG-1485：resolver 必须走可单测的纯函数模型',
      );
      expect(containsCodeLine(body, '_asbConfig.dragSeekSensitivity'), isTrue,
          reason: 'BUG-1485：灵敏度必须读用户设置档位，不得写死');
      expect(
        containsIdentifier(body, 'horizontalGestureSensitivity'),
        isFalse,
        reason: 'BUG-1485：resolver 在场时 fork 的比例制灵敏度被忽略，'
            '再传它只会误导后来者以为它还生效',
      );
    });

    test('_buildSeekIndicator 经 VideoSeekIndicatorLabel 算目标/增量', () {
      final String body = methodBody(corpus, 'Widget _buildSeekIndicator(');
      expect(body.contains('VideoSeekIndicatorLabel.target('), isTrue,
          reason: 'HUD 必须显目标绝对时间（非纯增量）');
      expect(body.contains('VideoSeekIndicatorLabel.deltaSigned('), isTrue,
          reason: 'HUD 必须显带符号增量');
    });

    test('BUG-1485：fork 的 resolver 注入点存活（re-vendor 后被抹掉即红）', () {
      // 测试 CWD = `fushi/`；vendored 包在 workspace 根。
      final String forkSrc = File(
        '../third_party/media_kit_video/lib/media_kit_video_controls/'
        'src/controls/material.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      expect(
          containsCodeLine(forkSrc, 'typedef HorizontalSeekResolver'), isTrue,
          reason: 'fork 补丁被 re-vendor 抹掉：缺 HorizontalSeekResolver typedef');
      expect(
        containsCodeLine(
          forkSrc,
          'final HorizontalSeekResolver? horizontalSeekResolver;',
        ),
        isTrue,
        reason: 'fork 补丁被 re-vendor 抹掉：theme 缺 horizontalSeekResolver 字段',
      );
      expect(
        containsCodeLine(forkSrc, '_theme(context).horizontalSeekResolver'),
        isTrue,
        reason: 'fork 补丁被 re-vendor 抹掉：onHorizontalDragUpdate 不再调 resolver，'
            '会静默退回按总时长比例换算的旧公式（BUG-1485 症状复发）',
      );
      expect(
        containsCodeLine(forkSrc, 'Duration swipeDuration = Duration.zero;'),
        isTrue,
        reason: 'fork 补丁被 re-vendor 抹掉：swipeDuration 退回 int 整秒，'
            '亚秒级微调被量化掉',
      );
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
