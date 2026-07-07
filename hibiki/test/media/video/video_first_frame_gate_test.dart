import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';

/// TODO-1276 守卫：**首开视频只转一次圈**的根因不变量。
///
/// 根因：首开路径曾有两个独立加载指示器接力显示——① 页级 [VideoLoadingOverlay]
/// （`_buildLoadingBody`）覆盖 `controller.load()`（open+seek+play）阶段；② `load()`
/// 返回、`Video` 挂载后，media_kit 自带缓冲圈继续覆盖「已下发 play 但首帧尚未解码
/// 出画」的窗口。两个圈背景/样式不同（页级在 surface 底、media_kit 在纯黑底），用户
/// 看到转圈消失又出现 = 「转两次圈」。
///
/// 修复：**首开**时页级加载态保持到首帧真正解码出画（[VideoPlayerController.hasFirstFrame]）
/// 再挂载 `Video`——此刻 media_kit 已有帧、不再缓冲，全程只有一个圈。
///
/// media_kit 视频无法离屏跑，故此处只锁两层可静态验证的判据：
///   1. 首帧判据纯函数 [VideoPlayerController.framePresent] 的真值表；
///   2. 页面把 `!_videoReadyToShow` 并入转圈判据、且仅在**首开**（`isInitialVideoOpen`）
///      门控（换集行为不变，不碰全屏路由复用的同一 VideoController 实例）。
/// 真实「单圈」观感只能在真机复测（打开视频，转圈到画面出现只出现一次、不消失再现）。
void main() {
  String read(String relPath) {
    for (final String prefix in <String>['', '../']) {
      final File f = File('$prefix$relPath');
      if (f.existsSync()) return f.readAsStringSync();
    }
    throw StateError('找不到文件：$relPath');
  }

  group('首帧判据 framePresent (TODO-1276)', () {
    test('宽高均为非空正数才算首帧已出画', () {
      expect(VideoPlayerController.framePresent(1920, 1080), isTrue);
      expect(VideoPlayerController.framePresent(1, 1), isTrue);
    });

    test('未解码 / 零 / 负 / 单轴缺失一律未就绪', () {
      expect(VideoPlayerController.framePresent(null, null), isFalse,
          reason: '未解码：宽高均 null');
      expect(VideoPlayerController.framePresent(1920, null), isFalse,
          reason: '高未就绪');
      expect(VideoPlayerController.framePresent(null, 1080), isFalse,
          reason: '宽未就绪');
      expect(VideoPlayerController.framePresent(0, 0), isFalse,
          reason: '零尺寸不算出画');
      expect(VideoPlayerController.framePresent(1920, 0), isFalse);
      expect(VideoPlayerController.framePresent(0, 1080), isFalse);
      expect(VideoPlayerController.framePresent(-1, -1), isFalse,
          reason: '负尺寸异常值不算出画');
    });
  });

  group('页面首开单圈门控 (TODO-1276)', () {
    final String src =
        read('lib/src/pages/implementations/video_hibiki_page.dart');

    test('转圈判据并入 !_videoReadyToShow（首帧就绪前保持页级加载态）', () {
      expect(src.contains('!_videoReadyToShow'), isTrue,
          reason: '页级转圈必须保持到首帧就绪，否则会与 media_kit 缓冲圈接力成两次转圈');
      expect(src.contains('bool _videoReadyToShow = false'), isTrue,
          reason: '_videoReadyToShow 必须默认 false（首开未就绪即转圈）');
    });

    test('仅首开门控：换集复用 controller 不重置可见态（不破坏全屏路由复用）', () {
      expect(src.contains('isInitialVideoOpen'), isTrue,
          reason: '必须区分首开与换集：换集不得把 _videoReadyToShow 打回 false，'
              '否则会卸载正在复用的 Video（BUG-120/121 全屏路由风险）');
      expect(
          src.contains('if (isInitialVideoOpen) {') &&
              src.contains(
                  '_videoReadyToShow = controller.isReadyForFirstPaint'),
          isTrue,
          reason: '可见态赋值必须门控在首开分支内');
    });

    test('就绪监听 + 兜底定时器齐备（始终不就绪也绝不无限转圈）', () {
      // TODO-1297：页面就绪判据从仅 hasFirstFrame 收紧为 isReadyForFirstPaint
      // （首帧已出画且缓冲结束），故页级慢路径靠它翻真可见态。
      expect(src.contains('isReadyForFirstPaint'), isTrue,
          reason: '首开慢路径靠 isReadyForFirstPaint（首帧就绪且缓冲结束）后翻真可见态');
      expect(src.contains('_firstFramePromoteTimer'), isTrue,
          reason: '解码异常机型 / 纯音频容器 / 缓冲久拖始终不就绪时须有兜底超时，避免无限转圈');
    });
  });
}
