/// 漫画阅读器的界面件（chrome）：顶栏 [MangaReaderTopBar]、底栏跳页 slider
/// [MangaReaderBottomBar]、隐藏界面时的页码角标 [MangaHiddenPageBadge]。
///
/// 与 EPUB 阅读器的 [ReaderDesktopHeader] 同一套视觉语言（48px、左返回 / 中标题 /
/// 右动作、窄窗折叠进 ⋮ 溢出菜单），但布局自己画：栏是**深色实底/半透明**（底色
/// 偏好只管页图周围，栏本身不跟着变白，否则白底档下白字栏不可读），动作要按
/// 「导航 / 视图 / 界面」分组并夹分隔线，还要塞 OCR 进度胶囊，[ReaderDesktopHeader]
/// 的 `title + leading + trailing` 三槽装不下。折叠阈值复用 [readerHeaderCompact]，
/// 折叠规则（只留 pinned、其余进 ⋮）与 EPUB 同一句。
///
/// 两种形态由页面决定、本组件只管画：
///  * 固定（`floating == false`）：实底、占布局，页面把正文 WebView 往下让
///    [mangaChromeTopInset]；
///  * 悬浮（`floating == true`）：半透明、盖在正文上，默认收起，正文中央点击唤出、
///    再点一下收起（**只认点击**：鼠标移动不唤出，唤出后也不自动收起）。
library;

import 'package:flutter/material.dart';
import 'package:fushi/utils.dart' show FushiBorderRadius;
import 'package:fushi/src/reader/reader_desktop_chrome.dart'
    show kReaderDesktopHeaderHeight, readerHeaderCompact;

/// 顶栏内容行高（不含系统状态栏）。与 EPUB 顶栏同值，两个阅读器视觉对齐。
const double kMangaChromeBarHeight = kReaderDesktopHeaderHeight;

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

/// 固定态下正文 WebView 底部让出的高度（纯函数，单测钉住）。
///
/// 与 [mangaChromeTopInset] 同构、同理由：让位高度**必须**等于底栏画出的高度
/// （同一个常量 + 同一个系统手势区 inset），否则页图最后一行会压在栏下。
///
/// [contentReady] == false 时底栏不画（没有正文就没有可跳的页），故也不让位。
double mangaChromeBottomInset({
  required bool floating,
  required bool chromeVisible,
  required bool contentReady,
  required double gestureInset,
}) {
  if (floating || !chromeVisible || !contentReady) return 0;
  return gestureInset + kMangaChromeBottomBarHeight;
}

/// 当前是否该画顶栏（纯函数）。
///
///  * 界面被用户隐藏（M 键，[chromeVisible] == false）→ 不画；
///  * 固定态 → 画；
///  * 悬浮态 → 唤出中（[transientVisible]）才画——**但没有正文时无条件画**
///    （[contentReady] == false：加载失败 / 本章未下载）。悬浮态的唤出手势是正文
///    WebView 的中央点击，没有正文就没有那条通道（顶边悬停热区已按「只认点击」
///    的口径删掉），返回键一收就再也叫不回来（iOS 没有系统返回键 +
///    `PopScope(canPop: false)` 关掉了侧滑，只能杀进程）。出口不随内容存亡，也不
///    随形态收起。
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
    this.leading = const <MangaChromeAction>[],
  });

  /// 书名 / 章节名；空串时只画页码。
  final String title;
  final VoidCallback onBack;
  final String backTooltip;

  /// 紧跟返回键的动作（章节目录）：窄窗也常驻，不折进 ⋮。
  final List<MangaChromeAction> leading;

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
    return DecoratedBox(
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
                    for (final MangaChromeAction a in leading) _button(a),
                    Expanded(child: _buildTitleArea(context, compact)),
                    for (int i = 0; i < visibleGroups.length; i++) ...<Widget>[
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

/// 整卷 OCR 进度浮标（`OCR 19/182 · DirectML`），挂在页面右上角、顶栏下沿。
///
/// 不放进顶栏：悬浮顶栏默认收起、用户也会隐藏界面，进度却要一直看得见（对齐
/// Mangatan / Chimahon）。[busy] 画转圈；[warning] 用琥珀色（加速降级 / 没有可用
/// 引擎，BUG-1163：降级必须看得见）。浮标只是读数，不吃指针事件。
class MangaOcrProgressBadge extends StatelessWidget {
  const MangaOcrProgressBadge({
    super.key,
    required this.text,
    this.busy = true,
    this.warning = false,
  });

  final String text;
  final bool busy;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final Color fg = warning ? MangaReaderTopBar._accent : Colors.white;
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xB3000000),
          borderRadius: FushiBorderRadius.chip,
          border: warning ? Border.all(color: fg.withValues(alpha: 0.6)) : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (busy) ...<Widget>[
              SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: fg),
              ),
              const SizedBox(width: 8),
            ],
            // 警告（没有可用引擎）要把原因和解决办法说全，窄屏上折成两行；进度读数
            // 恒一行。Flexible 让 maxLines / 省略号在有界宽度里真正生效。
            Flexible(
              child: Text(
                text,
                maxLines: warning ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: fg,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 底栏行高（不含系统手势区）。比顶栏矮：只有一条 slider 和两个页码读数。
const double kMangaChromeBottomBarHeight = 44;

/// slider 的物理左端对应第几页（纯函数，单测钉住）。
///
/// RTL（日漫右开本）下页序在视觉上从右往左推进，slider 必须跟着镜像，否则「把滑块
/// 往前推」会倒着翻页。镜像只发生在**显示**层：[MangaReaderBottomBar] 收到的和回调
/// 出去的永远是 0-based 真实页号。
///
/// 返回值是给 [Slider] 用的 0..max 位置值。
double mangaSliderPosition({
  required int pageIndex,
  required int pageCount,
  required bool rtl,
}) {
  if (pageCount <= 1) return 0;
  final int clamped = pageIndex.clamp(0, pageCount - 1);
  return (rtl ? pageCount - 1 - clamped : clamped).toDouble();
}

/// [mangaSliderPosition] 的逆：slider 位置 → 0-based 真实页号。
int mangaSliderPageIndex({
  required double position,
  required int pageCount,
  required bool rtl,
}) {
  if (pageCount <= 1) return 0;
  final int slot = position.round().clamp(0, pageCount - 1);
  return rtl ? pageCount - 1 - slot : slot;
}

/// 底栏：`[3] ──────●──── [40]`，拖动跳页。
///
/// 此前跳页的唯一入口是顶栏页码胶囊弹出的输入框——要跳到「大概三分之二处」必须先
/// 知道总页数再心算页号。slider 是漫画阅读器的标配（Mihon / Tachiyomi / Kindle 都
/// 有），缺它是用户「本体比 Mihon 薄」的具体一条。
///
/// 拖动中只更新本地预览（[onPagePreview] 留给调用方画页码读数），**松手才真跳页**
/// （[onPageCommitted]）：漫画翻页要 loadData 重建窗口文档，按住滑块扫过 40 页会
/// 连发 40 次重建。
class MangaReaderBottomBar extends StatefulWidget {
  const MangaReaderBottomBar({
    super.key,
    required this.pageCount,
    required this.pageListenable,
    required this.currentPage,
    required this.rtl,
    required this.onPageCommitted,
    this.floating = true,
  });

  /// 整卷总页数；<= 1 时整条栏不画（一页的书没有跳页需求）。
  final int pageCount;

  /// 翻页通知源：只重画本栏，不重建整页（正文是原生 WebView）。
  final Listenable pageListenable;

  /// 当前 0-based 页号，每次 [pageListenable] 触发时重新取。
  final int Function() currentPage;

  /// 右开本：slider 镜像（见 [mangaSliderPosition]）。
  final bool rtl;

  /// 松手时回调，参数是 0-based 真实页号。
  final ValueChanged<int> onPageCommitted;

  /// 与顶栏同义：悬浮态半透明、固定态实底。
  final bool floating;

  @override
  State<MangaReaderBottomBar> createState() => _MangaReaderBottomBarState();
}

class _MangaReaderBottomBarState extends State<MangaReaderBottomBar> {
  /// 拖动中的 slider 位置；null = 没在拖，读 [MangaReaderBottomBar.currentPage]。
  double? _dragPosition;

  @override
  Widget build(BuildContext context) {
    if (widget.pageCount <= 1) return const SizedBox.shrink();
    final TextTheme text = Theme.of(context).textTheme;
    final double bottomInset = MediaQuery.paddingOf(context).bottom;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: widget.floating
            ? const Color(0xB3000000)
            : const Color(0xF2141414),
        border: widget.floating
            ? null
            : const Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: SizedBox(
          height: kMangaChromeBottomBarHeight,
          child: ListenableBuilder(
            listenable: widget.pageListenable,
            builder: (BuildContext context, Widget? _) {
              final int pageCount = widget.pageCount;
              final double maxPosition = (pageCount - 1).toDouble();
              final double position =
                  _dragPosition ??
                  mangaSliderPosition(
                    pageIndex: widget.currentPage(),
                    pageCount: pageCount,
                    rtl: widget.rtl,
                  );
              final int shownPage =
                  mangaSliderPageIndex(
                    position: position,
                    pageCount: pageCount,
                    rtl: widget.rtl,
                  ) +
                  1;
              final TextStyle? readout = text.labelMedium?.copyWith(
                color: MangaReaderTopBar._fg,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              );
              return Row(
                children: <Widget>[
                  const SizedBox(width: 12),
                  Text(
                    '$shownPage',
                    key: const ValueKey<String>('manga_slider_current_page'),
                    style: readout,
                  ),
                  Expanded(
                    child: Slider(
                      key: const ValueKey<String>('manga_page_slider'),
                      value: position.clamp(0, maxPosition),
                      max: maxPosition,
                      // 每一格恰好一页：divisions 缺省时滑块落在页与页之间，
                      // 松手才 round，拖动读数会跳。
                      divisions: pageCount > 1 ? pageCount - 1 : null,
                      onChanged: (double v) =>
                          setState(() => _dragPosition = v),
                      onChangeEnd: (double v) {
                        setState(() => _dragPosition = null);
                        widget.onPageCommitted(
                          mangaSliderPageIndex(
                            position: v,
                            pageCount: pageCount,
                            rtl: widget.rtl,
                          ),
                        );
                      },
                    ),
                  ),
                  Text(
                    '$pageCount',
                    key: const ValueKey<String>('manga_slider_page_count'),
                    style: readout?.copyWith(color: MangaReaderTopBar._fgDim),
                  ),
                  const SizedBox(width: 12),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 隐藏界面（M 键）时角落里常驻的页码角标。
///
/// 隐藏界面是为了让页图全出血，但代价是**连自己读到第几页都看不见**了——用户只能
/// 把界面调出来看一眼再关掉。角标半透明、不吃指针（[IgnorePointer]），不破坏全出血。
class MangaHiddenPageBadge extends StatelessWidget {
  const MangaHiddenPageBadge({
    super.key,
    required this.pageListenable,
    required this.label,
  });

  final Listenable pageListenable;

  /// 页码文案（如 `3 / 40`）；返回 null 不画。
  final String? Function() label;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ListenableBuilder(
        listenable: pageListenable,
        builder: (BuildContext context, Widget? _) {
          final String? shown = label();
          if (shown == null) return const SizedBox.shrink();
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0x66000000),
              borderRadius: FushiBorderRadius.chip,
            ),
            child: Text(
              shown,
              key: const ValueKey<String>('manga_hidden_page_badge'),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Colors.white70,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          );
        },
      ),
    );
  }
}
