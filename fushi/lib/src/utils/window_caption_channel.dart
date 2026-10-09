import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart'
    show NSVisualEffectViewMaterial, WindowManipulator;

/// 把标题栏配色推给 Windows 原生 runner（DWM caption / text color）。
///
/// 仅 Windows 生效，其它平台直接 no-op。显式设置 caption color 后，
/// Windows 在窗口失焦时也不会再把标题栏灰化，所以失焦态同样跟随主题色。
class WindowCaptionChannel {
  WindowCaptionChannel._();

  static const MethodChannel _channel = MethodChannel('app.fushi/window');

  static int? _lastCaption;
  static int? _lastText;

  /// macOS 启动时先隐藏 nib 自动显示的主窗口，首帧就绪后再显示。
  static Future<void> showStartupWindow() async {
    if (!Platform.isMacOS) return;
    await _channel.invokeMethod<void>('showStartupWindow');
  }

  /// Windows 启动时暂缓向 Flutter 子窗口交付中间尺寸。
  /// 调用方必须在 finally 中结束准备，最终尺寸仍经过原生 resize gate。
  static Future<void> beginStartupWindowPreparation() async {
    if (!Platform.isWindows) return;
    await _channel.invokeMethod<void>('beginStartupWindowPreparation');
  }

  static Future<void> endStartupWindowPreparation() async {
    if (!Platform.isWindows) return;
    await _channel.invokeMethod<void>('endStartupWindowPreparation');
  }

  /// 设置标题栏背景色与文字色。同值不重复下发，避免每次 rebuild 都刷 channel。
  static Future<void> setCaptionColors({
    required Color caption,
    required Color text,
  }) async {
    if (!Platform.isWindows) {
      return;
    }
    final int captionArgb = caption.toARGB32();
    final int textArgb = text.toARGB32();
    if (captionArgb == _lastCaption && textArgb == _lastText) {
      return;
    }
    _lastCaption = captionArgb;
    _lastText = textArgb;
    try {
      await _channel.invokeMethod<void>('setCaptionColors', <String, int>{
        'caption': captionArgb,
        'text': textArgb,
      });
    } on PlatformException {
      // 旧 Windows（< Win11 build 22000）不支持 DWMWA_CAPTION_COLOR，
      // 原生侧静默失败即可，标题栏维持系统默认绘制。
    }
  }

  /// 系统窗口材质（Windows 11 Mica / macOS NSVisualEffectView vibrancy）是否
  /// 已在窗口上生效。只有它为 true 时，首页外壳才把 scaffold 底色调成半透明让
  /// 系统材质透出来；Win10 / 旧 runner / 其它平台恒 false，外壳保持实心。
  static final ValueNotifier<bool> systemBackdropActive =
      ValueNotifier<bool>(false);

  static bool? _lastMica;
  static bool? _lastDark;

  /// 玻璃材质开启时请求系统窗口材质（[mica]），[dark] 决定材质的明暗。
  /// Windows 走 runner 的 DWM Mica；macOS 走 macos_window_utils 的
  /// NSVisualEffectView（`underWindowBackground` 是 Apple 给整窗背景的
  /// vibrancy 材质，关闭时回到不透明的 `windowBackground`）。
  /// 同值不重复下发；结果写进 [systemBackdropActive]。
  static Future<void> setSystemBackdrop({
    required bool mica,
    required bool dark,
  }) async {
    if (!Platform.isWindows && !Platform.isMacOS) {
      return;
    }
    if (mica == _lastMica && dark == _lastDark) {
      return;
    }
    _lastMica = mica;
    _lastDark = dark;
    if (Platform.isMacOS) {
      systemBackdropActive.value = await _setMacOSBackdrop(
        vibrancy: mica,
        dark: dark,
      );
      return;
    }
    bool active = false;
    try {
      active = await _channel.invokeMethod<bool>(
            'setSystemBackdrop',
            <String, bool>{'mica': mica, 'dark': dark},
          ) ??
          false;
    } on PlatformException {
      active = false;
    } on MissingPluginException {
      active = false;
    }
    systemBackdropActive.value = active;
  }

  static Future<bool> _setMacOSBackdrop({
    required bool vibrancy,
    required bool dark,
  }) async {
    try {
      // vibrancy 材质跟随窗口外观而不是 app 主题；app 钉了深 / 浅色时把窗口
      // 外观对齐，否则深色 app 底下会透出浅色材质。
      await WindowManipulator.overrideMacOSBrightness(dark: dark);
      await WindowManipulator.setMaterial(
        vibrancy
            ? NSVisualEffectViewMaterial.underWindowBackground
            : NSVisualEffectViewMaterial.windowBackground,
      );
      return vibrancy;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// TODO-615：主动熄灭 Windows 任务栏的「请求注意」高亮（FlashWindowEx +
  /// FLASHW_STOP）。
  ///
  /// `SetForegroundWindow`（`window_manager` 的 `show()`/`focus()`/
  /// `setAlwaysOnTop()` 在前台锁定下会退化触发）会把 Hibiki 的任务栏按钮设为闪烁
  /// 请求注意态，用户得点一下才能消掉（TODO-341 / TODO-615）。判前台守卫在前台
  /// 判据抖动时仍可能漏判而留下残留高亮，所以唤前台路径无论如何在尾部主动 clear
  /// 一次：FLASHW_STOP 对一个本就没有 flash 的窗口是 no-op，纯幂等清除。
  ///
  /// 仅 Windows 生效，其它平台直接 no-op。原生侧失败（旧主机/缺通道）静默吞掉，
  /// 不让一次窗口装饰调用拖垮查词生命周期。
  static Future<void> clearTaskbarFlash() async {
    if (!Platform.isWindows) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('clearTaskbarFlash');
    } on PlatformException {
      // 主机不实现该方法（旧 runner / 测试桩）时静默忽略。
    } on MissingPluginException {
      // 通道未注册（widget 测试 / 非 window runner 宿主）时静默忽略。
    }
  }

  /// BUG-1933：Windows 全屏切换（runner 自有实现，替代 window_manager /
  /// media_kit 的去边框实现）。
  ///
  /// window_manager 的 `setFullScreen` 和 media_kit 的 `EnterNativeFullscreen`
  /// 都靠剥掉 `WS_CAPTION|WS_THICKFRAME` 实现全屏——风格变更让 DWM 重建窗口
  /// visual，至少一帧合成里 Flutter 子窗图层缺席，露出主窗重定向表面
  /// （主题 surface 色；浅色主题下就是用户看到的「全屏/取消全屏闪一帧白色」）。
  /// runner 侧改为保留边框、把窗口放大到客户区恰好盖满显示器（边框悬屏外）+
  /// TOPMOST 盖任务栏，与最大化同路径，实测不露表面；过渡瞬间还会把当前画面
  /// 快照垫进表面兜底。仅 Windows 生效，其它平台 no-op（macOS 走
  /// WindowManipulator、Linux 仍走 window_manager）。
  static Future<void> setFullscreen(bool fullscreen) async {
    if (!Platform.isWindows) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('setFullscreen', <String, bool>{
        'fullscreen': fullscreen,
      });
    } on PlatformException {
      // 旧 runner 不实现该方法时静默忽略（调用方各有回退语义）。
    } on MissingPluginException {
      // 通道未注册（widget 测试 / 非 window runner 宿主）时静默忽略。
    }
  }

  /// BUG-2462：告诉 runner「引擎刚光栅化了一帧、视图物理尺寸是这个」。
  ///
  /// runner 的子窗 resize 闸门（`child_resize_gate.h`）以此确认它交付的尺寸已被
  /// 引擎 surface 采用；发送方是 `rasterized_frame_size_reporter.dart`，只在尺寸
  /// 变化时调。旧 runner / 非 window 宿主静默忽略。
  static Future<void> reportRasterizedFrameSize({
    required int width,
    required int height,
  }) async {
    if (!Platform.isWindows) {
      return;
    }
    try {
      await _channel.invokeMethod<void>(
        'reportRasterizedFrameSize',
        <String, int>{'width': width, 'height': height},
      );
    } on PlatformException {
      // 旧 runner 不实现该方法：闸门不存在，也就没有要确认的东西。
    } on MissingPluginException {
      // 通道未注册（widget 测试 / 非 window runner 宿主）时静默忽略。
    }
  }

  /// BUG-1933：当前是否处于 runner 自有实现的全屏态。非 Windows / 通道不可用
  /// 恒 false（window_manager 在 Windows 上不再进入全屏，其 isFullScreen 也
  /// 恒 false，两边不会都为 true）。
  static Future<bool> isFullscreen() async {
    if (!Platform.isWindows) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('isFullscreen') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 把窗口/任务栏图标设为 [path] 指向的本地图片（仅 Windows）。
  ///
  /// 原生侧用 WIC 解码图片成 big/small HICON 后 WM_SETICON。运行时只改当前
  /// 窗口图标，改不了 exe 文件本身（文件图标是嵌入资源）。其它平台直接返回
  /// false 不触达 channel。成功返回 true。
  static Future<bool> setWindowIcon(String path) async {
    if (!Platform.isWindows) {
      return false;
    }
    try {
      final bool? ok = await _channel.invokeMethod<bool>(
        'setWindowIcon',
        <String, String>{'path': path},
      );
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Windows 11 Snap Layouts：自绘最大化按钮的原生命中区。
  //
  // 系统标题栏隐藏后，系统看不到最大化按钮，悬停也就弹不出贴靠布局。runner
  // （caption_snap_button.h）在 Dart 上报的矩形里对 WM_NCHITTEST 答
  // HTMAXBUTTON；指针落在那块时 Flutter 收不到鼠标，悬停 / 按下 / 点击由原生
  // 经 `onCaptionMaxButton` 回传，按钮照常画状态层、由 Dart 执行最大化 / 还原。

  /// 原生侧报告的最大化按钮悬停态（指针在 HTMAXBUTTON 命中区里）。
  static final ValueNotifier<bool> captionMaxButtonHovered =
      ValueNotifier<bool>(false);

  /// 原生侧报告的最大化按钮按下态。
  static final ValueNotifier<bool> captionMaxButtonPressed =
      ValueNotifier<bool>(false);

  /// 原生命中区上完成的一次点击（按下与松开都在按钮上）。同一时刻只有一个
  /// 顶栏，后挂上的覆盖先前的。
  static VoidCallback? onCaptionMaxButtonClick;

  static bool _nativeHandlerInstalled = false;
  static Rect? _lastMaxButtonRect;

  static void _ensureNativeHandler() {
    if (_nativeHandlerInstalled) return;
    _nativeHandlerInstalled = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'onCaptionMaxButton') return null;
      switch (call.arguments) {
        case 'hover':
          captionMaxButtonHovered.value = true;
        case 'leave':
          captionMaxButtonHovered.value = false;
          captionMaxButtonPressed.value = false;
        case 'press':
          captionMaxButtonPressed.value = true;
        case 'release':
          captionMaxButtonPressed.value = false;
        case 'click':
          onCaptionMaxButtonClick?.call();
      }
      return null;
    });
  }

  /// 上报最大化按钮在 Flutter 视图里的矩形（**物理像素**）；null = 撤销命中区
  /// （按钮卸载 / 顶栏收起）。仅 Windows，同值不重复下发。
  static Future<void> setCaptionMaxButtonRect(Rect? physical) async {
    if (!Platform.isWindows) return;
    final Rect? rounded = physical == null || physical.isEmpty
        ? null
        : Rect.fromLTRB(
            physical.left.roundToDouble(),
            physical.top.roundToDouble(),
            physical.right.roundToDouble(),
            physical.bottom.roundToDouble(),
          );
    if (rounded == _lastMaxButtonRect) return;
    _lastMaxButtonRect = rounded;
    if (rounded == null) {
      captionMaxButtonHovered.value = false;
      captionMaxButtonPressed.value = false;
    }
    _ensureNativeHandler();
    try {
      await _channel.invokeMethod<void>(
        'setCaptionMaxButtonRect',
        <String, int>{
          'left': rounded?.left.toInt() ?? 0,
          'top': rounded?.top.toInt() ?? 0,
          'right': rounded?.right.toInt() ?? 0,
          'bottom': rounded?.bottom.toInt() ?? 0,
        },
      );
    } on PlatformException {
      // 旧 runner 没有这条方法：没有贴靠布局，按钮照常由 Flutter 处理。
    } on MissingPluginException {
      // 同上。
    }
  }
}
