import 'package:flutter/material.dart';

class VideoTranslucentSidePanel extends StatelessWidget {
  const VideoTranslucentSidePanel({
    required this.title,
    required this.child,
    this.onClose,
    this.alignment = Alignment.centerRight,
    this.width = 400,
    super.key,
  });

  final String title;
  final Widget child;
  final VoidCallback? onClose;
  final Alignment alignment;
  final double width;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final Size screen = MediaQuery.sizeOf(context);
    const double horizontalMargin = 10.0;
    final double availableWidth =
        (screen.width - horizontalMargin * 2).clamp(0.0, double.infinity);
    final double maxPanelWidth = availableWidth * 0.94;
    final double minPanelWidth = maxPanelWidth < 280.0 ? maxPanelWidth : 280.0;
    final double panelWidth =
        width.clamp(minPanelWidth, maxPanelWidth).toDouble();
    final BorderRadiusDirectional borderRadius = alignment.x < 0
        ? const BorderRadiusDirectional.horizontal(end: Radius.circular(8))
        : const BorderRadiusDirectional.horizontal(start: Radius.circular(8));

    return Align(
      alignment: alignment,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: horizontalMargin,
            vertical: 10,
          ),
          child: SizedBox(
            width: panelWidth,
            child: Material(
              color: colorScheme.surface.withValues(alpha: 0.78),
              elevation: 8,
              clipBehavior: Clip.antiAlias,
              borderRadius: borderRadius,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // BUG-254：去掉右上角 X 关闭按钮，改为点击面板外的空白区域关闭
                  // （由页面层的全屏透明 barrier 承载，见 video_hibiki_page 的
                  // [_buildVideoSidePanelOverlay]）。[onClose] 仍保留供 barrier / 其他
                  // 调用方复用，header 不再渲染关闭按钮。
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                    child: Text(
                      title,
                      maxLines: 2,
                      softWrap: true,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(child: child),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
