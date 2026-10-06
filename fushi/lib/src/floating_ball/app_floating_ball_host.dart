/// 全局悬浮球宿主：挂在 `main.dart` 根 builder 的 Stack 上（导航之上、查词弹窗
/// 宿主之下），任何页面都在。设计见 `docs/specs/2026-09-28-floating-ball.md`。
///
/// 三件事：
///  1. 应用内球（设置 → 悬浮球 → 应用内，默认开）：复用 [ReaderFloatingBall]（同一套
///     停靠 / 拖动 / 展开几何），活动范围是整窗扣掉系统 inset；按钮 = 用户为当前
///     路由所属场景勾选的按钮（页面此刻提供不了的专属按钮跳过）。
///  2. Android 应用外（设置 → 悬浮球 → 应用外，默认关）：按偏好起停原生
///     `FloatingBallService`，并把前后台状态告诉它（前台时原生球隐藏，应用内球
///     开着就由本球接管）。
///  3. 外部查词入口（iOS App Intent / `fushi://lookup` 深链）：排队到 app 初始化
///     完成，再交给应用内查词弹窗；Android 系统球「查词」（打开查词页）、「拍照
///     查词」（开相机）与「立即同步」同样排队。
///  4. 系统球上点「关闭」= 用户关掉了应用外悬浮球：同步关掉设置里的「应用外」开关，
///     两边始终一致（否则下次回到 Fushi 又会按开关把球拉起来）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/floating_ball/camera_ocr_photo.dart';
import 'package:fushi/src/floating_ball/desktop_system_ball_assets.dart';
import 'package:fushi/src/floating_ball/floating_ball_channel.dart';
import 'package:fushi/src/floating_ball/floating_ball_config.dart';
import 'package:fushi/src/floating_ball/floating_ball_scene.dart';
import 'package:fushi/src/floating_ball/screen_ocr_picker.dart';
import 'package:fushi/src/lookup/global_lookup_channel.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_lookup_host.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi/src/ocr/system_ocr_setup_dialog.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';
import 'package:fushi/src/reader/reader_floating_ball.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/sync/manual_sync_ui.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 截屏识字送给系统 OCR 的语言。Fushi 的查词对象是日语；ML Kit / Vision 的日文
/// 识别器同时认拉丁字母与汉字。
const String kFloatingBallOcrLanguage = 'ja';

/// 外部查词请求（App Intent / 深链）。app 未初始化时先存着，宿主就绪后取走。
final ValueNotifier<String?> pendingExternalLookup = ValueNotifier<String?>(
  null,
);

/// Android 系统球「查词」：Fushi 已被拉到前台，等 app 就绪后打开查词页。
final ValueNotifier<bool> pendingOpenLookupPage = ValueNotifier<bool>(false);

/// Android 系统球「拍照查词」：Fushi 已被拉到前台，等 app 就绪后开相机。
final ValueNotifier<bool> pendingCameraOcr = ValueNotifier<bool>(false);

/// Android 系统球「立即同步」：Fushi 已被拉到前台，等 app 就绪后跑一轮同步。
final ValueNotifier<bool> pendingSync = ValueNotifier<bool>(false);

/// 截屏 / 拍照识字报「系统 OCR 模型未就绪」：等 app 就绪后弹出模型配置（BUG-2906）。
/// Android 截屏 OCR 在原生服务里识别，报错时原生把 Fushi 拉到前台再经通道置位。
final ValueNotifier<bool> pendingSystemOcrSetup = ValueNotifier<bool>(false);

/// 从应用外交来一个要查的词（iOS App Intent、`fushi://lookup?word=`）。
void deliverExternalLookup(String word) {
  final String trimmed = word.trim();
  if (trimmed.isEmpty) return;
  pendingExternalLookup.value = trimmed;
}

/// 应用内球的活动范围：整窗扣掉系统 inset。
///
/// 左右两侧只扣真正挡住画面的那一侧：Android（`shortEdges`）本就只在刘海侧上报
/// inset；iOS 横屏却左右**对称**上报外壳深度（实测 iPhone 17 Pro 各 61.6），照扣
/// 会让球在没有灵动岛的那一侧也停在离屏幕边一大截的黑边中间、贴不到边。
/// [sensorHousingEdge] 是外壳所在的边（[FloatingBallChannel.sensorHousingEdge]）：
/// 在左 / 右时，对侧的水平 inset 归零；未知时保守地两侧都扣。
///
/// 旋转那一帧新 inset 可能先于新外壳边到达：竖 ↔ 横时旧值是 up / down（两侧照扣）
/// 或 left / right 遇上竖屏（左右 inset 本就为 0），都无害；只有横屏左 ↔ 右翻转
/// 会错侧，那条靠原生在界面方向变化时推送新值（见宿主的 `_sensorHousingEdge`）。
Rect appFloatingBallViewport(
  Size window,
  EdgeInsets viewPadding, {
  AxisDirection? sensorHousingEdge,
}) {
  final double left = sensorHousingEdge == AxisDirection.right
      ? 0
      : viewPadding.left;
  final double right = sensorHousingEdge == AxisDirection.left
      ? 0
      : viewPadding.right;
  return Rect.fromLTRB(
    left,
    viewPadding.top,
    window.width - right,
    window.height - viewPadding.bottom,
  );
}

/// 原生系统球的按钮文案（原生侧不维护多语言）。
Map<String, String> floatingBallNativeLabels() => <String, String>{
  FloatingBallGlobalAction.lookup.storageValue: t.floating_ball_action_lookup,
  FloatingBallGlobalAction.popupLookup.storageValue:
      t.floating_ball_action_popup_lookup,
  FloatingBallGlobalAction.clipboard.storageValue:
      t.floating_ball_action_clipboard,
  FloatingBallGlobalAction.screenOcr.storageValue:
      t.floating_ball_action_screen_ocr,
  FloatingBallGlobalAction.cameraOcr.storageValue:
      t.floating_ball_action_camera_ocr,
  FloatingBallGlobalAction.sync.storageValue: t.sync_now,
  'open_app': t.floating_ball_action_open_app,
  'close': t.floating_ball_action_close,
  'ball': t.reader_floating_ball,
  'notification': t.floating_ball_notification,
  'ocr_notification': t.floating_ball_ocr_notification,
  'ocr_hint': t.floating_ball_ocr_pick_hint,
  'ocr_no_text': t.floating_ball_ocr_empty,
  'ocr_model_unavailable': t.floating_ball_ocr_model_unavailable,
  'ocr_failed': t.floating_ball_ocr_failed,
};

/// 全局按钮的图标：应用内球与原生系统球共用这一张表（FushiIcons 语义图标；
/// Android 原生按码位从 app 自带的 FushiSymbols 字体取字形，桌面由 Dart 画成
/// PNG），两边画出来是同一颗。
IconData floatingBallGlobalActionIcon(FloatingBallGlobalAction action) =>
    switch (action) {
      FloatingBallGlobalAction.lookup => FushiIcons.search,
      FloatingBallGlobalAction.popupLookup => FushiIcons.pictureInPicture,
      FloatingBallGlobalAction.clipboard => FushiIcons.paste,
      FloatingBallGlobalAction.screenOcr => FushiIcons.ocr,
      FloatingBallGlobalAction.cameraOcr => FushiIcons.camera,
      FloatingBallGlobalAction.sync => FushiIcons.sync,
    };

/// 「关闭悬浮球」按钮的图标（应用内 / 应用外同一颗）。
const IconData kFloatingBallCloseIcon = FushiIcons.close;

/// 原生系统球「打开 Fushi」按钮的图标。
const IconData kFloatingBallOpenAppIcon = FushiIcons.openInNew;

/// 原生系统球每颗按钮的图标（与应用内球同一颗 IconData）。
Map<String, IconData> floatingBallNativeIconData() => <String, IconData>{
  for (final FloatingBallGlobalAction action in FloatingBallGlobalAction.values)
    action.storageValue: floatingBallGlobalActionIcon(action),
  'open_app': kFloatingBallOpenAppIcon,
  'close': kFloatingBallCloseIcon,
};

/// 原生系统球的按钮图标（FushiSymbols 码位，Android 用）。常量 IconData 在
/// Dart 里被引用，图标字体按码位裁剪时这些字形才会留下，原生侧才取得到。
Map<String, int> floatingBallNativeIcons() => <String, int>{
  for (final MapEntry<String, IconData> e
      in floatingBallNativeIconData().entries)
    e.key: e.value.codePoint,
};

/// 原生系统球的配色：取当前主题，与应用内球（M3E FAB menu）同源——
/// - `ballContainer` / `onBallContainer`：球本体 FAB（primaryContainer）；
/// - `buttonContainer` / `onButtonContainer`：tonal 小圆钮（secondaryContainer）
///   与图标色；
/// - `outline`：描边，只有墨水屏不透明（此时上面两组都降级成 surface /
///   onSurface，「描边无填色」），其余为全透明（原生不画环）；
/// - `ballOpen` / `onBallOpen`：展开态球变成的关闭钮（primary 底 + onPrimary ×，
///   墨水屏 surface / onSurface）；
/// - `surface` / `onSurface` / `primary`：截屏识字冻结层的行框与提示条沿用。
///
/// 原生侧持久化这张表（Android 存 SharedPreferences），主题一变 Dart 重新下发
/// （配色进起球签名）。
Map<String, int> floatingBallNativeColors(
  ColorScheme colors, {
  bool eink = false,
}) => <String, int>{
  'surface': colors.surface.toARGB32(),
  'onSurface': colors.onSurface.toARGB32(),
  'primary': colors.primary.toARGB32(),
  'ballContainer': (eink ? colors.surface : colors.primaryContainer).toARGB32(),
  'onBallContainer': (eink ? colors.onSurface : colors.onPrimaryContainer)
      .toARGB32(),
  'buttonContainer': (eink ? colors.surface : colors.secondaryContainer)
      .toARGB32(),
  'onButtonContainer': (eink ? colors.onSurface : colors.onSecondaryContainer)
      .toARGB32(),
  'outline': eink ? colors.onSurface.toARGB32() : 0x00000000,
  'ballOpen': (eink ? colors.surface : colors.primary).toARGB32(),
  'onBallOpen': (eink ? colors.onSurface : colors.onPrimary).toARGB32(),
};

/// 展开态球（M3E FAB menu 的关闭钮）上那颗 × 的图标 PNG 键：桌面原生球在
/// iconImages 里按这个键取，着 `onBallOpen` 色（按钮图标是 `onButtonContainer`）。
const String kFloatingBallNativeBallCloseKey = 'ball_close';

/// 本平台有没有这个全局按钮的能力。
bool floatingBallGlobalActionAvailable(FloatingBallGlobalAction action) =>
    action.availableOn(isAndroid: Platform.isAndroid, isIOS: Platform.isIOS);

/// 本平台有没有应用外悬浮球。
bool get floatingBallSystemBallSupported =>
    FloatingBallScope.systemBallSupported(
      isAndroid: Platform.isAndroid,
      isDesktop: isDesktopSystemBallPlatform,
    );

/// 应用外球上有没有这颗全局按钮（桌面另有一套、并受查词模块开关约束，见
/// [FloatingBallGlobalAction.availableIn]）。
bool floatingBallSystemActionAvailable(
  FloatingBallGlobalAction action, {
  required bool lookupModuleEnabled,
}) => action.availableIn(
  FloatingBallScope.system,
  isAndroid: Platform.isAndroid,
  isIOS: Platform.isIOS,
  isDesktop: isDesktopSystemBallPlatform,
  lookupModuleEnabled: lookupModuleEnabled,
);

/// 桌面系统球动作落到的执行面：全局查词覆盖窗与主窗。宿主只决定「哪颗按钮走
/// 哪条路、参数按什么单位交出去」，测试替换本类来钉住这层分发。
class DesktopSystemBallActionTarget {
  const DesktopSystemBallActionTarget();

  /// 全局查词覆盖窗此刻能不能接查词（查词模块开着且启动过）。
  bool get overlayLookupAvailable =>
      GlobalLookupController.instance.isAvailable;

  /// 查前台程序当前选中的文字（与全局查词热键同一条路径）。
  Future<void> lookupSelection() => GlobalLookupController.instance
      .triggerSelectionLookup(source: 'floatingBall');

  /// 在覆盖窗里查 [text]；参数与 [GlobalLookupController.lookupText] 同义。
  Future<bool> lookupText(
    String text, {
    String sentence = '',
    Rect? anchorScreenRect,
    GlobalLookupPhysicalPlacement? physicalPlacement,
  }) => GlobalLookupController.instance.lookupText(
    text,
    sentence: sentence,
    anchorScreenRect: anchorScreenRect,
    physicalPlacement: physicalPlacement,
  );

  /// 收起覆盖窗里开着的查词卡（截屏前收起，免得它被截进图里；退出冻结层时收起）。
  Future<void> dismissLookup() => GlobalLookupChannel.hide();

  /// 系统 OCR 识别一张截图（macOS Vision / Windows.Media.Ocr）。
  Future<SystemOcrPageResult> recognize(Uint8List png) =>
      const MethodChannelSystemOcr().recognize(
        png,
        language: kFloatingBallOcrLanguage,
      );

  Future<void> bringMainWindowToFront() =>
      DesktopLookupService.instance.bringMainWindowToFront();
}

/// 最近一次起球闭包（[_AppFloatingBallHostState._syncSystemBall]）的 Future。
/// 测试 await 它来确认闭包真的跑完了再断言，而不是等一段时间碰运气。
@visibleForTesting
Future<void>? debugLatestSystemBallSync;

/// 最近一次「按新的自动恢复选项落定已关闭的球」（关掉对应显示开关）的落盘
/// Future。测试 await 它确认写库真的完成，再断言 / 拆库。
@visibleForTesting
Future<void>? debugLatestClosedBallSettle;

/// 桌面截屏识字此刻开着的冻结层（宿主只有一个，见 [_AppFloatingBallHostState]）。
_DesktopScreenOcrSession? _activeDesktopScreenOcr;

/// 集成测试用：此刻冻结层截的显示器（屏幕物理像素）与识别出的行（截图像素）；
/// 没开冻结层或还在识别时为 null。真机测试据此算出点哪个字。
@visibleForTesting
({Rect screen, List<SystemOcrTextLine> lines})? get debugDesktopScreenOcrState {
  final _DesktopScreenOcrSession? session = _activeDesktopScreenOcr;
  final List<SystemOcrTextLine>? lines = session?.lines;
  if (session == null || lines == null) return null;
  return (screen: session.screen, lines: lines);
}

/// 桌面系统球动作的执行面（测试替换）。
@visibleForTesting
DesktopSystemBallActionTarget desktopSystemBallActionTarget =
    const DesktopSystemBallActionTarget();

class AppFloatingBallHost extends ConsumerStatefulWidget {
  const AppFloatingBallHost({super.key});

  @override
  ConsumerState<AppFloatingBallHost> createState() =>
      _AppFloatingBallHostState();
}

class _AppFloatingBallHostState extends ConsumerState<AppFloatingBallHost>
    with WidgetsBindingObserver {
  final FloatingBallSceneRegistry _registry =
      FloatingBallSceneRegistry.instance;

  PreferencesRepository? _prefs;

  /// 上一次下发给原生系统球的配置（模式 + 按钮 + 语言）；相同就不重复下发。
  String? _systemSignature;

  /// 起停决策的代数：每次决定起球 / 停球都 +1。起球闭包每次 await 回来先核对
  /// 自己仍是最新一代，否则放弃——用户在它等图标渲染时关了开关、或主题 / 语言
  /// 连着变两次，旧闭包都不能再把球拉起来 / 用旧配置盖掉新配置。
  int _systemGeneration = 0;

  /// 自上次停球以来是否已经要求过起球（含还在路上的起球闭包）。停球要看它而
  /// 不是看 [_systemSignature]：签名要等原生回话才落，在那之前关开关也得停。
  bool _systemRequested = false;

  /// 截屏期间把球藏起来，别把自己拍进去。
  bool _capturing = false;

  /// 桌面截屏识字此刻开着的冻结层（null = 没开）。
  _DesktopScreenOcrSession? get _desktopOcr => _activeDesktopScreenOcr;
  set _desktopOcr(_DesktopScreenOcrSession? session) =>
      _activeDesktopScreenOcr = session;

  bool _foreground = true;

  /// 用户在当前页面点了「关闭悬浮球」；[_dismissedOwner] 是那一页的身份
  /// （[FloatingBallSceneSnapshot.owner]），页面一换就自动恢复。
  bool _dismissed = false;
  Object? _dismissedOwner;

  /// 用户在应用外球上点了关闭、而「自动恢复」含应用外
  /// （[FloatingBallAutoRestore.restoresSystem]）：开关不动，球停到下次回到
  /// Fushi（[didChangeAppLifecycleState] 收到 resumed）再拉起。
  bool _systemBallClosed = false;

  /// 当前主题给原生系统球的配色（build 里按 Theme 刷新；变了就重新下发）。
  Map<String, int> _systemBallColors = const <String, int>{};
  bool _systemBallAnimate = true;

  /// 刘海 / 灵动岛所在的边（只有 iOS 会有值），见 [appFloatingBallViewport]。
  ///
  /// 主路径是原生推送（`sensorHousingEdgeChanged`，iOS 界面方向一变就推）：
  /// 横屏左 ↔ 右翻转 180° 时窗口尺寸与左右对称的安全区都不变，[didChangeMetrics]
  /// 不一定触发，只靠它重查会让球停在灵动岛底下（BUG-2911）。查询只做首次取值
  /// 与尺寸变化时的兜底；两条路的回话按原生发出顺序到达、都是当时的真值，谁后到
  /// 谁准。
  AxisDirection? _sensorHousingEdge;

  void _onSensorHousingEdge(AxisDirection? edge) {
    if (!mounted || edge == _sensorHousingEdge) return;
    setState(() => _sensorHousingEdge = edge);
  }

  Future<void> _refreshSensorHousingEdge() async =>
      _onSensorHousingEdge(await FloatingBallChannel.sensorHousingEdge());

  @override
  void didChangeMetrics() {
    if (floatingBallSensorHousingEdgeSupported) {
      unawaited(_refreshSensorHousingEdge());
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _registry.addListener(_onChanged);
    pendingExternalLookup.addListener(_onChanged);
    pendingOpenLookupPage.addListener(_onChanged);
    pendingCameraOcr.addListener(_onChanged);
    pendingSync.addListener(_onChanged);
    pendingSystemOcrSetup.addListener(_onChanged);
    if (Platform.isIOS ||
        Platform.isAndroid ||
        isDesktopSystemBallPlatform ||
        floatingBallSensorHousingEdgeSupported) {
      unawaited(
        FloatingBallChannel.installHandler(
          onLookup: deliverExternalLookup,
          onScreenOcrFinished: _onScreenOcrFinished,
          onOpenLookupPage: () => pendingOpenLookupPage.value = true,
          onOpenCameraOcr: () => pendingCameraOcr.value = true,
          onOpenSync: () => pendingSync.value = true,
          onOpenSystemOcrSetup: () => pendingSystemOcrSetup.value = true,
          onSystemBallClosedByUser: _onSystemBallClosedByUser,
          onSystemBallAction: _onDesktopSystemBallAction,
          onSystemBallPositionChanged: _onDesktopSystemBallMoved,
          onScreenOcrTap: _onDesktopScreenOcrTap,
          onScreenOcrDismissed: _onDesktopScreenOcrDismissed,
          onSensorHousingEdgeChanged: _onSensorHousingEdge,
        ),
      );
    }
    // 处理器（同步装上）先于首次查询：查询在路上时原生若推来新方向，两条消息
    // 按发出顺序到达，不会被后到的旧值盖掉，也不会因为还没处理器而丢。
    if (floatingBallSensorHousingEdgeSupported) {
      unawaited(_refreshSensorHousingEdge());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _registry.removeListener(_onChanged);
    pendingExternalLookup.removeListener(_onChanged);
    pendingOpenLookupPage.removeListener(_onChanged);
    pendingCameraOcr.removeListener(_onChanged);
    pendingSync.removeListener(_onChanged);
    pendingSystemOcrSetup.removeListener(_onChanged);
    _prefs?.removeListener(_onPrefsChanged);
    // 还在路上的起球闭包作废。
    _systemGeneration++;
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _onPrefsChanged() {
    _settleClosedBalls();
    _syncSystemBall();
    if (mounted) setState(() {});
  }

  /// 「关闭悬浮球」留下的临时关闭态（[_systemBallClosed] / [_dismissed]）只在
  /// 「自动恢复」覆盖那颗球时才成立；选项改成不再恢复它，就按新选项把这次关闭
  /// 落定成关掉对应的显示开关——与在新选项下点关闭的结果一致，开关仍是唯一
  /// 真相源，不留一个「等回到 Fushi 再起」的标记去违背用户刚改的选项。
  ///
  /// setPref 先同步写内存缓存再落盘，所以紧随其后的 [_syncSystemBall] 读到的
  /// 已是关掉的开关，直接走停球分支。
  void _settleClosedBalls() {
    final PreferencesRepository? prefs = _prefs;
    if (prefs == null) return;
    final FloatingBallAutoRestore restore = prefs.floatingBallAutoRestore;
    final List<Future<void>> writes = <Future<void>>[];
    if (_systemBallClosed && !restore.restoresSystem) {
      _systemBallClosed = false;
      if (prefs.floatingBallSystem) {
        writes.add(prefs.setFloatingBallSystem(false));
      }
    }
    if (_dismissed && !restore.restoresInApp) {
      _dismissed = false;
      _dismissedOwner = null;
      if (prefs.floatingBallInApp) {
        writes.add(prefs.setFloatingBallInApp(false));
      }
    }
    if (writes.isEmpty) return;
    final Future<void> settle = Future.wait(writes).then((_) {});
    debugLatestClosedBallSettle = settle;
    unawaited(settle);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 回到 Fushi：关掉的应用外球按「自动恢复」重新拉起。桌面主窗失焦只到
    // inactive，所以这里认任何一次 resumed，而不只认后台 → 前台。
    final bool restoreSystem =
        state == AppLifecycleState.resumed && _systemBallClosed;
    if (restoreSystem) {
      _systemBallClosed = false;
      _syncSystemBall(force: true);
    }
    final bool foreground = switch (state) {
      AppLifecycleState.resumed => true,
      AppLifecycleState.paused || AppLifecycleState.hidden => false,
      // inactive（下拉通知栏、系统对话框）与 detached 不改变谁该露面。
      _ => _foreground,
    };
    if (foreground == _foreground) return;
    _foreground = foreground;
    // 从后台回到 Fushi：本页关掉的应用内球也恢复（「不自动恢复」时关闭已经
    // 落成了关掉「应用内显示」，不会走到这里）。
    if (foreground && _dismissed) {
      setState(() {
        _dismissed = false;
        _dismissedOwner = null;
      });
    }
    if (_systemSignature != null) {
      unawaited(FloatingBallChannel.setAppForeground(foreground));
    }
    // 从「显示在其他应用上层」授权页回来：再试一次起系统球。桌面没有这道权限，
    // 主窗每次拿回焦点都重发一遍（重画图标、收起菜单）只是白做。
    if (foreground && Platform.isAndroid && !restoreSystem) {
      _syncSystemBall(force: true);
    }
  }

  /// 按偏好起停原生系统球（Android 悬浮窗服务 / Windows、macOS 置顶窗口）。
  void _syncSystemBall({bool force = false}) {
    final PreferencesRepository? prefs = _prefs;
    if (prefs == null || !floatingBallSystemBallSupported) return;
    if (!prefs.floatingBallSystem) {
      _systemBallClosed = false;
      _stopSystemBall();
      return;
    }
    // 用户关掉的球等回到 Fushi 再起，期间配置变化不能把它拉起来。
    if (_systemBallClosed) return;
    final bool lookupModuleEnabled = ref
        .read(appProvider)
        .moduleVisibility
        .isEnabled(ModuleId.lookup);
    // 应用外只有全局按钮（原生侧拿不到任何页面的场景按钮）。
    final List<String> actions = <String>[
      for (final String id in prefs.floatingBallButtons(
        FloatingBallScope.system,
      ))
        if (FloatingBallGlobalAction.fromStorage(id)
            case final FloatingBallGlobalAction action
            when floatingBallSystemActionAvailable(
              action,
              lookupModuleEnabled: lookupModuleEnabled,
            ))
          action.storageValue,
    ];
    final Map<String, String> labels = floatingBallNativeLabels();
    final Map<String, int> icons = floatingBallNativeIcons();
    final Map<String, int> colors = _systemBallColors;
    final bool animate = _systemBallAnimate;
    // 动效也进签名：系统减弱动画切换时配色可能完全没变。
    final String signature =
        '${actions.join(',')}|${labels.values.join('|')}|'
        '${colors.values.join(',')}|$animate';
    if (!force && signature == _systemSignature) return;
    final int generation = ++_systemGeneration;
    _systemRequested = true;
    // 起球要 await 原生回话与桌面资源；回来时还是最新一代、开关还开着，才继续。
    // 「用户关过、等回到 Fushi 再起」也算过期：那个标记可能是同时在路上的另一代
    // 读到并落下的，本代已经过了入口那道门。
    bool stale() =>
        generation != _systemGeneration ||
        !prefs.floatingBallSystem ||
        _systemBallClosed;
    final Future<void> run = () async {
      // 用户在系统球上点过关闭、而当时主引擎不在（没收到推送）：按「自动恢复」
      // 处理——含应用外时这次起球就是「打开 Fushi 自动恢复」（还在后台则等回到
      // 前台）；否则按开关把球拉起来就违背了用户刚做的事，改为把开关关掉。
      //
      // 这个标记是一次性的（Android 读即清，见 FloatingBallService
      // .takeClosedByUser）：拿到它的那一代就必须处理，不论自己是否已被新一代
      // 取代——过期代丢掉 true，下一代读到的只剩 false，会把球重新拉起来。
      final bool closedByUser =
          await FloatingBallChannel.takeSystemBallClosedByUser();
      if (closedByUser) {
        if (!prefs.floatingBallAutoRestore.restoresSystem) {
          _systemSignature = null;
          if (prefs.floatingBallSystem) {
            await prefs.setFloatingBallSystem(false);
          }
          return;
        }
        if (!_foreground) {
          _systemSignature = null;
          _systemBallClosed = true;
          return;
        }
      }
      // 桌面原生窗口不加载图标字体：图标画成已着色的 PNG、球面带原图、位置由
      // Dart 持久化后交给它。
      final bool desktop = isDesktopSystemBallPlatform;
      final Map<String, Uint8List>? iconImages = desktop
          ? <String, Uint8List>{
              ...await renderFloatingBallIconPngs(
                floatingBallNativeIconData(),
                Color(
                  colors['onButtonContainer'] ??
                      colors['onSurface'] ??
                      0xFF1D1B20,
                ),
              ),
              // 展开态球上的 ×：与按钮图标不同色（onPrimary）。
              ...await renderFloatingBallIconPngs(const <String, IconData>{
                kFloatingBallNativeBallCloseKey: kFloatingBallCloseIcon,
              }, Color(colors['onBallOpen'] ?? 0xFFFFFFFF)),
            }
          : null;
      // 球面 = 主题 primaryContainer 上的吉祥物（主题一变配色进签名、重新合成）。
      final Uint8List? ballImage = desktop
          ? await renderFloatingBallFacePng(
              Color(colors['ballContainer'] ?? 0xFFEADDFF),
            )
          : null;
      // 调 start 之前唯一一道门：此前的 await 只产出本地数据（图标、球面），
      // 过期代多做完它们不留任何痕迹，逐个 await 设门只是重复同一个判断。
      if (stale()) return;
      final bool started = await FloatingBallChannel.startSystemBall(
        actions: actions,
        labels: labels,
        icons: icons,
        colors: colors,
        animate: animate,
        ocrLanguage: kFloatingBallOcrLanguage,
        iconImages: iconImages,
        ballImage: ballImage,
        dock: desktop ? prefs.floatingBallSystemDock : null,
        fraction: desktop ? prefs.floatingBallSystemVerticalFraction : null,
      );
      // 起的过程中被更新的决定取代：结果归新一代处理（关了开关的那一代已经发过
      // stop，消息按序到原生，这颗球不会留下）。签名更不能记：记了之后同样配置
      // 的下一次起球会被当成「已下发」跳过，开关开着却没有球。
      if (stale()) return;
      // 起不来（Android 没权限 / 桌面建窗失败）：不记签名，下次同步再试。
      _systemSignature = started ? signature : null;
      if (started) {
        await FloatingBallChannel.setAppForeground(_foreground);
      }
    }();
    debugLatestSystemBallSync = run;
    unawaited(run);
  }

  /// 停原生系统球，并让还在路上的起球闭包作废。
  void _stopSystemBall() {
    if (!_systemRequested) return;
    _systemGeneration++;
    _systemRequested = false;
    _systemSignature = null;
    unawaited(FloatingBallChannel.stopSystemBall());
  }

  /// 配色与动效独立同步：无障碍开关变化也要让已运行的系统球收到新策略。
  void _syncSystemBallAppearance(
    ColorScheme scheme, {
    required bool eink,
    required bool animate,
  }) {
    final Map<String, int> colors = floatingBallNativeColors(
      scheme,
      eink: eink,
    );
    if (_mapEquals(colors, _systemBallColors) &&
        animate == _systemBallAnimate) {
      return;
    }
    _systemBallColors = colors;
    _systemBallAnimate = animate;
    // build 里触发：等这一帧结束再下发，不在 build 期间改状态。
    if (_prefs != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncSystemBall());
    }
  }

  static bool _mapEquals(Map<String, int> a, Map<String, int> b) {
    if (a.length != b.length) return false;
    for (final MapEntry<String, int> e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  void _attachPrefs(PreferencesRepository prefs) {
    if (identical(prefs, _prefs)) return;
    _prefs?.removeListener(_onPrefsChanged);
    _prefs = prefs;
    prefs.addListener(_onPrefsChanged);
    _syncSystemBall(force: true);
  }

  /// 桌面系统球上点了某个动作（原生只画与报事件，动作都在这里执行）。[anchor] 是
  /// 球在屏幕上的矩形（物理像素、左上原点），查词卡锚在球旁边。
  void _onDesktopSystemBallAction(String id, Rect? anchor) {
    unawaited(_runDesktopSystemBallAction(id, anchor));
  }

  Future<void> _runDesktopSystemBallAction(String id, Rect? anchor) async {
    final DesktopSystemBallActionTarget target = desktopSystemBallActionTarget;
    switch (id) {
      case 'lookup':
        // 同「唤起主窗并打开查词页」热键。按钮只在查词模块开着时下发（模块关着
        // 查词页没有入口，见 [FloatingBallGlobalAction.availableIn]）。
        await target.bringMainWindowToFront();
        ref.read(appProvider).requestHomeDictionaryTab(focusSearch: true);
      case 'popup_lookup':
        // 查前台程序当前选中的文字：点球不激活 Fushi，前台还是那个程序。按钮只在
        // 查词模块开着时下发，而模块一开覆盖窗就起（含会话中途打开，见
        // [GlobalLookupController.followLookupModule]）；走到 else 是真异常，
        // 记一笔而不是静默。
        if (target.overlayLookupAvailable) {
          await target.lookupSelection();
        } else {
          ErrorLogService.instance.log(
            'floating_ball.popup_lookup',
            StateError('global lookup overlay is not started'),
            StackTrace.current,
          );
        }
      case 'clipboard':
        final ClipboardData? data = await Clipboard.getData(
          Clipboard.kTextPlain,
        );
        final String text = data?.text?.trim() ?? '';
        if (text.isEmpty) return;
        if (target.overlayLookupAvailable) {
          // 原生报来的球矩形是屏幕物理像素：走物理像素通道，不能当逻辑像素再乘
          // 主窗 DPR（spec 2026-09-30「原生 → Dart」）。
          await target.lookupText(
            text,
            physicalPlacement: anchor == null
                ? null
                : GlobalLookupPhysicalPlacement(anchorScreenRect: anchor),
          );
        } else {
          // 全局查词没开：退回主窗里的查词弹窗。
          await target.bringMainWindowToFront();
          FloatingLyricLookupNotifier.instance.requestLookup(text, 0);
        }
      case 'screen_ocr':
        await _desktopScreenOcr(anchor);
      case 'sync':
        // 同步的结果、冲突裁决与重新登录提示都在主窗里给：先把主窗唤到前台。
        await target.bringMainWindowToFront();
        await _manualSync();
      case 'open_app':
        await target.bringMainWindowToFront();
    }
  }

  /// 桌面应用外球的截屏识字：原生截球所在的显示器并盖上冻结层 → 系统 OCR →
  /// 原生画行框 → 点字（[_onDesktopScreenOcrTap]）用全局查词卡查。按钮只在查词
  /// 模块开着时下发（结果要用覆盖窗，见 [FloatingBallGlobalAction.availableIn]）。
  Future<void> _desktopScreenOcr(Rect? anchor) async {
    final DesktopSystemBallActionTarget target = desktopSystemBallActionTarget;
    if (!target.overlayLookupAvailable) {
      ErrorLogService.instance.log(
        'floating_ball.screen_ocr',
        StateError('global lookup overlay is not started'),
        StackTrace.current,
      );
      return;
    }
    // 上一次的冻结层还开着（原生没关就又点了球）：作废它。
    _desktopOcr = null;
    // 冻结层的行框与提示条跟球同一套主题色（球还没起过时取当前主题）。
    final Map<String, int> colors = _systemBallColors.isEmpty
        ? floatingBallNativeColors(
            Theme.of(context).colorScheme,
            eink: isEinkTheme(context),
          )
        : _systemBallColors;
    // 开着的查词卡会被截进图里，而且它挡着的字点不到。
    await target.dismissLookup();
    final DesktopScreenOcrCapture capture =
        await FloatingBallChannel.startScreenOcrCapture(
          anchor: anchor,
          labels: <String, String>{
            'recognizing': t.floating_ball_ocr_recognizing,
            'hint': t.floating_ball_ocr_pick_hint,
            'close': t.floating_ball_ocr_close,
          },
          colors: colors,
        );
    final Uint8List? png = capture.png;
    final Rect? screen = capture.screen;
    if (png == null || screen == null) {
      // 没截到图就没有冻结层可写字：提示只能在主窗里给。
      await target.bringMainWindowToFront();
      _toast(
        capture.error == DesktopScreenOcrCapture.permissionDenied
            ? t.floating_ball_ocr_screen_permission
            : t.floating_ball_ocr_failed,
      );
      return;
    }
    final _DesktopScreenOcrSession session = _DesktopScreenOcrSession(screen);
    _desktopOcr = session;
    String? message;
    List<SystemOcrTextLine> lines = const <SystemOcrTextLine>[];
    try {
      final SystemOcrPageResult result = await target.recognize(png);
      lines = result.lines;
      if (result.isEmpty) message = t.floating_ball_ocr_empty;
    } on SystemOcrUnavailableException catch (error) {
      message = error.reason == kSystemOcrLanguageUnavailableReason
          ? t.floating_ball_ocr_language_missing
          : t.floating_ball_ocr_failed;
    } catch (error, stack) {
      ErrorLogService.instance.log('floating_ball.screen_ocr', error, stack);
      message = t.floating_ball_ocr_failed;
    }
    // 识别途中用户已经关掉冻结层（或又点了一次）：结果作废。
    if (!identical(_desktopOcr, session)) return;
    session.lines = lines;
    await FloatingBallChannel.updateScreenOcrOverlay(
      lines: <Rect>[for (final SystemOcrTextLine line in lines) line.rect],
      message: message,
    );
  }

  /// 冻结层上点了一下（截图像素）：点在字上 → 查从这个字起的后缀，卡锚在这个字
  /// 旁边（物理像素通道）；点在字外 / 识别失败后点任意处 → 退出。识别还没回来时
  /// 的点击不理。
  void _onDesktopScreenOcrTap(Offset point) {
    final _DesktopScreenOcrSession? session = _desktopOcr;
    final List<SystemOcrTextLine>? lines = session?.lines;
    if (session == null || lines == null) return;
    final DesktopSystemBallActionTarget target = desktopSystemBallActionTarget;
    final ScreenOcrHit? hit = screenOcrHitTest(
      lines: lines,
      point: point,
      scale: 1,
    );
    if (hit == null) {
      _desktopOcr = null;
      unawaited(FloatingBallChannel.stopScreenOcr());
      unawaited(target.dismissLookup());
      return;
    }
    final String text = hit.line.text;
    unawaited(
      target.lookupText(
        text.substring(hit.charIndex),
        sentence: text,
        physicalPlacement: GlobalLookupPhysicalPlacement(
          anchorScreenRect: hit.charRect.shift(session.screen.topLeft),
        ),
      ),
    );
  }

  /// 冻结层被 Esc / 右键 / 关闭钮关掉（原生已关层、已恢复球）。
  void _onDesktopScreenOcrDismissed() {
    if (_desktopOcr == null) return;
    _desktopOcr = null;
    unawaited(desktopSystemBallActionTarget.dismissLookup());
  }

  /// 桌面系统球拖动吸附后：落库（位置由 Dart 持久化，下次起球带回去）。
  void _onDesktopSystemBallMoved(String dock, double fraction) {
    unawaited(_prefs?.setFloatingBallSystemPosition(dock, fraction));
  }

  /// 系统球 / 常驻通知上点了关闭：服务已经自己停了，把「应用外」开关同步关掉。
  void _onSystemBallClosedByUser() {
    unawaited(() async {
      // 清掉原生的持久标记，免得下次启动再处理一遍。
      await FloatingBallChannel.takeSystemBallClosedByUser();
      _systemSignature = null;
      final PreferencesRepository? prefs = _prefs;
      if (prefs == null || !prefs.floatingBallSystem) return;
      // 「自动恢复」含应用外：开关不动，回到 Fushi 再拉起。原生那边球已经收了，
      // 让在路上的起球闭包作废，免得它又把球摆出来。
      if (prefs.floatingBallAutoRestore.restoresSystem) {
        _systemGeneration++;
        _systemBallClosed = true;
        return;
      }
      await prefs.setFloatingBallSystem(false);
    }());
  }

  /// 系统球「查词」：app 就绪后切到查词页并聚焦搜索框（与桌面「唤起主窗并打开
  /// 查词页」同一出口 [AppModel.requestHomeDictionaryTab]）。
  void _flushOpenLookupPage(AppModel appModel) {
    if (!pendingOpenLookupPage.value) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!pendingOpenLookupPage.value) return;
      pendingOpenLookupPage.value = false;
      appModel.requestHomeDictionaryTab(focusSearch: true);
    });
  }

  /// 系统球「拍照查词」：app 就绪后开相机（识别要用已初始化的词典查词）。
  void _flushCameraOcr() {
    if (!pendingCameraOcr.value) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!pendingCameraOcr.value) return;
      pendingCameraOcr.value = false;
      unawaited(_cameraOcr());
    });
  }

  /// 系统球「立即同步」：app 就绪后跑一轮同步（同步要用已初始化的数据库与通道）。
  void _flushSync() {
    if (!pendingSync.value) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!pendingSync.value) return;
      pendingSync.value = false;
      unawaited(_manualSync());
    });
  }

  /// 系统 OCR 模型未就绪：app 就绪后弹出模型配置（查状态 / 立即下载）。
  void _flushSystemOcrSetup() {
    if (!pendingSystemOcrSetup.value) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!pendingSystemOcrSetup.value) return;
      final BuildContext? ctx = _navigatorContext;
      if (ctx == null) return;
      pendingSystemOcrSetup.value = false;
      unawaited(
        showSystemOcrSetupDialog(ctx, language: kFloatingBallOcrLanguage),
      );
    });
  }

  /// 外部查词：app 就绪后才交给查词弹窗（弹窗要用已初始化的词典）。
  void _flushExternalLookup() {
    final String? word = pendingExternalLookup.value;
    if (word == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final String? current = pendingExternalLookup.value;
      if (current == null) return;
      pendingExternalLookup.value = null;
      FloatingLyricLookupNotifier.instance.requestLookup(current, 0);
    });
  }

  // ── 全局按钮 ────────────────────────────────────────────────────────

  BuildContext? get _navigatorContext =>
      ref.read(appProvider).navigatorKey.currentContext;

  void _toast(String message) {
    final BuildContext? ctx = _navigatorContext;
    if (ctx == null) return;
    ScaffoldMessenger.maybeOf(
      ctx,
    )?.showSnackBar(FushiSnackBar(content: Text(message)));
  }

  Future<void> _manualLookup() async {
    final BuildContext? ctx = _navigatorContext;
    if (ctx == null) return;
    final String? word = await showAppDialog<String>(
      context: ctx,
      builder: (BuildContext context) => const _ManualLookupDialog(),
    );
    if (word == null || word.trim().isEmpty) return;
    FloatingLyricLookupNotifier.instance.requestLookup(word.trim(), 0);
  }

  Future<void> _clipboardLookup() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final String text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      _toast(t.floating_ball_clipboard_empty);
      return;
    }
    FloatingLyricLookupNotifier.instance.requestLookup(text, 0);
  }

  /// 立即同步：与设置页「立即同步」同一个入口，重入（已有同步在跑）、三种结果的
  /// 提示、逐通道冲突裁决、鉴权失效登出全由它处理。
  Future<void> _manualSync() async {
    final BuildContext? ctx = _navigatorContext;
    if (ctx == null) return;
    await runManualSyncWithFeedback(
      context: ctx,
      appModel: ref.read(appProvider),
    );
  }

  /// Android 截屏 OCR 截到帧（或放弃）：把藏起来的球放回来。
  void _onScreenOcrFinished() {
    if (mounted && _capturing) setState(() => _capturing = false);
  }

  Future<void> _screenOcr() async {
    if (Platform.isAndroid) {
      // 原生只藏得了原生球：Flutter 球要自己藏，等 screenOcrFinished 再放回来。
      setState(() => _capturing = true);
      final bool started = await FloatingBallChannel.startScreenOcr(
        language: kFloatingBallOcrLanguage,
        labels: floatingBallNativeLabels(),
      );
      if (started) return;
      _onScreenOcrFinished();
      if (!await FloatingBallChannel.canDrawOverlays()) {
        _toast(t.floating_ball_overlay_permission_needed);
        await FloatingBallChannel.requestOverlayPermission();
      } else {
        _toast(t.floating_ball_ocr_failed);
      }
      return;
    }
    if (Platform.isIOS) await _screenOcrInApp();
  }

  /// iOS：截自己的窗口 → Vision → 选取页。
  Future<void> _screenOcrInApp() async {
    setState(() => _capturing = true);
    // 等球从画面上消失再截。
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame;
    final Uint8List? bytes;
    try {
      bytes = await FloatingBallChannel.captureScreen();
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
    if (bytes == null) {
      _toast(t.floating_ball_ocr_failed);
      return;
    }
    await _recognizeAndPick(bytes, fit: ScreenOcrImageFit.window);
  }

  /// 拍照查词（Android / iOS）：系统相机拍一张 → 转正方向 → 系统 OCR → 选取页。
  /// 走系统拍照 intent / UIImagePickerController，Android 不需要 CAMERA 运行时
  /// 权限（manifest 没声明它，见 `AppModel.requestExternalStoragePermissions`）。
  Future<void> _cameraOcr() async {
    final Uint8List? photo;
    try {
      photo = await pickCameraPhotoBytes(maxSide: kCameraOcrMaxSide);
    } on PlatformException catch (error, stack) {
      // iOS 拒绝过相机权限（camera_access_denied）、没有相机等。
      ErrorLogService.instance.log('floating_ball.camera_ocr', error, stack);
      _toast(t.floating_ball_camera_unavailable);
      return;
    }
    if (photo == null) return; // 用户在相机里取消。
    final Uint8List? bytes = await compute(normalizeCameraOcrPhoto, photo);
    if (bytes == null) {
      _toast(t.floating_ball_ocr_failed);
      return;
    }
    await _recognizeAndPick(bytes, fit: ScreenOcrImageFit.contain);
  }

  /// 送检图 → 系统 OCR → 全屏选取页（点字查词）。截屏与拍照共用。
  Future<void> _recognizeAndPick(
    Uint8List bytes, {
    required ScreenOcrImageFit fit,
  }) async {
    final SystemOcrPageResult result;
    try {
      result = await const MethodChannelSystemOcr().recognize(
        bytes,
        language: kFloatingBallOcrLanguage,
      );
    } on SystemOcrUnavailableException catch (error) {
      if (error.reason == kSystemOcrModelUnavailableReason) {
        // 不只提示「没就绪」：直接带用户去把模型配好（BUG-2906）。
        pendingSystemOcrSetup.value = true;
      } else {
        _toast(t.floating_ball_ocr_failed);
      }
      return;
    } catch (error, stack) {
      ErrorLogService.instance.log('floating_ball.screen_ocr', error, stack);
      _toast(t.floating_ball_ocr_failed);
      return;
    }
    if (result.isEmpty) {
      _toast(t.floating_ball_ocr_empty);
      return;
    }
    final NavigatorState? navigator = ref
        .read(appProvider)
        .navigatorKey
        .currentState;
    if (navigator == null) return;
    // 无过渡：截图与当前画面同形，淡入 / 滑入只会让人以为画面跳了。
    unawaited(
      navigator.push(
        PageRouteBuilder<void>(
          opaque: true,
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder:
              (
                BuildContext context,
                Animation<double> animation,
                Animation<double> secondaryAnimation,
              ) => ScreenOcrPickerPage(
                imageBytes: bytes,
                result: result,
                fit: fit,
              ),
        ),
      ),
    );
  }

  /// 应用内球的「关闭悬浮球」，按「自动恢复」（[FloatingBallAutoRestore]）：
  /// 含应用内时只在**这一次页面**里收起，离开这个页面或从后台回到 Fushi 就自动
  /// 恢复（下次再进同一个视频 / 书也照常出现），不动设置里的「应用内显示」——
  /// 用户的原话是「这次不要，之后要」；选了「不自动恢复」则直接关掉「应用内
  /// 显示」，要到设置里重开。
  ReaderHeaderAction _closeInAppAction(
    FloatingBallSceneSnapshot scene,
    PreferencesRepository prefs,
  ) => ReaderHeaderAction(
    key: const ValueKey<String>('floating_ball_action_close'),
    icon: kFloatingBallCloseIcon,
    label: t.floating_ball_action_close,
    onPressed: () {
      if (!prefs.floatingBallAutoRestore.restoresInApp) {
        unawaited(prefs.setFloatingBallInApp(false));
        return;
      }
      setState(() {
        _dismissed = true;
        _dismissedOwner = scene.owner;
      });
    },
  );

  ReaderHeaderAction _globalAction(FloatingBallGlobalAction action) =>
      switch (action) {
        FloatingBallGlobalAction.lookup => ReaderHeaderAction(
          key: const ValueKey<String>('floating_ball_action_lookup'),
          icon: floatingBallGlobalActionIcon(action),
          label: t.floating_ball_action_lookup,
          onPressed: () => unawaited(_manualLookup()),
        ),
        FloatingBallGlobalAction.popupLookup => ReaderHeaderAction(
          key: const ValueKey<String>('floating_ball_action_popup_lookup'),
          icon: floatingBallGlobalActionIcon(action),
          label: t.floating_ball_action_popup_lookup,
          onPressed: () => unawaited(FloatingBallChannel.openPopupLookup()),
        ),
        FloatingBallGlobalAction.clipboard => ReaderHeaderAction(
          key: const ValueKey<String>('floating_ball_action_clipboard'),
          icon: floatingBallGlobalActionIcon(action),
          label: t.floating_ball_action_clipboard,
          onPressed: () => unawaited(_clipboardLookup()),
        ),
        FloatingBallGlobalAction.screenOcr => ReaderHeaderAction(
          key: const ValueKey<String>('floating_ball_action_screen_ocr'),
          icon: floatingBallGlobalActionIcon(action),
          label: t.floating_ball_action_screen_ocr,
          onPressed: () => unawaited(_screenOcr()),
        ),
        FloatingBallGlobalAction.cameraOcr => ReaderHeaderAction(
          key: const ValueKey<String>('floating_ball_action_camera_ocr'),
          icon: floatingBallGlobalActionIcon(action),
          label: t.floating_ball_action_camera_ocr,
          onPressed: () => unawaited(_cameraOcr()),
        ),
        FloatingBallGlobalAction.sync => ReaderHeaderAction(
          key: const ValueKey<String>('floating_ball_action_sync'),
          icon: floatingBallGlobalActionIcon(action),
          label: t.sync_now,
          onPressed: () => unawaited(_manualSync()),
        ),
      };

  /// 勾选的按钮 id → 此刻能显示的动作：全局按钮看平台能力，专属按钮看页面此刻
  /// 有没有提供（例如漫画的整卷 OCR 只在满足条件时提供）。
  ReaderHeaderAction? _resolveButton(
    String id,
    FloatingBallSceneSnapshot scene,
  ) {
    final FloatingBallGlobalAction? global =
        FloatingBallGlobalAction.fromStorage(id);
    if (global == null) return scene.actions[id];
    return floatingBallGlobalActionAvailable(global)
        ? _globalAction(global)
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final AppModel appModel = ref.watch(appProvider);
    if (!appModel.isInitialised) return const SizedBox.shrink();
    final PreferencesRepository prefs = appModel.prefsRepo;
    _syncSystemBallAppearance(
      Theme.of(context).colorScheme,
      eink: isEinkTheme(context) || appModel.einkMode,
      animate: !appModel.einkMode && fushiMotionEnabled(context),
    );
    _attachPrefs(prefs);
    _flushExternalLookup();
    _flushOpenLookupPage(appModel);
    _flushCameraOcr();
    _flushSync();
    _flushSystemOcrSetup();

    final FloatingBallSceneSnapshot scene = _registry.current;
    // 页面把必需入口托付给了球（阅读器关掉顶栏和底栏）：球必须在，本页不能被
    // 「关闭」——哪怕是之前在这页的弹层上点的关闭（那时场景不是当前，关闭键还在）。
    final bool pinned = scene.pinnedIds.isNotEmpty;
    // 离开了点「关闭」的那一页：恢复。只清字段、不 setState（正在 build）。
    if (_dismissed && (pinned || !identical(scene.owner, _dismissedOwner))) {
      _dismissed = false;
      _dismissedOwner = null;
    }
    if (!prefs.floatingBallInApp ||
        scene.hidesBall ||
        _capturing ||
        _dismissed) {
      return const SizedBox.shrink();
    }
    final List<ReaderHeaderAction> buttons = <ReaderHeaderAction>[
      for (final String id in scene.pinnedIds)
        if (scene.actions[id] case final ReaderHeaderAction action) action,
      ...prefs
          .floatingBallButtons(scene.scope)
          .where((String id) => !scene.pinnedIds.contains(id))
          .map((String id) => _resolveButton(id, scene))
          .nonNulls,
    ];
    // 勾选的按钮一颗都不剩 = 用户不要这颗球（关闭键不算数）。
    if (buttons.isEmpty) return const SizedBox.shrink();
    // 「关闭悬浮球」排最上（离球最远，防误触）；按钮在下、末颗紧贴球。接管中的
    // 页面没有关闭键，固定按钮占最上面那几格。
    final List<ReaderHeaderAction> actions = <ReaderHeaderAction>[
      if (!pinned) _closeInAppAction(scene, prefs),
      ...buttons,
    ];
    final Size window = MediaQuery.sizeOf(context);
    final Rect viewport = appFloatingBallViewport(
      window,
      MediaQuery.viewPaddingOf(context),
      sensorHousingEdge: _sensorHousingEdge,
    );
    // ReaderFloatingBall 返回 Positioned，必须是 Stack 的直接子节点。本宿主挂在
    // 导航之上，没有 Overlay 祖先，球与按钮的 Tooltip 要自带一层；Stack 只在
    // 球 / 按钮上命中，空白处照常穿透到底下页面。
    return Overlay.wrap(
      child: Stack(
        children: <Widget>[
          ReaderFloatingBall(
            key: const ValueKey<String>('fushi_app_floating_ball'),
            viewport: viewport,
            actions: actions,
            dock: ReaderFloatingBallDock.decode(prefs.floatingBallDock),
            verticalFraction: prefs.floatingBallVerticalFraction,
            animate: !appModel.einkMode,
            onDockChanged: (ReaderFloatingBallDock dock, double fraction) {
              unawaited(prefs.setFloatingBallPosition(dock.id, fraction));
            },
          ),
        ],
      ),
    );
  }
}

class _ManualLookupDialog extends StatefulWidget {
  const _ManualLookupDialog();

  @override
  State<_ManualLookupDialog> createState() => _ManualLookupDialogState();
}

class _ManualLookupDialogState extends State<_ManualLookupDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    final MaterialLocalizations l10n = MaterialLocalizations.of(context);
    return FushiAlertDialog(
      title: Text(t.floating_ball_action_lookup),
      content: FushiTextFieldControl(
        key: const ValueKey<String>('floating_ball_lookup_field'),
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(hintText: t.floating_ball_lookup_hint),
        onSubmitted: (_) => _submit(),
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButtonLabel),
        ),
        FushiFilledButton(
          onPressed: _submit,
          child: Text(l10n.searchFieldLabel),
        ),
      ],
    );
  }
}

/// 桌面截屏识字的一次冻结层：截的是哪块显示器、识别出了哪些行（null = 还在识别）。
class _DesktopScreenOcrSession {
  _DesktopScreenOcrSession(this.screen);

  /// 那块显示器的屏幕矩形（物理像素、左上原点）；截图像素 + 它的左上 = 屏幕坐标。
  final Rect screen;

  List<SystemOcrTextLine>? lines;
}
