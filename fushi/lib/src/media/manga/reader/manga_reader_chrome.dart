/// 漫画阅读器顶栏（chrome）。
///
/// 与 EPUB 阅读器的 [ReaderDesktopHeader] 同一套视觉语言（48px、左返回 / 中标题 /
/// 右动作、窄窗折叠进 ⋮ 溢出菜单），但布局自己画：漫画页永远是黑底，动作要按
/// 「导航 / 视图 / 界面」分组并夹分隔线，还要塞 OCR 进度胶囊，[ReaderDesktopHeader]
/// 的 `title + leading + trailing` 三槽装不下。折叠阈值复用 [readerHeaderCompact]，
/// 折叠规则（只留 pinned、其余进 ⋮）与 EPUB 同一句。
///
/// 两种形态由页面决定、本组件只管画：
///  * 固定（`floating == false`）：实底、占布局，页面把正文 WebView 往下让
///    [mangaChromeTopInset]；
///  * 悬浮（`floating == true`）：半透明、盖在正文上，默认收起、唤出后自动收起。
library;

import 'package:flutter/material.dart';
import 'package:fushi/utils.dart' show FushiBorderRadius;
import 'package:fushi/src/reader/reader_desktop_chrome.dart'
    show kReaderDesktopHeaderHeight, readerHeaderCompact;

/// 顶栏内容行高（不含系统状态栏）。与 EPUB 顶栏同值，两个阅读器视觉对齐。
const double kMangaChromeBarHeight = kReaderDesktopHeaderHeight;

/// 悬浮态唤出后自动收起的时长。漫画不另设滑杆：EPUB 那边是 1–10s 可调、默认 3s，
/// 漫画先跟默认，等真有人要调再开旗。
const Duration kMangaChromeAutoHide = Duration(seconds: 3);

/// 固定态下正文 WebView 顶部让出的高度（纯函数，单测钉住）。
///
///  * 悬浮 / 界面被隐藏（M 键）→ 0：正文全出血；
///  * 固定且界面可见 → 状态栏 + 顶栏行高。正文让位的高度**必须**等于顶栏画出的
///    高度（同一个常量），否则页图第一行会压在栏下（EPUB 顶栏 BUG-2387 同款铁律）。
double mangaChromeTopInset({
  required bool floating,
  required bool chromeVisible,
  required double statusBarInset,
}) {
  if (floating || !chromeVisible) return 0;
  return statusBarInset + kMangaChromeBarHeight;
}

/// 当前是否该画顶栏（纯函数）。
///
///  * 界面被用户隐藏（M 键，[chromeVisible] == false）→ 不画；
///  * 固定态 → 画；
///  * 悬浮态 → 唤出中（[transientVisible]）才画——**但没有正文时无条件画**
///    （[contentReady] == false：加载失败 / 本章未下载）。悬浮态的唤出手势是正文
///    WebView 的中央点击，没有正文就没有那条通道；桌面还有顶边热区，触屏没有，
///    返回键一收就再也叫不回来（iOS 没有系统返回键 + `PopScope(canPop: false)`
///    关掉了侧滑，只能杀进程）。出口不随内容存亡，也不随形态收起。
bool mangaChromeBarPainted({
  required bool floating,
  required bool chromeVisible,
  required bool transientVisible,
  required bool contentReady,
}) {
  if (!chromeVisible) return false;
  return !floating || transientVisible || !contentReady;
}

/// 顶栏里的一颗动作。[active] 是「开关型」动作的当前态（高亮 + 溢出菜单打勾）。
class MangaChromeAction {
  const MangaChromeAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.key,
    this.pinned = false,
    this.active = false,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Key? key;

  /// 窄窗紧凑形态仍保留为图标按钮；其余收进 ⋮。
  final bool pinned;

  /// 开关型动作当前处于开启态：图标用强调色，溢出菜单里带勾。
  final bool active;

  /// 忙碌中：图标位画转圈（例如整卷 OCR 进行中）。
  final bool busy;
}

/// 顶栏。`[← 返回] [标题 · 页码胶囊] ……… [组1] │ [组2] │ [组3] [⋮]`。
class MangaReaderTopBar extends StatelessWidget {
  const MangaReaderTopBar({
    super.key,
    required this.title,
    required this.onBack,
    required this.backTooltip,
    required this.groups,
    required this.floating,
    this.pageLabel,
    this.pageListenable,
    this.onPageTap,
    this.status,
    this.onHoverChanged,
  });

  /// 书名 / 章节名；空串时只画页码。
  final String title;
  final VoidCallback onBack;
  final String backTooltip;

  /// 动作分组（按顺序从左到右），组与组之间画分隔线。空组自动跳过。
  final List<List<MangaChromeAction>> groups;

  /// 悬浮态：半透明底；固定态：实底。
  final bool floating;

  /// 页码胶囊文案（如 `3-4 / 40`），每次 [pageListenable] 触发时重新取；返回
  /// null 不画。只重建胶囊、不重建整页——翻页是高频事件，页面本体带着原生
  /// WebView，不该跟着 setState。
  final String? Function()? pageLabel;
  final Listenable? pageListenable;
  final VoidCallback? onPageTap;

  /// 页码胶囊右侧的状态件（OCR 进度胶囊 / debug 命中信息）。
  final Widget? status;

  /// 鼠标进出顶栏（悬浮态：悬停期间不自动收起）。
  final ValueChanged<bool>? onHoverChanged;

  static const Color _fg = Colors.white;
  static const Color _fgDim = Colors.white70;
  static const Color _accent = Colors.amberAccent;

  Color get _background =>
      floating ? const Color(0xB3000000) : const Color(0xF2141414);

  @override
  Widget build(BuildContext context) {
    final double statusBar = MediaQuery.paddingOf(context).top;
    final List<List<MangaChromeAction>> visibleGroups =
        <List<MangaChromeAction>>[
          for (final List<MangaChromeAction> g in groups)
            if (g.isNotEmpty) g,
        ];
    return MouseRegion(
      onEnter: (_) => onHoverChanged?.call(true),
      onExit: (_) => onHoverChanged?.call(false),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _background,
          border: floating
              ? null
              : const Border(bottom: BorderSide(color: Colors.white12)),
        ),
        child: Padding(
          padding: EdgeInsets.only(top: statusBar),
          child: SizedBox(
            height: kMangaChromeBarHeight,
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final bool compact = readerHeaderCompact(constraints.maxWidth);
                // 折叠规则与 EPUB 顶栏 `readerHeaderOverflow` 同一句：紧凑态只留
                // pinned，其余按组序收进 ⋮。
                final List<MangaChromeAction> overflow = <MangaChromeAction>[
                  for (final List<MangaChromeAction> g in visibleGroups)
                    for (final MangaChromeAction a in g)
                      if (compact && !a.pinned) a,
                ];
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    children: <Widget>[
                      IconButton(
                        key: const ValueKey<String>('manga_reader_back_button'),
                        tooltip: backTooltip,
                        color: _fg,
                        iconSize: 22,
                        icon: const Icon(Icons.arrow_back),
                        onPressed: onBack,
                      ),
                      Expanded(child: _buildTitleArea(context, compact)),
                      for (
                        int i = 0;
                        i < visibleGroups.length;
                        i++
                      ) ...<Widget>[
                        if (i > 0 && !compact) _divider(),
                        for (final MangaChromeAction a in visibleGroups[i])
                          if (!compact || a.pinned) _button(a),
                      ],
                      if (overflow.isNotEmpty) _overflowMenu(context, overflow),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTitleArea(BuildContext context, bool compact) {
    final TextTheme text = Theme.of(context).textTheme;
    return Row(
      children: <Widget>[
        if (title.isNotEmpty && !compact)
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(left: 4, right: 8),
              child: Text(
                title,
                key: const ValueKey<String>('manga_reader_title'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.titleSmall?.copyWith(
                  color: _fg.withValues(alpha: 0.9),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        if (pageLabel != null)
          ListenableBuilder(
            listenable:
                pageListenable ?? Listenable.merge(const <Listenable>[]),
            builder: (BuildContext context, Widget? _) {
              final String? label = pageLabel!();
              if (label == null) return const SizedBox.shrink();
              return Material(
                color: Colors.white12,
                borderRadius: FushiBorderRadius.chip,
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  key: const ValueKey<String>('manga_page_jump_button'),
                  onTap: onPageTap,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    child: Text(
                      label,
                      style: text.labelLarge?.copyWith(
                        color: _fg,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        if (status != null) ...<Widget>[
          const SizedBox(width: 8),
          Flexible(child: status!),
        ],
      ],
    );
  }

  Widget _divider() => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 2),
    child: SizedBox(
      width: 1,
      height: 20,
      child: ColoredBox(color: Colors.white24),
    ),
  );

  Widget _button(MangaChromeAction a) {
    final Widget icon = a.busy
        ? const SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: _fg),
          )
        : Icon(a.icon, color: a.active ? _accent : _fg);
    return IconButton(
      key: a.key,
      tooltip: a.label,
      iconSize: 22,
      icon: icon,
      onPressed: a.onPressed,
    );
  }

  Widget _overflowMenu(BuildContext context, List<MangaChromeAction> overflow) {
    return PopupMenuButton<MangaChromeAction>(
      key: const ValueKey<String>('manga_chrome_overflow'),
      tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
      icon: const Icon(Icons.more_vert, color: _fg),
      iconSize: 22,
      onSelected: (MangaChromeAction a) => a.onPressed?.call(),
      itemBuilder: (BuildContext context) =>
          <PopupMenuEntry<MangaChromeAction>>[
            for (final MangaChromeAction a in overflow)
              PopupMenuItem<MangaChromeAction>(
                value: a,
                enabled: a.onPressed != null,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(a.icon, size: 20),
                    const SizedBox(width: 12),
                    Flexible(child: Text(a.label)),
                    if (a.active) ...<Widget>[
                      const SizedBox(width: 12),
                      const Icon(Icons.check, size: 18),
                    ],
                  ],
                ),
              ),
          ],
    );
  }
}

/// 顶栏右侧的小胶囊（OCR 进度 `12/40 · DirectML`）。[warning] 时琥珀色（BUG-1163：
/// 推理后端降级必须看得见）。
class MangaChromeStatusChip extends StatelessWidget {
  const MangaChromeStatusChip({
    super.key,
    required this.text,
    this.warning = false,
  });

  final String text;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final Color fg = warning
        ? MangaReaderTopBar._accent
        : MangaReaderTopBar._fgDim;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: FushiBorderRadius.chip,
        border: warning ? Border.all(color: fg.withValues(alpha: 0.6)) : null,
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: fg,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
