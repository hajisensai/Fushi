/// 跨平台阅读器 chrome（ッツ / Hoshi Reader 形态）的纯函数与外壳组件。
///
/// 各平台阅读器的控制面由三块组成：
///  * **顶部工具栏** [ReaderDesktopHeader]：左「← 返回 / 目录 / 插图 / 统计」，居中书名，
///    右「有声书导入 / 全屏 / 外观设置」。它取代桌面端的底部设置栏，显隐与底栏同一
///    台状态机（点空白唤出、自动收起 / 挤压常驻）。
///  * **右侧抽屉** [ReaderSideSheet]：设置与导航不再弹居中大对话框，而是从右贴边滑出
///    一条纵向面板（[showReaderSideSheet]），点面板外空白即关。
///  * **底部状态行**（reader_status_footer.dart）：常驻挤压式。
///
/// 窄屏折叠次要操作，导航和设置共用侧栏。
///
/// 顶部工具栏在**歌词模式下同样在场**：歌词页是独立 HTML 文档，页内没有任何 chrome，
/// 顶栏是它唯一的返回 / 设置面，而「切回阅读模式」的开关本身就住在这套 chrome 的设置
/// 抽屉里——关掉顶栏等于把歌词模式关成一间没有门的房间。只有底部状态行仍留在歌词模式
/// 之外（它画字数进度 / 阅读追踪，歌词模式不刷新进度，见 reader_status_footer.dart 的
/// `readerStatusFooterEnabled`）。
library;

import 'package:flutter/material.dart';

import 'package:fushi/src/utils/misc/platform_utils.dart'
    show kFushiSettingsWideMinHeight, kFushiSettingsWideThreshold;

/// 顶部工具栏视觉高度 == 挤压态预留高（chrome 铁律：同一真相源，见
/// reader_chrome_floating.dart 文件头）。
const double kReaderDesktopHeaderHeight = 48;

/// 工具栏书名字号（逻辑 px）。阅读器 chrome 的排版活在**阅读面自己的尺度**上，
/// 不跟随 app 全局 MD3 排版令牌——它要和顶部进度胶囊
/// （[kTopProgressFontSize] = 12）、底部状态行（[kReaderStatusFooterFontSize]）
/// 成一族，比正文小一档而比进度胶囊大一档。具名而不写死数字，是为了让
/// md3_design_system_static_test 的豁免有个可指的真相源。
const double kReaderDesktopHeaderTitleFontSize = 14;

/// 右侧抽屉宽度（逻辑 px）。窄窗口下由 [showReaderSideSheet] 收窄到留出 48px 空白。
const double kReaderSideSheetWidth = 400;

/// 有声书面板的容器按可用空间选择：桌面/宽窗走右侧侧栏（与设置侧栏同一容器
/// [showReaderSideSheet]，用户 2026-09-13 拍板：不再弹居中对话框），手机保留全高
/// 底部面板（面板内部 `Flexible` 需要有界高度，bottom sheet 给得起）。
bool readerAudiobookUsesSideSheet({
  required bool desktop,
  required Size window,
}) =>
    desktop ||
    (window.width >= kFushiSettingsWideThreshold &&
        window.height >= kFushiSettingsWideMinHeight);

/// 导航抽屉打开时是否把焦点直接放进「书内搜索」输入框。
///
/// 桌面端有物理键盘：Ctrl+F / 工具栏目录键唤出导航抽屉后，光标落进搜索框才是
/// 「搜索」这个动作的自然续写，不占任何屏幕空间。
///
/// 移动端相反——autofocus 会立刻顶起软键盘，把本来就是主角的**章节目录**压到
/// 剩下的半屏里（抽屉是全高路由，键盘的 viewInsets 直接吃掉下半部分），用户
/// 十次里有九次只是想点一章跳过去，却先要按返回键收键盘。故手机 / 平板一律
/// 不 autofocus：点搜索框仍照常弹键盘，主动权交回用户。
bool readerNavigationAutofocusesSearch({
  required bool navigationPresentation,
  required bool desktop,
}) =>
    navigationPresentation && desktop;

/// 顶部工具栏的顶部预留高。
///
///  * 未启用 / 未占位（`_hasEverLoaded && _showChrome`）→ 0；
///  * 悬浮 → 0：顶栏隐藏时正文满屏，唤出时以半透明面**盖在正文上**
///    （[readerChromeSurfaceColor]），与视频播放器的浮动控制栏同一语义；
///  * 挤压且占位 → [headerHeight]（视觉高度 == 预留高度，正文永不排到它下面）。
///
/// 历史：BUG-2387（2026-09-09）曾删掉 `floating → 0`，让悬浮态也恒定预留 48px，
/// 换来的是「顶栏收起后正文顶上一直留一条空带」——用户 2026-09-13 明确要求回到
/// 「隐藏满屏、唤出覆盖」。「不盖字」的契约只对挤压态成立。悬浮态显隐仍不翻
/// `_showChrome`、不改本函数返回值，故仍不 reflow、不重锚。
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

/// 悬浮态 chrome（顶栏 / 底栏 / 状态行）盖在正文上时的底色：主题背景抬到 0.92
/// 不透明度——既让盖住的那几行字隐约可见（用户知道下面还有正文），又保证按钮与
/// 读数可辨。不用 BackdropFilter：它每帧重采样重模糊（BUG-969），三块面一起开代价
/// 可测。挤压态原样返回（正文本就不在它下面）。
Color readerChromeSurfaceColor(Color background, {required bool floating}) =>
    floating ? background.withValues(alpha: 0.92) : background;

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

bool readerHeaderCompact(double width) =>
    width < kReaderDesktopHeaderCompactWidth;

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
      fontSize: kReaderDesktopHeaderTitleFontSize,
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
                        key: const ValueKey<String>(
                            'fushi_desktop_header_title'),
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
                            tooltip: MaterialLocalizations.of(context)
                                .moreButtonTooltip,
                            icon: Icon(Icons.more_vert, color: textColor),
                            iconSize: 22,
                            onSelected: (ReaderHeaderAction a) =>
                                a.onPressed?.call(),
                            itemBuilder: (BuildContext context) =>
                                <PopupMenuEntry<ReaderHeaderAction>>[
                              for (final ReaderHeaderAction a in overflow)
                                PopupMenuItem<ReaderHeaderAction>(
                                  value: a,
                                  enabled: a.onPressed != null,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      Icon(a.icon, size: 20),
                                      const SizedBox(width: 12),
                                      Flexible(
                                        child: Text(a.label),
                                      ),
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
              Semantics(
                identifier: 'hibiki.reader.side_sheet.close',
                child: IconButton(
                  key: const ValueKey<String>('fushi_side_sheet_close'),
                  icon: const Icon(Icons.close),
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: onClose,
                ),
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

/// BUG-2276：正文 WebView 上报的一次点击，是否应当**只**用来关掉压在正文之上的
/// 侧抽屉（外观设置 / 导航），而不再当成正文点击（翻页 / 查词 / 收放控制栏）。
///
/// 为什么正文点击会漏过 Flutter 的 modal barrier：[showReaderSideSheet] 是
/// `barrierColor: Colors.transparent` 的路由（ッツ 形态不给正文压暗），而
/// **透明遮罩不画任何像素**。macOS 的平台视图命中模型恰恰以「平台视图之上有没有
/// Flutter 绘制」为唯一判据：`FlutterCompositor` 把排在平台视图之后的 backing
/// store 图层的 `paint_region` 写进 `FlutterMutatorView._hitTestIgnoreRegion`，
/// 只有落在该区域的鼠标事件才会被 Flutter 截住（BUG-1692 的根因，同一机制的
/// 另一面）。一张什么都不画的遮罩因此在 macOS 上等于不存在——点击直穿到
/// WKWebView，抽屉的 `barrierDismissible` 永远等不到那次点击，用户看到的就是
/// 「设置/导航开着，点正文关不掉」。Windows（WebView 是纹理）与 Android
/// （hybrid composition）由 Flutter 统一派发指针，遮罩照常吃掉点击，JS 侧根本
/// 收不到这次 tap，故该门在那些平台恒假、行为零变化。
///
/// [readerRouteIsCurrent] 是「阅读器页是不是最顶层路由」：抽屉开着时为 false。
/// 两个条件缺一不可——只看抽屉标志会在抽屉关闭动画期误吞一次正文点击，只看路由
/// 则会把压在正文上的**实色**遮罩对话框（那些遮罩在 macOS 上照常吃点击，JS 不会
/// 上报 tap）也算进来。
bool readerWebViewPointerClosesSideSheet({
  required bool sideSheetOpen,
  required bool readerRouteIsCurrent,
}) =>
    sideSheetOpen && !readerRouteIsCurrent;

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
            child: Padding(
              padding:
                  EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
              child: SafeArea(child: Builder(builder: builder)),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (
      BuildContext ctx,
      Animation<double> animation,
      Animation<double> secondary,
      Widget child,
    ) {
      final Animation<Offset> slide = Tween<Offset>(
        begin: Offset(left ? -1 : 1, 0),
        end: Offset.zero,
      ).animate(
        CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
      );
      return SlideTransition(position: slide, child: child);
    },
  );
}
