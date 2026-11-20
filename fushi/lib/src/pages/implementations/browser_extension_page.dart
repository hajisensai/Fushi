import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/lookup/browser_default_detector.dart';
import 'package:fushi/src/lookup/browser_extension_installer.dart';
import 'package:fushi/src/lookup/browser_extension_setup.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart'
    show BrowserExtensionInstallFlow, browserExtensionInstallFlowOn;
import 'package:fushi/src/settings/settings_kit_core.dart';
import 'package:fushi/src/sync/fushi_api_server.dart' show kFushiApiDefaultPort;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show isEinkTheme, isGlassDesign;
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptiveSegmentedButton;
import 'package:fushi/src/utils/adaptive/shell_style.dart'
    show shellRedesignActive;
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart'
    show
        FushiCoverBlockColors,
        FushiCoverBlockSize,
        fushiCoverBlockRadius,
        fushiCoverBlockShape;
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiFloatingChromeInset;
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_masthead_scaffold.dart'
    show FushiMastheadScaffold;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/reveal_in_file_manager.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_neutral_decor.dart'
    show FushiStatusTone, fushiStatusColor;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:url_launcher/url_launcher.dart';

/// 探测默认浏览器的注入点（测试里换成同步返回，避免真起 `reg` / `defaults`）。
typedef BrowserKindDetector = Future<BrowserKind?> Function();

// 色块色相（拼贴改版同一套 `FushiCoverBlockColors.fromHue` 语言：只给色相，
// 饱和度 / 亮度由色块钉死，深浅主题都可读；墨水屏一律回落中性色）。
/// 「开始」态：查词模块色（靛蓝）——首装是正常状态，不是错误。
const double _kHueSetup = 229;

/// 已连接：绿。
const double _kHueConnected = 140;

/// 检测过但没连上 / 版本不一致：琥珀（提醒，不是故障）。
const double _kHueAttention = 45;

/// 连过、现在断了：红（真正的异常）。
const double _kHueLost = 4;

/// 「试一试」块：青（视频 / 网页那一侧的色）。
const double _kHueTry = 196.2;

/// 「浏览器扩展」页（「浏览器」模块的子页；桌面与安卓有，判据 [browserExtensionInstallFlowOn]）。
///
/// 把原来埋在「设置 → 查词」里的安装入口独立成页，并在原「半自动安装引导」之上补：
/// ① 服务 + 连接状态卡；② 加载扩展后「验证插件已正常启用」的连接检测（扩展 SW 启动时
/// 主动打 `/api/extension/status`，server 刷新 last-seen，这里据此判断已连上）；
/// ③ 扩展版本（内容指纹）与「重新准备/刷新」。自建 MV3 无真·一键（浏览器封侧载），故仍为
/// 半自动引导；但 host/port/token 已由安装助手自动写入扩展，用户无需手填。
///
/// 2026-11-16 拼贴改版：顶部状态是一整块色块（[_StatusBlock]）——首装是靛蓝「开始」
/// 态，检测没连上是琥珀，连过又断了才是红，已连接是绿并把「打开试用网页」提成主动作；
/// 色块下沿是前置条件清单（查词服务 / 默认浏览器 / 扩展连接，各自 ✓ / ✗ 与就地修复）。
/// 安装引导是分步卡（当前展开步骤是高亮大卡、已完成步打勾收成一行、未来步骤淡化，
/// 顶部五段进度条），第 1 步浏览器用设计系统分段组件，地址 / 路径是可复制的代码块。
/// 右栏「试一试」色块（未连接时）与「内置 vs 已加载」版本对比卡（不一致时转琥珀）。
/// 宽屏两栏、窄屏单栏，错峰进场。
class BrowserExtensionPage extends ConsumerStatefulWidget {
  const BrowserExtensionPage({
    super.key,
    this.detectBrowser = detectDefaultBrowserKind,
    this.hostedByHub = false,
  });

  /// 默认浏览器探测（预选第 1 步的浏览器分段 + 状态清单里的「默认浏览器」）。
  final BrowserKindDetector detectBrowser;

  /// 作「浏览器」模块的子页时（[WebHubPage]）为 true：「标题胶囊 + 子页页签」
  /// 那一行由宿主统一画、叠在本页上，本页不画页头，正文让出宿主工具栏的高度
  /// （[FushiFloatingChromeInset]）。false = 独立页（从「设置 › 查词」/ 引导
  /// push 进来），页头画本页标题与返回键。
  final bool hostedByHub;

  @override
  ConsumerState<BrowserExtensionPage> createState() =>
      _BrowserExtensionPageState();
}

class _BrowserExtensionPageState extends ConsumerState<BrowserExtensionPage> {
  /// 解压出的扩展目录绝对路径（已复制到剪贴板）；null 表示尚未准备。
  String? _extensionDir;
  bool _preparing = false;

  // 准备时的一次性快照，驱动引导横幅文案（成功 / 先开 server / 端口冲突）。
  bool _serverEnabled = false;
  bool _hasToken = false;
  int _serverPort = kFushiApiDefaultPort;
  bool _portConflict = false;

  // 连接检测（验证插件已正常启用）状态。
  bool _verifying = false;
  bool? _verifyConnected;

  /// 状态清单里「开启查词服务」进行中。
  bool _enablingServer = false;

  /// 探测到的系统默认浏览器（受支持的 Chromium 系才有值）。
  BrowserKind? _detectedBrowser;

  /// 安装引导是否展开；null = 跟随连接状态（已连接折叠、未连接展开）。
  bool? _guideExpanded;

  // 连接状态卡片的轻量刷新（扩展 last-seen 由 server 端异步更新，这里定时重绘显示）。
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    _statusTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) setState(() {});
    });
    unawaited(
      widget.detectBrowser().then((BrowserKind? kind) {
        if (!mounted || kind == null) return;
        setState(() => _detectedBrowser = kind);
      }),
    );
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(FushiSnackBar(content: Text(message)));
  }

  /// 时间窗见 [kBrowserExtensionSeenWindow]（与控制通道同一判据）。
  bool _isRecentlySeen(AppModel appModel) =>
      isBrowserExtensionRecentlySeen(appModel.browserExtensionLastSeenAt);

  /// 准备扩展：幂等开启 yomitan-api server（token 为空才播种、绝不覆盖）→ 用当前 server
  /// 真值解压扩展到本机 → 路径复制剪贴板。与原设置里的安装动作同一流程，仅换到页面里。
  Future<void> _prepare() async {
    if (_preparing) return;
    final AppModel appModel = ref.read(appProvider);
    setState(() => _preparing = true);
    // 开 server + 解压扩展与控制通道共用（browser_extension_setup.dart）。
    final BrowserExtensionPrepareResult result =
        await prepareBrowserExtensionForInstall(appModel);
    await Clipboard.setData(ClipboardData(text: result.directory));
    if (!mounted) return;
    setState(() {
      _preparing = false;
      _extensionDir = result.directory;
      _serverEnabled = result.serverEnabled;
      _hasToken = result.hasToken;
      _serverPort = result.port;
      _portConflict = result.portConflict;
      _verifyConnected = null;
    });
    _snack(t.copied);
  }

  /// 状态清单的「开启查词服务」：与「准备扩展」同一个幂等入口（token 为空才播种、
  /// 已启用不重启），只是不解压扩展。端口被占时按准备流程同一口径提示。
  Future<void> _enableServer() async {
    if (_enablingServer) return;
    final AppModel appModel = ref.read(appProvider);
    setState(() => _enablingServer = true);
    final bool ready = await appModel.ensureFushiApiServerForBrowserExtension();
    if (!mounted) return;
    setState(() => _enablingServer = false);
    if (!ready) _snack(_portInUseMessage(appModel.fushiApiPort));
  }

  /// 验证插件已正常启用：加载/重新加载扩展后，其 SW 会主动打本机 server，刷新 last-seen。
  /// 这里点一下后短轮询若干秒，检测到近期活跃即判定已连接。
  Future<void> _verify() async {
    setState(() {
      _verifying = true;
      _verifyConnected = null;
    });
    final AppModel appModel = ref.read(appProvider);
    final bool connected = await waitForBrowserExtensionConnection(
      lastSeen: () => appModel.browserExtensionLastSeenAt,
      cancelled: () => !mounted,
    );
    if (!mounted) return;
    setState(() {
      _verifying = false;
      _verifyConnected = connected;
    });
  }

  Future<void> _openTestPage() async {
    final AppModel appModel = ref.read(appProvider);
    await launchUrl(
      Uri.parse(appModel.browserExtensionTestPageUrl),
      mode: LaunchMode.externalApplication,
    );
  }

  /// 版本不一致时「打开扩展管理页」：默认浏览器优先，没探测到就取枚举首项。
  Future<void> _openExtensionsPage() async {
    final bool opened = await tryOpenBrowserExtensionsPage(
      _detectedBrowser ?? BrowserKind.values.first,
    );
    if (!opened) _snack(t.browser_extension_open_page_failed);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppModel appModel = ref.watch(appProvider);

    // 重设计外壳（墨水屏除外）下独立成页时换成页头大字（返回键按本页路由判，
    // 同下方「首个路由不出箭头」口径）；被 hub 托管时页头归 hub，照旧。
    if (!widget.hostedByHub && shellRedesignActive(context)) {
      return FushiMastheadScaffold(
        title: t.nav_browser_extension,
        body: _buildBody(theme, appModel, masthead: true),
      );
    }

    // BUG-1658：顶层各 tab 页头统一为 FushiPageHeader 大标题（全出血 + 自身
    // spacing.page 内边距，与书架/视频/游戏/查词/下载同一几何），不再用旧 AppBar
    // 小标题工具栏。M3E 下 FushiPageHeader 本身就是浮动胶囊页头。
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 本页是双身份页：作顶层 tab 时侧栏在旁边、本页就是首个路由，不出箭头
          // （页头几何与 BUG-1658 结论一致）；被「设置 → 查词 → 浏览器扩展」
          // push 成全屏路由时侧栏被盖住，这里承接返回键（同 BrowsePage 范式）。
          //
          // 判据是**本页自己所在的 PageRoute 是不是首个**，不是 `Navigator.canPop()`：
          // 本页的下拉框会临时 push 一个 PopupRoute，canPop() 会因此变成 true，
          // 于是每开一次下拉都闪出一个返回箭头。
          if (!widget.hostedByHub)
            FushiPageHeader(
              title: t.nav_browser_extension,
              leading: ModalRoute.of(context)?.isFirst == false
                  ? FushiIconButton(
                      icon: Icons.arrow_back,
                      tooltip: t.back,
                      onTap: () => Navigator.of(context).maybePop(),
                    )
                  : null,
            ),
          Expanded(child: _buildBody(theme, appModel)),
        ],
      ),
    );
  }

  /// [masthead]：正文铺在页头大字底下，列表顶部再让出页头下沿
  /// （`MediaQuery.paddingOf(context).top`）。
  Widget _buildBody(
    ThemeData theme,
    AppModel appModel, {
    bool masthead = false,
  }) {
    final bool serverOn = appModel.fushiApiServerEnabled;
    final bool connected = _isRecentlySeen(appModel);
    final String? build = appModel.browserExtensionBuild;
    final bool guideExpanded = _guideExpanded ?? !connected;
    final double page = FushiDesignTokens.of(context).spacing.page;
    // 宿主 hub 的工具栏行叠在本页上：正文顶部让出它（独立页时为 0）。
    final double chromeTop = FushiFloatingChromeInset.of(context) + 8;
    final _LinkState link = connected
        ? _LinkState.connected
        : appModel.browserExtensionLastSeenAt != null
        ? _LinkState.lost
        : _verifyConnected == false
        ? _LinkState.notDetected
        : _LinkState.setup;

    final Widget hero = ValueListenableBuilder<String?>(
      valueListenable: appModel.browserExtensionReportedBuild,
      builder: (BuildContext context, String? reported, Widget? _) {
        return _StatusBlock(
          link: link,
          serverOn: serverOn,
          port: appModel.fushiApiPort,
          detectedBrowser: _detectedBrowser,
          verifying: _verifying,
          verifyResult: _verifyConnected,
          onVerify: _verifying ? null : _verify,
          enablingServer: _enablingServer,
          onEnableServer: _enablingServer ? null : _enableServer,
          onOpenTestPage: serverOn ? _openTestPage : null,
        );
      },
    );
    final Widget guide = _buildGuide(
      connected: connected,
      expanded: guideExpanded,
    );
    // 已连接时「打开试用网页」已是状态块的主动作，右栏不再重复一块。
    final Widget? tryIt = connected
        ? null
        : _TryItBlock(serverOn: serverOn, onOpen: _openTestPage);
    final Widget version = _versionCard(appModel, build);

    Widget entrance(int index, Widget child) =>
        FushiStaggeredEntrance(index: index, child: child);
    const double gap = 16;

    return FushiEntranceScope(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // 两栏阈值：左栏要容得下状态块的「标题 + 主动作」一行与三格清单，
          // 右栏至少一张色块宽。
          final bool wide = constraints.maxWidth >= 920;
          final double top =
              chromeTop + (masthead ? MediaQuery.paddingOf(context).top : 0);
          if (!wide) {
            return ListView(
              padding: EdgeInsets.fromLTRB(page, top, page, 32),
              children: <Widget>[
                entrance(0, hero),
                const SizedBox(height: gap),
                entrance(1, guide),
                if (tryIt != null) ...<Widget>[
                  const SizedBox(height: gap),
                  entrance(2, tryIt),
                ],
                const SizedBox(height: gap),
                entrance(3, version),
              ],
            );
          }
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(page, top, page, 32),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1320),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      flex: 3,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          entrance(0, hero),
                          const SizedBox(height: gap),
                          entrance(1, guide),
                        ],
                      ),
                    ),
                    const SizedBox(width: 24),
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          if (tryIt != null) ...<Widget>[
                            entrance(2, tryIt),
                            const SizedBox(height: gap),
                          ],
                          entrance(3, version),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 安装引导：展开 = 分步卡；折叠 = 一行「重新安装 / 更新扩展」入口卡。
  /// 两态之间尺寸弹簧过渡 + 交叉淡化。
  Widget _buildGuide({required bool connected, required bool expanded}) {
    final Duration d = fushiMotionDuration(context, FushiMotion.long);
    final Widget child = expanded
        ? KeyedSubtree(
            key: const ValueKey<String>('browser-extension-guide-open'),
            child: BrowserExtensionInstallSteps(
              path: _extensionDir,
              serverEnabled: _serverEnabled,
              hasToken: _hasToken,
              serverPort: _serverPort,
              portConflict: _portConflict,
              detectedBrowser: _detectedBrowser,
              preparing: _preparing,
              onPrepare: _preparing ? null : _prepare,
              verifying: _verifying,
              onVerify: _verifying ? null : _verify,
              onCollapse: connected
                  ? () => setState(() => _guideExpanded = false)
                  : null,
            ),
          )
        : KeyedSubtree(
            key: const ValueKey<String>('browser-extension-guide-collapsed'),
            child: _reinstallEntry(),
          );
    return FushiAnimatedSize(
      duration: d,
      curve: FushiMotion.standard,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: d,
        reverseDuration: fushiMotionDuration(context, FushiMotion.longReverse),
        switchInCurve: FushiMotion.enter,
        switchOutCurve: FushiMotion.exit,
        layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
          alignment: Alignment.topCenter,
          children: <Widget>[...previous, if (current != null) current],
        ),
        child: child,
      ),
    );
  }

  /// 已连接时折叠出的引导入口（整卡可点 / 可聚焦，Enter 展开）。
  Widget _reinstallEntry() {
    final ThemeData theme = Theme.of(context);
    return FushiCard(
      onTap: () => setState(() => _guideExpanded = true),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      child: Row(
        children: <Widget>[
          const FushiListLeadingIcon(FushiIcons.restart),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  t.browser_extension_guide_reinstall,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  t.browser_extension_guide_reinstall_hint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          FushiIcon(
            FushiIcons.expandMore,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }

  /// 版本卡（BUG-1079 扩展为双行）：app 内置指纹 + 扩展自报的「浏览器中实际加载」指纹；
  /// 两者都有且不一致时整卡转琥珀并给出指引（扩展自更新未生效，需手动到扩展管理页
  /// 重新加载）。浏览器侧指纹经 [AppModel.browserExtensionReportedBuild]
  /// （ValueNotifier）实时驱动。
  Widget _versionCard(AppModel appModel, String? build) {
    return ValueListenableBuilder<String?>(
      valueListenable: appModel.browserExtensionReportedBuild,
      builder: (BuildContext context, String? reported, Widget? _) {
        final bool mismatch =
            build != null && reported != null && build != reported;
        return _VersionBlock(
          bundled: build,
          loaded: reported,
          mismatch: mismatch,
          onOpenExtensionsPage: _openExtensionsPage,
        );
      },
    );
  }
}

/// 端口被占的提示：默认端口（19633）通常是 Yomitan 的 yomitan-api 组件，给专项修复路径。
String _portInUseMessage(int port) => port == kFushiApiDefaultPort
    ? t.browser_extension_yomitan_port_conflict(port: port)
    : t.sync_server_port_in_use(port: port);

/// 色块配色：墨水屏回落中性，其余按色相派生（拼贴同一套）。
FushiCoverBlockColors _blockColors(BuildContext context, double hue) {
  final ThemeData theme = Theme.of(context);
  if (isEinkTheme(context)) return FushiCoverBlockColors.resolve(theme, null);
  return FushiCoverBlockColors.fromHue(theme, hue);
}

/// 色块里的主按钮：反色（块的前景色作底、块底色作字），任何色相上都够对比。
ButtonStyle _inverseButtonStyle(FushiCoverBlockColors colors) =>
    FilledButton.styleFrom(
      backgroundColor: colors.onContainer,
      foregroundColor: colors.container,
      disabledBackgroundColor: colors.onContainer.withValues(alpha: 0.18),
      disabledForegroundColor: colors.onContainer.withValues(alpha: 0.5),
    );

/// 块内 glyph 的外形：MD3 是 M3E 多边形，Apple 是圆角方块（同导入面色块）。
ShapeBorder _glyphShape(
  BuildContext context,
  RoundedPolygon shape,
  double size,
) {
  if (isGlassDesign(context)) {
    return RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(size * 0.3),
    );
  }
  return MaterialShapeBorder(shape: shape);
}

/// 两行按钮的转圈占位（检测中 / 开启中 / 准备中）。
Widget _busyIcon() => const SizedBox(
  width: 16,
  height: 16,
  child: FushiCircularProgressIndicator(strokeWidth: 2),
);

// -----------------------------------------------------------------------------
// 状态块
// -----------------------------------------------------------------------------

/// 扩展连接的四种页面态。
enum _LinkState {
  /// 本次会话从没见过扩展、也没检测失败：首装的正常「开始」态。
  setup,

  /// 点过「检测连接」但没等到扩展。
  notDetected,

  /// 本次会话连上过、现在超出心跳窗口：真正的异常。
  lost,

  /// 心跳窗口内见过扩展。
  connected,
}

/// 顶部状态色块：glyph + 标题 + 一句指引 + 主动作，下沿是前置条件清单。
/// 底色按 [_LinkState] 换色相（AnimatedContainer 过渡），glyph 随状态弹簧转动变形。
class _StatusBlock extends StatelessWidget {
  const _StatusBlock({
    required this.link,
    required this.serverOn,
    required this.port,
    required this.detectedBrowser,
    required this.verifying,
    required this.verifyResult,
    required this.onVerify,
    required this.enablingServer,
    required this.onEnableServer,
    required this.onOpenTestPage,
  });

  final _LinkState link;
  final bool serverOn;
  final int port;
  final BrowserKind? detectedBrowser;
  final bool verifying;
  final bool? verifyResult;
  final VoidCallback? onVerify;
  final bool enablingServer;
  final VoidCallback? onEnableServer;
  final VoidCallback? onOpenTestPage;

  double get _hue => switch (link) {
    _LinkState.setup => _kHueSetup,
    _LinkState.notDetected => _kHueAttention,
    _LinkState.lost => _kHueLost,
    _LinkState.connected => _kHueConnected,
  };

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiCoverBlockColors colors = _blockColors(context, _hue);
    final Color fg = colors.onContainer;
    final bool connected = link == _LinkState.connected;
    final String title = switch (link) {
      _LinkState.setup => t.browser_extension_status_setup,
      _LinkState.notDetected => t.browser_extension_status_never,
      _LinkState.lost => t.browser_extension_status_lost,
      _LinkState.connected => t.browser_extension_status_connected,
    };
    final String hint = switch (link) {
      _LinkState.connected => t.browser_extension_hero_connected_hint,
      _LinkState.lost => t.browser_extension_hero_lost_hint,
      _ => t.browser_extension_hero_setup_hint,
    };

    final Widget verifyLabel = Text(
      verifying
          ? t.browser_extension_verify_checking
          : t.browser_extension_verify_button,
    );
    final Widget verifyIcon = verifying
        ? _busyIcon()
        : const FushiIcon(FushiIcons.wifi, size: 18);
    // 已连接：主动作换成「打开试用网页」，检测连接退成文字按钮。
    final List<Widget> actions = connected
        ? <Widget>[
            FushiFilledButton.icon(
              style: _inverseButtonStyle(colors),
              onPressed: onOpenTestPage,
              icon: const FushiIcon(FushiIcons.openInNew, size: 18),
              label: Text(t.browser_extension_test_page_action),
            ),
            FushiTextButton.icon(
              style: TextButton.styleFrom(foregroundColor: fg),
              onPressed: onVerify,
              icon: verifyIcon,
              label: verifyLabel,
            ),
          ]
        : <Widget>[
            FushiFilledButton.icon(
              style: _inverseButtonStyle(colors),
              onPressed: onVerify,
              icon: verifyIcon,
              label: verifyLabel,
            ),
          ];

    final Widget texts = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AnimatedSwitcher(
          duration: fushiMotionDuration(context, FushiMotion.medium),
          switchInCurve: FushiMotion.enter,
          switchOutCurve: FushiMotion.exit,
          layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
            alignment: AlignmentDirectional.centerStart,
            children: <Widget>[...previous, if (current != null) current],
          ),
          child: Text(
            title,
            key: ValueKey<String>(title),
            style: theme.textTheme.headlineSmall?.copyWith(
              color: fg,
              fontWeight: FontWeight.w800,
              height: 1.2,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          hint,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: fg.withValues(alpha: 0.85),
            height: 1.45,
          ),
        ),
      ],
    );

    final _CheckMark extensionMark = switch (link) {
      _LinkState.connected => _CheckMark.ok,
      _LinkState.lost => _CheckMark.fail,
      _ => _CheckMark.pending,
    };
    // [actionBelow]：块太窄放不下行尾动作钮时折到文字下面（见 [_CheckTile]）。
    List<Widget> buildChecks({required bool actionBelow}) => <Widget>[
      _CheckTile(
        colors: colors,
        actionBelow: actionBelow,
        mark: serverOn ? _CheckMark.ok : _CheckMark.fail,
        icon: serverOn ? FushiIcons.cloud : FushiIcons.cloudOff,
        label: t.browser_extension_check_server,
        value: serverOn
            ? t.browser_extension_port_label(port: port)
            : t.browser_extension_check_server_off,
        action: serverOn
            ? null
            : FushiFilledButton(
                style: _inverseButtonStyle(colors),
                onPressed: onEnableServer,
                child: enablingServer
                    ? _busyIcon()
                    : Text(t.browser_extension_check_server_enable),
              ),
      ),
      // 「默认浏览器」只在桌面有意义（探测只认桌面系统的默认浏览器；安卓的安装引导
      // 固定推荐 Vivaldi，见 [BrowserExtensionInstallFlow.android]）。
      if (_currentInstallFlow() == BrowserExtensionInstallFlow.desktop)
        _CheckTile(
          colors: colors,
          mark: detectedBrowser != null ? _CheckMark.ok : _CheckMark.pending,
          icon: FushiIcons.globe,
          label: t.browser_extension_browser_default,
          value: detectedBrowser != null
              ? browserDisplayName(detectedBrowser!)
              : t.browser_extension_check_browser_unknown,
        ),
      _CheckTile(
        colors: colors,
        mark: extensionMark,
        icon: FushiIcons.browserExtension,
        label: t.browser_extension_check_extension,
        value: switch (link) {
          _LinkState.connected => t.browser_extension_check_extension_connected,
          _LinkState.lost => t.browser_extension_check_extension_lost,
          _ => t.browser_extension_check_extension_waiting,
        },
      ),
    ];

    // 检测结果：只在检测过之后出现一行（语义靠图标）。
    final bool? result = verifyResult;
    final Widget resultLine = result == null
        ? const SizedBox(width: double.infinity)
        : Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                FushiIcon(
                  result ? FushiIcons.success : FushiIcons.error,
                  size: 18,
                  color: fg,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    result
                        ? t.browser_extension_verify_connected
                        : t.browser_extension_verify_not_detected,
                    style: theme.textTheme.bodyMedium?.copyWith(color: fg),
                  ),
                ),
              ],
            ),
          );

    return AnimatedContainer(
      duration: fushiMotionDuration(context, FushiMotion.long),
      curve: FushiMotion.standard,
      decoration: ShapeDecoration(
        color: colors.container,
        shape: fushiCoverBlockShape(context, FushiCoverBlockSize.regular),
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool narrow = constraints.maxWidth < 560;
          final double pad = narrow ? 20 : 26;
          // 宽版三块并排：每块宽 = (内容宽 − 两道 8 的缝) / 3。
          final double tileWidth = narrow
              ? constraints.maxWidth - pad * 2
              : (constraints.maxWidth - pad * 2 - 16) / 3;
          final List<Widget> checks = buildChecks(
            actionBelow: tileWidth < _kCheckTileInlineActionMinWidth,
          );
          final Widget glyph = _StatusGlyph(
            link: link,
            colors: colors,
            size: narrow ? 52 : 68,
          );
          final Widget actionBar = Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: actions,
          );
          return Padding(
            padding: EdgeInsets.all(pad),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  crossAxisAlignment: narrow
                      ? CrossAxisAlignment.start
                      : CrossAxisAlignment.center,
                  children: <Widget>[
                    glyph,
                    SizedBox(width: narrow ? 14 : 20),
                    Expanded(child: texts),
                    if (!narrow) ...<Widget>[
                      const SizedBox(width: 16),
                      actionBar,
                    ],
                  ],
                ),
                if (narrow) ...<Widget>[const SizedBox(height: 16), actionBar],
                SizedBox(height: narrow ? 16 : 22),
                if (narrow)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (int i = 0; i < checks.length; i++) ...<Widget>[
                        if (i > 0) const SizedBox(height: 6),
                        checks[i],
                      ],
                    ],
                  )
                else
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        for (int i = 0; i < checks.length; i++) ...<Widget>[
                          if (i > 0) const SizedBox(width: 8),
                          Expanded(child: checks[i]),
                        ],
                      ],
                    ),
                  ),
                FushiAnimatedSize(
                  duration: fushiMotionDuration(context, FushiMotion.medium),
                  curve: FushiMotion.standard,
                  alignment: Alignment.topCenter,
                  child: resultLine,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 状态块左侧 glyph：底是块的前景色、图标是块的底色（拼贴 glyph 同一画法）。
/// MD3 每个状态一个 M3E 多边形，状态切换时弹簧转一下并轻微放大，读作「变形」；
/// Apple 是圆角方块里的 SF 式符号交叉淡入。
class _StatusGlyph extends StatelessWidget {
  const _StatusGlyph({
    required this.link,
    required this.colors,
    required this.size,
  });

  final _LinkState link;
  final FushiCoverBlockColors colors;
  final double size;

  @override
  Widget build(BuildContext context) {
    final IconData icon = switch (link) {
      _LinkState.setup => FushiIcons.browserExtension,
      _LinkState.notDetected => FushiIcons.warning,
      _LinkState.lost => FushiIcons.linkOff,
      _LinkState.connected => FushiIcons.check,
    };
    final RoundedPolygon shape = switch (link) {
      _LinkState.setup => MaterialShapes.cookie9Sided,
      _LinkState.notDetected => MaterialShapes.cookie4Sided,
      _LinkState.lost => MaterialShapes.softBurst,
      _LinkState.connected => MaterialShapes.sunny,
    };
    final Widget face = AnimatedContainer(
      duration: fushiMotionDuration(context, FushiMotion.medium),
      curve: FushiMotion.standard,
      width: size,
      height: size,
      decoration: ShapeDecoration(
        color: colors.onContainer,
        shape: _glyphShape(context, shape, size),
      ),
      child: Center(
        child: AnimatedSwitcher(
          duration: fushiMotionDuration(context, FushiMotion.short),
          child: FushiIcon(
            icon,
            key: ValueKey<_LinkState>(link),
            size: size * 0.46,
            color: colors.container,
          ),
        ),
      ),
    );
    if (isGlassDesign(context)) return face;
    return SettingsSpringValue(
      value: link.index.toDouble(),
      builder: (BuildContext context, double t, Widget? child) {
        final double pulse = (t - t.roundToDouble()).abs();
        final double angle = t * math.pi / 4;
        return Transform.rotate(
          angle: angle,
          child: Transform.scale(
            scale: 1 + pulse * 0.3,
            child: Transform.rotate(angle: -angle * 0.85, child: child),
          ),
        );
      },
      child: face,
    );
  }
}

enum _CheckMark { ok, fail, pending }

/// 前置条件小卡：✓ / ✗ / 待定标记 + 名称 + 当前值，可带就地修复动作。
/// 底是块前景色的薄层（墨水屏改描边），跟着色块换色。
class _CheckTile extends StatelessWidget {
  const _CheckTile({
    required this.colors,
    required this.mark,
    required this.icon,
    required this.label,
    required this.value,
    this.action,
    this.actionBelow = false,
  });

  final FushiCoverBlockColors colors;
  final _CheckMark mark;
  final IconData icon;
  final String label;
  final String value;
  final Widget? action;

  /// 动作钮折到文字下面（块宽不足 [_kCheckTileInlineActionMinWidth] 时）：行尾
  /// 放一颗「开启服务」会把文字列挤到十来像素，连小图标都放不下。
  final bool actionBelow;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SettingsKitStyle style = SettingsKitStyle.of(context);
    final bool eink = isEinkTheme(context);
    final Color fg = colors.onContainer;
    final Duration d = fushiMotionDuration(context, FushiMotion.medium);
    final bool ok = mark == _CheckMark.ok;
    final Widget badge = AnimatedContainer(
      duration: d,
      curve: FushiMotion.standard,
      width: 22,
      height: 22,
      decoration: ShapeDecoration(
        color: ok ? fg : fg.withValues(alpha: 0),
        shape: CircleBorder(
          side: ok
              ? BorderSide.none
              : BorderSide(color: fg.withValues(alpha: 0.55), width: 1.5),
        ),
      ),
      child: Center(
        child: switch (mark) {
          _CheckMark.ok => FushiIcon(
            FushiIcons.check,
            size: 15,
            color: colors.container,
          ),
          _CheckMark.fail => FushiIcon(
            FushiIcons.close,
            size: 14,
            color: fg.withValues(alpha: 0.8),
          ),
          _CheckMark.pending => FushiIcon(
            FushiIcons.remove,
            size: 14,
            color: fg.withValues(alpha: 0.6),
          ),
        },
      ),
    );
    return AnimatedContainer(
      duration: d,
      curve: FushiMotion.standard,
      padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 10, 10),
      decoration: ShapeDecoration(
        color: fg.withValues(alpha: eink ? 0 : (ok ? 0.07 : 0.12)),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(SettingsKitRadii.small(style)),
          side: eink ? BorderSide(color: fg) : BorderSide.none,
        ),
      ),
      child: Row(
        children: <Widget>[
          badge,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    FushiIcon(icon, size: 14, color: fg.withValues(alpha: 0.7)),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: fg.withValues(alpha: 0.75),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (action != null && actionBelow) ...<Widget>[
                  const SizedBox(height: 8),
                  action!,
                ],
              ],
            ),
          ),
          if (action != null && !actionBelow) ...<Widget>[
            const SizedBox(width: 8),
            action!,
          ],
        ],
      ),
    );
  }
}

/// [_CheckTile] 行尾放得下动作钮的最小块宽：小于它时动作钮折到文字下面。
const double _kCheckTileInlineActionMinWidth = 280;

// -----------------------------------------------------------------------------
// 右栏：试一试 / 版本
// -----------------------------------------------------------------------------

/// 「试一试」色块：在真网页上试一遍基础功能（未连接时显示；连上后主动作并进状态块）。
///
/// 页面由本机 yomitan-api server 提供（`/onboarding/extension-test`）——必须是 http：
/// Chrome 默认不给扩展 `file://` 权限，本地 HTML 文件证明不了插件是否活着。server 没开
/// 时整块转中性、按钮禁用（URL 打开就是连接失败），提示先开服务器。
class _TryItBlock extends StatelessWidget {
  const _TryItBlock({required this.serverOn, required this.onOpen});

  final bool serverOn;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiCoverBlockColors colors = serverOn
        ? _blockColors(context, _kHueTry)
        : FushiCoverBlockColors.resolve(theme, null);
    const double minHeight = 200;
    const double glyphSize = 56;
    return FushiHoverLift(
      enabled: serverOn,
      builder: (BuildContext context, bool hovering) => FushiCard(
        onTap: serverOn ? onOpen : null,
        color: colors.container,
        shape: fushiCoverBlockShape(context, FushiCoverBlockSize.regular),
        borderRadius: BorderRadius.circular(
          fushiCoverBlockRadius(FushiCoverBlockSize.regular, minHeight),
        ),
        padding: const EdgeInsets.all(22),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: minHeight - 44),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AnimatedRotation(
                turns: hovering && fushiMotionEnabled(context) ? -10 / 360 : 0,
                duration: fushiMotionDuration(context, FushiMotion.medium),
                curve: FushiMotion.standard,
                child: SizedBox.square(
                  dimension: glyphSize,
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      color: colors.onContainer,
                      shape: _glyphShape(
                        context,
                        MaterialShapes.clover4Leaf,
                        glyphSize,
                      ),
                    ),
                    child: Center(
                      child: FushiIcon(
                        FushiIcons.travelExplore,
                        size: 28,
                        color: colors.container,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                t.browser_extension_test_page_title,
                style: theme.textTheme.titleLarge?.copyWith(
                  color: colors.onContainer,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                serverOn
                    ? t.browser_extension_test_page_action_desc
                    : t.browser_extension_test_page_server_off,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onContainer.withValues(alpha: 0.85),
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 18),
              FushiFilledButton.icon(
                style: _inverseButtonStyle(colors),
                onPressed: serverOn ? onOpen : null,
                icon: const FushiIcon(FushiIcons.openInNew, size: 18),
                label: Text(t.browser_extension_test_page_action),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 版本对比卡：「App 内置」与「浏览器中加载」两格并排，中间一枚 = / ≠ 标记；
/// 一致时右上角「已是最新」，不一致时整卡转琥珀色块、给出重新加载指引与
/// 「打开扩展管理页」。浏览器还没自报版本（旧扩展 / 未连接）时不判定。
class _VersionBlock extends StatelessWidget {
  const _VersionBlock({
    required this.bundled,
    required this.loaded,
    required this.mismatch,
    required this.onOpenExtensionsPage,
  });

  final String? bundled;
  final String? loaded;
  final bool mismatch;
  final VoidCallback onOpenExtensionsPage;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final FushiCoverBlockColors? warn = mismatch
        ? _blockColors(context, _kHueAttention)
        : null;
    final Color fg = warn?.onContainer ?? scheme.onSurface;
    final Color muted =
        warn?.onContainer.withValues(alpha: 0.75) ?? scheme.onSurfaceVariant;
    final bool matched = bundled != null && loaded != null && !mismatch;
    final Duration d = fushiMotionDuration(context, FushiMotion.medium);

    final Widget? status = mismatch
        ? _StatusPill(
            icon: FushiIcons.refresh,
            label: t.browser_extension_version_reload_title,
            color: fg,
          )
        : matched
        ? _StatusPill(
            icon: FushiIcons.success,
            label: t.browser_extension_version_match,
            color: fushiStatusColor(context, FushiStatusTone.success),
          )
        : null;

    Widget cell(String label, String? value) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelMedium?.copyWith(color: muted),
        ),
        const SizedBox(height: 4),
        SelectableText(
          value ?? '—',
          maxLines: 1,
          style: theme.textTheme.titleSmall?.copyWith(
            fontFamily: 'monospace',
            fontWeight: FontWeight.w600,
            color: value == null ? muted : fg,
          ),
        ),
      ],
    );

    final Widget compare = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Widget app = cell(t.browser_extension_version_app, bundled);
        final Widget browser = cell(
          t.browser_extension_version_browser,
          loaded,
        );
        final Widget sign = AnimatedContainer(
          duration: d,
          curve: FushiMotion.standard,
          width: 30,
          height: 30,
          decoration: ShapeDecoration(
            color: fg.withValues(alpha: mismatch ? 0.16 : 0.08),
            shape: const CircleBorder(),
          ),
          child: Center(
            child: Text(
              mismatch ? '≠' : '=',
              style: theme.textTheme.titleMedium?.copyWith(
                color: fg,
                fontWeight: FontWeight.w800,
                height: 1,
              ),
            ),
          ),
        );
        if (constraints.maxWidth < 340) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[app, const SizedBox(height: 10), browser],
          );
        }
        return Row(
          children: <Widget>[
            Expanded(child: app),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: sign,
            ),
            Expanded(child: browser),
          ],
        );
      },
    );

    final Widget body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            FushiIcon(FushiIcons.browserExtension, size: 20, color: muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                t.browser_extension_version_label,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (status != null) status,
          ],
        ),
        const SizedBox(height: 16),
        compare,
        FushiAnimatedSize(
          duration: d,
          curve: FushiMotion.standard,
          alignment: Alignment.topCenter,
          child: mismatch
              ? Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        t.browser_extension_version_mismatch,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: fg,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 12),
                      FushiFilledButton.icon(
                        style: _inverseButtonStyle(warn!),
                        onPressed: onOpenExtensionsPage,
                        icon: const FushiIcon(FushiIcons.openInNew, size: 18),
                        label: Text(
                          _stripTrailingColon(
                            t.browser_extension_step_open_page,
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );

    if (warn == null) {
      return FushiCard(padding: const EdgeInsets.all(20), child: body);
    }
    return AnimatedContainer(
      duration: d,
      curve: FushiMotion.standard,
      padding: const EdgeInsets.all(20),
      decoration: ShapeDecoration(
        color: warn.container,
        shape: fushiCoverBlockShape(context, FushiCoverBlockSize.regular),
      ),
      child: body,
    );
  }
}

/// 小状态胶囊（图标 + 一个词）。
class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: ShapeDecoration(
        color: color.withValues(alpha: 0.14),
        shape: const StadiumBorder(),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiIcon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// 去掉 i18n 文案末尾的冒号（「打开浏览器扩展管理页：」作标题 / 按钮时不带冒号）。
String _stripTrailingColon(String text) =>
    text.replaceFirst(RegExp(r'[:：]\s*$'), '');

// -----------------------------------------------------------------------------
// 安装引导
// -----------------------------------------------------------------------------

/// 半自动安装引导：分步卡（5 步）。顶部五段进度条；展开的步骤是高亮大卡（tonal 底 +
/// 放大的编号）、已完成步骤打勾收成一行、未到的步骤淡化；点步骤标题展开收起，
/// 「下一步」推进。原为 `settings_schema_lookup.dart` 的私有 AlertDialog 内容，
/// 抽出复用于 [BrowserExtensionPage] 并暴露给 widget 测试。
class BrowserExtensionInstallSteps extends StatefulWidget {
  const BrowserExtensionInstallSteps({
    super.key,
    required this.path,
    required this.serverEnabled,
    required this.hasToken,
    required this.serverPort,
    required this.portConflict,
    this.detectedBrowser,
    this.preparing = false,
    this.onPrepare,
    this.verifying = false,
    this.onVerify,
    this.onCollapse,
    this.flow,
  });

  /// 用哪套安装步骤；null = 按本平台（[browserExtensionInstallFlowOn]）。
  final BrowserExtensionInstallFlow? flow;

  /// 解压出的扩展目录绝对路径（供「加载已解压」时选择）；null = 还没准备。
  final String? path;

  /// yomitan-api server 是否已开启（决定自动配置横幅是成功还是提醒）。
  final bool serverEnabled;

  /// 是否已设 API token（未设时连接虽通但鉴权会失败，一并提醒）。
  final bool hasToken;

  /// 安装助手自动启服失败时的端口及冲突态，用于给出 Yomitan 专项修复路径。
  final int serverPort;
  final bool portConflict;

  /// 探测到的默认浏览器：第 1 步预选它的分段并标星。
  final BrowserKind? detectedBrowser;

  /// 第 4 步「准备 / 重新准备扩展文件」。
  final bool preparing;
  final VoidCallback? onPrepare;

  /// 第 5 步「检测连接」。
  final bool verifying;
  final VoidCallback? onVerify;

  /// 非 null 时卡头出「收起」按钮（已连接时引导可折回入口）。
  final VoidCallback? onCollapse;

  @override
  State<BrowserExtensionInstallSteps> createState() =>
      _BrowserExtensionInstallStepsState();
}

class _BrowserExtensionInstallStepsState
    extends State<BrowserExtensionInstallSteps> {
  static const int _stepCount = 5;

  late BrowserKind _browser =
      widget.detectedBrowser ?? BrowserKind.values.first;

  /// 用户是否手动选过浏览器（选过之后不再被迟到的探测结果覆盖）。
  bool _browserPicked = false;

  /// 当前步（0 起）；小于它的都算已完成。
  int _current = 0;

  /// 展开的步骤；null = 全部收起。
  int? _open = 0;

  @override
  void didUpdateWidget(covariant BrowserExtensionInstallSteps oldWidget) {
    super.didUpdateWidget(oldWidget);
    final BrowserKind? detected = widget.detectedBrowser;
    if (!_browserPicked &&
        detected != null &&
        detected != oldWidget.detectedBrowser) {
      _browser = detected;
    }
  }

  void _advance(int index) {
    setState(() {
      _current = math.max(_current, index + 1);
      _open = index + 1 < _stepCount ? index + 1 : null;
    });
  }

  void _toggle(int index) {
    setState(() => _open = _open == index ? null : index);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(FushiSnackBar(content: Text(message)));
  }

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    _snack(t.copied);
  }

  /// 扩展管理页地址：一律经纯函数 [browserExtensionsPageUrl] 取，页面不写 URL 字面量。
  String _extensionsUrl(BrowserKind kind) => browserExtensionsPageUrl(kind);

  Future<void> _openExtensionsPage(BrowserKind kind) async {
    final bool opened = await tryOpenBrowserExtensionsPage(kind);
    if (!opened) _snack(t.browser_extension_open_page_failed);
  }

  Future<void> _reveal(String path) async {
    final bool revealed = await revealInFileManager(path);
    if (!revealed) _snack(t.media_file_location_failed);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool autoReady = widget.serverEnabled && widget.hasToken;
    // 两套步骤数相同（[_stepCount]），只换前两步：桌面是「选浏览器、开扩展管理页」
    // 与「开发者模式」；安卓是「装 Vivaldi」与「扩展按钮 › 管理扩展 › 开发者模式」。
    final List<(String, Widget Function(BuildContext))> steps =
        <(String, Widget Function(BuildContext))>[
          ...switch (_flow) {
            BrowserExtensionInstallFlow.desktop =>
              <(String, Widget Function(BuildContext))>[
                (
                  _stripTrailingColon(t.browser_extension_step_open_page),
                  _browserStep,
                ),
                (
                  t.browser_extension_step_dev_mode,
                  (BuildContext _) => _nextOnly(1),
                ),
              ],
            BrowserExtensionInstallFlow.android =>
              <(String, Widget Function(BuildContext))>[
                (t.browser_extension_android_step_browser, _androidBrowserStep),
                (
                  t.browser_extension_android_step_manager,
                  (BuildContext _) => _nextOnly(1),
                ),
              ],
          },
          (
            t.browser_extension_step_load_unpacked,
            (BuildContext _) => _nextOnly(2),
          ),
          (t.browser_extension_step_pick_folder, _folderStep),
          (t.browser_extension_step_verify, _verifyStep),
        ];

    return FushiCard(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 4),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        t.browser_extension_guide_title,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        t.browser_extension_guide_progress(
                          current: math.min(_current + 1, _stepCount),
                          total: _stepCount,
                        ),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (widget.onCollapse != null)
                  FushiIconButton(
                    icon: FushiIcons.expandLess,
                    tooltip: t.collection_collapse,
                    onTap: widget.onCollapse,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: _SegmentedProgress(count: _stepCount, done: _current),
          ),
          const SizedBox(height: 12),
          // 自动配置状态横幅：只在准备过、且未就绪时提醒（端口冲突 / 先开 server）。
          // 就绪时不显示——「完成」由最后一步承担，横幅重复它反而是句废话。
          if (widget.path != null && !autoReady) ...<Widget>[
            // 统一提示块（中性底 + 单色语义图标）：端口冲突是警告，未开服务器只是提醒。
            FushiInlineNotice(
              severity: widget.portConflict
                  ? FushiNoticeSeverity.warning
                  : FushiNoticeSeverity.info,
              message: widget.portConflict
                  ? _portInUseMessage(widget.serverPort)
                  : t.browser_extension_enable_server_first,
            ),
            const SizedBox(height: 8),
          ],
          for (int i = 0; i < steps.length; i++)
            _stepTile(context, i, title: steps[i].$1, body: steps[i].$2),
        ],
      ),
    );
  }

  /// 一步：展开时是 tonal 底的高亮大卡（编号放大），收起时是一行；未到的步骤
  /// 收起时淡化。底色 / 内边距 / 编号尺寸都随展开态过渡，正文走 [FushiAnimatedSize]。
  Widget _stepTile(
    BuildContext context,
    int index, {
    required String title,
    required Widget Function(BuildContext) body,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final SettingsKitStyle style = SettingsKitStyle.of(context);
    final bool done = index < _current;
    final bool active = index == _current;
    final bool open = _open == index;
    final bool future = !done && !active;
    final Duration d = fushiMotionDuration(context, FushiMotion.medium);
    final FushiCardColors tone = _cardToneColors(
      context,
      FushiCardTone.primary,
    );
    final double radius = SettingsKitRadii.card(style);
    final double indicator = open ? 40 : 30;
    final TextStyle? titleStyle = open
        ? theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: tone.onContainer,
          )
        : theme.textTheme.bodyLarge?.copyWith(
            fontWeight: active ? FontWeight.w600 : null,
            color: done ? scheme.onSurfaceVariant : null,
          );

    return AnimatedOpacity(
      opacity: future && !open ? 0.6 : 1,
      duration: d,
      curve: FushiMotion.standard,
      child: AnimatedContainer(
        duration: d,
        curve: FushiMotion.standard,
        margin: const EdgeInsets.symmetric(vertical: 2),
        decoration: ShapeDecoration(
          color: open ? tone.container : tone.container.withValues(alpha: 0),
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Material(
              type: MaterialType.transparency,
              child: FushiPressScale(
                child: InkWell(
                  key: ValueKey<String>('browser-extension-step-$index'),
                  customBorder: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.circular(radius),
                  ),
                  onTap: () => _toggle(index),
                  child: AnimatedPadding(
                    duration: d,
                    curve: FushiMotion.standard,
                    padding: open
                        ? const EdgeInsetsDirectional.fromSTEB(14, 14, 10, 6)
                        : const EdgeInsetsDirectional.fromSTEB(4, 8, 10, 8),
                    child: Row(
                      children: <Widget>[
                        _StepIndicator(
                          number: index + 1,
                          done: done,
                          active: active || open,
                          extent: indicator,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: AnimatedDefaultTextStyle(
                            duration: d,
                            curve: FushiMotion.standard,
                            style: titleStyle ?? const TextStyle(),
                            child: Text(title),
                          ),
                        ),
                        AnimatedRotation(
                          turns: open ? 0.5 : 0,
                          duration: d,
                          curve: FushiMotion.standard,
                          child: FushiIcon(
                            FushiIcons.expandMore,
                            size: 20,
                            color: open
                                ? tone.onContainer
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            FushiAnimatedSize(
              duration: d,
              curve: FushiMotion.standard,
              alignment: Alignment.topCenter,
              child: open
                  ? Padding(
                      // 正文与标题对齐（编号宽 + 间距）。
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        14 + 40 + 14,
                        2,
                        16,
                        18,
                      ),
                      child: body(context),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }

  Widget _nextButton(int index) {
    return FushiFilledButton(
      onPressed: () => _advance(index),
      child: Text(t.onboarding_action_next),
    );
  }

  BrowserExtensionInstallFlow get _flow => widget.flow ?? _currentInstallFlow();

  /// 安卓第 1 步：为什么是 Vivaldi，以及去应用商店装它。
  Widget _androidBrowserStep(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          t.browser_extension_android_browser_hint,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            _nextButton(0),
            FushiFilledButton.tonalIcon(
              onPressed: _openVivaldiListing,
              icon: const FushiIcon(FushiIcons.openInNew, size: 18),
              label: Text(t.browser_extension_android_get_browser),
            ),
          ],
        ),
      ],
    );
  }

  /// 应用商店里的 Vivaldi：先试 market://（交给设备上的商店），没有商店再开网页版。
  Future<void> _openVivaldiListing() async {
    for (final Uri uri in kVivaldiAndroidListingUris) {
      try {
        if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          return;
        }
      } on PlatformException {
        // 没有能接 market:// 的商店，换下一个地址。
      }
    }
    _snack(t.browser_extension_open_page_failed);
  }

  Widget _nextOnly(int index) {
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: _nextButton(index),
    );
  }

  /// 第 1 步：浏览器分段（默认浏览器带星预选），只显示选中那个的扩展页地址。
  Widget _browserStep(BuildContext context) {
    final BrowserKind? detected = widget.detectedBrowser;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 支持列表的唯一真相源是 [BrowserKind]：按枚举遍历，新增浏览器只改枚举。
        adaptiveSegmentedButton<BrowserKind>(
          context: context,
          segments: <ButtonSegment<BrowserKind>>[
            for (final BrowserKind kind in BrowserKind.values)
              ButtonSegment<BrowserKind>(
                value: kind,
                label: Text(browserDisplayName(kind)),
                icon: kind == detected
                    ? const FushiIcon(FushiIcons.star, size: 16)
                    : null,
                tooltip: kind == detected
                    ? t.browser_extension_browser_default
                    : null,
              ),
          ],
          selected: <BrowserKind>{_browser},
          onSelectionChanged: (Set<BrowserKind> picked) => setState(() {
            _browser = picked.first;
            _browserPicked = true;
          }),
        ),
        const SizedBox(height: 12),
        AnimatedSwitcher(
          duration: fushiMotionDuration(context, FushiMotion.short),
          switchInCurve: FushiMotion.enter,
          switchOutCurve: FushiMotion.exit,
          child: KeyedSubtree(
            key: ValueKey<BrowserKind>(_browser),
            child: _urlField(context, _browser),
          ),
        ),
        const SizedBox(height: 14),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: _nextButton(0),
        ),
      ],
    );
  }

  /// 扩展管理页地址代码块：等宽地址 + 复制；宽时「尝试打开」同行，窄时换到下一行。
  Widget _urlField(BuildContext context, BrowserKind kind) {
    final String url = _extensionsUrl(kind);
    final Widget open = FushiTextButton.icon(
      onPressed: () => _openExtensionsPage(kind),
      icon: const FushiIcon(FushiIcons.openInNew, size: 18),
      label: Text(t.browser_extension_open_page_action),
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool inline = constraints.maxWidth >= 440;
        final Widget block = _CodeBlock(
          icon: FushiIcons.link,
          text: url,
          maxLines: 1,
          actions: <Widget>[
            FushiIconButton(
              icon: Icons.copy,
              size: 18,
              tooltip: t.copy,
              onTap: () => _copy(url),
            ),
            if (inline) open,
          ],
        );
        if (inline) return block;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[block, const SizedBox(height: 4), open],
        );
      },
    );
  }

  /// 第 4 步：路径代码块（等宽、复制、在文件管理器中打开）+ 「重新准备 / 刷新文件」
  /// tonal 按钮；还没准备时给「准备扩展文件」主按钮。
  Widget _folderStep(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? path = widget.path;
    final Widget prepareIcon = widget.preparing
        ? _busyIcon()
        : const FushiIcon(FushiIcons.browserExtension, size: 18);
    if (path == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            t.browser_extension_folder_not_ready,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          FushiFilledButton.icon(
            onPressed: widget.onPrepare,
            icon: prepareIcon,
            label: Text(t.browser_extension_prepare_button),
          ),
          const SizedBox(height: 8),
          Text(
            t.browser_extension_prepare_hint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _CodeBlock(
          icon: FushiIcons.folder,
          text: path,
          actions: <Widget>[
            FushiIconButton(
              icon: Icons.copy,
              size: 18,
              tooltip: t.copy,
              onTap: () => _copy(path),
            ),
            if (_flow == BrowserExtensionInstallFlow.desktop)
              FushiIconButton(
                icon: FushiIcons.folderOpen,
                size: 18,
                tooltip: t.media_file_location_open,
                onTap: () => _reveal(path),
              ),
          ],
        ),
        if (_flow == BrowserExtensionInstallFlow.android) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            t.browser_extension_android_folder_hint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            _nextButton(3),
            FushiFilledButton.tonalIcon(
              onPressed: widget.onPrepare,
              icon: widget.preparing
                  ? prepareIcon
                  : const FushiIcon(FushiIcons.refresh, size: 18),
              label: Text(t.browser_extension_reinstall_button),
            ),
          ],
        ),
      ],
    );
  }

  /// 第 5 步：自动配置完成说明 + 「检测连接」（结果显示在顶部状态块）。
  Widget _verifyStep(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          t.browser_extension_step_done_auto,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (_flow == BrowserExtensionInstallFlow.android) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            t.browser_extension_android_keep_running,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 12),
        FushiFilledButton.icon(
          onPressed: widget.onVerify == null
              ? null
              : () {
                  _advance(_stepCount - 1);
                  widget.onVerify!();
                },
          icon: widget.verifying
              ? _busyIcon()
              : const FushiIcon(FushiIcons.wifi, size: 18),
          label: Text(
            widget.verifying
                ? t.browser_extension_verify_checking
                : t.browser_extension_verify_button,
          ),
        ),
      ],
    );
  }
}

/// 可复制的代码块：页面底色的内嵌条 + 前导图标 + 等宽可选中文字 + 尾部动作。
class _CodeBlock extends StatelessWidget {
  const _CodeBlock({
    required this.icon,
    required this.text,
    required this.actions,
    this.maxLines,
  });

  final IconData icon;
  final String text;
  final List<Widget> actions;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SettingsKitStyle style = SettingsKitStyle.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsetsDirectional.fromSTEB(14, 4, 4, 4),
      decoration: ShapeDecoration(
        color: tokens.surfaces.page,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(SettingsKitRadii.small(style)),
          side: isEinkTheme(context)
              ? BorderSide(color: theme.colorScheme.outline)
              : BorderSide.none,
        ),
      ),
      child: Row(
        children: <Widget>[
          FushiIcon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: SelectableText(
                text,
                maxLines: maxLines,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFamily: 'monospace',
                  height: 1.4,
                ),
              ),
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

/// 顶部五段进度条：已完成段实心 primary，当前段半透明，未到段是轨道色。
class _SegmentedProgress extends StatelessWidget {
  const _SegmentedProgress({required this.count, required this.done});

  final int count;
  final int done;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final Color fill = eink ? scheme.onSurface : scheme.primary;
    final Color track = eink
        ? scheme.outlineVariant
        : FushiDesignTokens.of(context).surfaces.search;
    final Duration d = fushiMotionDuration(context, FushiMotion.long);
    return Row(
      children: <Widget>[
        for (int i = 0; i < count; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 4),
          Expanded(
            child: AnimatedContainer(
              duration: d,
              curve: FushiMotion.standard,
              height: i == done ? 8 : 6,
              decoration: ShapeDecoration(
                color: i < done
                    ? fill
                    : i == done
                    ? fill.withValues(alpha: 0.4)
                    : track,
                shape: const StadiumBorder(),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 步骤编号：未到 = 描边圆 + 数字；当前 / 展开 = primary 实心并弹簧形变成圆角方块
/// （M3E；Apple 保持圆）；已完成 = primary 圆 + 勾。
class _StepIndicator extends StatelessWidget {
  const _StepIndicator({
    required this.number,
    required this.done,
    required this.active,
    required this.extent,
  });

  final int number;
  final bool done;
  final bool active;
  final double extent;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool expressive =
        SettingsKitStyle.of(context) == SettingsKitStyle.expressive;
    final bool eink = isEinkTheme(context);
    final Color solid = eink ? scheme.onSurface : scheme.primary;
    final Color onSolid = eink ? scheme.surface : scheme.onPrimary;
    return SettingsSpringValue(
      value: done || active ? 1 : 0,
      builder: (BuildContext context, double t, Widget? _) {
        final double c = t.clamp(0.0, 1.0);
        final double scale = 1 + math.max(0.0, t - 1) * 0.8;
        final double radius = active && !done && expressive
            ? lerpDouble(extent / 2, extent * 0.3, c)!
            : extent / 2;
        final Color fill = Color.lerp(solid.withValues(alpha: 0), solid, c)!;
        final Color fg = Color.lerp(scheme.onSurfaceVariant, onSolid, c)!;
        return Transform.scale(
          scale: scale,
          child: AnimatedContainer(
            duration: fushiMotionDuration(context, FushiMotion.medium),
            curve: FushiMotion.standard,
            width: extent,
            height: extent,
            decoration: ShapeDecoration(
              color: fill,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(radius),
                side: BorderSide(
                  color: scheme.outline.withValues(alpha: 1 - c),
                  width: 1.5,
                ),
              ),
            ),
            child: Center(
              child: done
                  ? FushiIcon(FushiIcons.check, size: extent * 0.55, color: fg)
                  : Text(
                      '$number',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: fg,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
            ),
          ),
        );
      },
    );
  }
}

/// TODO-1087：暴露安装引导分步 widget 给测试（验证可复制字段 + 分步渲染 + 横幅），
/// 不改变生产调用路径（生产由 [BrowserExtensionPage] 使用）。
@visibleForTesting
Widget buildBrowserExtensionInstallStepsForTest({
  required String path,
  required bool serverEnabled,
  required bool hasToken,
  int serverPort = kFushiApiDefaultPort,
  bool portConflict = false,
  BrowserKind? detectedBrowser,
  BrowserExtensionInstallFlow? flow,
}) {
  return BrowserExtensionInstallSteps(
    flow: flow,
    path: path,
    serverEnabled: serverEnabled,
    hasToken: hasToken,
    serverPort: serverPort,
    portConflict: portConflict,
    detectedBrowser: detectedBrowser,
  );
}

/// [fushiCardToneColors] 在墨水屏 / neutral 下返回 null（卡片走描边口径）；
/// 本页的高亮步骤卡始终需要一对确定的底色与前景，null 时回落到中性分层色。
FushiCardColors _cardToneColors(BuildContext context, FushiCardTone tone) {
  final FushiCardColors? colors = fushiCardToneColors(context, tone);
  final ColorScheme cs = Theme.of(context).colorScheme;
  return FushiCardColors(
    container:
        colors?.container ?? FushiDesignTokens.of(context).surfaces.search,
    onContainer: colors?.onContainer ?? cs.onSurface,
  );
}

/// 本平台的安装流程；没有安装引导的平台（iOS）根本进不到本页，按桌面兜底只为
/// 让类型非空。判据只在 [browserExtensionInstallFlowOn]。
BrowserExtensionInstallFlow _currentInstallFlow() =>
    browserExtensionInstallFlowOn(defaultTargetPlatform) ??
    BrowserExtensionInstallFlow.desktop;

/// Vivaldi 安卓版的商店地址：先 market://（设备上的应用商店），再 Google Play 网页。
final List<Uri> kVivaldiAndroidListingUris = <Uri>[
  Uri.parse('market://details?id=com.vivaldi.browser'),
  Uri.parse(
    'https://play.google.com/store/apps/details?id=com.vivaldi.browser',
  ),
];
