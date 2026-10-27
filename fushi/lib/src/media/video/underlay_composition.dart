// Windows 底层合成（ci/patches/flutter-engine 的 FlutterDesktopViewSetUnderlayComposition）：
// Flutter 视图改由 DirectComposition topmost visual（预乘 alpha）呈现，视图 HWND 的子窗口
// （窗口宿主档的 WebView2，硬件 PlayReady）垫在 Flutter 下面、从透明像素处透出来，
// Flutter 的控件 / 字幕 / 查词弹窗画在它上面。
//
// 透出来的前提是视频区下面没有任何不透明的 Flutter 底色：页面自己让开，外层标题栏
// 框架（盖着整个 Navigator 的 surface 底色）听 [underlayCompositionActive]。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 与 HDR 输出同一条 runner 通道（`underlayCompositionSupported` / `setUnderlayComposition`）。
const MethodChannel kUnderlayCompositionChannel = MethodChannel(
  'app.fushi/hdr_output',
);

/// 底层合成是否开着（标题栏框架据此让开底色）。
final ValueNotifier<bool> underlayCompositionActive = ValueNotifier<bool>(
  false,
);

int _holders = 0;

/// 引擎能否做底层合成（打了补丁的 flutter_windows.dll 导出了开关）。不改任何状态。
Future<bool> underlayCompositionSupported() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return false;
  try {
    return await kUnderlayCompositionChannel.invokeMethod<bool>(
          'underlayCompositionSupported',
        ) ??
        false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

/// 请求开启：返回引擎是否支持（原版引擎 / 非 Windows → false，什么也不变）。
/// 与 [releaseUnderlayComposition] 成对调用；按持有数计，换页交接（新页先 acquire、
/// 旧页后 release）不会中途关掉。
Future<bool> acquireUnderlayComposition() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return false;
  bool ok = false;
  try {
    ok =
        await kUnderlayCompositionChannel.invokeMethod<bool>(
          'setUnderlayComposition',
          true,
        ) ??
        false;
  } on MissingPluginException {
    ok = false;
  } on PlatformException {
    ok = false;
  }
  if (!ok) return false;
  _holders++;
  underlayCompositionActive.value = true;
  return true;
}

/// 归还 [acquireUnderlayComposition] 成功拿到的一份；最后一份归还时关闭。
Future<void> releaseUnderlayComposition() async {
  if (_holders == 0) return;
  _holders--;
  if (_holders > 0) return;
  await _afterBuildPhase();
  // 等待期间又有页 acquire（换页交接）：这份已经不是最后一份。
  if (_holders > 0) return;
  underlayCompositionActive.value = false;
  try {
    await kUnderlayCompositionChannel.invokeMethod<bool>(
      'setUnderlayComposition',
      false,
    );
  } on MissingPluginException {
    // 引擎 / runner 已不在（退出中）。
  } on PlatformException {
    // 同上。
  }
}

/// 页面 dispose 里归还时树是锁着的（`finalizeTree` 卸载 inactive element）：此刻改
/// [underlayCompositionActive] 会让标题栏的 ValueListenableBuilder 标脏失败（断言，release
/// 下是标题栏停在透明底）。在帧的 build 阶段里就等这一帧画完再通知。
Future<void> _afterBuildPhase() {
  final SchedulerBinding binding = SchedulerBinding.instance;
  if (binding.schedulerPhase != SchedulerPhase.persistentCallbacks) {
    return Future<void>.value();
  }
  final Completer<void> done = Completer<void>();
  binding.addPostFrameCallback((Duration _) => done.complete());
  return done.future;
}

/// 底层合成下画在 WebView2 子窗口上面、要自己接鼠标的一块 Flutter 区域（全局逻辑坐标）。
@immutable
class UnderlayInputExclusion {
  const UnderlayInputExclusion(this.rect, this.radius);

  final Rect rect;

  /// 圆角半径（同坐标系）；挖洞按圆角矩形挖，少裁掉一点网页。
  final double radius;

  @override
  bool operator ==(Object other) =>
      other is UnderlayInputExclusion &&
      other.rect == rect &&
      other.radius == radius;

  @override
  int get hashCode => Object.hash(rect, radius);
}

/// 当前所有 [UnderlayInputRegion] 的区域；底层合成关着时恒为空表。
///
/// 网页档里 WebView2 子窗口收整块矩形的输入（Win32 命中测试先落到子窗口），画在它上面的
/// Flutter 控件看得见、点不到——2026-10-26 用户截图「网页的层级比悬浮球还高，点不到悬浮球」。
/// 网页视图（`WebVideoSurface`）听这张表，把这些区域从子窗口上挖掉。
final ValueNotifier<List<UnderlayInputExclusion>> underlayInputExclusions =
    ValueNotifier<List<UnderlayInputExclusion>>(
      const <UnderlayInputExclusion>[],
    );

final Set<_RenderUnderlayInputRegion> _regionBoxes =
    <_RenderUnderlayInputRegion>{};
bool _regionFrameCallbackInstalled = false;

/// 每帧画完后收一次区域：区域盒子常在 [RepaintBoundary] 里随祖先平移（悬浮球拖动 / 吸附），
/// 自己不重画，所以不能在 paint 里报。只有登记过盒子才装这个回调；表没变不通知。
void _collectUnderlayInputExclusions(Duration _) {
  final List<UnderlayInputExclusion> next = <UnderlayInputExclusion>[
    if (underlayCompositionActive.value)
      for (final _RenderUnderlayInputRegion box in _regionBoxes)
        if (box.attached && box.hasSize && !box.size.isEmpty)
          UnderlayInputExclusion(
            MatrixUtils.transformRect(
              box.getTransformTo(null),
              Offset.zero & box.size,
            ),
            box.radius,
          ),
  ];
  if (!listEquals(next, underlayInputExclusions.value)) {
    underlayInputExclusions.value = next;
  }
}

/// 标记一块「画在网页上面、要自己接鼠标」的 Flutter 区域（见 [underlayInputExclusions]）。
/// 不改布局与绘制；底层合成关着时什么也不做。
class UnderlayInputRegion extends SingleChildRenderObjectWidget {
  const UnderlayInputRegion({this.radius = 0, super.child, super.key});

  final double radius;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderUnderlayInputRegion(radius);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderUnderlayInputRegion renderObject,
  ) {
    renderObject.radius = radius;
  }
}

class _RenderUnderlayInputRegion extends RenderProxyBox {
  _RenderUnderlayInputRegion(this.radius);

  double radius;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _regionBoxes.add(this);
    if (!_regionFrameCallbackInstalled) {
      _regionFrameCallbackInstalled = true;
      SchedulerBinding.instance.addPersistentFrameCallback(
        _collectUnderlayInputExclusions,
      );
      // 开 / 关底层合成本身不一定引起重绘：补一帧，让区域表立刻跟上。
      underlayCompositionActive.addListener(
        () => SchedulerBinding.instance.scheduleFrame(),
      );
    }
  }

  @override
  void detach() {
    _regionBoxes.remove(this);
    super.detach();
  }
}
