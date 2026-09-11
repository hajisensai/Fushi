import 'dart:io' show Platform;
import 'dart:ui' show FlutterView, FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'package:fushi/src/utils/window_caption_channel.dart';

/// BUG-2462：把「引擎真的光栅化了一帧、尺寸是多少」告诉 Windows runner。
///
/// runner 的子窗 resize 闸门（`windows/runner/child_resize_gate.h`）需要一个权威
/// 信号来判定「引擎 surface 已经切到我交付的尺寸」。Flutter Windows 引擎的 resize
/// 同步器在 100ms 超时后不复位目标；此后只要有人再把子窗拉回 surface 当前尺寸，
/// 目标就永久钉死、每一帧都被丢——用户看到的就是「加载中进全屏画面冻结，拖窗口才
/// 恢复」。runner 靠本上报避开那条序列：待确认的交付未被确认前，回到 surface 尺寸的
/// 请求先压着。
///
/// 为什么用光栅化时刻而不是 build 时刻：引擎的接受判定发生在光栅化 / present，
/// build 完成不代表 surface 已切换；若按 build 上报，runner 可能在那一帧真正落地前
/// 就把下一尺寸交付出去，又回到「等于 surface 尺寸」的早退分支。[FrameTiming] 在
/// 光栅化完成后才回调，`frameNumber` 与 build 时的
/// [PlatformDispatcher.frameData] 一一对应，据此把尺寸和帧对上。
///
/// 只在光栅化尺寸**变化**时发一次 channel，不是逐帧开销。
class RasterizedFrameSizeTracker {
  RasterizedFrameSizeTracker({this.maxTrackedFrames = 64});

  /// build 过但尚未收到 timing 的帧数上限；timing 在 release 下最长积压 1 秒
  /// （引擎按批上报），60fps 下 64 帧足够，超出只丢最旧的。
  final int maxTrackedFrames;

  final Map<int, Size> _builtSizes = <int, Size>{};
  Size? _lastReported;

  /// 一帧刚在 Dart 侧 build 完（persistent frame callback 时刻）时记录其视图物理尺寸。
  void recordBuilt(int frameNumber, Size physicalSize) {
    _builtSizes[frameNumber] = physicalSize;
    while (_builtSizes.length > maxTrackedFrames) {
      _builtSizes.remove(_builtSizes.keys.first);
    }
  }

  /// 引擎上报了一批已光栅化的帧号；返回需要通知 runner 的尺寸序列（只含变化）。
  ///
  /// 帧号找不到对应 build 记录的（纹理帧驱动的 `DrawLastLayerTrees` 重绘没有 Dart
  /// build，或被 [maxTrackedFrames] 淘汰的）直接跳过：它们的尺寸等于上一棵树，
  /// 不带来新信息。
  List<Size> onFramesRasterized(Iterable<int> frameNumbers) {
    final List<Size> changes = <Size>[];
    for (final int frameNumber in frameNumbers) {
      final Size? size = _builtSizes.remove(frameNumber);
      if (size == null || size == _lastReported) continue;
      _lastReported = size;
      changes.add(size);
    }
    return changes;
  }

  @visibleForTesting
  int get trackedFrameCount => _builtSizes.length;
}

/// 在 `main()` 里、`runApp` 之前调一次（仅 Windows 生效）。
void installRasterizedFrameSizeReporter() {
  if (!Platform.isWindows) return;
  final RasterizedFrameSizeTracker tracker = RasterizedFrameSizeTracker();
  final SchedulerBinding scheduler = SchedulerBinding.instance;
  scheduler.addPersistentFrameCallback((Duration _) {
    final FlutterView? view =
        WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view == null) return;
    tracker.recordBuilt(
      scheduler.platformDispatcher.frameData.frameNumber,
      view.physicalSize,
    );
  });
  scheduler.addTimingsCallback((List<FrameTiming> timings) {
    for (final Size size in tracker.onFramesRasterized(
      timings.map((FrameTiming t) => t.frameNumber),
    )) {
      WindowCaptionChannel.reportRasterizedFrameSize(
        width: size.width.round(),
        height: size.height.round(),
      );
    }
  });
}
