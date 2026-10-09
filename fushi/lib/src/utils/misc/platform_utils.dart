import 'dart:io' show Platform;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';

// Architecture decision: platform branching uses runtime Platform.is* checks
// centralized in this file, not Dart conditional imports.
// Conditional imports (if (dart.library.io)) only distinguish web vs native,
// which this app does not target. For platform-specific behavior beyond simple
// boolean checks, use the service abstractions in package:fushi_platform with
// implementations under lib/src/platform/{android,ios,desktop}/.

bool get isDesktopPlatform =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

bool get isMobilePlatform => Platform.isAndroid || Platform.isIOS;

bool get isAndroidPlatform => Platform.isAndroid;

bool get isIOSPlatform => Platform.isIOS;

bool get supportsNativeAudio =>
    Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

bool get supportsFloatingOverlay => Platform.isAndroid;

bool get isWindowsPlatform => Platform.isWindows;

bool get isMacOSPlatform => Platform.isMacOS;

/// WebView 本地资源（EPUB / 漫画页 / 字体）走自定义 scheme 投递的平台。
///
/// WKWebView（iOS / macOS）与 WPE WebKit（Linux，`flutter_inappwebview_linux`）
/// 都没有能拦截 `https://` 的 `shouldInterceptRequest`，只能注册自定义 scheme
/// （`WKURLSchemeHandler` / `webkit_web_context_register_uri_scheme`）；Android 与
/// Windows 则拦截 `https://fushi.local/...`。资源 URL 的构造与 WebView 的
/// `resourceCustomSchemes` 必须问同一个判据，否则页面请求的 scheme 没人接。
bool get webViewUsesCustomSchemeTransport =>
    Platform.isMacOS || Platform.isIOS || Platform.isLinux;

/// Sets the system-UI mode for the **home/menu shell** (book shelf, video,
/// dictionary search, settings -- everything that is NOT an open media session).
///
/// Every platform, Android included, shows both the status bar and the
/// navigation bar (the user reversed TODO-097 on 2026-10-04: the Android home
/// shell shows the status bar again). Show every overlay first, then
/// edge-to-edge: Flutter 3.44's edgeToEdge only changes decor fitting and does
/// not clear the FULLSCREEN / IMMERSIVE_STICKY a video page leaves behind, so
/// visibility must be restored explicitly through `manual` (BUG-2925).
///
/// Readers restore this mode through AppModel.closeMedia; video pages restore
/// it when the last display owner exits.
Future<void> setHomeShellSystemUiMode() async {
  await SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.manual,
    overlays: SystemUiOverlay.values,
  );
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
}

/// The system-UI mode the **novel reader body** declares once its content is
/// ready (BUG-3077).
///
/// Android keeps both system bars hidden ([SystemUiMode.immersiveSticky], the
/// mode `AppModel.openMedia` already entered): the reader draws its own
/// chrome, and its top / bottom text inset is `viewPadding` plus the reader's
/// own reserves, so any visible bar pushes the page body away from the edge.
/// iOS and desktop keep [SystemUiMode.edgeToEdge] (iOS shows the status bar in
/// the reader, as it always has; desktop has no system bars).
///
/// Android must not send edgeToEdge here. Up to Flutter 3.44 the Android
/// `PlatformPlugin.enableEdgeToEdge()` only changed decor fitting and left the
/// IMMERSIVE_STICKY flags from `openMedia` in place, so the bars stayed hidden
/// and `viewPadding.top` stayed at the cutout inset. Flutter 3.47 first calls
/// `decorView.setSystemUiVisibility(0)`, which clears those flags: the status
/// and navigation bars came back as soon as a book finished loading, and the
/// status-bar height went straight into the text's top padding (the "top
/// margin got bigger" report). Declaring the wanted mode directly does not
/// depend on that engine detail.
///
/// [android] defaults to the running platform; tests pass it explicitly.
Future<void> setReaderSystemUiMode({bool? android}) async {
  await SystemChrome.setEnabledSystemUIMode(
    readerSystemUiMode(android: android ?? Platform.isAndroid),
  );
}

/// The mode [setReaderSystemUiMode] sends (see there).
SystemUiMode readerSystemUiMode({required bool android}) =>
    android ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge;

/// Windows/Linux 桌面用 MD3 的钳制滚动（去掉 iOS 风格回弹）；macOS（Cupertino
/// 平台，刻意不动）与移动端保持原有可回弹物理。始终保留 AlwaysScrollable 外层，
/// 使短内容也可滚动 / 触发下拉刷新等行为。
ScrollPhysics desktopAwareScrollPhysics() {
  final bool md3Desktop = Platform.isWindows || Platform.isLinux;
  return md3Desktop
      ? const AlwaysScrollableScrollPhysics(parent: ClampingScrollPhysics())
      : const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics());
}

/// 让**横向**滚动区接受鼠标 / 触控板 / 触笔的拖动滚动。
///
/// Flutter 桌面的默认 `MaterialScrollBehavior.dragDevices` 不含
/// [PointerDeviceKind.mouse]：横排合集行、标签筛选栏、分段按钮条这类横向滚动区，
/// 用鼠标左键按住左右拖会**毫无反应**（用户实报），只能靠滚轮。这里显式放开鼠标 /
/// 触控板 / 触笔拖动，触屏行为不变。
///
/// 只包横向滚动区，**刻意不做成全局 `MaterialApp.scrollBehavior`**：垂直网格若
/// 也放开鼠标拖动滚动，会与卡片拖拽（`MediaCardDraggable` 里的 [Draggable]）抢
/// 手势竞技场，把「拖卡进合集」变成「拖动网格滚动」。横向区没有这个冲突——横拖
/// 归滚动、纵拖归拖卡，两者都要过 `kTouchSlop`、方向先满足者胜，正好是自然分工。
///
/// 同理，区内若有 `LongPressDraggable`（标签 chip）也不冲突：按下即动归滚动、
/// 按住不动满 `kLongPressTimeout` 归拖拽。
class HorizontalDragScrollable extends StatelessWidget {
  const HorizontalDragScrollable({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => ScrollConfiguration(
    behavior: ScrollConfiguration.of(context).copyWith(
      dragDevices: const <PointerDeviceKind>{
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.stylus,
        PointerDeviceKind.trackpad,
      },
    ),
    child: child,
  );
}

/// 让**横向**滚动区接受鼠标滚轮（把滚轮的纵向 delta 投到横轴）。BUG-1214。
///
/// 根因：Flutter 的 `Scrollable` 取 pointer signal 的分量是按**自身轴**取的
/// （`scrollable.dart` 的 `_pointerSignalEventDelta`：横向取 `scrollDelta.dx`、
/// 纵向取 `dy`），只有按住 `pointerAxisModifiers`（默认 Shift）且是物理鼠标时
/// 才翻轴。物理滚轮发的是 `(0, dy)`，所以横向滚动区**裸滚轮完全没反应**——用户
/// 只能拖滚动条或横拖（后者还受 `dragDevices` 限制，见 [HorizontalDragScrollable]）。
///
/// 修法与 Flutter 自己处理滚轮的路径一致：向 [PointerSignalResolver] 登记，命中
/// 后调 [ScrollPosition.pointerScroll]（会正确更新 [ScrollDirection]、走物理钳制），
/// 不是自造 `jumpTo`。
///
/// **只认物理鼠标**（`PointerDeviceKind.mouse`）：触控板两个方向都能给，横向分量
/// 本来就被 `Scrollable` 直接吃掉，翻轴反而会让纵向双指手势莫名横滚——这也是
/// Flutter 只对鼠标做轴翻转的理由。
///
/// 事件派发是内层优先：内层 `Scrollable` 若已表态（如触控板给了 dx、或 Shift 已
/// 翻轴），它先登记、本件的登记自动变 no-op，不会双份滚动。内容没超出视口时本件
/// 不登记，滚轮照常冒泡给外层（弹窗纵向滚动不被吞）。
///
/// **什么时候不要用**（BUG-1536）：横向区**嵌在纵向滚动页面里**时不要包本件——
/// 内容超出视口时它会一直登记，指针停在这一行上整页就纵向滚不动了（用户实报的
/// 视频首页横滚行症状）。那种场景把本件撤掉即可：未按 Shift 时横向 `Scrollable`
/// 取 `dx`（物理滚轮恒 0）不登记，滚轮冒泡给外层纵滚；按住 Shift 时 Flutter 自己
/// 就翻轴横滚。本件只留给**自身占满一屏、外面没有纵向滚动可抢**的横向面板（如
/// 波形对轴弹窗的时间轴，那里用户明确要过裸滚轮平移）。
class WheelToHorizontalScroll extends StatelessWidget {
  const WheelToHorizontalScroll({
    required this.controller,
    required this.child,
    super.key,
  });

  /// 目标横向滚动区的控制器（本件挂在滚动件**外面**，故不能靠 context 查 position）。
  final ScrollController controller;

  final Widget child;

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (event.kind != PointerDeviceKind.mouse) return;
    if (!controller.hasClients) return;

    final ScrollPosition position = controller.position;
    final double raw = event.scrollDelta.dy;
    if (raw == 0) return;
    // 与 Flutter 同口径：轴方向反向（RTL 下的横向滚动区）时取负。
    final double delta = axisDirectionIsReversed(position.axisDirection)
        ? -raw
        : raw;
    final double target = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    // 滚不动（已到头 / 内容没超出视口）就不登记，把事件让给外层滚动区。
    if (target == position.pixels) return;

    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (PointerSignalEvent _) => position.pointerScroll(delta),
    );
  }

  @override
  Widget build(BuildContext context) =>
      Listener(onPointerSignal: _onPointerSignal, child: child);
}

enum WindowSizeClass { compact, medium, expanded }

enum DesktopContentKind { readerShelf, dictionary, settings }

enum SupportingPaneSide { start, end }

/// Single source of truth for the Material compact/medium/expanded
/// breakpoints. [width] must be the **real physical viewport width** in
/// logical pixels — see [windowSizeClassReal] for why the raw logical width
/// handed down inside [FushiAppUiScale] is not it.
WindowSizeClass windowSizeClassForWidth(double width) {
  if (width >= 840) return WindowSizeClass.expanded;
  if (width >= 600) return WindowSizeClass.medium;
  return WindowSizeClass.compact;
}

/// Classify by the **real** viewport width.
///
/// BUG-401: inside [FushiAppUiScale] the subtree is laid out against a
/// virtual canvas of `realViewport / scale` (so visual scaling can fill the
/// screen). A breakpoint that reads that inflated logical width never falls
/// into [WindowSizeClass.compact] on desktop — the window's real width could
/// shrink, but the logical width stayed high, so the phone (bottom-bar)
/// layout was unreachable. The real width is `logicalWidth * scale`.
///
/// [appUiScale] is the net [FushiAppUiScale.of] factor at the call site
/// (1.0 below the neutraliser, on undecorated routes, or when no scale
/// ancestor exists). A non-finite / non-positive scale degrades to identity
/// (treat the logical width as already-real).
WindowSizeClass windowSizeClassReal(double logicalWidth, double appUiScale) {
  final bool usableScale =
      appUiScale.isFinite && !appUiScale.isNaN && appUiScale > 0;
  final double realWidth = usableScale
      ? logicalWidth * appUiScale
      : logicalWidth;
  return windowSizeClassForWidth(realWidth);
}

WindowSizeClass windowSizeClassOf(BoxConstraints constraints) =>
    windowSizeClassForWidth(constraints.maxWidth);

WindowSizeClass windowSizeClassFromContext(BuildContext context) =>
    windowSizeClassForWidth(MediaQuery.sizeOf(context).width);

double? desktopContentMaxWidth(
  WindowSizeClass sizeClass,
  DesktopContentKind kind,
) {
  if (sizeClass == WindowSizeClass.compact) return null;
  return switch (kind) {
    // UI v2：取消书架/视频库在宽屏上的 1280px 内容宽上限（用户实报「莫名的左右
    // 宽度上限」）。合集横排行/卡片网格是媒体墙布局，随窗口放宽天然多排一列，
    // 居中锁窄反而两侧留白。侧向留白也为零（见 [desktopContentPadding]），
    // 卡片自带内边距，真正 full-bleed。
    DesktopContentKind.readerShelf => null,
    // TODO-1352: 取消查词页（nav「查词」）在宽屏上的强制内容宽度上限。此前 1040px 把
    // 查词结果区 WebView 居中锁死在窄栏，宽屏两侧大片留白、用户无法让词典正文占满。
    // 返回 null 让 [DesktopContentLayout] 走 full-bleed 分支（词典正文是文字流，
    // 仍保留 16/24px 侧向留白不贴边），词典正文随窗口放宽（可容纳更多
    // --dict-columns 与更长释义）。嵌套查词弹窗渲染在根 Overlay、独立走
    // popupMaxWidth，不受此项影响。
    DesktopContentKind.dictionary => null,
    // 取消设置页（含各库页内嵌的 [ModuleSettingsView] 设置标签页）在宽屏上的
    // 960px 强制内容宽上限——这是书架（1280）/ 查词（1040）同款「莫名奇妙的宽度
    // 限制」的最后一处残留：设置详情本身就是填满 pane 的列表流（设置主页的宽屏
    // 主从布局早已按用户拍板不限宽，见 settings_home_page._buildWideLayout 注释），
    // 唯独走 [DesktopContentLayout] 的这一支还把正文居中锁在 960，4K 窗口下两侧
    // 各留 700+px 空白、且与同一 app 内不限宽的设置详情自相矛盾。
    // 返回 null 走 full-bleed 分支，仍由 [desktopContentPadding] 保留 16/24px
    // 侧向留白（正文不贴边）。
    DesktopContentKind.settings => null,
  };
}

/// [DesktopContentLayout] 的侧向留白。媒体墙类页面（[DesktopContentKind.readerShelf]：
/// 书架/视频/游戏/漫画目录/来源页）恒为零——卡片自带内边距，宽屏上再叠 16/24px
/// 强制侧向留白只是在侧栏与内容间挤出一条空带（用户实报「首页左右强制的间距」）。
/// 设置是文字流正文，贴边可读性差，宽屏保留 16/24px。
///
/// 查词页（[DesktopContentKind.dictionary]）同样为零（2026-10-06 用户截图「查词
/// 顶部这块左边还是没对齐」）：页内搜索框、结果卡、历史列表各自已按页边
/// （[FushiSpacingTokens.page]）内缩，再叠 16/24 会让整块比外壳大标题 / 右上
/// 按钮组多缩进一截，与库页同一条页边对不齐。
EdgeInsets desktopContentPadding(
  WindowSizeClass sizeClass,
  DesktopContentKind kind,
) {
  if (kind == DesktopContentKind.readerShelf ||
      kind == DesktopContentKind.dictionary) {
    return EdgeInsets.zero;
  }
  return switch (sizeClass) {
    WindowSizeClass.compact => EdgeInsets.zero,
    WindowSizeClass.medium => const EdgeInsets.symmetric(horizontal: 16),
    WindowSizeClass.expanded => const EdgeInsets.symmetric(horizontal: 24),
  };
}

double desktopDialogContentWidth(double availableWidth) {
  return (availableWidth * 0.8).clamp(256.0, 420.0);
}

double readerShelfGridExtentForWidth(double width) {
  if (width >= 1280) return 210;
  if (width >= 960) return 190;
  if (width >= 600) return 180;
  return 150;
}

double readerShelfGridExtentForLayout({
  required double mediaWidth,
  double? contentWidth,
}) {
  return readerShelfGridExtentForWidth(contentWidth ?? mediaWidth);
}

double supportingPaneWidthForLayout(double width) {
  return (width * 0.3).clamp(280.0, 360.0);
}

/// 书籍 / 视频快捷设置宽窗 master-detail 左父菜单的固定宽度。比
/// [supportingPaneWidthForLayout] 更窄，给右侧详情留更多空间。
const double kFushiSettingsSupportingPaneWidth = 208.0;

/// 书籍 / 视频快捷设置切换到宽窗 master-detail（左父菜单 + 右详情）的**宽度**阈值。
/// 窄于此值走窄窗 push。
///
/// 与 [kFushiSettingsWideMinHeight] 一起构成确定性的几何判据
/// `_isWide = maxWidth >= 阈值 && maxHeight >= 阈值`：两个 sheet 共用同一组常量，
/// 同一台设备 / 同一窗口尺寸下视频与书籍必然同时进 / 同时不进横屏（不再用「post-frame
/// 测左父菜单内容是否溢出」那套会随内容高度发散、导致同设备两种表现的回退）。
const double kFushiSettingsWideThreshold = 560.0;

/// 书籍 / 视频快捷设置进入宽窗 master-detail 所需的**最小可用高度**阈值。窗口比这
/// 更矮时左父菜单放不下，回退窄窗 push（不出滚动条）。书籍设置已把阅读进度并入右侧
/// 外观详情、左父菜单只留分类导航 + 动作，使两个 sheet 的左栏都能在此高度内放下。
const double kFushiSettingsWideMinHeight = 440.0;

/// 桌面宽窗下书籍 / 视频 / 阅读器快捷设置弹窗（[FushiDialogFrame]）的最大内容宽度。
/// 全屏 push 的设置类页面（如 `BookCssEditorPage`）也用它约束正文宽度，与限宽弹窗
/// 里的兄弟设置页保持同宽，消除各处重复出现的 `900` 魔法数。
const double kFushiSettingsDialogMaxWidth = 900.0;

/// 页内快捷设置面板（视频设置侧栏等）的自适应内容宽度：取窗口宽度的一半，
/// 下限 [kFushiSettingsWideThreshold]（560，即旧固定宽——窄窗行为零变化），
/// 上限对齐兄弟设置弹窗的 [kFushiSettingsDialogMaxWidth]（900）。
///
/// BUG-1546：视频页内设置侧栏此前硬编码 560 固定宽，桌面大窗口下被挤成窄条
/// （用户实报「视频、小说等设置被限制了宽度」）。宽度跟随窗口自适应后，
/// ≥1120 逻辑宽的窗口面板随之放宽，≥1800 达到 900 上限；同时下限保住旧值，
/// 手机 / 窄窗仍由 [VideoTranslucentSidePanel] 的 94% 可用宽钳制兜底。
double fushiQuickSettingsPanelWidth(double windowWidth) {
  if (!windowWidth.isFinite) return kFushiSettingsWideThreshold;
  return (windowWidth * 0.5)
      .clamp(kFushiSettingsWideThreshold, kFushiSettingsDialogMaxWidth)
      .toDouble();
}

class DesktopContentLayout extends StatelessWidget {
  const DesktopContentLayout({
    required this.kind,
    required this.child,
    super.key,
  });

  final DesktopContentKind kind;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // BUG-401: classify on the real physical width so a desktop window
        // dragged narrow collapses the shelf/dictionary/settings body into
        // the compact (full-bleed) layout instead of staying expanded.
        final WindowSizeClass sizeClass = windowSizeClassReal(
          constraints.maxWidth,
          FushiAppUiScale.of(context),
        );
        final double? maxWidth = desktopContentMaxWidth(sizeClass, kind);
        final Widget padded = Padding(
          padding: desktopContentPadding(sizeClass, kind),
          child: child,
        );
        if (maxWidth == null) return padded;
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: padded,
          ),
        );
      },
    );
  }
}

class MaterialSupportingPaneLayout extends StatelessWidget {
  const MaterialSupportingPaneLayout({
    required this.primary,
    required this.supporting,
    super.key,
    this.supportingSide = SupportingPaneSide.end,
    this.minSplitWidth = 840,
    this.supportingWidth,
    this.dividerColor,
    this.showDivider = true,
  });

  final Widget primary;
  final Widget supporting;
  final SupportingPaneSide supportingSide;
  final double minSplitWidth;
  final double? supportingWidth;
  final Color? dividerColor;

  /// 为 false 时两个窗格之间不画 1px 分隔线（也不占那 1px），窗格边界只由各自
  /// 的内容表达。设置主页的宽屏主从用它：用户实报窗格之间那条竖线多余。
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth < minSplitWidth) return primary;

        final double resolvedSupportingWidth =
            supportingWidth ??
            supportingPaneWidthForLayout(constraints.maxWidth);
        final Color resolvedDividerColor =
            dividerColor ?? Theme.of(context).dividerColor;
        final Widget? divider = showDivider
            ? FushiVerticalDivider(
                width: 1,
                thickness: 1,
                color: resolvedDividerColor,
              )
            : null;
        final Widget fixedSupporting = SizedBox(
          width: resolvedSupportingWidth,
          child: supporting,
        );
        final Widget flexiblePrimary = Expanded(child: primary);

        return Row(
          // stretch (not the Row default center) so each pane gets a tight,
          // full-height constraint. Under center the panes receive a LOOSE
          // height, so a detail pane built from an own-scrolling
          // SingleChildScrollView shrink-wraps to its content and is then
          // vertically centered — a short settings page (e.g. the audiobook
          // destination with only a couple of desktop-visible toggles) floated
          // to the middle instead of hugging the top. A tight height makes the
          // scroll view fill the pane, so its content stays top-aligned.
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: supportingSide == SupportingPaneSide.start
              ? <Widget>[
                  fixedSupporting,
                  if (divider != null) divider,
                  flexiblePrimary,
                ]
              : <Widget>[
                  flexiblePrimary,
                  if (divider != null) divider,
                  fixedSupporting,
                ],
        );
      },
    );
  }
}
