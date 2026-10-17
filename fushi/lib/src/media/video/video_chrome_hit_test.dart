import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:media_kit_video/media_kit_video.dart'
    show VideoControlsChromeRegion;

/// 视频页「这一下落在控件上，还是落在画面上」的唯一判据：按落点做一次**真实**
/// hit-test，看命中路径里有没有控件。
///
/// 旧判据是几何猜测——只把顶 / 底各一条「按钮行高」宽的带当控制条。M3E 浮动底栏
/// （进度条 + 胶囊按钮行 + 外边距 + 抬升）远比这条带高，按钮上半截落在带外，连点
/// 「+10s」两下就被当成双击画面 → 切全屏 / 双击 seek；不在两条带里的浮层按钮
/// （侧边动作栏、自动连播卡、横幅、小窗三键……）同样中招。控件长在哪、多高都由
/// 渲染树说了算，判据不再复制任何几何。
///
/// 命中路径里出现以下任一即算控件：
/// - [VideoControlsChromeRegion]：media_kit 控制条的顶栏 / 中央按钮 / 进度条 / 底栏
///   整块区域（含按钮间空隙与外边距）；
/// - 带 `onTap` 语义的 [RenderSemanticsAnnotations]：[InkWell] 与全部 Material 按钮
///   都会挂这层（可用时才有 onTap），覆盖页面自己叠的各种浮层按钮。铺满画面的
///   [GestureDetector] 手势层走的是另一类语义节点，不会被误算。
///
/// 不用「click 光标」当判据：[InkWell] 的默认光标是
/// `WidgetStateMouseCursor.adaptiveClickable`，原生平台解析成 basic，只有 web 才是 click。
bool videoPointerHitsChrome({
  required Offset globalPosition,
  required int viewId,
}) {
  final HitTestResult result = HitTestResult();
  RendererBinding.instance.hitTestInView(result, globalPosition, viewId);
  return hitPathIsVideoChrome(
    result.path.map((HitTestEntry entry) => entry.target),
  );
}

/// [videoPointerHitsChrome] 的纯判定部分。
bool hitPathIsVideoChrome(Iterable<HitTestTarget> targets) {
  for (final HitTestTarget target in targets) {
    if (VideoControlsChromeRegion.isRegion(target)) return true;
    if (target is RenderSemanticsAnnotations &&
        target.properties.onTap != null) {
      return true;
    }
  }
  return false;
}
