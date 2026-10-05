// M3 Expressive「其余组件」的主题层（用户 2026-10-05：「所有组件都是 m3e」）。
//
// 提示条 / tooltip / 徽标 / 滚动条 / 日期与时间选择器 / 轮播这几类组件的
// Material 主题只在这里写一次，buildFushiThemeData 逐个调用。单独成文件是为了
// 让 theme_notifier.dart 里只剩一行调用：那个文件同时被对话框、按钮、导航等
// 多条 M3E 线改，组件主题各自收在自己的文件里互不踩。
//
// 规格取自 m3.material.io 对应组件页，M3E 的取舍写在各函数注释里。Apple 设计
// 系统（appleDesign）只在会被 Material 原生控件直接吃到的地方给 Apple 口径，其余
// 交回各 Fushi* 包装自绘；墨水屏（eink）不画阴影、不靠颜色区分状态。
import 'package:flutter/material.dart';

import 'package:fushi/src/utils/components/fushi_design_tokens.dart';

/// 反色浮层（提示条 / toast / plain tooltip）共用的形状：单行高 48 时就是
/// M3E 的全胶囊，多行退成 24 圆角块。
const double kFushiM3eInverseSurfaceRadius = 24;

/// M3E plain tooltip 圆角（规格 corner-extra-small）。
const double kFushiM3ePlainTooltipRadius = 4;

/// M3E rich tooltip / 菜单类小浮层圆角（corner-medium）。
const double kFushiM3eRichTooltipRadius = 12;

/// 提示条（SnackBar）：M3 规格是 inverseSurface 底 + inverseOnSurface 正文 +
/// inversePrimary 动作；M3E 下把形状换成与 toast 同一副全胶囊（单行）/ 24 圆角
/// （多行），elevation 3。玻璃设计系统由 FushiSnackBar 自绘玻璃胶囊，本体透明。
SnackBarThemeData fushiM3eSnackBarTheme({
  required ColorScheme cs,
  required TextTheme tt,
  required bool eink,
  required bool glassDesign,
  Color? glassBackground,
}) {
  final bool glassCapsule = glassDesign && !eink;
  return SnackBarThemeData(
    behavior: SnackBarBehavior.floating,
    shape: glassCapsule
        ? RoundedRectangleBorder(borderRadius: FushiBorderRadius.card)
        : RoundedRectangleBorder(
            borderRadius: const BorderRadius.all(
              Radius.circular(kFushiM3eInverseSurfaceRadius),
            ),
            // 墨水屏没有阴影可用，前景色细边界定浮条。
            side: eink
                ? BorderSide(color: cs.onInverseSurface)
                : BorderSide.none,
          ),
    insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    contentTextStyle: glassCapsule
        ? null
        : (tt.bodyMedium ?? const TextStyle()).copyWith(
            color: cs.onInverseSurface,
            fontWeight: FontWeight.w500,
          ),
    actionTextColor: eink ? cs.onInverseSurface : cs.inversePrimary,
    closeIconColor: cs.onInverseSurface,
    // 玻璃设计系统：FushiSnackBar 自己把内容画进玻璃胶囊，SnackBar 本体必须
    // 透明无阴影，否则胶囊外再多一层底。
    backgroundColor: glassCapsule
        ? Colors.transparent
        : (glassBackground ?? cs.inverseSurface),
    elevation: glassCapsule ? 0 : (eink ? 0 : 3),
  );
}

/// plain tooltip：M3 规格 inverseSurface 底、corner-extra-small、bodySmall、
/// 8×4 内边距、最小高 24。悬停 400ms 才出（默认 0 会在鼠标划过工具栏时一路闪），
/// 离开 100ms 收起。rich tooltip 见 FushiRichTooltip（surfaceContainer 卡）。
TooltipThemeData fushiM3eTooltipTheme({
  required ColorScheme cs,
  required TextTheme tt,
  required bool eink,
  Color? glassBackground,
}) {
  return TooltipThemeData(
    waitDuration: const Duration(milliseconds: 400),
    exitDuration: const Duration(milliseconds: 100),
    constraints: const BoxConstraints(minHeight: 24),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: glassBackground ?? cs.inverseSurface,
      borderRadius: const BorderRadius.all(
        Radius.circular(kFushiM3ePlainTooltipRadius),
      ),
      border: eink ? Border.all(color: cs.onInverseSurface) : null,
    ),
    textStyle: (tt.bodySmall ?? const TextStyle()).copyWith(
      color: cs.onInverseSurface,
      fontWeight: FontWeight.w500,
    ),
  );
}

/// 徽标：M3 规格小点 6、带数字 16 高，error / onError，labelSmall。M3E 把数字
/// 加粗一档（emphasized），读数更利落。墨水屏 error 塌成前景色，交给默认。
BadgeThemeData fushiM3eBadgeTheme({
  required ColorScheme cs,
  required TextTheme tt,
  required bool eink,
}) {
  return BadgeThemeData(
    backgroundColor: eink ? cs.onSurface : cs.error,
    textColor: eink ? cs.surface : cs.onError,
    smallSize: 6,
    largeSize: 16,
    padding: const EdgeInsets.symmetric(horizontal: 4),
    textStyle: (tt.labelSmall ?? const TextStyle()).copyWith(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      height: 1,
    ),
  );
}

/// 滚动条：粗细两个亮度同为 3（BUG-1997：常驻覆盖在列表右侧，粗了会压住最右
/// 一列的操作按钮），全圆头；拇指 onSurfaceVariant——静息 38%、悬停 60%、
/// 拖动 80%，状态层与其它 M3E 控件同一套递进。墨水屏交回默认实色。
ScrollbarThemeData fushiM3eScrollbarTheme({
  required ColorScheme cs,
  required bool eink,
}) {
  return ScrollbarThemeData(
    thickness: WidgetStateProperty.all(kFushiScrollbarThickness),
    thumbVisibility: WidgetStateProperty.all(true),
    radius: const Radius.circular(kFushiScrollbarThickness),
    thumbColor: eink
        ? null
        : WidgetStateProperty.resolveWith((Set<WidgetState> states) {
            if (states.contains(WidgetState.dragged)) {
              return cs.onSurfaceVariant.withValues(alpha: 0.8);
            }
            if (states.contains(WidgetState.hovered)) {
              return cs.onSurfaceVariant.withValues(alpha: 0.6);
            }
            return cs.onSurfaceVariant.withValues(alpha: 0.38);
          }),
  );
}

/// 日期选择器：M3 对话框面板（surfaceContainerHigh、28 圆角、无 tint），
/// 选中日 primary 全圆、今天 primary 描边，范围段 secondaryContainer；M3E 把
/// 年份 / 日格换成胶囊、标题用 headlineLarge emphasized。
DatePickerThemeData fushiM3eDatePickerTheme({
  required ColorScheme cs,
  required TextTheme tt,
  required bool eink,
  required bool appleDesign,
}) {
  if (appleDesign) return const DatePickerThemeData();
  return DatePickerThemeData(
    backgroundColor: cs.surfaceContainerHigh,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: FushiBorderRadius.dialog,
      side: eink ? BorderSide(color: cs.outline) : BorderSide.none,
    ),
    headerForegroundColor: cs.onSurfaceVariant,
    headerHeadlineStyle: (tt.headlineLarge ?? const TextStyle()).copyWith(
      fontWeight: FontWeight.w600,
      color: cs.onSurface,
    ),
    dayShape: WidgetStateProperty.all(const StadiumBorder()),
    yearShape: WidgetStateProperty.all(const StadiumBorder()),
    todayBorder: BorderSide(color: cs.primary, width: 1.5),
    rangeSelectionBackgroundColor: cs.secondaryContainer,
    dividerColor: cs.outlineVariant,
    dayStyle: (tt.bodyLarge ?? const TextStyle()).copyWith(
      fontWeight: FontWeight.w500,
    ),
  );
}

/// 时间选择器：同一副对话框面板；M3E 的时 / 分大块是 16 圆角、选中段
/// primaryContainer，表盘 surfaceContainerHighest，上下午切换 12 圆角。
TimePickerThemeData fushiM3eTimePickerTheme({
  required ColorScheme cs,
  required TextTheme tt,
  required bool eink,
  required bool appleDesign,
}) {
  if (appleDesign) return const TimePickerThemeData();
  return TimePickerThemeData(
    backgroundColor: cs.surfaceContainerHigh,
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: FushiBorderRadius.dialog,
      side: eink ? BorderSide(color: cs.outline) : BorderSide.none,
    ),
    hourMinuteShape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(16)),
    ),
    dayPeriodShape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(12)),
    ),
    hourMinuteColor: eink
        ? null
        : WidgetStateColor.resolveWith(
            (Set<WidgetState> states) => states.contains(WidgetState.selected)
                ? cs.primaryContainer
                : cs.surfaceContainerHighest,
          ),
    hourMinuteTextColor: eink
        ? null
        : WidgetStateColor.resolveWith(
            (Set<WidgetState> states) => states.contains(WidgetState.selected)
                ? cs.onPrimaryContainer
                : cs.onSurface,
          ),
    dialBackgroundColor: eink ? null : cs.surfaceContainerHighest,
    dialHandColor: cs.primary,
    hourMinuteTextStyle: (tt.displayMedium ?? const TextStyle()).copyWith(
      fontWeight: FontWeight.w600,
    ),
  );
}

/// 轮播（CarouselView / FushiCarousel）：M3 规格项圆角 corner-extra-large 28、
/// 项间距 8、无投影；底色 surfaceContainer（图未到时的占位色块）。
CarouselViewThemeData fushiM3eCarouselTheme({
  required ColorScheme cs,
  required bool eink,
}) {
  return CarouselViewThemeData(
    backgroundColor: cs.surfaceContainer,
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: const BorderRadius.all(Radius.circular(28)),
      side: eink ? BorderSide(color: cs.outline) : BorderSide.none,
    ),
    padding: const EdgeInsets.symmetric(horizontal: 4),
  );
}
