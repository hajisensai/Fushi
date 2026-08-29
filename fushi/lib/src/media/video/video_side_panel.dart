import 'package:flutter/material.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_chrome_colors.dart';

/// 底部半透明**抽屉**：与 [VideoTranslucentSidePanel] 同一套配色/圆角/焦点纪律，只是
/// 贴底而不是贴边——视频全幅可见、继续播放，字幕在真实位置实时预览（字幕调整专用，
/// 2026-08 字幕工作台 PR-C）。
///
/// 三个交互：头部拖拽条上下拖改高度（[minHeightFraction]..[maxHeightFraction]）、
/// 「收起」把抽屉缩成只剩头部一条、「关闭」交给 [onClose]（页面层的点外 barrier 也会
/// 关）。高度是本 widget 的瞬时状态，不持久化——每次打开回到 [initialHeightFraction]。
class VideoTranslucentBottomDrawer extends StatefulWidget {
  const VideoTranslucentBottomDrawer({
    required this.title,
    required this.child,
    this.onClose,
    this.initialHeightFraction = 0.42,
    this.minHeightFraction = 0.2,
    this.maxHeightFraction = 0.9,
    this.maxWidth = 1100,
    super.key,
  });

  final String title;
  final Widget child;
  final VoidCallback? onClose;

  /// 打开时的高度（占屏高比例）。
  final double initialHeightFraction;
  final double minHeightFraction;
  final double maxHeightFraction;

  /// 桌面大窗口下的宽度上限（抽屉居中）；窄窗吃满宽度减边距。
  final double maxWidth;

  @override
  State<VideoTranslucentBottomDrawer> createState() =>
      _VideoTranslucentBottomDrawerState();
}

class _VideoTranslucentBottomDrawerState
    extends State<VideoTranslucentBottomDrawer> {
  late double _fraction = widget.initialHeightFraction;
  bool _collapsed = false;

  void _onDrag(DragUpdateDetails details, double screenHeight) {
    if (screenHeight <= 0) return;
    setState(() {
      _collapsed = false;
      _fraction = (_fraction - details.delta.dy / screenHeight)
          .clamp(widget.minHeightFraction, widget.maxHeightFraction)
          .toDouble();
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colorScheme = theme.colorScheme;
    final Size screen = MediaQuery.sizeOf(context);
    const double margin = 10.0;
    final double width = (screen.width - margin * 2)
        .clamp(0.0, widget.maxWidth)
        .toDouble();
    final double height = (screen.height * _fraction)
        .clamp(0.0, screen.height - margin * 2)
        .toDouble();
    const BorderRadius borderRadius = BorderRadius.all(Radius.circular(12));

    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(margin, 0, margin, margin),
          child: SizedBox(
            width: width,
            height: _collapsed ? null : height,
            child: Material(
              key: const ValueKey<String>('video-subtitle-drawer'),
              color: colorScheme.surface
                  .withValues(alpha: kVideoOverlayTranslucentAlpha),
              elevation: 8,
              clipBehavior: Clip.antiAlias,
              borderRadius: borderRadius,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  GestureDetector(
                    key: const ValueKey<String>('video-subtitle-drawer-handle'),
                    behavior: HitTestBehavior.opaque,
                    onVerticalDragUpdate: (DragUpdateDetails d) =>
                        _onDrag(d, screen.height),
                    onTap: () => setState(() => _collapsed = !_collapsed),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 8, 4),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                Center(
                                  child: Container(
                                    width: 36,
                                    height: 4,
                                    decoration: BoxDecoration(
                                      color: colorScheme.outlineVariant,
                                      borderRadius: borderRadius,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  widget.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium,
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            key: const ValueKey<String>(
                              'video-subtitle-drawer-collapse',
                            ),
                            tooltip: _collapsed
                                ? t.video_subtitle_adjust_expand
                                : t.video_subtitle_adjust_collapse,
                            onPressed: () =>
                                setState(() => _collapsed = !_collapsed),
                            icon: Icon(
                              _collapsed
                                  ? Icons.keyboard_arrow_up
                                  : Icons.keyboard_arrow_down,
                            ),
                          ),
                          IconButton(
                            key: const ValueKey<String>(
                              'video-subtitle-drawer-close',
                            ),
                            tooltip: t.dialog_close,
                            onPressed: widget.onClose,
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (!_collapsed) ...<Widget>[
                    const Divider(height: 1),
                    Expanded(child: widget.child),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

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
    // 侧栏与窗口四边都留有安全间距，因此外侧两个角也应完整露出；旧实现只给
    // 靠画面一侧加圆角，右侧栏的右上 / 右下仍是直角，看起来像贴边抽屉。
    const BorderRadius borderRadius = BorderRadius.all(Radius.circular(12));

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
              // 浮层 alpha 两档制的半透明档（UI 巡检 PR-4）。
              color: colorScheme.surface
                  .withValues(alpha: kVideoOverlayTranslucentAlpha),
              elevation: 8,
              clipBehavior: Clip.antiAlias,
              borderRadius: borderRadius,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // BUG-254：去掉右上角 X 关闭按钮，改为点击面板外的空白区域关闭
                  // （由页面层的全屏透明 barrier 承载，见 video_fushi_page 的
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
