import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/video/video_side_panel.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 视频画面顶部居中的紧凑浮条层（「浮条调轴」用）：整片画面大小的透明层，浮条
/// 表面按内容收缩、宽度封顶 [maxWidth]，进场从上方滑入淡入。层本身不吃命中，
/// 浮条以外的画面照常可点。
///
/// [FushiAppUiScale] 必须包在 [Align] **外面**：缩放 ≠ 1 时它按收到约束的最大值
/// 铺满一张画布、再把**紧**约束传给子树。曾经放在 Align 里面——Align 给的是整片
/// 画面的宽松约束，缩放层把它当画布铺满，浮条表面被撑成盖住大半个画面的空白大板
/// （maxWidth 也被紧约束覆盖），正好挡住调轴时要看的画面。放在外面则画布 = 整片
/// 画面，Align 再给浮条宽松约束。
class VideoTopFloatBarLayer extends StatelessWidget {
  const VideoTopFloatBarLayer({
    required this.scale,
    required this.surfaceKey,
    required this.child,
    this.maxWidth = 720,
    super.key,
  });

  /// 视频页界面缩放（`_videoUiScale`）。
  final double scale;

  /// 挂在浮条表面上的 key（测试 / 几何断言按它取浮条矩形）。
  final Key surfaceKey;

  /// 浮条宽度上限（缩放后画布里的逻辑像素）。
  final double maxWidth;

  /// 浮条内容（表面内已留内边距）。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return FushiAppUiScale(
      scale: scale,
      child: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: fushiMotionDuration(context, FushiMotion.medium),
              curve: FushiMotion.enter,
              builder: (BuildContext context, double t, Widget? child) =>
                  FractionalTranslation(
                    translation: Offset(0, -0.4 * (1 - t)),
                    child: Opacity(opacity: t.clamp(0.0, 1.0), child: child),
                  ),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: VideoFloatingPanelSurface(
                  opaque: true,
                  surfaceKey: surfaceKey,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
