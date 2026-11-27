import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/floating_ball/floating_ball_channel.dart';
import 'package:fushi/src/lookup/global_lookup_channel.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';

/// 应用外查词卡临时「借」主窗做一件要 Flutter 界面的事（截屏识字「制卡时框选截图」、
/// 制卡前编辑例句……）的统一出口。
///
/// 覆盖窗查词卡画不了 Flutter 对话框、Windows 上也收不到键盘（`WS_EX_NOACTIVATE`），
/// 这类界面只能放进主窗。反馈 6RETmKY1TH：借完必须还——主窗放回原处（托盘 / 最小化 /
/// 原样），前台还给用户发起查词时在用的程序，查词卡原样放回，结果照常在卡上说。
/// 不经这里、自己 `bringMainWindowToFront` 的话，Fushi 会一直停在前台。

/// [MainWindowExcursionPort.suspendLookup] 收起的那张查词卡：放回时要同一个 route 与
/// generation（原生按两者认领，过期的放回不会复活新一次查词的卡）。
@immutable
class LookupCardSuspension {
  const LookupCardSuspension({required this.route, required this.generation});

  final GlobalLookupRoute route;
  final int generation;
}

/// 借主窗收起查词卡用的 generation。与 galgame 截图收卡
/// （`gal_hook_text_overlay_controller.dart` 从 1 << 52 起）分开取段，原生按
/// generation 认领，两边永不撞号。
int _nextExcursionSuspendGeneration = 1 << 48;

/// 借主窗要碰的原生面（测试替换）。
class MainWindowExcursionPort {
  const MainWindowExcursionPort();

  /// 关掉此刻的查词卡（收不起来时的退路）。
  Future<void> dismissLookup() => GlobalLookupChannel.hide();

  /// 暂时收起（不关掉）此刻的查词卡：卡片的 WebView、查词 route 与位置都留着，
  /// [restoreLookup] 放回原位。收不起来（没有绑定的卡 / 原生拒绝）时返回 null。
  Future<LookupCardSuspension?> suspendLookup() async {
    final GlobalLookupRoute route = GlobalLookupChannel.currentRoute;
    final int generation = ++_nextExcursionSuspendGeneration;
    final bool suspended = await GlobalLookupChannel.runWithRoute(
      route,
      () => GlobalLookupChannel.suspendForCapture(generation),
    );
    return suspended
        ? LookupCardSuspension(route: route, generation: generation)
        : null;
  }

  /// 放回 [suspendLookup] 收起的卡。[returnForeground] 非 null 时原生先把前台交还给
  /// 它（[FloatingBallChannel.foregroundAppToken] 记下的窗口 / app），再不激活地放回
  /// 卡片。返回卡有没有回到屏上。
  Future<bool> restoreLookup(
    LookupCardSuspension suspension, {
    int? returnForeground,
  }) => GlobalLookupChannel.runWithRoute(
    suspension.route,
    () => GlobalLookupChannel.restoreAfterCapture(
      suspension.generation,
      returnForeground: returnForeground,
    ),
  );

  /// 记下主窗此刻的呈现状态与用户正在用的前台窗口。要在任何 Fushi 窗口抢前台
  /// 之前调（截屏识字的冻结层会抢一次前台，所以那条路在开冻结层前就记好）。
  Future<MainWindowPresentation?> captureMainWindowPresentation() async =>
      DesktopLookupService.instance.captureMainWindowPresentation(
        foregroundApp: await FloatingBallChannel.foregroundAppToken(),
      );

  /// 把主窗放回 [presentation] 记下的位置（托盘 / 最小化 / 原样）。
  Future<void> settleMainWindowPresentation(
    MainWindowPresentation presentation,
  ) => DesktopLookupService.instance.settleMainWindowPresentation(presentation);

  Future<void> bringMainWindowToFront() =>
      DesktopLookupService.instance.bringMainWindowToFront();
}

/// [runMainWindowExcursion] 的结果。
@immutable
class MainWindowExcursionResult<T> {
  const MainWindowExcursionResult(this.value, {required this.cardRestored});

  /// [runMainWindowExcursion] 的 `body` 返回值；主窗不可用时为 null。
  final T? value;

  /// 发起这件事的查词卡回到了屏上：结果照常在卡上说。为 false 时卡已关（收不起来
  /// 只能关），主窗也就留在前台，结果由宿主在主窗说。
  final bool cardRestored;
}

/// 借主窗跑 [body]：收起查词卡（收不起来就关掉）→ 主窗拉到前台 → 用
/// [navigatorContext] 跑 [body] → 无论成败都把主窗放回 [presentation]、前台还给原
/// 程序、查词卡放回原位。
///
/// [presentation] 为 null 时此刻现记（覆盖窗卡片不抢前台，此刻的前台就是用户的程序）；
/// 路径上有别的 Fushi 窗口先抢过前台（截屏识字冻结层）时由调用方传它早先记下的那份。
/// 卡收不起来时主窗不放回：卡已关，结果只能在主窗里说。
Future<MainWindowExcursionResult<T>> runMainWindowExcursion<T>({
  required MainWindowExcursionPort port,
  required BuildContext? Function() navigatorContext,
  required Future<T?> Function(BuildContext context) body,
  MainWindowPresentation? presentation,
}) async {
  final MainWindowPresentation? before =
      presentation ?? await port.captureMainWindowPresentation();
  final LookupCardSuspension? card = await port.suspendLookup();
  if (card == null) await port.dismissLookup();
  await port.bringMainWindowToFront();
  T? value;
  bool cardRestored = false;
  try {
    final BuildContext? context = navigatorContext();
    if (context != null && context.mounted) value = await body(context);
  } finally {
    if (card != null) {
      if (before != null) await port.settleMainWindowPresentation(before);
      cardRestored = await port.restoreLookup(
        card,
        returnForeground: before?.foregroundApp,
      );
    }
  }
  return MainWindowExcursionResult<T>(value, cardRestored: cardRestored);
}

/// 默认的借主窗原生面（测试替换）。
@visibleForTesting
MainWindowExcursionPort mainWindowExcursionPort =
    const MainWindowExcursionPort();
