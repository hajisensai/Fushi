import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';

/// TODO-1297 守卫：**「进度条已缓冲但还在加载」**根因不变量。
///
/// 根因：TODO-1276 只用首帧解码出画（[VideoPlayerController.hasFirstFrame]，宽高
/// 均为正）当「首开可挂载 [Video]」的判据。但**首帧已解码 != 可稳定起播**：网络流
/// 常在解码出首帧（宽高就绪、hasFirstFrame 翻真）时仍在缓冲（libmpv
/// `paused-for-cache` / `core-idle`）。页面据 hasFirstFrame 提前挂载 media_kit，
/// media_kit 自带缓冲圈接着盖住画面——正是 TODO-1276 想消除的「第二个圈」，而进度条
/// 的已缓冲填充（`demuxer-cache-time`）此刻已可见，用户看到「进度条显示已经缓冲了、
/// 但还在加载」。
///
/// 修复：首开就绪判据收紧为 [VideoPlayerController.readyForFirstPaint]＝首帧已出画
/// **且**未在缓冲。页级上下文加载层（[VideoLoadingOverlay]，带返回按钮不困死用户）
/// 覆盖整个解码 + 缓冲窗口，直到有稳定帧且缓冲结束再让位给 media_kit，杜绝冗余第二个圈。
///
/// media_kit 视频无法离屏跑，故此处只锁两层可静态验证的判据：
///   1. 就绪判据纯函数 [VideoPlayerController.readyForFirstPaint] 的真值表；
///   2. 页面 / 控制器把该判据 + 缓冲订阅接进首开就绪链路（源码扫描）。
/// 真实「进度条缓冲完立即出画、无第二个圈」观感只能在真机复测（打开网络流视频，
/// 缓冲进度条填满即出画，不再多转一段圈）。
void main() {
  String read(String relPath) {
    for (final String prefix in <String>['', '../']) {
      final File f = File('$prefix$relPath');
      if (f.existsSync()) return f.readAsStringSync();
    }
    throw StateError('找不到文件：$relPath');
  }

  group('就绪判据 readyForFirstPaint (TODO-1297)', () {
    test('首帧已出画且未在缓冲才算首开可挂载', () {
      expect(
        VideoPlayerController.readyForFirstPaint(1920, 1080, false),
        isTrue,
        reason: '有稳定帧且缓冲结束 = 可挂载 Video，media_kit 不会再出缓冲圈',
      );
    });

    test('首帧已出画但仍在缓冲 -> 未就绪（页级加载层继续覆盖缓冲窗口）', () {
      expect(
        VideoPlayerController.readyForFirstPaint(1920, 1080, true),
        isFalse,
        reason: '这正是「进度条已缓冲但还在加载」的场景：首帧解码出画但 mpv 仍缓冲，'
            '若此刻挂载 Video，media_kit 缓冲圈会接力成第二个圈',
      );
    });

    test('缓冲结束但首帧未出画 -> 仍未就绪（无稳定帧不挂载）', () {
      expect(
          VideoPlayerController.readyForFirstPaint(null, null, false), isFalse);
      expect(
          VideoPlayerController.readyForFirstPaint(1920, null, false), isFalse);
      expect(VideoPlayerController.readyForFirstPaint(0, 0, false), isFalse);
    });

    test('未解码且仍在缓冲 -> 未就绪', () {
      expect(
          VideoPlayerController.readyForFirstPaint(null, null, true), isFalse);
    });
  });

  group('控制器缓冲就绪链路 (TODO-1297)', () {
    final String src = read('lib/src/media/video/video_player_controller.dart');

    test('isReadyForFirstPaint 组合首帧 + 非缓冲', () {
      expect(src.contains('bool get isReadyForFirstPaint'), isTrue);
      expect(
        src.contains(
            'readyForFirstPaint(videoWidth, videoHeight, isBuffering)'),
        isTrue,
        reason: '就绪 = 首帧已出画 && 未缓冲，读同一 player.state.buffering 真值',
      );
      expect(src.contains('bool get isBuffering'), isTrue);
    });

    test('始终挂缓冲订阅，翻转即 notifyListeners 驱动就绪重评', () {
      expect(src.contains('_bufferingReadySub'), isTrue,
          reason: '缓冲结束不一定伴随宽高/播放态变化，须独立订阅驱动就绪重评，'
              '否则页级加载层只能等兜底定时器让位');
      // 该订阅必须在 dispose / 换集前取消，避免向已销毁 State 通知（对齐 widthSub）。
      final int cancels = '_bufferingReadySub?.cancel()'.allMatches(src).length;
      expect(cancels >= 2, isTrue,
          reason: '换集清理 + dispose 两处都要取消，防泄漏 / 向旧 player 通知');
    });
  });

  group('页面首开就绪门控 (TODO-1297)', () {
    final String src =
        read('lib/src/pages/implementations/video_hibiki_page.dart');

    test('首开就绪判据用 isReadyForFirstPaint（含缓冲结束），非仅 hasFirstFrame', () {
      expect(
        src.contains('_videoReadyToShow = controller.isReadyForFirstPaint'),
        isTrue,
        reason: '快路径可见态赋值必须并入缓冲结束判据，否则缓冲中提前挂载会出第二个圈',
      );
      expect(
        src.contains('_controller?.isReadyForFirstPaint ?? false'),
        isTrue,
        reason: '慢路径 promote 监听也须重评 isReadyForFirstPaint（缓冲结束才翻真）',
      );
    });
  });
}
