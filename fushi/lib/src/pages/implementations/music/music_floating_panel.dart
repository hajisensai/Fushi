/// 播放页的浮层卡片（音效 / 音质 / 播放队列共用一个外壳，用户 2026-11-08：音效「做个
/// panel」、队列「侧边栏推出很丑」、音质「排版很差」）。
///
/// 宽屏（≥ [kMusicFloatingPanelMinWidth]）：浮在页面上的圆角卡片，不挤压播放页布局，
/// 按 [alignment] 停靠（音效 / 音质居中，队列在右下角挨着控件区）；点卡片外 / Esc 关闭。
/// 窄屏：同一块内容装进底部弹层。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 宽于此（逻辑像素）时浮起卡片；更窄时走底部弹层。
const double kMusicFloatingPanelMinWidth = 720;

/// 这个上下文下浮层是不是浮起的卡片（否则是底部弹层）。
bool musicFloatingPanelFloats(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= kMusicFloatingPanelMinWidth;

/// 打开浮层。[builder] 给出卡片正文（自己负责内边距）；[scrollable] 为真时正文外包一层
/// 纵向滚动（队列面板自带列表时传假，并给定 [height]）。
Future<void> showMusicFloatingPanel({
  required BuildContext context,
  required WidgetBuilder builder,
  double maxWidth = 560,
  AlignmentGeometry alignment = Alignment.center,
  EdgeInsets margin = const EdgeInsets.all(24),
  double? height,
  bool scrollable = true,
}) {
  final Size screen = MediaQuery.sizeOf(context);
  if (!musicFloatingPanelFloats(context)) {
    return adaptiveModalSheet<void>(
      context: context,
      builder: (BuildContext c) {
        final Widget body = builder(c);
        if (height != null) {
          return SizedBox(
            height: (screen.height * 0.75).clamp(320, 720).toDouble(),
            child: body,
          );
        }
        return SafeArea(
          child: scrollable ? SingleChildScrollView(child: body) : body,
        );
      },
    );
  }
  return showAppDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.12),
    builder: (BuildContext c) {
      final FushiDesignTokens tokens = FushiDesignTokens.of(c);
      final Widget body = builder(c);
      return SafeArea(
        child: Padding(
          padding: margin,
          child: Align(
            alignment: alignment,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: Material(
                color: tokens.surfaces.group,
                elevation: 8,
                shadowColor: Colors.black.withValues(alpha: 0.35),
                borderRadius: FushiM3eShape.containerLargeRadius,
                clipBehavior: Clip.antiAlias,
                child: height != null
                    ? SizedBox(height: height, child: body)
                    : (scrollable ? SingleChildScrollView(child: body) : body),
              ),
            ),
          ),
        ),
      );
    },
  );
}
