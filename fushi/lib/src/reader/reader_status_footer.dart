import 'dart:async';
import 'dart:math' as math;

import 'package:intl/intl.dart' show NumberFormat;
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_audio/fushi_audio.dart' show StudySessionTotals;

import 'package:fushi/src/reader/reader_chrome_floating.dart'
    show kTopProgressFontSize;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 各平台共用的阅读器底部状态行。
///
/// 一条极简的状态行。挤压态常驻、占预留高（正文永不压到它下面）；悬浮态
/// （`tap_empty_hide_chrome`）不占预留、随控制栏一起唤出 / 收起，收起期间屏底只剩
/// 一条 [ReaderProgressEdgeLine] 细进度线。两段读数都贴**右下角**，顺序与播放条唤出
/// 时的 [ReaderStatusInline] 一致：
///  * 阅读追踪——计时器图标 + `<本次时长>`（如 `0:00`）；
///  * 字数进度——一段短进度条 + `<百分比>%`。
///
/// 2026-09-13 精简：此前是 `<字/时> / h <时长>  <已读> / <总字数>  <百分比>%
/// (<本章已读> / <本章总字数> <本章百分比>%)` 六个数一串，用户要「简洁 + 进度条」。
/// 字/时、字数、本章进度全部进统计侧栏（`ReaderStatisticsSheet`）。
///
/// 追踪块此前独自钉在**左**下角：底部信息被劈成左右两个角，视线要在两角之间跳；而
/// 有声书播放条一唤出（[ReaderStatusInline]），同一串数字又整体飞到右端，两条底部形态
/// 互换时读数横跨整屏跳位。两段并排贴右后，底部读数只有一处落点。
///
/// 2026-09-14 分层修正（用户）：横屏读数并进底栏那一行（[readerPlaybackStatusInline]
/// → [ReaderStatusInline]），底部只有一层；竖屏读数独立成行时并进**底栏那块遮罩的
/// 最底部**并居中（[centered]，装配在 `_wrapBottomChromeBar`），底栏的背景因此一路
/// 盖到屏底，而不是底栏一块、读数一块两块半透明遮罩拼在一起。只有底栏整条不画时
/// （默认布局无播放条、底栏槽位空）读数才自己贴屏底右端。
///
/// 它取代顶部进度 pill：进度数字统一放在右下角；窄屏文案省略，完整统计仍可点击查看。
///
/// 高度只有一个真相源 [kReaderStatusFooterHeight]：页面用它算底部预留
/// （`_readerBottomReserve`）喂 WebView，组件用它画自身——视觉高度 == 预留高度
/// 是 chrome 的铁律（见 reader_chrome_floating.dart 文件头）。
const double kReaderStatusFooterHeight = 28;

/// 悬浮形态（[ReaderStatusFooter.floating]）读数胶囊离窗口底边的外边距：胶囊是浮在
/// 正文上的悬浮件，不能贴着窗口底边（无系统底 inset 的桌面窗口里会被切掉半截阴影、
/// 看着像被挤出窗外，10-06 反馈）。有更大的系统底 inset 时以 inset 为准。
const double kReaderStatusFooterFloatingBottomGap = 8;

/// 状态行**带高**的预留口径：悬浮形态多出 [kReaderStatusFooterFloatingBottomGap]。
/// 组件与页面（底部悬浮件坐落高度）共用这一处，视觉 == 预留。
double readerStatusFooterPaintedHeight({
  required bool floating,
  double height = kReaderStatusFooterHeight,
}) => floating ? height + kReaderStatusFooterFloatingBottomGap : height;

/// 状态行文字字号，与顶部进度 pill 同源（12）。
const double kReaderStatusFooterFontSize = kTopProgressFontSize;

/// 状态行是否启用：非歌词模式，且两段读数里至少还剩一段要画。保留 desktop 参数
/// 兼容调用方。
///
/// 歌词模式是独立 HTML 文档，进度与阅读追踪都不适用（顶部进度 pill 在歌词模式同样
/// 不画），且它的底部留白走 `independentDocumentInsets` 的 Flutter 侧 Padding，
/// 不经 `setChromeInsets`；状态行在歌词模式下既不画也不占预留。
///
/// 「计时 / 本次字数 / 字每时 / 进度」四个读数开关**都**关掉时整条行不画也不占预留——
/// 空行照占 28px 是白吃正文高度。判据只此一处（[readerStatusFooterReserve] 的
/// `enabled` 就是它），绘制与预留不会各判各的。
bool readerStatusFooterEnabled({
  required bool desktop,
  required bool lyricsMode,
  required bool showTimer,
  required bool showProgress,
  required bool showChars,
  required bool showSpeed,
}) => !lyricsMode && (showTimer || showProgress || showChars || showSpeed);

/// 状态行是否已被底栏**吸收**：挤压态底栏占位（[bottomChromeReserve] > 0）且宽屏把
/// 同一串读数并进了底栏右端（[inlineStatus]，[ReaderStatusInline]）。
///
/// 那时状态行既不画也不占预留——底部只有一条。此前挤压态下状态行坐在底栏之上、底栏
/// 右端又画一份同样的数字：同一串「计时 / 已读 / 百分比」上下叠两行，多占一条
/// [kReaderStatusFooterHeight] 的正文高度（BUG-2467）。悬浮态底栏不占位
/// （[bottomChromeReserve] == 0），状态行照常在场，底栏唤出时盖在其上、收起后露出。
/// 窄屏（读数不并进底栏）状态行仍独立成行，坐在底栏之上，不吸收。
///
/// 悬浮态底栏不占位（[bottomChromeReserve] == 0），改看 [floatingBarPainted]——
/// 有声书播放条此刻画着且读数并进了它右端，状态行同样让位；播放条收起后状态行
/// 与顶栏一起收起（[readerStatusFooterVisible]），屏底只剩细进度线。
bool readerStatusFooterAbsorbedByBar({
  required bool inlineStatus,
  required double bottomChromeReserve,
  bool floatingBarPainted = false,
}) => inlineStatus && (bottomChromeReserve > 0 || floatingBarPainted);

/// 状态行的底部预留高：启用、未被底栏吸收（[absorbedByBar]，见
/// [readerStatusFooterAbsorbedByBar]）且**非悬浮**时占 [footerHeight]，否则 0。
///
/// 悬浮态（[floating]）状态行与顶栏 / 底栏同一台显隐状态机：收起时正文满屏、唤出时
/// 盖在正文上——与 `readerDesktopHeaderReserve` / `bottomChromeReserve` 的悬浮语义
/// 一致（用户 2026-09-13 拍板「隐藏满屏、唤出覆盖」）。
///
/// 悬浮态但读数**常驻**（[persistent]，「收起控制栏时保留读数」）时，读数胶囊一直
/// 在屏上，就按挤压式占 [footerHeight]——不然它常年盖住每一栏的末几个字。这时**不**看
/// [absorbedByBar]：悬浮态的吸收只来自有声书播放条的临时唤出（`floatingBarPainted`），
/// 跟着它翻预留会让正文在每次唤出 / 收起时重排。
double readerStatusFooterReserve({
  required bool enabled,
  required double footerHeight,
  bool absorbedByBar = false,
  bool floating = false,
  bool persistent = false,
}) {
  if (!enabled) return 0;
  if (floating) return persistent ? footerHeight : 0;
  return absorbedByBar ? 0 : footerHeight;
}

/// 状态行是否此刻绘制：启用、首屏已就绪、未被底栏吸收；悬浮态额外随
/// [transientVisible]（与 `bottomBarVisible` 同一唤出 / 收起真值），除非读数常驻
/// （[persistent]）——那时控制栏收起后读数胶囊照样留在原位（[readerStatusFooterResting]）。
bool readerStatusFooterVisible({
  required bool enabled,
  required bool hasEverLoaded,
  required bool absorbedByBar,
  required bool floating,
  required bool transientVisible,
  bool persistent = false,
}) {
  if (!enabled || !hasEverLoaded || absorbedByBar) return false;
  if (floating) return transientVisible || persistent;
  return true;
}

/// 读数胶囊是否处于「常驻静息」态：悬浮态、读数常驻、控制栏此刻收起。静息态胶囊
/// 更透明、不带阴影，只留读数本身，不跟正文抢视线。
bool readerStatusFooterResting({
  required bool floating,
  required bool persistent,
  required bool transientVisible,
}) => floating && persistent && !transientVisible;

/// 屏底细进度线是否绘制：只在悬浮态、状态行收起、进度开关开着且总字数已知时——
/// 它是状态行收起后唯一留在屏上的进度指示（2px，不占预留、不参与命中）。
bool readerProgressEdgeLineVisible({
  required bool floating,
  required bool footerVisible,
  required bool showProgress,
  required bool hasTotal,
}) => floating && !footerVisible && showProgress && hasTotal;

/// 屏底细进度线高度（逻辑 px）。
const double kReaderProgressEdgeLineHeight = 2;

/// 状态读数并进底栏那一行所需的最小可用宽（逻辑 px）：五颗传输键（-10s / 上一句 /
/// 播放 / 下一句 / +10s）加槽位按钮之后，还要塞得下「计时 · 字数 · 字每时 · 进度条
/// 百分比」这一串（图标写法约 300；此前只有计时 + 进度时约 160、阈值 480）。
///
/// 这只是「并不并进底栏」的版式取舍，不是读数排得下的保证：并进之后读数拿的是
/// 播放条尾部的真实剩余宽度（`AudiobookPlayBar.trailingStatus`），按实测宽度降级 /
/// 缩放（[ReaderStatusInline]），字号放大 / 位数变多时不靠这个常量兜底。
const double kReaderStatusInlineMinWidth = 620;

/// 状态读数是否并进底栏那一行（横屏「同层」），而不是在底栏之下另占一行。
///
/// 判据是**屏幕方向 + 一条宽度下限**。此前借用顶栏那个为按钮数定的固定窗宽阈值
/// （[readerHeaderCompact]，760）：横屏手机 ~700 逻辑 px 放得下五颗传输键加一串
/// 读数，却被判成窄屏，读数被踢到底栏之下单独占一行，底部凭空多出一层
/// （用户 2026-09-14「横屏应该同层进度显示」）。
///
/// 竖屏一律分层：竖屏那点宽度要留给传输键的触控面，把读数挤进同一行只会两边都
/// 难受——那时读数独立成行，坐在底栏这块遮罩的最底部并**居中**
/// （[ReaderStatusFooter.centered]）。
bool readerPlaybackStatusInline({
  required bool enabled,
  required bool landscape,
  required double width,
  double minWidth = kReaderStatusInlineMinWidth,
}) => enabled && landscape && width >= minWidth;

/// 状态行里进度条的宽 / 高（逻辑 px）。
const double kReaderStatusProgressTrackWidth = 72;
const double kReaderStatusProgressTrackHeight = 3;

/// 全书进度比例（0–1）；总字数未知 / 为 0 时 null。
double? readerProgressRatio({required int? current, required int? total}) {
  if (current == null || total == null || total <= 0) return null;
  return (current / total).clamp(0.0, 1.0);
}

/// 状态行**底部带**的高度：状态行坐进系统底部安全区（iPhone home indicator 34pt /
/// Android 手势条）里，带高 = max(状态行预留 [footerReserve], 系统底 inset
/// [bottomInset])；状态行不在场（预留 0：歌词模式 / 被底栏吸收）时只剩系统 inset。
///
/// 此前预留是 `状态行高 + 系统 inset` 两段相加、状态行画在安全区**之上**：iPhone 上
/// 底部一共扣掉 28 + 34 = 62pt，其中 34pt 是一条谁也不用的纯背景空带（BUG-2470）。
/// home indicator 是叠在内容上的一条 5pt 细线（8pt 离底），不是不可用区域——参照
/// Hoshi Reader iOS 把进度读数直接放进去；桌面 / Android 沉浸模式 inset 为 0，带高就是
/// 状态行高，零变化。
double readerStatusFooterBandHeight({
  required double footerReserve,
  required double bottomInset,
}) => math.max(footerReserve, bottomInset);

/// 每小时字数（四舍五入到整数）。时长或字数为 0 时返回 0，不做「不足 1 分钟无值」的
/// 统计口径门槛（那是统计页 `computeCph` 的事）：状态行开局就要显示 `0 / h`。
int readingCharsPerHour({required int chars, required int durationMs}) {
  if (chars <= 0 || durationMs <= 0) return 0;
  return (chars * 3600000 / durationMs).round();
}

/// 本次阅读时长的秒表格式：不足 1 小时 `m:ss`（开局 `0:00`），≥ 1 小时 `h:mm:ss`。
String formatReadingSessionClock(int durationMs) {
  final int totalSeconds = durationMs <= 0 ? 0 : durationMs ~/ 1000;
  final int hours = totalSeconds ~/ 3600;
  final int minutes = (totalSeconds % 3600) ~/ 60;
  final int seconds = totalSeconds % 60;
  final String ss = seconds.toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:$ss';
  }
  return '$minutes:$ss';
}

/// 阅读追踪文案：`<本次时长>`（`m:ss` / `h:mm:ss`）。字数 / 字每时是读数行里
/// 另外两段（[readerStatusReadoutTexts]），口径仍是 [readingCharsPerHour]。
String readerTrackerLabel(StudySessionTotals totals) =>
    formatReadingSessionClock(totals.durationMs);

/// 进度文案：`<百分比>%`（一位小数）。总字数未知 / 为 0 时返回 null（不画这一段）。
/// 已读 / 总字数与本章进度在统计侧栏里看。
String? readerProgressLabel({required int? current, required int? total}) {
  final double? ratio = readerProgressRatio(current: current, total: total);
  if (ratio == null) return null;
  return '${(ratio * 100).toStringAsFixed(1)}%';
}

/// 读数行的排版密度，从宽到窄依次降级（[readerStatusPickDensity] 取第一档放得下的）：
///  * [labeled]——数字带文字单位（`1,284 字` / `8,640 字/时`），进度条加长；宽屏用；
///  * [icons]——单位换成图标（`T 1,284` / `⌚ 8,640/h`），宽度与界面语言无关；
///  * [noTrack]——去掉进度条，只留百分比（屏底细线 / 百分比已经说明了进度）；
///  * [compact]——数字改紧凑写法（`1.2万` / `8.6k`）；
///  * [minimal]——再隐藏本次字数。计时、字每时、百分比始终保留。
enum ReaderStatusReadoutDensity { labeled, icons, noTrack, compact, minimal }

/// 读数行加长后的进度条宽（[ReaderStatusReadoutDensity.labeled]）。
const double kReaderStatusProgressTrackWidthLabeled = 84;

/// 读数行里字数 / 字每时前面那枚图标的边长与它和数字的间距。
const double kReaderStatusReadoutIconSize = 13;
const double kReaderStatusReadoutIconGap = 3;

/// 两段读数之间那颗圆点分隔符：点宽 + 两侧留白。
const double kReaderStatusReadoutDotSize = 3;
const double kReaderStatusReadoutDotGap = 7;

/// 计时键与时长文字的间距；进度条与百分比的间距。
const double kReaderStatusClockTextGap = 2;
const double kReaderStatusTrackTextGap = 8;

/// 读数行某一档密度下各段的文案与排版（纯数据，宽度估算与绘制共用同一份）。
/// 某段为 null = 这一档不画它（开关关着，或被降级掉）。
@immutable
class ReaderStatusReadoutTexts {
  const ReaderStatusReadoutTexts({
    required this.density,
    required this.clock,
    required this.chars,
    required this.speed,
    required this.progress,
    required this.trackWidth,
  });

  final ReaderStatusReadoutDensity density;
  final String? clock;
  final String? chars;
  final String? speed;
  final String? progress;

  /// 进度条宽；null = 这一档不画进度条。
  final double? trackWidth;

  /// 字数 / 字每时前面是否画图标（非 [ReaderStatusReadoutDensity.labeled] 档）。
  bool get iconLabels => density != ReaderStatusReadoutDensity.labeled;
}

/// 按 [density] 生成读数各段文案。[charsUnit] / [speedUnit] 是带文字单位档的格式化
/// 函数（i18n，`$n 字` / `$n 字/时`），由调用方传入，纯函数本身不碰全局翻译。
ReaderStatusReadoutTexts readerStatusReadoutTexts({
  required ReaderStatusReadoutDensity density,
  required StudySessionTotals totals,
  required bool showTimer,
  required bool showChars,
  required bool showSpeed,
  required String? progress,
  required String locale,
  required String Function(String n) charsUnit,
  required String Function(String n) speedUnit,
}) {
  final bool compact =
      density.index >= ReaderStatusReadoutDensity.compact.index;
  final NumberFormat format = compact
      ? NumberFormat.compact(locale: locale)
      : NumberFormat.decimalPattern(locale);
  final bool labeled = density == ReaderStatusReadoutDensity.labeled;
  final int cph = readingCharsPerHour(
    chars: totals.chars,
    durationMs: totals.durationMs,
  );
  final String? chars =
      showChars && density != ReaderStatusReadoutDensity.minimal
      ? (labeled
            ? charsUnit(format.format(totals.chars))
            : format.format(totals.chars))
      : null;
  final String? speed = showSpeed
      ? (labeled ? speedUnit(format.format(cph)) : '${format.format(cph)}/h')
      : null;
  final double? trackWidth =
      progress == null || density.index > ReaderStatusReadoutDensity.icons.index
      ? null
      : (labeled
            ? kReaderStatusProgressTrackWidthLabeled
            : kReaderStatusProgressTrackWidth);
  return ReaderStatusReadoutTexts(
    density: density,
    clock: showTimer ? readerTrackerLabel(totals) : null,
    chars: chars,
    speed: speed,
    progress: progress,
    trackWidth: trackWidth,
  );
}

/// 一档读数排成一行要多宽（逻辑 px）。[measure] 量一段文字的宽（绘制用同一套
/// TextStyle / textScaler），[clockSize] 是计时键边长。与 [ReaderStatusReadouts] 的
/// 排版常量一一对应——改排版必须同时改这里。
double readerStatusReadoutWidth(
  ReaderStatusReadoutTexts texts, {
  required double Function(String text) measure,
  required double clockSize,
}) {
  final List<double> segments = <double>[];
  final String? clock = texts.clock;
  if (clock != null) {
    segments.add(clockSize + kReaderStatusClockTextGap + measure(clock));
  }
  final double icon = texts.iconLabels
      ? kReaderStatusReadoutIconSize + kReaderStatusReadoutIconGap
      : 0;
  final String? chars = texts.chars;
  if (chars != null) segments.add(icon + measure(chars));
  final String? speed = texts.speed;
  if (speed != null) segments.add(icon + measure(speed));
  final String? progress = texts.progress;
  if (progress != null) {
    final double? track = texts.trackWidth;
    segments.add(
      (track == null ? 0 : track + kReaderStatusTrackTextGap) +
          measure(progress),
    );
  }
  if (segments.isEmpty) return 0;
  final double separators =
      (segments.length - 1) *
      (kReaderStatusReadoutDotSize + 2 * kReaderStatusReadoutDotGap);
  return segments.fold<double>(0, (double a, double b) => a + b) + separators;
}

/// 从宽到窄取第一档宽度不超过 [maxWidth] 的密度；[allowLabeled] 为 false 时从
/// [ReaderStatusReadoutDensity.icons] 起步（有声书播放条内联形态和 cue 文本抢宽度，
/// 不带文字单位）。都放不下时返回最窄档，由调用方缩放兜底。
ReaderStatusReadoutDensity readerStatusPickDensity({
  required double maxWidth,
  required double Function(ReaderStatusReadoutDensity density) widthOf,
  bool allowLabeled = true,
}) {
  for (final ReaderStatusReadoutDensity d
      in ReaderStatusReadoutDensity.values) {
    if (!allowLabeled && d == ReaderStatusReadoutDensity.labeled) continue;
    if (widthOf(d) <= maxWidth) return d;
  }
  return ReaderStatusReadoutDensity.minimal;
}

/// 播放条内联形态里那颗计时开关键的边长（逻辑 px）。播放条本身 56 高，容得下比
/// 状态行（行高就是上限）更大的一颗，与条上其余传输键同一密度。
const double kReaderStatusInlineClockButtonSize = 32;

/// 学习计时开关键：状态行 / 播放条右端那颗「计时中 ⏸ / 已停 ▶」。
///
/// 它取代此前那枚**纯装饰**的秒表字形（`Icons.timer_outlined` /
/// `Icons.timer_off_outlined`）：那个 [Icon] 只报状态，点下去没有任何 MD3 反馈；
/// 状态行形态好歹整块裹在一层 [GestureDetector] 里（点文字能停表，但屏幕上没有
/// 任何东西说它可点），播放条内联形态（[ReaderStatusInline]）更是整块不接指针——
/// 那里写着「计时中」的图标点一百下也不会停表。现在它是一颗真的 MD3 [IconButton]：
/// state layer + ripple + tooltip，点一下当场停 / 续表。
///
/// 图标与 tooltip 跟统计侧栏那颗暂停键同源（`reader_statistics_sheet.dart` 的
/// `_SessionClock`，同一个 `_toggleStudyClockManualPause` 入口）：同一个动作只用一套
/// 符号——计时中画 ⏸（点了会停），已停画 ▶（点了会续），文案复用同一对 i18n key。
///
/// 尺寸是方的 [size]，状态行里就等于整条行高（[kReaderStatusFooterHeight]）：视觉
/// 高度 == 预留高度是 chrome 铁律，按钮不能比行高多一个像素，否则就是挤正文。为此
/// 必须显式 `tapTargetSize: shrinkWrap`——[IconButton] 默认按
/// `ThemeData.materialTapTargetSize` 把自己裹进 48dp 触摸靶，那会把 28px 的状态行
/// 直接撑成 48px。
///
/// [ExcludeFocus]：状态行与播放条内联读数是纯指针面，不进焦点遍历池（TODO-700
/// 不变式）。裸 [IconButton] 默认可聚焦，不排除就会往 Tab 环里塞一个不受
/// `FushiFocusController` 管的节点。
class ReaderStudyClockButton extends StatelessWidget {
  const ReaderStudyClockButton({
    super.key,
    required this.active,
    required this.color,
    required this.onPressed,
    this.size = kReaderStatusFooterHeight,
  });

  /// 计时是否在走（[StudySessionTotals.active]）。与同屏其它计时指示同一读口。
  final bool active;

  /// 阅读器纸张主题的前景色（已调过透明度的 muted）。不读全局 Material 色。
  final Color color;

  /// 停 / 续表。为 null 时按钮呈禁用态（生产路径恒有值）。
  final VoidCallback? onPressed;

  /// 按钮边长；图标取其一半。
  final double size;

  @override
  Widget build(BuildContext context) {
    return ExcludeFocus(
      child: FushiIconButtonControl(
        icon: FushiIcon(
          active ? Icons.pause_rounded : Icons.play_arrow_rounded,
          key: ValueKey<bool>(active),
        ),
        color: color,
        iconSize: size / 2,
        padding: EdgeInsets.zero,
        constraints: BoxConstraints.tightFor(width: size, height: size),
        style: IconButton.styleFrom(
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        tooltip: active
            ? t.reader_stats_clock_pause
            : t.reader_stats_clock_resume,
        onPressed: onPressed,
      ),
    );
  }
}

/// 状态行 / 播放条里的短进度条：一段圆角轨道 + 已读比例填充。
class ReaderStatusProgressTrack extends StatelessWidget {
  const ReaderStatusProgressTrack({
    super.key,
    required this.ratio,
    required this.color,
    this.width = kReaderStatusProgressTrackWidth,
    this.height = kReaderStatusProgressTrackHeight,
  });

  final double ratio;
  final Color color;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(height),
        ),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: FractionallySizedBox(
            widthFactor: ratio.clamp(0.0, 1.0),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(height),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 悬浮态状态行收起后留在屏底的细进度线（[kReaderProgressEdgeLineHeight]）：
/// 不占预留、不吃指针（[IgnorePointer]），只是一条随全书进度增长的色带。
class ReaderProgressEdgeLine extends StatelessWidget {
  const ReaderProgressEdgeLine({
    super.key,
    required this.ratio,
    required this.color,
  });

  final double ratio;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        height: kReaderProgressEdgeLineHeight,
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: FractionallySizedBox(
            widthFactor: ratio.clamp(0.0, 1.0),
            child: ColoredBox(color: color.withValues(alpha: 0.55)),
          ),
        ),
      ),
    );
  }
}

class ReaderStatusFooter extends StatefulWidget {
  const ReaderStatusFooter({
    super.key,
    required this.sessionTotals,
    required this.currentChars,
    required this.totalChars,
    required this.showTimer,
    required this.showProgress,
    required this.showChars,
    required this.showSpeed,
    required this.textColor,
    required this.backgroundColor,
    this.height = kReaderStatusFooterHeight,
    this.bottomInset = 0,
    this.centered = false,
    this.tick = const Duration(seconds: 1),
    this.onTap,
    this.onTapTracker,
    this.onTapProgress,
    this.floating = false,
    this.resting = false,
  });

  /// 悬浮工具栏样式（M3E，默认）：读数是一枚浮在正文上的小胶囊（底色
  /// [backgroundColor]、全圆角、轻阴影），整条带透明——不画整条实体底栏，竖排 /
  /// 横排一样。带高（预留）不变，只是不再铺底色。
  final bool floating;

  /// 常驻静息态（[readerStatusFooterResting]）：控制栏收起、读数胶囊仍留在原位。
  /// 胶囊底色更透明、去掉阴影。只在 [floating] 时有意义。
  final bool resting;

  /// 会话累计的**读口**（每个 [tick] 采样一次）。账本在 `StudyClock`，页面不持有
  /// 任何会话累计副本（v92 统计纪律），所以这里拿的是函数而不是快照。
  final StudySessionTotals Function() sessionTotals;

  final int? currentChars;
  final int? totalChars;

  /// 阅读追踪（计时键 + 本次时长）是否显示（「显示阅读计时器」开关落到这里）。
  /// 关掉只是不画这一段——[StudyClock] 照常计时、照常落库，隐藏读数不等于停表
  /// （停表是点这一段本身的手动暂停）。
  final bool showTimer;

  /// 进度读数是否显示（「阅读进度指示」开关落到这里）。
  final bool showProgress;

  /// 本次已读字数（[StudySessionTotals] 的 chars）是否显示。
  final bool showChars;

  /// 本次字每时（[readingCharsPerHour]）是否显示。
  final bool showSpeed;

  final Color textColor;
  final Color backgroundColor;

  /// 读数行本身的高度（[kReaderStatusFooterHeight]）。
  final double height;

  /// 系统底部安全区高（iPhone home indicator）。整条状态行占
  /// `max(height, bottomInset)` 的带（[readerStatusFooterBandHeight]），读数行贴带顶、
  /// 多出的部分在读数行**之下**——读数落在 home indicator 细线之上，不与它重叠。
  final double bottomInset;

  /// 读数居中而不是贴右端。
  ///
  /// 竖屏（读数没并进底栏那一行）时这一行坐在底栏那块遮罩的最底部，与上面一排
  /// 居中的传输键同属一块面——那时读数贴在右角会和居中的播放键错开成两个重心。
  /// 状态行独自在屏底（没有底栏）时仍贴右：右下角是它与顶部进度 pill 共用的
  /// 视觉基线。
  final bool centered;

  /// 秒表刷新周期（测试可缩短）。
  final Duration tick;

  /// 点状态行空白处：与顶部进度 pill 同语义——唤出 / 收起控制栏。
  final VoidCallback? onTap;

  /// 点计时段「计时键 + 时长」：切换手动暂停计时。这是手动停 / 续表的**唯一**
  /// 入口——统计浮层里曾有一个同功能按钮，但开浮层本身就停表，层内开关改不动运行态。
  final VoidCallback? onTapTracker;

  /// 点字数 / 字每时 / 进度这几段：直接打开阅读统计浮层。
  final VoidCallback? onTapProgress;

  @override
  State<ReaderStatusFooter> createState() => _ReaderStatusFooterState();
}

/// 状态行秒表的周期刷新（[ReaderStatusFooter] / [ReaderStatusInline] 共用）。
///
/// 秒表 tick 只在读数真的变了才重建：计时暂停 / 失焦期间读数不动，不白重建。计时器
/// 只在所在子树看得见（[TickerMode] 开）时跑：被歌词覆盖层或别的路由盖住时停
/// （BUG-4126）。恢复时 TickerMode 翻转让 [didChangeDependencies] 重跑、随后照常
/// build，build 直接读 `sessionTotals()`，当帧就是现值。
mixin _TrackerTickRefresh<T extends StatefulWidget> on State<T> {
  Timer? _ticker;
  String? _lastSignature;

  Duration get trackerTick;

  /// 读数里是否有随会话累计变化的段（计时 / 字数 / 字每时任一开着）。
  bool get trackerShown;
  StudySessionTotals trackerTotals();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (TickerMode.valuesOf(context).enabled) {
      _ticker ??= Timer.periodic(trackerTick, (_) => _onTrackerTick());
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  void _onTrackerTick() {
    if (!mounted) return;
    // 会话类读数都隐藏时这一层没有随秒变化的内容，秒表 tick 不必重建。
    if (!trackerShown) return;
    final StudySessionTotals totals = trackerTotals();
    final String signature =
        '${readerTrackerLabel(totals)}|${totals.chars}|${totals.active}';
    if (signature == _lastSignature) return;
    setState(() => _lastSignature = signature);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}

class _ReaderStatusFooterState extends State<ReaderStatusFooter>
    with _TrackerTickRefresh<ReaderStatusFooter> {
  @override
  Duration get trackerTick => widget.tick;

  @override
  bool get trackerShown =>
      widget.showTimer || widget.showChars || widget.showSpeed;

  @override
  StudySessionTotals trackerTotals() => widget.sessionTotals();

  /// 悬浮胶囊左右内边距（单侧）。
  static const double _pillPadding = 12;

  @override
  Widget build(BuildContext context) {
    final StudySessionTotals totals = widget.sessionTotals();
    final Color muted = widget.textColor.withValues(alpha: 0.55);
    final double bandHeight = readerStatusFooterBandHeight(
      footerReserve: readerStatusFooterPaintedHeight(
        floating: widget.floating,
        height: widget.height,
      ),
      bottomInset: widget.bottomInset,
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: ColoredBox(
        color: widget.floating ? Colors.transparent : widget.backgroundColor,
        child: SizedBox(
          height: bandHeight,
          child: Padding(
            // 读数行贴带顶，多出的安全区在读数之下（BUG-2470）。
            padding: EdgeInsets.fromLTRB(16, 0, 16, bandHeight - widget.height),
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final Widget readouts = ReaderStatusReadouts(
                  keyPrefix: 'fushi_status',
                  totals: totals,
                  currentChars: widget.currentChars,
                  totalChars: widget.totalChars,
                  showTimer: widget.showTimer,
                  showChars: widget.showChars,
                  showSpeed: widget.showSpeed,
                  showProgress: widget.showProgress,
                  color: muted,
                  clockSize: widget.height,
                  rowHeight: widget.height,
                  maxWidth:
                      constraints.maxWidth -
                      (widget.floating ? 2 * _pillPadding : 0),
                  onTapTracker: widget.onTapTracker,
                  onTapStats: widget.onTapProgress,
                );
                // 读数整串贴右（或居中），只有一处落点。
                final Widget row = Row(
                  mainAxisSize: widget.floating
                      ? MainAxisSize.min
                      : MainAxisSize.max,
                  mainAxisAlignment: widget.centered
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.end,
                  children: <Widget>[Flexible(child: readouts)],
                );
                if (!widget.floating) return row;
                final bool resting = widget.resting;
                return Align(
                  alignment: widget.centered
                      ? Alignment.center
                      : AlignmentDirectional.centerEnd,
                  child: AnimatedContainer(
                    key: const ValueKey<String>('fushi_status_footer_pill'),
                    duration: fushiMotionDuration(context, FushiMotion.short),
                    curve: FushiMotion.standard,
                    padding: const EdgeInsets.symmetric(
                      horizontal: _pillPadding,
                    ),
                    decoration: ShapeDecoration(
                      color: resting
                          ? widget.backgroundColor.withValues(
                              alpha: widget.backgroundColor.a * 0.72,
                            )
                          : widget.backgroundColor,
                      shape: const StadiumBorder(),
                      shadows: <BoxShadow>[
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: resting ? 0 : 0.12,
                          ),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: row,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// 读数行本体：「计时键 时长 · 字数 · 字每时 · 进度条 百分比」，状态行胶囊
/// （[ReaderStatusFooter]）与有声书播放条内联形态（[ReaderStatusInline]）共用。
///
/// 按 [maxWidth] 自动降级（[readerStatusPickDensity]）：每一档先用与绘制同一套
/// TextStyle / textScaler 量宽，取第一档放得下的，不换行、不加高。最窄档仍放不下
/// （极窄 + 系统大字号）时整行等比缩小兜底。
class ReaderStatusReadouts extends StatelessWidget {
  const ReaderStatusReadouts({
    super.key,
    required this.keyPrefix,
    required this.totals,
    required this.currentChars,
    required this.totalChars,
    required this.showTimer,
    required this.showChars,
    required this.showSpeed,
    required this.showProgress,
    required this.color,
    required this.clockSize,
    required this.rowHeight,
    required this.maxWidth,
    this.allowLabeled = true,
    this.onTapTracker,
    this.onTapStats,
  });

  /// 各段 key 的前缀（`<prefix>_tracker` / `_chars` / `_speed` / `_progress` …）。
  final String keyPrefix;
  final StudySessionTotals totals;
  final int? currentChars;
  final int? totalChars;
  final bool showTimer;
  final bool showChars;
  final bool showSpeed;
  final bool showProgress;

  /// 已调过透明度的读数前景色。
  final Color color;
  final double clockSize;

  /// 每段命中区的高度（撑满所在行高）。
  final double rowHeight;
  final double maxWidth;

  /// 是否允许带文字单位的最宽档（播放条内联形态不允许）。
  final bool allowLabeled;

  /// 点计时段：停 / 续表。
  final VoidCallback? onTapTracker;

  /// 点字数 / 字每时 / 进度：打开统计浮层。
  final VoidCallback? onTapStats;

  /// 每一段的可点区域：命中区**撑满整条行高**（裸文字 + 14px 图标的行盒只有十几 px
  /// 高）。只扩竖向、不加横向内边距——读数和胶囊边缘的间距是视觉基线。行高不能为
  /// 命中区加高（视觉高度 == 预留高度是 chrome 铁律），28px 达不到 48dp 是已知取舍。
  Widget _hitTarget({required Widget child, VoidCallback? onTap}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: rowHeight,
        child: Center(widthFactor: 1, child: child),
      ),
    );
  }

  Widget _dot() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: kReaderStatusReadoutDotGap),
    child: SizedBox.square(
      dimension: kReaderStatusReadoutDotSize,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: color.a * 0.6),
          shape: BoxShape.circle,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final TextStyle style = TextStyle(
      fontSize: kReaderStatusFooterFontSize,
      color: color,
      height: 1.0,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    final TextScaler scaler =
        MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling;
    final TextDirection direction =
        Directionality.maybeOf(context) ?? TextDirection.ltr;
    final String locale = _numberLocale(context);
    final String? progress = showProgress
        ? readerProgressLabel(current: currentChars, total: totalChars)
        : null;
    final double? ratio = progress == null
        ? null
        : readerProgressRatio(current: currentChars, total: totalChars);

    ReaderStatusReadoutTexts textsFor(ReaderStatusReadoutDensity d) =>
        readerStatusReadoutTexts(
          density: d,
          totals: totals,
          showTimer: showTimer,
          showChars: showChars,
          showSpeed: showSpeed,
          progress: progress,
          locale: locale,
          charsUnit: (String n) => t.reader_status_session_chars(n: n),
          speedUnit: (String n) => t.reader_stats_chars_per_hour(n: n),
        );

    double measure(String text) {
      final TextPainter painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final double width = painter.width;
      painter.dispose();
      return width;
    }

    final ReaderStatusReadoutDensity density = readerStatusPickDensity(
      maxWidth: maxWidth,
      allowLabeled: allowLabeled,
      widthOf: (ReaderStatusReadoutDensity d) => readerStatusReadoutWidth(
        textsFor(d),
        measure: measure,
        clockSize: clockSize,
      ),
    );
    final ReaderStatusReadoutTexts texts = textsFor(density);

    Widget label(String text, String keySuffix) => Text(
      text,
      key: ValueKey<String>('${keyPrefix}_$keySuffix'),
      style: style,
      maxLines: 1,
      softWrap: false,
    );

    Widget iconLabel(IconData icon, String text, String keySuffix) {
      if (!texts.iconLabels) return label(text, keySuffix);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiIcon(icon, size: kReaderStatusReadoutIconSize, color: color),
          const SizedBox(width: kReaderStatusReadoutIconGap),
          label(text, keySuffix),
        ],
      );
    }

    final String? chars = texts.chars;
    final String? speed = texts.speed;
    final String? progressText = texts.progress;
    final double? trackWidth = texts.trackWidth;
    final String? clock = texts.clock;

    final List<Widget> statsSegments = <Widget>[
      if (chars != null) iconLabel(FushiIcons.textFields, chars, 'chars'),
      if (speed != null) iconLabel(FushiIcons.speed, speed, 'speed'),
      if (progressText != null)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (trackWidth != null && ratio != null) ...<Widget>[
              ReaderStatusProgressTrack(
                key: ValueKey<String>('${keyPrefix}_progress_track'),
                ratio: ratio,
                color: color,
                width: trackWidth,
              ),
              const SizedBox(width: kReaderStatusTrackTextGap),
            ],
            label(progressText, 'progress'),
          ],
        ),
    ];

    final List<Widget> children = <Widget>[
      if (clock != null)
        _hitTarget(
          onTap: onTapTracker,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 计时键本身就是停 / 续表的按钮（[ReaderStudyClockButton]）；外面那层
              // 命中区仍在，点时长文字也照停。
              ReaderStudyClockButton(
                key: ValueKey<String>('${keyPrefix}_clock_toggle'),
                active: totals.active,
                color: color,
                size: clockSize,
                onPressed: onTapTracker,
              ),
              const SizedBox(width: kReaderStatusClockTextGap),
              label(clock, 'tracker'),
            ],
          ),
        ),
      if (clock != null && statsSegments.isNotEmpty) _dot(),
      if (statsSegments.isNotEmpty)
        _hitTarget(
          onTap: onTapStats,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (int i = 0; i < statsSegments.length; i++) ...<Widget>[
                if (i > 0) _dot(),
                statsSegments[i],
              ],
            ],
          ),
        ),
    ];
    final Widget row = Row(
      key: ValueKey<String>('${keyPrefix}_readouts_${density.name}'),
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
    // 最窄档仍放不下（极窄 + 系统大字号）：等比缩小，行永远不溢出。
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.centerEnd,
      child: row,
    );
  }
}

/// 数字格式用的 locale：跟随界面语言（`1,284` / `1.2万`）；intl 不认识的退回 en。
String _numberLocale(BuildContext context) {
  final Locale? locale = Localizations.maybeLocaleOf(context);
  if (locale == null) return 'en';
  final String tag = locale.toLanguageTag().replaceAll('-', '_');
  if (NumberFormat.localeExists(tag)) return tag;
  if (NumberFormat.localeExists(locale.languageCode)) {
    return locale.languageCode;
  }
  return 'en';
}

/// 状态行文案的单行内联版：桌面端有声书播放条唤出时，把同一串读数并进播放条
/// 右端（底部只留一条）。同一读口、同一组件（[ReaderStatusReadouts]），只是起步
/// 于图标档（不带文字单位，和 cue 文本抢宽度）、计时键更大。
class ReaderStatusInline extends StatefulWidget {
  const ReaderStatusInline({
    super.key,
    required this.sessionTotals,
    required this.currentChars,
    required this.totalChars,
    required this.showTimer,
    required this.showProgress,
    required this.showChars,
    required this.showSpeed,
    required this.textColor,
    this.onToggleTimer,
    this.onOpenStats,
    this.tick = const Duration(seconds: 1),
  });

  final StudySessionTotals Function() sessionTotals;
  final int? currentChars;
  final int? totalChars;
  final bool showTimer;
  final bool showProgress;
  final bool showChars;
  final bool showSpeed;
  final Color textColor;

  /// 停 / 续表（与状态行的 [ReaderStatusFooter.onTapTracker] 同一入口
  /// `_toggleStudyClockManualPause`）。此前内联形态整块不接指针：播放条一唤出，
  /// 状态行让位（BUG-2467），屏幕上就只剩这一份写着「计时中」的读数，而它点不动。
  final VoidCallback? onToggleTimer;

  /// 点字数 / 字每时 / 进度：打开统计浮层（与状态行同一入口）。
  final VoidCallback? onOpenStats;

  final Duration tick;

  @override
  State<ReaderStatusInline> createState() => _ReaderStatusInlineState();
}

class _ReaderStatusInlineState extends State<ReaderStatusInline>
    with _TrackerTickRefresh<ReaderStatusInline> {
  @override
  Duration get trackerTick => widget.tick;

  @override
  bool get trackerShown =>
      widget.showTimer || widget.showChars || widget.showSpeed;

  @override
  StudySessionTotals trackerTotals() => widget.sessionTotals();

  @override
  Widget build(BuildContext context) {
    // 播放条把读数放在 `AudiobookPlayBar.trailingStatus`，给的是条尾跟随键之前
    // 那段的真实宽度上界：按实测宽度从图标档往下降级，最窄档仍放不下时
    // [ReaderStatusReadouts] 的 FittedBox 等比缩小——系统字号放大 / 位数变多也不会
    // 被挤出视口。无界宿主（maxWidth 无穷）下就是图标档原样排。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) =>
          ReaderStatusReadouts(
            keyPrefix: 'fushi_bar_status',
            totals: widget.sessionTotals(),
            currentChars: widget.currentChars,
            totalChars: widget.totalChars,
            showTimer: widget.showTimer,
            showChars: widget.showChars,
            showSpeed: widget.showSpeed,
            showProgress: widget.showProgress,
            color: widget.textColor.withValues(alpha: 0.55),
            clockSize: kReaderStatusInlineClockButtonSize,
            rowHeight: kReaderStatusInlineClockButtonSize,
            maxWidth: constraints.maxWidth,
            allowLabeled: false,
            onTapTracker: widget.onToggleTimer,
            onTapStats: widget.onOpenStats,
          ),
    );
  }
}
