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

import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/physics.dart' show SpringSimulation;
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_theme_host.dart';
import 'package:fushi/src/reader/reader_panel_chrome_kit.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_neutral_decor.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_section_title.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

/// 顶部工具栏视觉高度 == 挤压态预留高（chrome 铁律：同一真相源，见
/// reader_chrome_floating.dart 文件头）。
const double kReaderDesktopHeaderHeight = 48;

/// 工具栏书名字号（逻辑 px）。阅读器 chrome 的排版活在**阅读面自己的尺度**上，
/// 不跟随 app 全局 MD3 排版令牌——它要和顶部进度胶囊
/// （[kTopProgressFontSize] = 12）、底部状态行（[kReaderStatusFooterFontSize]）
/// 成一族，比正文小一档而比进度胶囊大一档。具名而不写死数字，是为了让
/// m3e_design_system_static_test 的豁免有个可指的真相源。
const double kReaderDesktopHeaderTitleFontSize = 14;

/// 悬浮工具栏样式（M3E floating toolbar，默认）下胶囊离窗口边 / 状态行的外边距。
const double kReaderFloatingBarMargin = 8;

/// 悬浮样式顶部胶囊行的整段外框高（上外边距 8 + 56 高胶囊 + 下外边距 8）：挤压态
/// （不点空白隐藏）据此给正文预留，正文不排到胶囊下面。
const double kReaderFloatingHeaderExtent = 72;

/// 悬浮样式底部（迷你播放条 / 悬浮工具栏）的最大宽度：宽屏上不拉成整条，
/// 居中成一块胶囊组。
const double kReaderFloatingBottomMaxWidth = 560;

/// 右侧抽屉宽度（逻辑 px）。窄窗口下由 [showReaderSideSheet] 收窄到留出 48px 空白。
const double kReaderSideSheetWidth = 400;

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

/// 平板档（[kReaderPanelCompactWidth] ≤ 宽 < [kReaderPanelExpandedWidth]）的侧板宽。
const double kReaderSideSheetTabletWidth = 380;

/// 抽屉实际宽度：桌面档 [kReaderSideSheetWidth]（400，约定 380–420），平板档
/// [kReaderSideSheetTabletWidth]；窄窗留 48px 空白给「点外面关掉」的手势，不让抽屉
/// 铺满整窗。
double readerSideSheetWidth(double windowWidth) {
  const double minBlank = 48;
  final double preferred = readerPanelTierFor(windowWidth) ==
          ReaderPanelTier.tablet
      ? kReaderSideSheetTabletWidth
      : kReaderSideSheetWidth;
  if (windowWidth - minBlank < preferred) {
    return (windowWidth - minBlank).clamp(0, preferred);
  }
  return preferred;
}

/// 顶部工具栏窄于此宽度（逻辑 px）时进入紧凑形态：只留 [ReaderHeaderAction.pinned]
/// 的按钮，其余收进右端 ⋮ 溢出菜单（「常用固定 + 溢出菜单」，避免图标越加越挤）。
///
/// 这个**与内容无关**的固定阈值只剩漫画顶栏（`manga_reader_chrome.dart`）在用：
/// 那一栏要按「导航 / 视图 / 界面」分组夹分隔线、还要塞 OCR 进度胶囊，所需宽度
/// 算不准。EPUB 顶栏已改按实际按钮数判断（[readerHeaderCompactForActions]）。
const double kReaderDesktopHeaderCompactWidth = 760;

bool readerHeaderCompact(double width) =>
    width < kReaderDesktopHeaderCompactWidth;

/// 顶栏一颗图标按钮占的宽度（逻辑 px）：[ReaderDesktopHeaderButton] 里的
/// `IconButton(iconSize: 22)` 在 MD3 默认视觉密度下是 40×40 的按压面，外加
/// tap-target 补到 48。取整数上界，宁可算宽一点也不让这一栏真的溢出。
const double kReaderDesktopHeaderButtonWidth = 48;

/// 书名至少要留住的宽度（逻辑 px）。低于它书名只剩一两个字加省略号，那时把次要
/// 按钮收进 ⋮ 把宽度让给书名才划算。
const double kReaderDesktopHeaderTitleMinWidth = 120;

/// 顶栏两端内边距合计（逻辑 px），与 [ReaderDesktopHeader] 的
/// `EdgeInsets.symmetric(horizontal: 8)` 同源。
const double kReaderDesktopHeaderHorizontalPadding = 16;

/// 章名最多吃掉标题槽的比例：书名是主信息，章名再长也不许把书名挤成省略号。
const double _chapterWidthFraction = 0.4;

/// EPUB 顶栏是否进入紧凑形态（只留 pinned 按钮，其余收进 ⋮ 溢出菜单）。
///
/// 判据是**这一栏此刻真的放不下**：[actionCount] 颗按钮加两端内边距占掉的宽之后，
/// 留给书名的若不足 [titleMinWidth] 才折叠。此前用的是与内容无关的固定窗宽阈值
/// [kReaderDesktopHeaderCompactWidth]（760）：横屏手机 ~700 逻辑 px 上明明只有
/// 六颗按钮、书名两侧还空着大半条，插图 / 统计 / 有声书照样被折进 ⋮（用户
/// 2026-09-14「顶部有空间的时候应该把顶栏收起的按钮放出来」）。顶部有空间，按钮
/// 就该在外面。
///
/// 书名不显示（[showsTitle] 为假，布局里关掉了书名）时按钮可以一路占到两端内边距，
/// 只有真排不下才折叠。
///
/// 折叠后栏内只剩 pinned 按钮加一颗 ⋮，宽度必然比展开态小，故这个判据不会在
/// 「折叠 → 变宽 → 又判不折叠」之间抖动。
bool readerHeaderCompactForActions({
  required double width,
  required int actionCount,
  bool showsTitle = true,
  double buttonWidth = kReaderDesktopHeaderButtonWidth,
  double titleMinWidth = kReaderDesktopHeaderTitleMinWidth,
  double horizontalPadding = kReaderDesktopHeaderHorizontalPadding,
}) {
  final double free = width - horizontalPadding - actionCount * buttonWidth;
  return free < (showsTitle ? titleMinWidth : 0);
}

/// 顶部工具栏的一个动作：图标 + 文案（溢出菜单里显示）+ 回调。
class ReaderHeaderAction {
  const ReaderHeaderAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.pinned = false,
    this.key,
    this.semanticsId,
    this.tooltip,
  });

  final IconData icon;

  /// 可见文案（工具栏标签 / 菜单项）：只放功能名，不拼快捷键。
  final String label;
  final VoidCallback? onPressed;

  /// 悬停提示；带快捷键的动作在这里括注键名（[tooltipWithShortcutHint]）。
  /// null 时与 [label] 相同。
  final String? tooltip;

  String get tooltipText => tooltip ?? label;

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

/// 桌面端阅读器顶部工具栏：`[leading…]  书名 · 章名  [trailing…]`，纯指针面（自带
/// ExcludeFocus，不进焦点遍历池——与底栏同一规则，见 focus-ownership.md）。
/// 宽度**真的**不足时（[readerHeaderCompactForActions]：按钮占完还留不下书名）
/// 折叠成「固定按钮 + ⋮ 溢出菜单」。
class ReaderDesktopHeader extends StatelessWidget {
  const ReaderDesktopHeader({
    super.key,
    required this.title,
    required this.leading,
    required this.trailing,
    required this.textColor,
    required this.backgroundColor,
    this.chapter = '',
    this.height = kReaderDesktopHeaderHeight,
    this.overflowActions = const <ReaderHeaderAction>[],
  });

  /// 恒在 ⋮ 菜单里的动作（布局的「更多」槽，2026-10 工具栏精简）；宽窗不展开。
  final List<ReaderHeaderAction> overflowActions;

  final String title;

  /// 当前章名（TOC 命中标签；命不中时调用方给「第 N 章」兜底）。空串=不显示。
  /// 与书名同在标题槽，故由调用方跟着「显示书名」开关一起开合。
  final String chapter;
  final List<ReaderHeaderAction> leading;
  final List<ReaderHeaderAction> trailing;
  final Color textColor;
  final Color backgroundColor;
  final double height;

  Widget _button(ReaderHeaderAction a) => ReaderDesktopHeaderButton(
        key: a.key,
        icon: a.icon,
        tooltip: a.tooltipText,
        color: textColor,
        semanticsId: a.semanticsId,
        onPressed: a.onPressed,
      );

  /// 标题槽：`书名 · 章名`。章名与书名重复（单章书的 TOC 常把章名写成书名）时只画书名。
  ///
  /// 两段各自省略号，但**不是**对半分：章名按可用宽的上限 [_chapterWidthFraction]
  /// 先量（非 flex 子节点先布局），剩下的整条归书名。章名短时书名照旧能铺满，
  /// 章名长时也只吃掉不到一半——一个 Text.rich 做不到这点（省略号只截尾，先没的
  /// 反而是后半段的章名）。
  Widget _buildTitleSlot(TextStyle titleStyle, TextStyle chapterStyle) {
    final Widget titleText = Text(
      title,
      key: const ValueKey<String>('fushi_desktop_header_title'),
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: titleStyle,
    );
    if (chapter.isEmpty || chapter == title) return titleText;
    if (title.isEmpty) {
      return Text(
        chapter,
        key: const ValueKey<String>('fushi_desktop_header_chapter'),
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: chapterStyle,
      );
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Flexible(child: titleText),
            Text(' · ', style: chapterStyle),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: constraints.maxWidth * _chapterWidthFraction,
              ),
              child: Text(
                chapter,
                key: const ValueKey<String>('fushi_desktop_header_chapter'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: chapterStyle,
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final TextStyle titleStyle = TextStyle(
      fontSize: kReaderDesktopHeaderTitleFontSize,
      fontWeight: FontWeight.w600,
      color: textColor.withValues(alpha: 0.85),
      height: 1.0,
    );
    // 章名是书名的附属信息：同字号、更淡、不加粗，让「哪本书」仍是第一眼读到的。
    final TextStyle chapterStyle = titleStyle.copyWith(
      fontWeight: FontWeight.w400,
      color: textColor.withValues(alpha: 0.55),
    );
    return ExcludeFocus(
      child: ColoredBox(
        color: backgroundColor,
        child: SizedBox(
          height: height,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool compact = readerHeaderCompactForActions(
                width: constraints.maxWidth,
                actionCount: leading.length +
                    trailing.length +
                    (overflowActions.isEmpty ? 0 : 1),
                showsTitle: title.isNotEmpty,
              );
              final List<ReaderHeaderAction> overflow = <ReaderHeaderAction>[
                ...readerHeaderOverflow(
                  compact: compact,
                  leading: leading,
                  trailing: trailing,
                ),
                ...overflowActions,
              ];
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
                      child: _buildTitleSlot(titleStyle, chapterStyle),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        for (final ReaderHeaderAction a in trailing)
                          if (!compact || a.pinned) _button(a),
                        if (overflow.isNotEmpty)
                          FushiPopupMenuButton<ReaderHeaderAction>(
                            key: const ValueKey<String>(
                              'fushi_desktop_header_overflow',
                            ),
                            tooltip: MaterialLocalizations.of(context)
                                .moreButtonTooltip,
                            icon: FushiIcon(Icons.more_vert, color: textColor),
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
                                      FushiIcon(a.icon, size: 20),
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
    final Widget button = FushiIconButtonControl(
      icon: FushiIcon(icon, color: color),
      iconSize: 22,
      tooltip: tooltip,
      onPressed: onPressed,
    );
    if (semanticsId == null) return button;
    return Semantics(identifier: semanticsId, child: button);
  }
}

/// 阅读器面板的呈现形态：宽窗贴边侧板，窄窗（手机竖屏）底部 sheet。
enum ReaderPanelPresentation { side, bottom }

/// 窄于此宽度（逻辑 px，MD3 compact window class 的上界）时，开启了
/// `bottomSheetWhenCompact` 的面板改从底部升起：手机竖屏上 400px 的侧板会把正文
/// 压成一条 48px 的缝，底部 sheet 保留上方一截正文可见、单手也够得着。
const double kReaderPanelCompactWidth = 600;

/// 宽于此（逻辑 px，MD3 expanded window class 下界）为桌面档：侧板浮在透明遮罩上，
/// 正文照常可见；600–840 的平板档侧板可覆盖正文，带一层淡遮罩。
const double kReaderPanelExpandedWidth = 840;

/// 面板的三档窗口（约定：手机 < 600 底部 sheet / 平板 600–840 侧板 + 淡遮罩 /
/// 桌面 ≥ 840 侧板 + 透明遮罩）。
enum ReaderPanelTier { phone, tablet, desktop }

ReaderPanelTier readerPanelTierFor(double windowWidth) {
  if (windowWidth < kReaderPanelCompactWidth) return ReaderPanelTier.phone;
  if (windowWidth < kReaderPanelExpandedWidth) return ReaderPanelTier.tablet;
  return ReaderPanelTier.desktop;
}

/// 各档遮罩不透明度（scrim 色上的 alpha）：手机 0.32（MD3 modal sheet）/ 平板
/// 0.16（侧板盖住正文，淡遮罩提示「点外面关」）/ 桌面 0（ッツ 形态，正文可读）。
double readerPanelScrimOpacity(
  ReaderPanelTier tier, {
  required ReaderPanelPresentation presentation,
}) {
  if (presentation == ReaderPanelPresentation.bottom) return 0.32;
  return tier == ReaderPanelTier.tablet ? 0.16 : 0;
}

/// 面板的形态判据（纯函数，供测试）：只有调用方允许、且窗口窄于
/// [kReaderPanelCompactWidth] 时才是底部 sheet。
ReaderPanelPresentation readerPanelPresentationFor(
  Size window, {
  required bool bottomSheetWhenCompact,
}) {
  if (bottomSheetWhenCompact && window.width < kReaderPanelCompactWidth) {
    return ReaderPanelPresentation.bottom;
  }
  return ReaderPanelPresentation.side;
}

/// 底部 sheet 的高度：可用高度（扣掉键盘与顶部安全区、再留一截正文可见）与
/// 窗高 [kReaderPanelBottomSheetHeightFraction] 取小。
const double kReaderPanelBottomSheetHeightFraction = 0.86;

/// 底部 sheet 的半屏档（约定「两档高度：半屏 / 86%」）：从满高向下拖过一段停在
/// 这里，再向下拖才关闭；从半屏向上拖回满高。
const double kReaderPanelBottomSheetHalfFraction = 0.5;

/// 底部 sheet 顶上至少留出的正文高度（逻辑 px），点它即关。
const double kReaderPanelBottomSheetTopGap = 48;

/// 底部 sheet 的最大宽度：横向更宽的窄窗（如 580 宽的分屏）不铺满整行。
const double kReaderPanelBottomSheetMaxWidth = 640;

double readerPanelBottomSheetHeight({
  required double windowHeight,
  required double topPadding,
  required double keyboardInset,
}) {
  final double available =
      windowHeight - keyboardInset - topPadding - kReaderPanelBottomSheetTopGap;
  final double preferred = windowHeight * kReaderPanelBottomSheetHeightFraction;
  return available < preferred ? (available < 0 ? 0 : available) : preferred;
}

/// 面板内容拿得到的呈现上下文（[ReaderSideSheet] 据此画拖动把手、
/// [ReaderSettingsSideButton] 在底部 sheet 下隐藏左右换边键）。
class ReaderPanelScope extends InheritedWidget {
  const ReaderPanelScope({
    super.key,
    required this.presentation,
    required super.child,
  });

  final ReaderPanelPresentation presentation;

  bool get isBottomSheet => presentation == ReaderPanelPresentation.bottom;

  static ReaderPanelPresentation of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ReaderPanelScope>()
          ?.presentation ??
      ReaderPanelPresentation.side;

  @override
  bool updateShouldNotify(ReaderPanelScope oldWidget) =>
      presentation != oldWidget.presentation;
}

/// 阅读器面板外壳（导航 / 设置 / 统计 / 有声书共用）：页头（可选图标徽标 +
/// 标题 + 副标题 + 动作 + 关闭 ×）+ 可选固定页头 [bottom] + 内容。
///
/// 页头是共享的 [ReaderPanelHeader]（reader_panel_chrome_kit.dart）：M3 Expressive 下
/// 图标落在 primaryContainer 的 cookie 形底上、标题加粗 titleLarge，副标题给
/// 上下文（书名 / 当前章）；Apple 下是强调色字形 + iOS 灰底关闭键。底部 sheet 形态在页头上方多一条拖动把手
/// （向下拖动关闭）。颜色全部取 context 主题，歌词模式注入的封面取色主题照常生效。
class ReaderSideSheet extends StatelessWidget {
  const ReaderSideSheet({
    super.key,
    required this.title,
    required this.child,
    required this.onClose,
    this.subtitle,
    this.icon,
    this.padding = defaultPadding,
    this.headerActions = const <Widget>[],
    this.bottom,
    this.scrollable = true,
  });

  /// 内容区默认留白；自管滚动的调用方（[scrollable] = false）按它对齐。
  static const EdgeInsets defaultPadding = EdgeInsets.fromLTRB(20, 4, 20, 24);

  final String title;

  /// 标题下一行的上下文（书名、当前章）；null / 空串不画。
  final String? subtitle;

  /// 页头左侧的中性图标徽标；null 不画。
  final IconData? icon;
  final Widget child;
  final VoidCallback onClose;
  final EdgeInsets padding;
  final List<Widget> headerActions;

  /// 标题行下方、不随内容滚动的页头（如设置抽屉的标签栏）。
  final Widget? bottom;

  /// false 时 [child] 直接铺满内容区、自己负责滚动（如 [TabBarView] 每页各自
  /// 滚动），[padding] 不再生效。
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final bool bottomSheet =
        ReaderPanelScope.of(context) == ReaderPanelPresentation.bottom;
    // 页头是四类面板共用的 [ReaderPanelHeader]（M3E：cookie 图标底 + 加粗
    // titleLarge；Apple：强调色字形 + 灰底关闭键）。侧板原地换内容时标题在
    // 页头里交叉淡入。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (bottomSheet) const _ReaderPanelDragHandle(),
        ReaderPanelHeader(
          title: title,
          subtitle: subtitle,
          icon: icon,
          compact: bottomSheet,
          actions: headerActions,
          onClose: onClose,
        ),
        if (bottom != null) bottom!,
        Expanded(
          child: scrollable
              ? SingleChildScrollView(padding: padding, child: child)
              : child,
        ),
      ],
    );
  }
}

/// 底部 sheet 顶端的拖动把手（MD3 drag handle：32×4、onSurfaceVariant 40%）。
/// 只是视觉提示 + 语义按钮；拖动关闭由路由外层的手势承担。
class _ReaderPanelDragHandle extends StatelessWidget {
  const _ReaderPanelDragHandle();

  @override
  Widget build(BuildContext context) {
    return ExcludeFocus(
      child: Semantics(
        button: true,
        label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
        onTap: () => Navigator.of(context).maybePop(),
        child: SizedBox(
          key: const ValueKey<String>('fushi_side_sheet_drag_handle'),
          height: 22,
          child: Center(
            child: Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: fushiNeutralSecondaryForeground(context)
                    .withValues(alpha: 0.4),
                borderRadius: const BorderRadius.all(Radius.circular(2)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 抽屉里分组标题：委托共享 [FushiSectionTitle.group]（与设置分组同一口径，
/// MD3 主色小标题 / Apple 13 号 semibold 次要灰字）。
class ReaderSideSheetSectionLabel extends StatelessWidget {
  const ReaderSideSheetSectionLabel(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) => FushiSectionTitle.group(
    label,
    padding: const EdgeInsets.only(top: 20, bottom: 8),
  );
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

/// 侧板原地换内容的切换器（约定：四类侧板同一时刻只开一个，从一个切到另一个
/// 不关再开）。桌面 / 平板档在侧板朝正文的一侧挂一条纵向 M3E 悬浮工具栏
/// （[FushiFloatingToolbar] vertical），列出各面板；点它只改 [current]，路由不动，
/// 内容由调用方的 builder 按 [current] 交叉淡入。手机底部 sheet 不挂（工具栏就在
/// sheet 下面，关掉再点同样一步）。
class ReaderPanelSwitcher {
  const ReaderPanelSwitcher({
    required this.items,
    required this.current,
    required this.onSelect,
  });

  /// (id, 图标, 文案)。
  final List<({String id, IconData icon, String label})> items;
  final ValueListenable<String> current;
  final ValueChanged<String> onSelect;
}

/// 侧板 / sheet 进出的弹簧曲线（M3E expressive spatial：轻微过冲后落位）。
/// 由 [SpringSimulation] 采样成 [Curve]，供 [showGeneralDialog] 的定时转场用。
class ReaderPanelSpringCurve extends Curve {
  const ReaderPanelSpringCurve({this.dampingRatio = 0.82});

  final double dampingRatio;

  @override
  double transformInternal(double t) {
    if (t >= 1) return 1;
    final SpringSimulation sim = SpringSimulation(
      SpringDescription.withDampingRatio(
        mass: 1,
        stiffness: 380,
        ratio: dampingRatio,
      ),
      0,
      1,
      0,
    );
    // 弹簧在 ~0.55s 内基本落定；把 t∈[0,1] 映射到这段时间，末端强制 1。
    return sim.x(t * 0.55);
  }
}

/// 从贴边滑出一条全高面板路由（各档见 [ReaderPanelTier]）；[bottomSheetWhenCompact]
/// 为 true 且窗口窄于 [kReaderPanelCompactWidth] 时改从底部升起
/// （[ReaderPanelPresentation]）。
///
/// 遮罩按档取（[readerPanelScrimOpacity]）：桌面透明（正文照常可见，ッツ 形态），
/// 平板淡遮罩，手机底部 sheet 用 MD3 modal 的 32%。都**不**对背后的 WebView
/// 平台视图做 BackdropFilter 实时模糊——平台视图上逐帧重采样在 Android 上掉帧
/// （BUG-969 同一机制），层次只靠表面色阶、圆角与 elevation。
///
/// 用**路由**而非页内 Stack 叠层：面板里有输入框（书内搜索 / 按字数跳转），焦点
/// 需要真正离开正文；走路由让焦点体系与既有的居中设置对话框完全一致
/// （focus-ownership.md 的 overlay 语义），不引入新的焦点所有者。关闭后由调用方
/// 经 `PageFocusOwnership.guardOverlay` 把焦点还给正文。
///
/// [switcher] 非空时桌面 / 平板侧板旁挂一条面板切换工具栏（原地换内容）。
///
/// 动效：进场 [FushiMotion.long] + M3E 弹簧（[ReaderPanelSpringCurve]）滑入并淡入，
/// 退场 emphasized accelerate；墨水屏 / 系统「减弱动态效果」下瞬时开合。
Future<T?> showReaderSideSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  ReaderSideSheetSide side = ReaderSideSheetSide.right,
  ValueListenable<ReaderSideSheetSide>? sideController,
  bool bottomSheetWhenCompact = false,
  ReaderPanelSwitcher? switcher,
}) {
  // showGeneralDialog 不像 showDialog 那样捕获主题：抽屉只会拿到 Navigator 层
  // 的根主题。歌词模式把整页换成封面取色主题（LyricsThemeHost），从页面 context
  // 打开的导航 / 设置 / 有声书 / 统计抽屉必须跟着它走，所以在这里补捕获。
  final CapturedThemes themes = InheritedTheme.capture(
    from: context,
    to: Navigator.of(context).context,
  );
  final LyricsThemeHostState? themeHost = LyricsThemeHost.maybeOf(context);
  final bool motion = fushiMotionEnabled(context);
  final Size window = MediaQuery.sizeOf(context);
  final ReaderPanelPresentation openedAs = readerPanelPresentationFor(
    window,
    bottomSheetWhenCompact: bottomSheetWhenCompact,
  );
  final double scrim = readerPanelScrimOpacity(
    readerPanelTierFor(window.width),
    presentation: openedAs,
  );
  ReaderPanelPresentation presentationOf(BuildContext ctx) =>
      readerPanelPresentationFor(
        MediaQuery.sizeOf(ctx),
        bottomSheetWhenCompact: bottomSheetWhenCompact,
      );
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: scrim == 0
        ? Colors.transparent
        : Theme.of(context).colorScheme.scrim.withValues(alpha: scrim),
    transitionDuration: motion ? FushiMotion.long : Duration.zero,
    pageBuilder: (BuildContext route, Animation<double> a, Animation<double> b) {
      Widget buildSheet(BuildContext ctx) {
        final ReaderPanelPresentation presentation = presentationOf(ctx);
        if (presentation == ReaderPanelPresentation.bottom) {
          return _ReaderBottomPanel(builder: builder);
        }
        if (sideController == null) {
          return _ReaderSidePanel(
            side: side,
            builder: builder,
            switcher: switcher,
          );
        }
        return ValueListenableBuilder<ReaderSideSheetSide>(
          valueListenable: sideController,
          builder:
              (BuildContext context, ReaderSideSheetSide current, Widget? _) {
            return _ReaderSidePanel(
              side: current,
              builder: builder,
              animateSide: true,
              switcher: switcher,
            );
          },
        );
      }

      final Widget child = Builder(builder: buildSheet);
      if (themeHost == null) return themes.wrap(child);
      return _ReaderSideSheetThemes(
        source: context,
        initialThemes: themes,
        changes: themeHost.themeChanges,
        child: child,
      );
    },
    transitionBuilder: (
      BuildContext ctx,
      Animation<double> animation,
      Animation<double> secondary,
      Widget child,
    ) {
      final CurvedAnimation curved = CurvedAnimation(
        parent: animation,
        curve: const ReaderPanelSpringCurve(),
        reverseCurve: FushiMotion.exit,
      );
      final Offset begin = switch (presentationOf(ctx)) {
        ReaderPanelPresentation.bottom => const Offset(0, 1),
        ReaderPanelPresentation.side =>
          (sideController?.value ?? side) == ReaderSideSheetSide.left
              ? const Offset(-1, 0)
              : const Offset(1, 0),
      };
      return SlideTransition(
        position: Tween<Offset>(begin: begin, end: Offset.zero).animate(curved),
        child: FadeTransition(
          opacity: CurvedAnimation(
            parent: animation,
            curve: const Interval(0, 0.5, curve: Curves.easeOut),
          ),
          child: child,
        ),
      );
    },
  );
}

/// BUG-3008: a capture is a snapshot, even when the source Theme merely passes
/// through the app theme. Keep the same panel subtree and refresh the snapshot
/// after the reader host publishes its effective theme. Never look up ancestors
/// during build: the source page may be deactivating before this route closes.
class _ReaderSideSheetThemes extends StatefulWidget {
  const _ReaderSideSheetThemes({
    required this.source,
    required this.initialThemes,
    required this.changes,
    required this.child,
  });

  final BuildContext source;
  final CapturedThemes initialThemes;
  final ValueListenable<ThemeData?> changes;
  final Widget child;

  @override
  State<_ReaderSideSheetThemes> createState() => _ReaderSideSheetThemesState();
}

class _ReaderSideSheetThemesState extends State<_ReaderSideSheetThemes> {
  late CapturedThemes _themes;

  @override
  void initState() {
    super.initState();
    _themes = widget.initialThemes;
    widget.changes.addListener(_refreshThemes);
    // Also cover a theme change between push and the route's first build.
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshThemes());
  }

  void _refreshThemes() {
    if (!mounted || !widget.source.mounted) return;
    final CapturedThemes themes = InheritedTheme.capture(
      from: widget.source,
      to: Navigator.of(widget.source).context,
    );
    setState(() => _themes = themes);
  }

  @override
  void dispose() {
    widget.changes.removeListener(_refreshThemes);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _themes.wrap(widget.child);
}

/// 面板底色：Apple = 分组页底（白 / 纯黑），里面的设置分组卡
/// （secondaryGroupedBackground）才浮得出来；MD3 = surfaceContainerLow
/// （Expressive 侧边面板），分组卡 surfaceContainer 比它高一级。
Color _readerPanelColor(BuildContext ctx) => isGlassDesign(ctx)
    ? appleColorsOf(ctx).groupedBackground
    : Theme.of(ctx).colorScheme.surfaceContainerLow;

/// 侧板旁的面板切换工具栏（纵向 M3E 悬浮工具栏，选中项 secondaryContainer）。
class _ReaderPanelSwitcherRail extends StatelessWidget {
  const _ReaderPanelSwitcherRail({required this.switcher});

  final ReaderPanelSwitcher switcher;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: switcher.current,
      builder: (BuildContext context, String current, Widget? _) {
        return FushiFloatingToolbar(
          key: const ValueKey<String>('fushi_reader_panel_switcher'),
          axis: Axis.vertical,
          compact: true,
          groups: <List<FushiToolbarItem>>[
            <FushiToolbarItem>[
              for (final ({String id, IconData icon, String label}) item
                  in switcher.items)
                FushiToolbarItem(
                  key: ValueKey<String>('fushi_reader_panel_switch_${item.id}'),
                  icon: item.icon,
                  label: item.label,
                  selected: item.id == current,
                  onPressed: () => switcher.onSelect(item.id),
                ),
            ],
          ],
        );
      },
    );
  }
}

/// 贴边侧板：全高、朝正文那一侧两角 [FushiRadii.sheetValue] 圆角（M3 Expressive
/// 模态侧板），贴边那侧直角。墨水屏补一圈 outline 切出面板。[switcher] 非空时
/// 朝正文一侧挂面板切换工具栏。
class _ReaderSidePanel extends StatelessWidget {
  const _ReaderSidePanel({
    required this.side,
    required this.builder,
    this.animateSide = false,
    this.switcher,
  });

  final ReaderSideSheetSide side;
  final WidgetBuilder builder;
  final bool animateSide;
  final ReaderPanelSwitcher? switcher;

  @override
  Widget build(BuildContext ctx) {
    final bool left = side == ReaderSideSheetSide.left;
    final double width = readerSideSheetWidth(MediaQuery.sizeOf(ctx).width);
    const Radius corner = Radius.circular(FushiRadii.sheetValue);
    final BorderRadius radius = left
        ? const BorderRadius.only(topRight: corner, bottomRight: corner)
        : const BorderRadius.only(topLeft: corner, bottomLeft: corner);
    Widget panel = SizedBox(
      // 换停靠边时会与 rail 对调；保留整个设置会话（含 notifier 的所有者）。
      key: const ValueKey<String>('reader_side_panel_content'),
      width: width,
      height: double.infinity,
      child: Material(
        key: const ValueKey<String>('fushi_reader_side_sheet'),
        color: _readerPanelColor(ctx),
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: isEinkTheme(ctx)
              ? BorderSide(color: Theme.of(ctx).colorScheme.outline)
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        elevation: kFushiFloatingElevation,
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: SafeArea(
            child: ReaderPanelScope(
              presentation: ReaderPanelPresentation.side,
              child: Builder(builder: builder),
            ),
          ),
        ),
      ),
    );
    final ReaderPanelSwitcher? sw = switcher;
    if (sw != null && sw.items.length > 1) {
      final Widget rail = SafeArea(
        key: const ValueKey<String>('reader_side_panel_rail'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 76, 12, 12),
          child: Align(
            alignment: Alignment.topCenter,
            child: _ReaderPanelSwitcherRail(switcher: sw),
          ),
        ),
      );
      panel = Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: left ? <Widget>[panel, rail] : <Widget>[rail, panel],
      );
    }
    final Alignment alignment =
        left ? Alignment.centerLeft : Alignment.centerRight;
    if (!animateSide) return Align(alignment: alignment, child: panel);
    return AnimatedAlign(
      duration: fushiMotionDuration(ctx, FushiMotion.short),
      curve: FushiMotion.standard,
      alignment: alignment,
      child: panel,
    );
  }
}

/// 底部 sheet：上两角 [FushiRadii.sheetValue] 圆角，两档高度——满高
/// [readerPanelBottomSheetHeight]（86%，键盘弹起时整块抬到键盘上方并收矮）与半屏
/// [kReaderPanelBottomSheetHalfFraction]。打开在满高；页头区向下拖：满高 → 半屏 →
/// 关闭，向上拖回满高（内容区的纵向拖动仍归内部滚动视图）。
class _ReaderBottomPanel extends StatefulWidget {
  const _ReaderBottomPanel({required this.builder});

  final WidgetBuilder builder;

  @override
  State<_ReaderBottomPanel> createState() => _ReaderBottomPanelState();
}

class _ReaderBottomPanelState extends State<_ReaderBottomPanel>
    with SingleTickerProviderStateMixin {
  /// 拖动位移（逻辑 px，> 0 = 向下）。松手未达阈值时弹回当前档。
  late final AnimationController _drag = AnimationController.unbounded(
    vsync: this,
    value: 0,
  );
  double _height = 1;
  double _halfHeight = 1;

  /// 当前停在半屏档。
  bool _half = false;

  @override
  void dispose() {
    _drag.dispose();
    super.dispose();
  }

  double get _restHeight => _half ? _halfHeight : _height;

  void _onDragUpdate(DragUpdateDetails details) {
    // 半屏档可向上拖回满高（负偏移，至多两档差）；满高档不能再往上。
    final double minOffset = _half ? -(_height - _halfHeight) : 0;
    _drag.value =
        (_drag.value + details.delta.dy).clamp(minOffset, _restHeight);
  }

  void _settle() {
    _drag.animateTo(
      0,
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.release,
    );
  }

  void _onDragEnd(DragEndDetails details) {
    final double velocity = details.primaryVelocity ?? 0;
    final double offset = _drag.value;
    final double gap = _height - _halfHeight;
    // 向上：半屏档回满高。视觉位置保持连续（换档的同时把偏移折算过去）。
    if (_half && (velocity < -500 || offset < -gap * 0.3)) {
      setState(() => _half = false);
      _drag.value = offset + gap;
      _settle();
      return;
    }
    final bool down = velocity > 700 || offset > _restHeight * 0.25;
    if (down) {
      // 满高 → 半屏（两档差得开才有半屏档；快甩直接关）；半屏 → 关闭。
      if (!_half && gap > 48 && velocity < 1800) {
        setState(() => _half = true);
        _drag.value = offset - gap;
        _settle();
        return;
      }
      Navigator.of(context).maybePop();
      return;
    }
    _settle();
  }

  @override
  Widget build(BuildContext ctx) {
    final Size size = MediaQuery.sizeOf(ctx);
    final double keyboard = MediaQuery.viewInsetsOf(ctx).bottom;
    _height = readerPanelBottomSheetHeight(
      windowHeight: size.height,
      topPadding: MediaQuery.paddingOf(ctx).top,
      keyboardInset: keyboard,
    );
    _halfHeight = (size.height * kReaderPanelBottomSheetHalfFraction)
        .clamp(0.0, _height);
    final double width = size.width < kReaderPanelBottomSheetMaxWidth
        ? size.width
        : kReaderPanelBottomSheetMaxWidth;
    final Widget panel = SizedBox(
      width: width,
      height: _restHeight,
      child: Material(
        key: const ValueKey<String>('fushi_reader_side_sheet'),
        color: _readerPanelColor(ctx),
        shape: RoundedRectangleBorder(
          borderRadius: FushiDesignTokens.of(ctx).radii.sheetRadius,
          side: isEinkTheme(ctx)
              ? BorderSide(color: Theme.of(ctx).colorScheme.outline)
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        elevation: kFushiFloatingElevation,
        child: SafeArea(
          top: false,
          child: ReaderPanelScope(
            presentation: ReaderPanelPresentation.bottom,
            child: Builder(builder: widget.builder),
          ),
        ),
      ),
    );
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.only(bottom: keyboard),
        child: AnimatedBuilder(
          animation: _drag,
          child: GestureDetector(
            behavior: HitTestBehavior.deferToChild,
            onVerticalDragUpdate: _onDragUpdate,
            onVerticalDragEnd: _onDragEnd,
            child: panel,
          ),
          builder: (BuildContext context, Widget? child) =>
              Transform.translate(offset: Offset(0, _drag.value), child: child),
        ),
      ),
    );
  }
}
