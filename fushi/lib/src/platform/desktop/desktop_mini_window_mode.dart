import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'package:fushi/src/shortcuts/global_navigation.dart'
    show exitWindowFullscreenIfActive;
import 'package:fushi/src/startup/desktop_window_placement.dart';
import 'package:fushi/src/utils/components/fushi_desktop_title_bar.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi/src/utils/window_caption_channel.dart';

/// 小窗态允许的窗口最小尺寸（16:9）。
///
/// 常规下限是 [DesktopWindowPlacement.minimumSize]（360x480，手机级地板，保证每个
/// 页面都还能排版）。小窗里只剩一块视频画面，没有任何需要排版的 UI，所以地板必须
/// 单独下探——不下探的话 360x480 会把「右下角一小块画中画」直接顶成半屏高的竖窗。
/// 240x135 是 16:9 下仍能看清画面的经验下限。
const Size kMiniWindowMinimumSize = Size(240, 135);

/// 小窗宽度取工作区宽度的这个比例（1920 宽 → 422）。
const double _kMiniWindowWidthFraction = 0.22;

/// 小窗宽度的绝对上下限：低于 320 看不清字幕，高于 560 就不叫「小窗」了。
const double _kMiniWindowMinWidth = 320;
const double _kMiniWindowMaxWidth = 560;

/// 小窗离工作区右/下边缘的留白（逻辑像素）。留白不是审美，是给 Windows 任务栏的
/// 自动隐藏触发带和 macOS 的 Dock 让位——贴边会让鼠标划到边缘时反复弹出系统条。
const double _kMiniWindowMargin = 24;

/// 由工作区与宽高比算小窗外框。
///
/// 纯函数（不碰 platform channel），所以「小窗摆哪儿、多大」这条策略可以在单测里被
/// 完整钉住，而不必真起一个窗口。
///
/// 规则：宽 = clamp(工作区宽 * 0.22, 320, 560)，高 = 宽 / [aspectRatio]，摆在工作区
/// 右下角、离边 [_kMiniWindowMargin]，最后整体 clamp 进工作区。
/// [aspectRatio] <= 0 或非有限（播放器还没解出视频尺寸时会给 0）退回 16/9。
Rect resolveMiniWindowBounds({
  required Rect workArea,
  required double aspectRatio,
}) {
  final double ratio = sanitizeMiniWindowAspectRatio(aspectRatio);

  // 先按策略定宽，再按工作区收窄——收窄要在算高**之前**做，否则小工作区上会得到
  // 「宽被裁了、高还是按原宽算的」的畸形矩形，比例锁一上就跳一下。
  double width = _clampDouble(
    workArea.width * _kMiniWindowWidthFraction,
    _kMiniWindowMinWidth,
    _kMiniWindowMaxWidth,
  );
  width = math.min(width, workArea.width);
  double height = width / ratio;
  if (height > workArea.height) {
    // 极端宽高比（竖屏视频）或极矮工作区：改成高度受限，宽度反算，保持比例不变。
    height = workArea.height;
    width = math.min(height * ratio, workArea.width);
  }

  // 右下角锚定：留白只在有地方留的时候留（工作区被小窗塞满时 clamp 会吃掉它）。
  final double left = _clampDouble(
    workArea.right - _kMiniWindowMargin - width,
    workArea.left,
    workArea.right - width,
  );
  final double top = _clampDouble(
    workArea.bottom - _kMiniWindowMargin - height,
    workArea.top,
    workArea.bottom - height,
  );

  return Rect.fromLTWH(left, top, width, height);
}

/// 把外部给的宽高比收敛成一个可用值：非有限 / <= 0 一律退回 16/9。
double sanitizeMiniWindowAspectRatio(double aspectRatio) {
  if (!aspectRatio.isFinite || aspectRatio <= 0) return 16 / 9;
  return aspectRatio;
}

double _clampDouble(double value, double lowerLimit, double upperLimit) {
  // 工作区比小窗还小时 lower > upper，直接 clamp 会抛 ArgumentError——先排序。
  final double lower = math.min(lowerLimit, upperLimit);
  final double upper = math.max(lowerLimit, upperLimit);
  return value.clamp(lower, upper).toDouble();
}

/// 桌面「小窗模式」唯一所有者。
///
/// 小窗 = 把**主窗本身**缩成工作区右下角一块按视频比例的置顶浮窗（不是新开窗口：
/// Flutter 桌面多窗口在本仓不可用，且再开一个引擎意味着第二个播放器实例）。因此
/// 它必须一次性拥有五样彼此耦合的窗口状态，任何一样各自为政都会留下残局：
///
///   · 窗口外框与最大化状态（进入前的要记住，退出要原样还回去）；
///   · 几何持久化闸门（小窗几何**不得**写进主窗记忆，见
///     [DesktopWindowPlacement.setGeometryMemorySuspended]）；
///   · 最小尺寸地板（常规 360x480 会把小窗顶大，见 [kMiniWindowMinimumSize]）；
///   · 置顶（小窗的全部意义就是压在别的窗口上面）；
///   · 自绘标题栏（32px 顶栏占掉小窗 1/7 的高度，必须让位）。
///
/// 所有权按 [Object] 登记（与 [FushiDesktopTitleBar.setContentFullscreen] 同构）：
/// 视频页销毁时用自己的 owner 调 [exit]，一个已经被别人接管的小窗不会被它误还原。
class DesktopMiniWindowMode {
  DesktopMiniWindowMode._();

  /// 让给自绘顶栏看的所有者标识。与 [_owner]（页面侧的所有者）不是一回事：顶栏只
  /// 认「有没有人要求隐藏」，这里用一个进程唯一的常量对象登记即可。
  static final Object _titleBarOwner = Object();

  static final ValueNotifier<bool> _active = ValueNotifier<bool>(false);

  /// 当前小窗的登记所有者（页面 State）。非空即表示 [_active] 为真。
  static Object? _owner;

  /// 进入前的普通窗口外框。最大化态下为**进入前的默认还原框**（最大化时
  /// `getBounds` 返回的是整个工作区，存它等于永久丢掉用户的窗口尺寸，与
  /// [DesktopWindowPlacement] 里那条纪律同源）。
  static Rect? _restoreBounds;

  /// 进入前是不是最大化。退出时先落 [_restoreBounds] 再重新最大化，这样用户按
  /// 「向下还原」拿回的仍是他自己的窗口尺寸。
  static bool _restoreMaximized = false;

  /// 进入前生效的最小尺寸（按当时工作区算的有效值，小屏上会低于 360x480）。
  static Size? _restoreMinimumSize;

  /// 进入前是不是已经置顶。用户可能自己开了「窗口置顶」，退出小窗不该把它关掉。
  static bool _restoreAlwaysOnTop = false;

  /// 当前已下发给窗口的宽高比，用于 [updateAspectRatio] 去重。
  static double _aspectRatio = 16 / 9;

  /// 测试缝：覆盖「是否桌面平台」判定。null = 用真实 [isDesktopPlatform]。
  /// （与 `manga_import_dialog.dart` 的同名缝同构：单测宿主本身就是 Windows，
  /// 不给缝就没法验「非桌面平台下整条路径是 no-op」。）
  @visibleForTesting
  static bool? debugDesktopOverride;

  static bool get _isDesktop => debugDesktopOverride ?? isDesktopPlatform;

  /// 当前是否处于小窗态。页面/标题栏/几何持久化都读它。
  static ValueListenable<bool> get activeListenable => _active;

  static bool get isActive => _active.value;

  /// 进入小窗：记住当前外框 → 暂停几何记忆 → 下探最小尺寸 → 摆到工作区右下角
  /// → 置顶 + clearTaskbarFlash → 隐藏自绘顶栏 → 锁宽高比。
  ///
  /// [aspectRatio] 为视频宽高比（<= 0 时退回 16/9）。幂等：同一 [owner] 重复调用只
  /// 当作「比例可能变了」，别的 owner 在小窗态下调用直接 no-op（不抢占）。
  ///
  /// 中途任一步失败都不会把状态机留在半途：真正决定「这是不是一个小窗」的是摆位
  /// （[WindowManager.setBounds]），它失败就把已经做过的几何改动全部回滚、闸门抬起、
  /// 状态保持 false；装饰性步骤（置顶 / 比例锁）失败只记日志继续。
  /// 进入 / 退出 / 改比例三条链各有七八次 platform 往返，`_active` 到最后才置位。
  /// 不串行的话，按住快捷键（OS key-repeat 连发）或按钮双击会让第二次 `enter` 在
  /// 第一次的 `setBounds` 之后 `_readBounds()`——读到的已是小窗框，随即**覆盖
  /// `_restoreBounds`**：退出小窗后主窗被还原成小窗尺寸，闸门抬起时那个尺寸还写进
  /// 主窗记忆，正是闸门要防的事。一条链没跑完，后来的一律排队。
  static Future<void> _transition = Future<void>.value();

  static Future<T> _serialize<T>(Future<T> Function() body) {
    final Future<T> run = _transition.then((_) => body());
    _transition = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// 接管所有权（BUG-2043 同构）：本地换集走 `pushReplacement`，旧页 dispose 晚于新页
  /// initState——新页在 initState 认领，旧页随后的 `exit(owner: 旧页)` 因 owner 不符
  /// 成为 no-op，小窗跨集保持；否则每换一集（含自动连播）小窗都弹回主窗。
  /// 未在小窗中返回 false。
  static bool claim({required Object owner}) {
    if (!_isDesktop || !_active.value) return false;
    _owner = owner;
    return true;
  }

  static Future<void> enter({
    required Object owner,
    required double aspectRatio,
  }) =>
      _serialize(() => _enterUnlocked(owner: owner, aspectRatio: aspectRatio));

  static Future<void> _enterUnlocked({
    required Object owner,
    required double aspectRatio,
  }) async {
    if (!_isDesktop) return;

    final double ratio = sanitizeMiniWindowAspectRatio(aspectRatio);
    if (_active.value) {
      if (identical(_owner, owner)) {
        // 已在串行链内：调 unlocked 版本。走公开的 updateAspectRatio 会排到自己
        // 后面等自己，直接死锁（并发 enter 的第二条链就是这么进来的）。
        await _updateAspectRatioUnlocked(ratio);
      }
      return;
    }

    // 全屏与小窗互斥，且全屏必须**先**退：Windows 全屏是「保边框的巨窗 + TOPMOST」
    // （BUG-1933，runner 自有实现），在它之上直接 setBounds 会得到一个仍带 TOPMOST
    // 巨窗语义的半吊子窗口。这里走 global_navigation 的单一原语，顺带把自绘顶栏的
    // 全屏归属同步回去。
    await _step('exitFullscreen', () async {
      await exitWindowFullscreenIfActive();
    });

    final bool maximized = await _readMaximized();
    final Rect? currentBounds = await _readBounds();
    // 工作区按「窗口现在在哪块屏」选：双屏用户把窗口拖到副屏再开小窗，小窗要出现在
    // 副屏的右下角而不是主屏。
    final Rect workArea = await _resolveWorkArea(currentBounds);
    final Rect target = resolveMiniWindowBounds(
      workArea: workArea,
      aspectRatio: ratio,
    );

    // 闸门必须在任何几何变更**之前**关上：unmaximize / setBounds 都会派发窗口事件，
    // main.dart 的 onWindowResized/onWindowUnmaximize 监听器会把小窗几何写进主窗记忆。
    DesktopWindowPlacement.setGeometryMemorySuspended(true);

    if (maximized) {
      await _step('unmaximize', () => windowManager.unmaximize());
    }
    // 先松地板再摆位：反过来的话 setBounds 会被 360x480 的最小尺寸顶回去。
    final bool loweredMinimum = await _step(
      'lowerMinimumSize',
      () => windowManager.setMinimumSize(kMiniWindowMinimumSize),
    );
    final bool placed = await _step(
      'setBounds',
      () => windowManager.setBounds(target),
    );

    if (!placed) {
      // 摆位失败 = 小窗没成立。把已经改过的两样几何状态还回去，闸门抬起，状态位
      // 保持 false——绝不留下「地板被松开、窗口还是原样、没人记得还原」的残局。
      if (loweredMinimum) {
        await _step(
          'rollback.minimumSize',
          () => windowManager.setMinimumSize(
            DesktopWindowPlacement.minimumSizeForWorkArea(workArea),
          ),
        );
      }
      if (maximized) {
        await _step('rollback.maximize', () => windowManager.maximize());
      }
      DesktopWindowPlacement.setGeometryMemorySuspended(false);
      return;
    }

    _restoreMaximized = maximized;
    // 最大化态没有可用的普通外框，读不到也可能为 null（窗口尚未就绪）——两种情况都
    // 退回 placement 的首启默认框，保证退出小窗时**总有**一个像样的外框可落，不会
    // 把用户留在一块 422x237 的小方块里。
    _restoreBounds = (!maximized && currentBounds != null)
        ? currentBounds
        : DesktopWindowPlacement.resolveInitialBounds(workArea: workArea);
    _restoreMinimumSize = DesktopWindowPlacement.minimumSizeForWorkArea(
      workArea,
    );
    _restoreAlwaysOnTop = await _readAlwaysOnTop();

    await _step('alwaysOnTop', () => windowManager.setAlwaysOnTop(true));
    // setAlwaysOnTop 在前台锁定下会退化触发 SetForegroundWindow，把任务栏按钮设成
    // 「请求注意」的闪烁态（见 WindowCaptionChannel.clearTaskbarFlash 的文档）。
    // FLASHW_STOP 对没在闪的窗口是 no-op，无条件清一次即可。
    await _step(
      'clearTaskbarFlash',
      () => WindowCaptionChannel.clearTaskbarFlash(),
    );

    // 32px 自绘顶栏在 240 高的小窗里就是 1/7 的画面，必须让位。按 owner 登记，
    // 不会和「视频全屏」这个另一个隐藏顶栏的所有者互相顶掉。
    FushiDesktopTitleBar.setContentFullscreen(
      owner: _titleBarOwner,
      enabled: true,
    );

    await _step('setAspectRatio', () => windowManager.setAspectRatio(ratio));
    _aspectRatio = ratio;

    _owner = owner;
    _active.value = true;
  }

  /// 退出小窗：按进入的逆序还原（含最小尺寸、外框、置顶、顶栏、宽高比锁）。
  ///
  /// [restoreAspectRatioLock] 为 false 时退出后清掉宽高比锁；true 时保留（用户自己
  /// 开了「窗口跟随视频比例」这项偏好，小窗只是顺带用了同一把锁，不能替他关掉）。
  ///
  /// 幂等；[owner] 不是当前持有者时 no-op 并返回 false。
  static Future<bool> exit({
    required Object owner,
    required bool restoreAspectRatioLock,
  }) => _serialize(
    () => _exitUnlocked(
      owner: owner,
      restoreAspectRatioLock: restoreAspectRatioLock,
    ),
  );

  static Future<bool> _exitUnlocked({
    required Object owner,
    required bool restoreAspectRatioLock,
  }) async {
    if (!_isDesktop) return false;
    if (!_active.value) return false;
    if (!identical(_owner, owner)) return false;

    // 先翻状态位再动窗口：还原是七八次 platform 往返，中途抛了也不能把状态机留在
    // 「标志说还在小窗、窗口已经不是小窗」的半途——那会让下一次 enter 直接 no-op。
    _active.value = false;
    _owner = null;

    final Rect? bounds = _restoreBounds;
    final Size minimumSize =
        _restoreMinimumSize ?? DesktopWindowPlacement.minimumSize;
    final bool maximized = _restoreMaximized;
    final bool keepAlwaysOnTop = _restoreAlwaysOnTop;
    _restoreBounds = null;
    _restoreMinimumSize = null;
    _restoreMaximized = false;
    _restoreAlwaysOnTop = false;

    // 逆序还原可视层：比例锁 → 顶栏 → 置顶。
    if (!restoreAspectRatioLock) {
      await _step('clearAspectRatio', () => windowManager.setAspectRatio(0));
    }
    FushiDesktopTitleBar.setContentFullscreen(
      owner: _titleBarOwner,
      enabled: false,
    );
    if (!keepAlwaysOnTop) {
      await _step(
        'clearAlwaysOnTop',
        () => windowManager.setAlwaysOnTop(false),
      );
    }

    // 几何这一对**不按**严格逆序：先把地板抬回常规值、再落外框。反过来（先落大框、
    // 再抬地板）中间会有一帧窗口比地板小，某些 WM 会自行纠正成地板尺寸并派发一次
    // resize，多出一个谁都不想要的中间态。
    await _step(
      'restoreMinimumSize',
      () => windowManager.setMinimumSize(minimumSize),
    );
    if (bounds != null) {
      await _step('restoreBounds', () => windowManager.setBounds(bounds));
    }
    if (maximized) {
      await _step('restoreMaximized', () => windowManager.maximize());
    }

    DesktopWindowPlacement.setGeometryMemorySuspended(false);
    // 闸门期间窗口事件一个都没写盘，所以此刻盘上还是进入小窗**之前**的几何——正好
    // 就是我们刚还原成的那个，本不需要补写。唯一的例外是上面那条「读不到外框就用
    // 默认框」的兜底路径，它让窗口落在了一个盘上没有的位置；补一次即时保存把两边
    // 对齐（值没变时 placement 内部的缓存会把它短路成 no-op，不多一次写盘）。
    await DesktopWindowPlacement.saveCurrentBoundsNow();
    return true;
  }

  /// 视频宽高比在小窗态变化时更新窗口比例与尺寸（换集/换源）。非小窗态 no-op。
  ///
  /// 必须连**外框**一起重算：window_manager 的 `setAspectRatio` 在 Windows 上只在
  /// 用户拖动窗口边框时（WM_SIZING）约束比例，不会矫正当前尺寸（同一条平台限制在
  /// `video_fushi/layout.part.dart` 里也记过）。只下发比例的话，从 16:9 换到 4:3 的
  /// 下一集会一直挂在上一集的框里两侧留黑。
  static Future<void> updateAspectRatio(double aspectRatio) =>
      _serialize(() => _updateAspectRatioUnlocked(aspectRatio));

  static Future<void> _updateAspectRatioUnlocked(double aspectRatio) async {
    if (!_isDesktop || !_active.value) return;

    final double ratio = sanitizeMiniWindowAspectRatio(aspectRatio);
    if ((ratio - _aspectRatio).abs() < 0.0001) return;
    _aspectRatio = ratio;

    await _step('updateAspectRatio', () => windowManager.setAspectRatio(ratio));

    final Rect? bounds = await _readBounds();
    final Rect workArea = await _resolveWorkArea(bounds);
    final Rect target = resolveMiniWindowBounds(
      workArea: workArea,
      aspectRatio: ratio,
    );
    await _step('updateBounds', () => windowManager.setBounds(target));
  }

  /// 清掉全部进程内状态。生产不用；测试之间必须复位，否则上一个用例留下的所有者/
  /// 还原框会让下一个用例的 [enter] 直接 no-op。
  @visibleForTesting
  static void resetForTesting() {
    _active.value = false;
    _owner = null;
    _restoreBounds = null;
    _restoreMinimumSize = null;
    _restoreMaximized = false;
    _restoreAlwaysOnTop = false;
    _aspectRatio = 16 / 9;
    _transition = Future<void>.value();
    debugDesktopOverride = null;
    FushiDesktopTitleBar.setContentFullscreen(
      owner: _titleBarOwner,
      enabled: false,
    );
    DesktopWindowPlacement.setGeometryMemorySuspended(false);
  }

  /// 每个窗口调用都必须经过这里：窗口在任何一步都可能不可用（进程正在退出、
  /// 通道未注册的 widget 测试宿主、旧 runner），一次装饰性调用失败不得掀翻整条
  /// 进入/退出路径。返回「这一步成没成」，让调用方自己决定是回滚还是继续。
  static Future<bool> _step(String step, Future<void> Function() body) async {
    try {
      await body();
      return true;
    } catch (e, stack) {
      ErrorLogService.instance.log('DesktopMiniWindow.$step', e, stack);
      return false;
    }
  }

  static Future<Rect?> _readBounds() async {
    try {
      final Rect bounds = await windowManager.getBounds();
      if (!bounds.width.isFinite || !bounds.height.isFinite) return null;
      if (bounds.width <= 0 || bounds.height <= 0) return null;
      return bounds;
    } catch (e, stack) {
      ErrorLogService.instance.log('DesktopMiniWindow.readBounds', e, stack);
      return null;
    }
  }

  static Future<bool> _readMaximized() async {
    try {
      return await windowManager.isMaximized();
    } catch (e, stack) {
      ErrorLogService.instance.log('DesktopMiniWindow.readMaximized', e, stack);
      return false;
    }
  }

  static Future<bool> _readAlwaysOnTop() async {
    try {
      return await windowManager.isAlwaysOnTop();
    } catch (e, stack) {
      ErrorLogService.instance.log(
        'DesktopMiniWindow.readAlwaysOnTop',
        e,
        stack,
      );
      return false;
    }
  }

  /// 取「窗口当前所在那块屏」的工作区。显示器查询失败时退回窗口自身外框，再不行
  /// 退回 placement 用的同一个 1280x720 兜底——两级兜底都只影响小窗摆在哪儿，不会
  /// 让进入小窗这件事失败。
  static Future<Rect> _resolveWorkArea(Rect? anchor) async {
    try {
      final List<Display> displays = await screenRetriever.getAllDisplays();
      final List<Rect> workAreas = displays
          .map(_workAreaFromDisplay)
          .whereType<Rect>()
          .toList();
      if (workAreas.isNotEmpty) {
        return DesktopWindowPlacement.selectWorkArea(
          workAreas: workAreas,
          currentBounds: anchor,
        );
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('DesktopMiniWindow.workArea', e, stack);
    }
    return anchor ?? const Rect.fromLTWH(0, 0, 1280, 720);
  }

  static Rect? _workAreaFromDisplay(Display display) {
    final Offset position = display.visiblePosition ?? Offset.zero;
    final Size size = display.visibleSize ?? display.size;
    if (size.width <= 0 || size.height <= 0) return null;
    return Rect.fromLTWH(position.dx, position.dy, size.width, size.height);
  }
}
