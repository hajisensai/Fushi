/// 桌面端阅读器 chrome（ッツ / Hoshi Reader 形态）的纯函数与外壳组件。
///
/// 桌面端（Windows / macOS / Linux，非歌词模式）阅读器的控制面由三块组成：
///  * **顶部工具栏** [ReaderDesktopHeader]：左「← 返回 / 目录 / 插图 / 统计」，居中书名，
///    右「有声书导入 / 全屏 / 外观设置」。它取代桌面端的底部设置栏，显隐与底栏同一
///    台状态机（点空白唤出、自动收起 / 挤压常驻）。
///  * **右侧抽屉** [ReaderSideSheet]：设置与导航不再弹居中大对话框，而是从右贴边滑出
///    一条纵向面板（[showReaderSideSheet]），点面板外空白即关。
///  * **底部状态行**（reader_status_footer.dart）：常驻挤压式。
///
/// 移动端形态不变；歌词模式仍走旧底栏（独立文档，正文 chrome 不适用）。
library;

import 'package:flutter/material.dart';

import 'package:fushi/src/reader/reader_status_footer.dart'
    show readerStatusFooterEnabled;

/// 顶部工具栏视觉高度 == 挤压态预留高（chrome 铁律：同一真相源，见
/// reader_chrome_floating.dart 文件头）。
const double kReaderDesktopHeaderHeight = 48;

/// 右侧抽屉宽度（逻辑 px）。窄窗口下由 [showReaderSideSheet] 收窄到留出 48px 空白。
const double kReaderSideSheetWidth = 400;

/// 桌面端 chrome（顶部工具栏 + 右侧抽屉）是否启用：与底部状态行同一判据——桌面且非
/// 歌词模式。单一真相源，页面的 `_desktopChromeEnabled` 委托到这里。
bool readerDesktopChromeEnabled({
  required bool desktop,
  required bool lyricsMode,
}) => readerStatusFooterEnabled(desktop: desktop, lyricsMode: lyricsMode);

/// 顶部工具栏的顶部预留高。
///
///  * 未启用（移动端 / 歌词模式）→ 0；
///  * 悬浮态（默认：点空白唤出、自动收起）→ 0，工具栏盖在正文之上；
///  * 挤压态且底栏占位（`_hasEverLoaded && _showChrome`）→ [headerHeight]。
///
/// 与 `bottomChromeReserve` 同构：工具栏和底栏是同一台显隐状态机的上下两端。
double readerDesktopHeaderReserve({
  required bool enabled,
  required bool barOccupiesLayout,
  required bool floating,
  required double headerHeight,
}) {
  if (!enabled || !barOccupiesLayout || floating) return 0;
  return headerHeight;
}

/// 抽屉实际宽度：窄窗留 48px 空白给「点外面关掉」的手势，不让抽屉铺满整窗。
double readerSideSheetWidth(double windowWidth) {
  const double minBlank = 48;
  if (windowWidth - minBlank < kReaderSideSheetWidth) {
    return (windowWidth - minBlank).clamp(0, kReaderSideSheetWidth);
  }
  return kReaderSideSheetWidth;
}

/// 顶部工具栏窄于此宽度（逻辑 px）时进入紧凑形态：只留 [ReaderHeaderAction.pinned]
/// 的按钮，其余收进右端 ⋮ 溢出菜单（「常用固定 + 溢出菜单」，避免图标越加越挤）。
const double kReaderDesktopHeaderCompactWidth = 760;

bool readerHeaderCompact(double width) => width < kReaderDesktopHeaderCompactWidth;

/// 顶部工具栏的一个动作：图标 + 文案（溢出菜单里显示）+ 回调。
class ReaderHeaderAction {
  const ReaderHeaderAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.pinned = false,
    this.key,
    this.semanticsId,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  /// 紧凑形态下仍保留为图标按钮（返回 / 导航 / 设置）；其余收进溢出菜单。
  final bool pinned;
  final Key? key;
  final String? semanticsId;
}

/// 紧凑形态下收进溢出菜单的动作（保持 leading → trailing 顺序）。纯函数供测试。
List<ReaderHeaderAction> readerHeaderOverflow({
  required bool compact,
  required List<ReaderHeaderAction> leading,
  required List<ReaderHeaderAction> trailing,
}) {
  if (!compact) return const <ReaderHeaderAction>[];
  return <ReaderHeaderAction>[
    for (final ReaderHeaderAction a in leading)
      if (!a.pinned) a,
    for (final ReaderHeaderAction a in trailing)
      if (!a.pinned) a,
  ];
}

/// 桌面端阅读器顶部工具栏：`[leading…]  书名  [trailing…]`，纯指针面（自带
/// ExcludeFocus，不进焦点遍历池——与底栏同一规则，见 focus-ownership.md）。
/// 宽度不足时按 [readerHeaderCompact] 折叠成「固定按钮 + ⋮ 溢出菜单」。
class ReaderDesktopHeader extends StatelessWidget {
  const ReaderDesktopHeader({
    super.key,
    required this.title,
    required this.leading,
    required this.trailing,
    required this.textColor,
    required this.backgroundColor,
    this.height = kReaderDesktopHeaderHeight,
  });

  final String title;
  final List<ReaderHeaderAction> leading;
  final List<ReaderHeaderAction> trailing;
  final Color textColor;
  final Color backgroundColor;
  final double height;

  Widget _button(ReaderHeaderAction a) => ReaderDesktopHeaderButton(
        key: a.key,
        icon: a.icon,
        tooltip: a.label,
        color: textColor,
        semanticsId: a.semanticsId,
        onPressed: a.onPressed,
      );

  @override
  Widget build(BuildContext context) {
    final TextStyle titleStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: textColor.withValues(alpha: 0.85),
      height: 1.0,
    );
    return ExcludeFocus(
      child: ColoredBox(
      color: backgroundColor,
      child: SizedBox(
        height: height,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool compact = readerHeaderCompact(constraints.maxWidth);
            final List<ReaderHeaderAction> overflow = readerHeaderOverflow(
              compact: compact,
              leading: leading,
              trailing: trailing,
            );
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: <Widget>[
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      for (final ReaderHeaderAction a in leading)
                        if (!compact || a.pinned) _button(a),
                    ],
                  ),
                  Expanded(
                    child: Text(
                      title,
                      key: const ValueKey<String>('fushi_desktop_header_title'),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: titleStyle,
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      for (final ReaderHeaderAction a in trailing)
                        if (!compact || a.pinned) _button(a),
                      if (overflow.isNotEmpty)
                        PopupMenuButton<ReaderHeaderAction>(
                          key: const ValueKey<String>(
                            'fushi_desktop_header_overflow',
                          ),
                          tooltip:
                              MaterialLocalizations.of(context).moreButtonTooltip,
                          icon: Icon(Icons.more_vert, color: textColor),
                          iconSize: 22,
                          onSelected: (ReaderHeaderAction a) =>
                              a.onPressed?.call(),
                          itemBuilder: (BuildContext context) => <
                              PopupMenuEntry<ReaderHeaderAction>>[
                            for (final ReaderHeaderAction a in overflow)
                              PopupMenuItem<ReaderHeaderAction>(
                                value: a,
                                enabled: a.onPressed != null,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    Icon(a.icon, size: 20),
                                    const SizedBox(width: 12),
                                    Text(a.label),
                                  ],
                                ),
                              ),
                          ],
                        ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
      ),
    );
  }
}

/// 顶部工具栏里的一颗图标按钮：统一 22px 图标、主题文字色、tooltip。
class ReaderDesktopHeaderButton extends StatelessWidget {
  const ReaderDesktopHeaderButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onPressed,
    this.semanticsId,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback? onPressed;
  final String? semanticsId;

  @override
  Widget build(BuildContext context) {
    final Widget button = IconButton(
      icon: Icon(icon, color: color),
      iconSize: 22,
      tooltip: tooltip,
      onPressed: onPressed,
    );
    if (semanticsId == null) return button;
    return Semantics(identifier: semanticsId, child: button);
  }
}

/// 右侧抽屉外壳：标题行（标题 + 关闭 ×）+ 可滚动内容。
class ReaderSideSheet extends StatelessWidget {
  const ReaderSideSheet({
    super.key,
    required this.title,
    required this.child,
    required this.onClose,
    this.padding = const EdgeInsets.fromLTRB(20, 4, 20, 24),
  });

  final String title;
  final Widget child;
  final VoidCallback onClose;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  title,
                  key: const ValueKey<String>('fushi_side_sheet_title'),
                  style: theme.textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                key: const ValueKey<String>('fushi_side_sheet_close'),
                icon: const Icon(Icons.close),
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: onClose,
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(padding: padding, child: child),
        ),
      ],
    );
  }
}

/// 抽屉里分组标题（ッツ 风格：小号大写字母间距标签，如 THEME / TEXT / LAYOUT）。
class ReaderSideSheetSectionLabel extends StatelessWidget {
  const ReaderSideSheetSectionLabel(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(
        label.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          letterSpacing: 1.2,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 抽屉贴哪一边：ッツ 形态下「导航 / 章节」贴左、「外观」贴右。
enum ReaderSideSheetSide { left, right }

/// 从左或右贴边滑出一条全高抽屉路由。遮罩透明（正文照常可见），点抽屉外空白即关。
///
/// 用**路由**而非页内 Stack 叠层：抽屉里有输入框（书内搜索 / 按字数跳转），焦点
/// 需要真正离开正文；走路由让焦点体系与既有的居中设置对话框完全一致
/// （focus-ownership.md 的 overlay 语义），不引入新的焦点所有者。
Future<T?> showReaderSideSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  ReaderSideSheetSide side = ReaderSideSheetSide.right,
}) {
  final bool left = side == ReaderSideSheetSide.left;
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (BuildContext ctx, Animation<double> a, Animation<double> b) {
      final double width = readerSideSheetWidth(MediaQuery.sizeOf(ctx).width);
      return Align(
        alignment: left ? Alignment.centerLeft : Alignment.centerRight,
        child: SizedBox(
          width: width,
          height: double.infinity,
          child: Material(
            key: const ValueKey<String>('fushi_reader_side_sheet'),
            color: Theme.of(ctx).colorScheme.surface,
            elevation: 8,
            child: Builder(builder: builder),
          ),
        ),
      );
    },
    transitionBuilder:
        (
          BuildContext ctx,
          Animation<double> animation,
          Animation<double> secondary,
          Widget child,
        ) {
          final Animation<Offset> slide =
              Tween<Offset>(
                begin: Offset(left ? -1 : 1, 0),
                end: Offset.zero,
              ).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              );
          return SlideTransition(position: slide, child: child);
        },
  );
}
