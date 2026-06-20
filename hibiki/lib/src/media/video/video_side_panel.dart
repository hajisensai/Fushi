import 'package:flutter/material.dart';

import 'package:hibiki/utils.dart';

class VideoTranslucentSidePanel extends StatelessWidget {
  const VideoTranslucentSidePanel({
    required this.title,
    required this.child,
    this.onClose,
    this.alignment = Alignment.centerRight,
    this.width = 400,
    this.locked = false,
    this.onToggleLock,
    super.key,
  });

  final String title;
  final Widget child;
  final VoidCallback? onClose;
  final Alignment alignment;
  final double width;

  /// 面板锁定状态（TODO-611）。锁定时页面层的「点面板外关闭」barrier 被门控成 no-op
  /// （仅对收藏句子列表这类需要锁定的面板传入；其它面板 [onToggleLock] 为 null）。
  final bool locked;

  /// 用户点 header 锁定图标时回调（TODO-611）。null 时不渲染锁定按钮（只有收藏句子
  /// 列表这类列表面板才传，其它面板不显示锁）。
  final VoidCallback? onToggleLock;

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
                    padding: EdgeInsets.fromLTRB(
                      16,
                      onToggleLock != null ? 4 : 10,
                      onToggleLock != null ? 4 : 16,
                      6,
                    ),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 2,
                            softWrap: true,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        // TODO-611：列表锁定开关。锁定后页面层「点面板外关闭」barrier
                        // 被门控成 no-op（面板不会被点外部关闭，仅 Esc 可关）。
                        // onToggleLock 为 null 时不渲染（只有收藏句子列表才传）。
                        if (onToggleLock != null)
                          IconButton(
                            tooltip: locked
                                ? t.video_subtitle_list_unlock
                                : t.video_subtitle_list_lock,
                            icon: Icon(
                              locked ? Icons.lock : Icons.lock_open,
                            ),
                            color: locked
                                ? colorScheme.primary
                                : colorScheme.onSurfaceVariant,
                            onPressed: onToggleLock,
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
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
