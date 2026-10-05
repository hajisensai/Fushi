import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/lookup/browser_default_detector.dart';
import 'package:fushi/src/lookup/browser_extension_installer.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/settings/settings_kit.dart';
import 'package:fushi/src/sync/yomitan_api_server.dart'
    show kYomitanApiDefaultPort;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/reveal_in_file_manager.dart';
import 'package:fushi/utils.dart';
import 'package:url_launcher/url_launcher.dart';

/// 探测默认浏览器的注入点（测试里换成同步返回，避免真起 `reg` / `defaults`）。
typedef BrowserKindDetector = Future<BrowserKind?> Function();

/// 桌面专属「浏览器扩展」页（顶层导航目的地，仅桌面显示）。
///
/// 把原来埋在「设置 → 查词」里的安装入口独立成页，并在原「半自动安装引导」之上补：
/// ① 服务 + 连接状态卡；② 加载扩展后「验证插件已正常启用」的连接检测（扩展 SW 启动时
/// 主动打 `/api/extension/status`，server 刷新 last-seen，这里据此判断已连上）；
/// ③ 扩展版本（内容指纹）与「重新准备/刷新」。自建 MV3 无真·一键（浏览器封侧载），故仍为
/// 半自动引导；但 host/port/token 已由安装助手自动写入扩展，用户无需手填。
///
/// 2026-10-06 M3E 重设计：顶部状态 hero（已连接 = 饱和 primaryContainer + 花瓣勾形；
/// 未连接 = 警示 / 错误容器 + 指引，状态切换走弹簧）；安装引导是竖向 stepper 卡（当前步
/// 高亮、已完成打勾、可展开收起，已连接时默认折叠成「重新安装 / 更新扩展」入口）；
/// 第 1 步用浏览器 chip 只显示一个扩展页地址；第 4 步路径卡；「试一试」是特色卡。
/// 宽屏两栏（左：状态 + 引导；右：试一试 + 版本），窄屏单栏，错峰进场。
class BrowserExtensionPage extends ConsumerStatefulWidget {
  const BrowserExtensionPage({
    super.key,
    this.detectBrowser = detectDefaultBrowserKind,
  });

  /// 默认浏览器探测（只用来预选第 1 步的浏览器 chip）。
  final BrowserKindDetector detectBrowser;

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
  int _serverPort = kYomitanApiDefaultPort;
  bool _portConflict = false;

  // 连接检测（验证插件已正常启用）状态。
  bool _verifying = false;
  bool? _verifyConnected;

  /// 探测到的系统默认浏览器（受支持的 Chromium 系才有值）。
  BrowserKind? _detectedBrowser;

  /// 安装引导是否展开；null = 跟随连接状态（已连接折叠、未连接展开）。
  bool? _guideExpanded;

  // 连接状态卡片的轻量刷新（扩展 last-seen 由 server 端异步更新，这里定时重绘显示）。
  Timer? _statusTimer;

  /// 判定「插件近期连上过」的时间窗：扩展 SW 启动/查词/心跳时打本机 server 刷新 last-seen，
  /// 加载/重新加载扩展后这段窗口内即可检测到。BUG-1045：扩展改用 chrome.alarms 每 60s
  /// 心跳保活，此窗口取 150s（> 一个心跳周期 + 抖动余量），单次心跳丢包不会误判「未连接」。
  static const Duration _seenWindow = Duration(seconds: 150);

  @override
  void initState() {
    super.initState();
    _statusTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) setState(() {});
    });
    unawaited(widget.detectBrowser().then((BrowserKind? kind) {
      if (!mounted || kind == null) return;
      setState(() => _detectedBrowser = kind);
    }));
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(FushiSnackBar(content: Text(message)));
  }

  bool _isRecentlySeen(AppModel appModel) {
    final DateTime? seen = appModel.browserExtensionLastSeenAt;
    if (seen == null) return false;
    return DateTime.now().difference(seen) < _seenWindow;
  }

  /// 准备扩展：幂等开启 yomitan-api server（token 为空才播种、绝不覆盖）→ 用当前 server
  /// 真值解压扩展到本机 → 路径复制剪贴板。与原设置里的安装动作同一流程，仅换到页面里。
  Future<void> _prepare() async {
    if (_preparing) return;
    final AppModel appModel = ref.read(appProvider);
    setState(() => _preparing = true);
    // TODO-1266：装扩展即默认开启 yomitan-api server（省得装完 401 连不上）。
    final bool serverReady =
        await appModel.ensureYomitanApiServerForBrowserExtension();
    // TODO-1087：解压时注入当前 server 真值，扩展默认即连本机 app，无需手填。
    final String dir = await prepareBundledBrowserExtension(
      serverConfig: BrowserExtensionServerConfig(
        host: '127.0.0.1',
        port: appModel.yomitanApiPort,
        token: appModel.yomitanApiKey,
      ),
    );
    await Clipboard.setData(ClipboardData(text: dir));
    if (!mounted) return;
    setState(() {
      _preparing = false;
      _extensionDir = dir;
      _serverEnabled = serverReady && appModel.yomitanApiServerEnabled;
      _hasToken = appModel.yomitanApiKey.isNotEmpty;
      _serverPort = appModel.yomitanApiPort;
      _portConflict = !serverReady;
      _verifyConnected = null;
    });
    _snack(t.copied);
  }

  /// 验证插件已正常启用：加载/重新加载扩展后，其 SW 会主动打本机 server，刷新 last-seen。
  /// 这里点一下后短轮询若干秒，检测到近期活跃即判定已连接。
  Future<void> _verify() async {
    setState(() {
      _verifying = true;
      _verifyConnected = null;
    });
    final AppModel appModel = ref.read(appProvider);
    final DateTime start = DateTime.now();
    bool connected = _isRecentlySeen(appModel);
    while (!connected &&
        DateTime.now().difference(start) < const Duration(seconds: 8)) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (!mounted) return;
      connected = _isRecentlySeen(appModel);
    }
    if (!mounted) return;
    setState(() {
      _verifying = false;
      _verifyConnected = connected;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppModel appModel = ref.watch(appProvider);

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

  Widget _buildBody(ThemeData theme, AppModel appModel) {
    final bool serverOn = appModel.yomitanApiServerEnabled;
    final bool connected = _isRecentlySeen(appModel);
    final String? build = appModel.browserExtensionBuild;
    final bool guideExpanded = _guideExpanded ?? !connected;
    final double page = FushiDesignTokens.of(context).spacing.page;

    final Widget hero = ValueListenableBuilder<String?>(
      valueListenable: appModel.browserExtensionReportedBuild,
      builder: (BuildContext context, String? reported, Widget? _) {
        return _StatusHero(
          connected: connected,
          serverOn: serverOn,
          port: appModel.yomitanApiPort,
          reportedBuild: reported,
          detectedBrowser: _detectedBrowser,
          verifying: _verifying,
          verifyResult: _verifyConnected,
          onVerify: _verifying ? null : _verify,
        );
      },
    );
    final Widget guide = _buildGuide(
      connected: connected,
      expanded: guideExpanded,
    );
    final Widget tryIt = _tryItCard(theme, serverOn: serverOn);
    final Widget version = _versionCard(theme, appModel, build);

    Widget entrance(int index, Widget child) =>
        FushiStaggeredEntrance(index: index, child: child);
    const double gap = 16;

    return FushiEntranceScope(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // 两栏阈值：左栏要容得下 hero 的「状态 + 检测连接」一行与第 1 步的
          // 地址行，右栏至少一张特色卡宽。
          final bool wide = constraints.maxWidth >= 920;
          if (!wide) {
            return ListView(
              padding: EdgeInsets.fromLTRB(page, 8, page, 32),
              children: <Widget>[
                entrance(0, hero),
                const SizedBox(height: gap),
                entrance(1, guide),
                const SizedBox(height: gap),
                entrance(2, tryIt),
                const SizedBox(height: gap),
                entrance(3, version),
              ],
            );
          }
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(page, 8, page, 32),
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
                          entrance(2, tryIt),
                          const SizedBox(height: gap),
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

  /// 安装引导：展开 = stepper 卡；折叠 = 一行「重新安装 / 更新扩展」入口卡。
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
    return AnimatedSize(
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
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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

  /// 「试一试」特色卡：在真网页上试一遍基础功能。
  ///
  /// 页面由本机 yomitan-api server 提供（`/onboarding/extension-test`）——必须是 http：
  /// Chrome 默认不给扩展 `file://` 权限，本地 HTML 文件证明不了插件是否活着。server 没开
  /// 时按钮禁用（URL 打开就是连接失败），提示先开服务器。
  Widget _tryItCard(ThemeData theme, {required bool serverOn}) {
    final SettingsKitStyle style = SettingsKitStyle.of(context);
    final FushiCardColors colors =
        fushiCardToneColors(context, FushiCardTone.secondary);
    final ColorScheme scheme = theme.colorScheme;
    return FushiCard(
      tone: FushiCardTone.secondary,
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (style == SettingsKitStyle.apple)
            const SettingsShapeIcon(
              icon: FushiIcons.travelExplore,
              tone: SettingsIconTone.teal,
              size: 44,
            )
          else
            SizedBox.square(
              dimension: 72,
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: scheme.secondary,
                  shape: const FushiCookieBorder(lobes: 9),
                ),
                child: Center(
                  child: FushiIcon(
                    FushiIcons.travelExplore,
                    size: 36,
                    color: scheme.onSecondary,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 16),
          Text(
            t.browser_extension_test_page_title,
            style: theme.textTheme.titleLarge?.copyWith(
              color: colors.onContainer,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            serverOn
                ? t.browser_extension_test_page_action_desc
                : t.browser_extension_test_page_server_off,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onContainer.withValues(alpha: 0.85),
            ),
          ),
          const SizedBox(height: 20),
          FushiFilledButton.icon(
            onPressed: serverOn ? _openTestPage : null,
            icon: const FushiIcon(FushiIcons.openInNew, size: 18),
            label: Text(t.browser_extension_test_page_action),
          ),
        ],
      ),
    );
  }

  Future<void> _openTestPage() async {
    final AppModel appModel = ref.read(appProvider);
    await launchUrl(
      Uri.parse(appModel.browserExtensionTestPageUrl),
      mode: LaunchMode.externalApplication,
    );
  }

  /// 版本卡（BUG-1079 扩展为双行）：app 内置指纹 + 扩展自报的「浏览器中实际加载」指纹；
  /// 两者都有且不一致时显示警示条（扩展自更新未生效，需手动到扩展管理页重新加载）。
  /// 浏览器侧指纹经 [AppModel.browserExtensionReportedBuild]（ValueNotifier）实时驱动。
  Widget _versionCard(ThemeData theme, AppModel appModel, String? build) {
    return ValueListenableBuilder<String?>(
      valueListenable: appModel.browserExtensionReportedBuild,
      builder: (BuildContext context, String? reported, Widget? _) {
        final bool mismatch =
            build != null && reported != null && build != reported;
        return FushiCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const SettingsShapeIcon(
                    icon: FushiIcons.info,
                    tone: SettingsIconTone.gray,
                    size: 36,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      t.browser_extension_version_label,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _versionRow(
                theme,
                label: t.browser_extension_version_app,
                value: build,
                first: true,
              ),
              const SizedBox(height: 2),
              _versionRow(
                theme,
                label: t.browser_extension_version_browser,
                value: reported,
                first: false,
              ),
              if (mismatch) ...<Widget>[
                const SizedBox(height: 12),
                // 中性提示块，语义（版本不一致）只体现在单色图标上；走共享
                // FushiInlineNotice，与全应用提示块同一几何。
                FushiInlineNotice(
                  severity: FushiNoticeSeverity.error,
                  icon: FushiIcons.refresh,
                  message: t.browser_extension_version_mismatch,
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// 版本卡里的一行（分段列表形：组首尾大圆角、中缝小圆角）。
  Widget _versionRow(
    ThemeData theme, {
    required String label,
    required String? value,
    required bool first,
  }) {
    final SettingsKitStyle style = SettingsKitStyle.of(context);
    final Radius outer = Radius.circular(SettingsKitRadii.small(style));
    const Radius inner = Radius.circular(4);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.vertical(
          top: first ? outer : inner,
          bottom: first ? inner : outer,
        ),
      ),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          const SizedBox(width: 12),
          Flexible(
            child: SelectableText(
              value ?? '—',
              maxLines: 1,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 状态 hero
// -----------------------------------------------------------------------------

/// 顶部状态大卡：已连接 = 饱和 primaryContainer + 九瓣花形勾；未连接 = 警示
/// （tertiary）/ 错误（服务未开或检测失败）容器 + 指引。底色与形状都随状态弹簧过渡。
class _StatusHero extends StatelessWidget {
  const _StatusHero({
    required this.connected,
    required this.serverOn,
    required this.port,
    required this.reportedBuild,
    required this.detectedBrowser,
    required this.verifying,
    required this.verifyResult,
    required this.onVerify,
  });

  final bool connected;
  final bool serverOn;
  final int port;
  final String? reportedBuild;
  final BrowserKind? detectedBrowser;
  final bool verifying;
  final bool? verifyResult;
  final VoidCallback? onVerify;

  FushiCardTone get _tone {
    if (connected) return FushiCardTone.primary;
    if (!serverOn || verifyResult == false) return FushiCardTone.error;
    return FushiCardTone.tertiary;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SettingsKitStyle style = SettingsKitStyle.of(context);
    final FushiCardTone tone = _tone;
    final FushiCardColors colors = fushiCardToneColors(context, tone);
    final Duration d = fushiMotionDuration(context, FushiMotion.long);
    final Color fg = colors.onContainer;
    final String title = connected
        ? t.browser_extension_status_connected
        : t.browser_extension_status_never;
    final String hint = connected
        ? t.browser_extension_hero_connected_hint
        : t.browser_extension_hero_setup_hint;

    final Widget verifyButton = connected
        ? FushiFilledButton.tonalIcon(
            onPressed: onVerify,
            icon: _verifyIcon(),
            label: Text(_verifyLabel()),
          )
        : FushiFilledButton.icon(
            onPressed: onVerify,
            icon: _verifyIcon(),
            label: Text(_verifyLabel()),
          );

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
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          hint,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: fg.withValues(alpha: 0.85)),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            _HeroPill(
              icon: serverOn ? FushiIcons.cloud : FushiIcons.cloudOff,
              label: serverOn
                  ? '${t.browser_extension_server_on} · '
                      '${t.browser_extension_port_label(port: port)}'
                  : t.browser_extension_server_off,
              color: fg,
            ),
            if (reportedBuild != null)
              _HeroPill(
                icon: FushiIcons.browserExtension,
                label: '${t.browser_extension_version_browser} · '
                    '$reportedBuild',
                color: fg,
              ),
            if (detectedBrowser != null)
              _HeroPill(
                icon: FushiIcons.globe,
                label: '${t.browser_extension_browser_default} · '
                    '${browserDisplayName(detectedBrowser!)}',
                color: fg,
              ),
          ],
        ),
      ],
    );

    // 检测结果：语义色只上在图标上，正文保持容器前景色。
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
      duration: d,
      curve: FushiMotion.standard,
      padding: EdgeInsets.all(style == SettingsKitStyle.apple ? 18 : 24),
      decoration: BoxDecoration(
        color: colors.container,
        borderRadius: BorderRadius.circular(SettingsKitRadii.container(style)),
      ),
      child: IconTheme.merge(
        data: IconThemeData(color: fg),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: fg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final bool narrow = constraints.maxWidth < 520;
                  final Widget icon = _HeroStatusIcon(
                    connected: connected,
                    tone: tone,
                    size: narrow ? 56 : 72,
                  );
                  if (narrow) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            icon,
                            const SizedBox(width: 16),
                            Expanded(child: texts),
                          ],
                        ),
                        const SizedBox(height: 16),
                        verifyButton,
                      ],
                    );
                  }
                  return Row(
                    children: <Widget>[
                      icon,
                      const SizedBox(width: 20),
                      Expanded(child: texts),
                      const SizedBox(width: 16),
                      verifyButton,
                    ],
                  );
                },
              ),
              AnimatedSize(
                duration: fushiMotionDuration(context, FushiMotion.medium),
                curve: FushiMotion.standard,
                alignment: Alignment.topCenter,
                child: resultLine,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _verifyIcon() => verifying
      ? const SizedBox(
          width: 16,
          height: 16,
          child: FushiCircularProgressIndicator(strokeWidth: 2),
        )
      : const FushiIcon(FushiIcons.wifi, size: 18);

  String _verifyLabel() => verifying
      ? t.browser_extension_verify_checking
      : t.browser_extension_verify_button;
}

/// hero 左侧的状态形状图标。M3E：饱和色块里的勾 / 叹号，已连接是九瓣花形、
/// 未连接是四瓣 cookie；状态切换时弹簧转 45° 并过冲放大，读作「变形」。
/// Apple：不垫底，只用系统语义色着色字形。
class _HeroStatusIcon extends StatelessWidget {
  const _HeroStatusIcon({
    required this.connected,
    required this.tone,
    required this.size,
  });

  final bool connected;
  final FushiCardTone tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    final IconData icon = connected ? FushiIcons.check : FushiIcons.warning;
    if (SettingsKitStyle.of(context) == SettingsKitStyle.apple) {
      final Color color = fushiStatusColor(
        context,
        connected
            ? FushiStatusTone.success
            : tone == FushiCardTone.error
                ? FushiStatusTone.error
                : FushiStatusTone.warning,
      );
      return SettingsSpringValue(
        value: connected ? 1 : 0,
        builder: (BuildContext context, double t, Widget? _) {
          final double c = t.clamp(0.0, 1.0);
          final double pulse = (t - c).abs();
          return Transform.scale(
            scale: 1 + pulse * 0.8,
            child: SizedBox.square(
              dimension: size * 0.75,
              child: Center(
                child: FushiIcon(
                  connected ? FushiIcons.success : FushiIcons.warning,
                  size: size * 0.7,
                  fill: 1,
                  color: color,
                ),
              ),
            ),
          );
        },
      );
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final (Color fill, Color onFill) = switch (tone) {
      FushiCardTone.primary => (scheme.primary, scheme.onPrimary),
      FushiCardTone.error => (scheme.error, scheme.onError),
      _ => (scheme.tertiary, scheme.onTertiary),
    };
    return SettingsSpringValue(
      value: connected ? 1 : 0,
      builder: (BuildContext context, double t, Widget? _) {
        final double c = t.clamp(0.0, 1.0);
        final double pulse = (t - c).abs();
        final double angle = t * math.pi / 4;
        return Transform.rotate(
          angle: angle,
          child: Transform.scale(
            scale: 1 + pulse * 0.8,
            child: SizedBox.square(
              dimension: size,
              child: AnimatedContainer(
                duration: fushiMotionDuration(context, FushiMotion.medium),
                curve: FushiMotion.standard,
                decoration: ShapeDecoration(
                  color: fill,
                  shape: FushiCookieBorder(lobes: connected ? 9 : 4),
                ),
                child: Center(
                  child: Transform.rotate(
                    angle: -angle,
                    child: FushiIcon(
                      icon,
                      size: size * 0.5,
                      color: onFill,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// hero 里的状态小胶囊（服务端口 / 浏览器中加载的版本 / 默认浏览器）。
class _HeroPill extends StatelessWidget {
  const _HeroPill({
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiIcon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 安装引导 stepper
// -----------------------------------------------------------------------------

/// 半自动安装引导：M3E 竖向 stepper 卡（5 步，当前步高亮、已完成打勾、点步骤标题
/// 展开收起，「下一步」推进）。原为 `settings_schema_lookup.dart` 的私有 AlertDialog
/// 内容，抽出复用于 [BrowserExtensionPage] 并暴露给 widget 测试。
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
  });

  /// 解压出的扩展目录绝对路径（供「加载已解压」时选择）；null = 还没准备。
  final String? path;

  /// yomitan-api server 是否已开启（决定自动配置横幅是成功还是提醒）。
  final bool serverEnabled;

  /// 是否已设 API token（未设时连接虽通但鉴权会失败，一并提醒）。
  final bool hasToken;

  /// 安装助手自动启服失败时的端口及冲突态，用于给出 Yomitan 专项修复路径。
  final int serverPort;
  final bool portConflict;

  /// 探测到的默认浏览器：第 1 步预选它的 chip 并标星。
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

  /// 用户是否手动点过浏览器 chip（点过之后不再被迟到的探测结果覆盖）。
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

  String _portInUseMessage() {
    return widget.serverPort == kYomitanApiDefaultPort
        ? t.browser_extension_yomitan_port_conflict(port: widget.serverPort)
        : t.sync_server_port_in_use(port: widget.serverPort);
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
    ScaffoldMessenger.of(context)
        .showSnackBar(FushiSnackBar(content: Text(message)));
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
    final bool autoReady = widget.serverEnabled && widget.hasToken;
    final List<(String, Widget Function(BuildContext))> steps =
        <(String, Widget Function(BuildContext))>[
      (
        t.browser_extension_step_open_page.replaceFirst(
          RegExp(r'[:：]\s*$'),
          '',
        ),
        _browserStep,
      ),
      (t.browser_extension_step_dev_mode, (BuildContext _) => _nextOnly(1)),
      (
        t.browser_extension_step_load_unpacked,
        (BuildContext _) => _nextOnly(2)
      ),
      (t.browser_extension_step_pick_folder, _folderStep),
      (t.browser_extension_step_verify, _verifyStep),
    ];

    return FushiCard(
      padding: const EdgeInsets.fromLTRB(20, 18, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const SettingsShapeIcon(
                icon: FushiIcons.browserExtension,
                tone: SettingsIconTone.blue,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      t.browser_extension_guide_title,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      t.browser_extension_guide_progress(
                        current: math.min(_current + 1, _stepCount),
                        total: _stepCount,
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
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
          const SizedBox(height: 14),
          TweenAnimationBuilder<double>(
            tween: Tween<double>(end: _current / _stepCount),
            duration: fushiMotionDuration(context, FushiMotion.long),
            curve: FushiMotion.standard,
            builder: (BuildContext context, double value, Widget? _) =>
                FushiLinearProgressIndicator(value: value),
          ),
          const SizedBox(height: 10),
          // 自动配置状态横幅：只在准备过、且未就绪时提醒（端口冲突 / 先开 server）。
          // 就绪时不显示——「完成」由最后一步承担，横幅重复它反而是句废话。
          if (widget.path != null && !autoReady) ...<Widget>[
            // 统一提示块（中性底 + 单色语义图标）：端口冲突是警告，未开服务器只是提醒。
            FushiInlineNotice(
              severity: widget.portConflict
                  ? FushiNoticeSeverity.warning
                  : FushiNoticeSeverity.info,
              message: widget.portConflict
                  ? _portInUseMessage()
                  : t.browser_extension_enable_server_first,
            ),
            const SizedBox(height: 8),
          ],
          for (int i = 0; i < steps.length; i++)
            _stepTile(
              context,
              i,
              title: steps[i].$1,
              body: steps[i].$2,
            ),
        ],
      ),
    );
  }

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
    final bool last = index == _stepCount - 1;
    final Duration d = fushiMotionDuration(context, FushiMotion.medium);
    // 竖向连接线：指示器中心（4 + 16）对齐；已完成段用 primary，其余 outlineVariant。
    final BorderDirectional rail = BorderDirectional(
      start: BorderSide(
        color: last
            ? Colors.transparent
            : done
                ? scheme.primary
                : scheme.outlineVariant,
        width: 2,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Material(
          type: MaterialType.transparency,
          child: FushiPressScale(
            child: InkWell(
              key: ValueKey<String>('browser-extension-step-$index'),
              borderRadius:
                  BorderRadius.circular(SettingsKitRadii.small(style)),
              onTap: () => _toggle(index),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Row(
                  children: <Widget>[
                    _StepIndicator(
                      number: index + 1,
                      done: done,
                      active: active,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        title,
                        style: (active
                                ? theme.textTheme.titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w700)
                                : theme.textTheme.bodyLarge)
                            ?.copyWith(
                          color: done ? scheme.onSurfaceVariant : null,
                        ),
                      ),
                    ),
                    AnimatedRotation(
                      turns: open ? 0.5 : 0,
                      duration: d,
                      curve: FushiMotion.standard,
                      child: FushiIcon(
                        FushiIcons.expandMore,
                        size: 20,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: d,
          curve: FushiMotion.standard,
          alignment: Alignment.topCenter,
          child: open
              ? Container(
                  margin: const EdgeInsetsDirectional.only(start: 19),
                  padding: const EdgeInsetsDirectional.fromSTEB(25, 4, 4, 16),
                  decoration: BoxDecoration(border: rail),
                  child: body(context),
                )
              : Container(
                  margin: const EdgeInsetsDirectional.only(start: 19),
                  height: last ? 0 : 4,
                  decoration: BoxDecoration(border: rail),
                ),
        ),
      ],
    );
  }

  Widget _nextButton(int index) {
    return FushiFilledButton(
      onPressed: () => _advance(index),
      child: Text(t.onboarding_action_next),
    );
  }

  Widget _nextOnly(int index) {
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: _nextButton(index),
    );
  }

  /// 第 1 步：一排浏览器 chip（默认浏览器标星预选），只显示选中那个的扩展页地址。
  Widget _browserStep(BuildContext context) {
    final BrowserKind? detected = widget.detectedBrowser;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // 支持列表的唯一真相源是 [BrowserKind]：按枚举遍历，新增浏览器只改枚举。
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final BrowserKind kind in BrowserKind.values)
              FushiChoiceChip(
                selected: _browser == kind,
                label: Text(browserDisplayName(kind)),
                avatar: kind == detected
                    ? const FushiIcon(FushiIcons.star, size: 18)
                    : null,
                tooltip: kind == detected
                    ? t.browser_extension_browser_default
                    : null,
                onSelected: (_) => setState(() {
                  _browser = kind;
                  _browserPicked = true;
                }),
              ),
          ],
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
        _nextButton(0),
      ],
    );
  }

  /// 扩展管理页地址卡：等宽地址 + 复制；宽时「尝试打开」同行，窄时换到下一行。
  Widget _urlField(BuildContext context, BrowserKind kind) {
    final ThemeData theme = Theme.of(context);
    final SettingsKitStyle style = SettingsKitStyle.of(context);
    final String url = _extensionsUrl(kind);
    final Widget open = FushiTextButton.icon(
      onPressed: () => _openExtensionsPage(kind),
      icon: const FushiIcon(FushiIcons.openInNew, size: 18),
      label: Text(t.browser_extension_open_page_action),
    );
    final Widget field = Row(
      children: <Widget>[
        FushiIcon(FushiIcons.link, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 10),
        Expanded(
          child: SelectableText(
            url,
            maxLines: 1,
            style:
                theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
          ),
        ),
        FushiIconButton(
          icon: Icons.copy,
          size: 18,
          tooltip: t.copy,
          onTap: () => _copy(url),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool inline = constraints.maxWidth >= 440;
        return Container(
          padding: const EdgeInsetsDirectional.fromSTEB(14, 4, 4, 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(SettingsKitRadii.small(style)),
          ),
          child: inline
              ? Row(children: <Widget>[Expanded(child: field), open])
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[field, open],
                ),
        );
      },
    );
  }

  /// 第 4 步：路径卡（等宽、复制、在文件管理器中打开）+ 「重新准备 / 刷新文件」
  /// tonal 按钮；还没准备时给「准备扩展文件」主按钮。
  Widget _folderStep(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? path = widget.path;
    final Widget prepareIcon = widget.preparing
        ? const SizedBox(
            width: 16,
            height: 16,
            child: FushiCircularProgressIndicator(strokeWidth: 2),
          )
        : const FushiIcon(FushiIcons.browserExtension, size: 18);
    if (path == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            t.browser_extension_folder_not_ready,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      );
    }
    final SettingsKitStyle style = SettingsKitStyle.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          padding: const EdgeInsetsDirectional.fromSTEB(14, 6, 4, 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(SettingsKitRadii.small(style)),
          ),
          child: Row(
            children: <Widget>[
              FushiIcon(
                FushiIcons.folder,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SelectableText(
                  path,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontFamily: 'monospace'),
                ),
              ),
              FushiIconButton(
                icon: Icons.copy,
                size: 18,
                tooltip: t.copy,
                onTap: () => _copy(path),
              ),
              FushiIconButton(
                icon: FushiIcons.folderOpen,
                size: 18,
                tooltip: t.media_file_location_open,
                onTap: () => _reveal(path),
              ),
            ],
          ),
        ),
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

  /// 第 5 步：自动配置完成说明 + 「检测连接」（结果显示在顶部状态卡）。
  Widget _verifyStep(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          t.browser_extension_step_done_auto,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        FushiFilledButton.tonalIcon(
          onPressed: widget.onVerify == null
              ? null
              : () {
                  _advance(_stepCount - 1);
                  widget.onVerify!();
                },
          icon: widget.verifying
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: FushiCircularProgressIndicator(strokeWidth: 2),
                )
              : const FushiIcon(FushiIcons.wifi, size: 18),
          label: Text(widget.verifying
              ? t.browser_extension_verify_checking
              : t.browser_extension_verify_button),
        ),
      ],
    );
  }
}

/// stepper 的步骤指示器：未到 = 中性圆 + 数字；当前 = primary 实心并弹簧形变成
/// 圆角方块（M3E）；已完成 = primary 圆 + 勾。
class _StepIndicator extends StatelessWidget {
  const _StepIndicator({
    required this.number,
    required this.done,
    required this.active,
  });

  final int number;
  final bool done;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool expressive =
        SettingsKitStyle.of(context) == SettingsKitStyle.expressive;
    const double extent = 32;
    return SettingsSpringValue(
      value: done || active ? 1 : 0,
      builder: (BuildContext context, double t, Widget? _) {
        final double c = t.clamp(0.0, 1.0);
        final double scale = 1 + math.max(0.0, t - 1) * 0.8;
        final double radius =
            active && expressive ? lerpDouble(extent / 2, 10, c)! : extent / 2;
        final Color fill =
            Color.lerp(scheme.surfaceContainerHighest, scheme.primary, c)!;
        final Color fg =
            Color.lerp(scheme.onSurfaceVariant, scheme.onPrimary, c)!;
        return Transform.scale(
          scale: scale,
          child: SizedBox.square(
            dimension: extent,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: fill,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(radius),
                ),
              ),
              child: Center(
                child: done
                    ? FushiIcon(FushiIcons.check, size: 18, color: fg)
                    : Text(
                        '$number',
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: fg,
                          fontWeight: FontWeight.w700,
                        ),
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
  int serverPort = kYomitanApiDefaultPort,
  bool portConflict = false,
  BrowserKind? detectedBrowser,
}) {
  return BrowserExtensionInstallSteps(
    path: path,
    serverEnabled: serverEnabled,
    hasToken: hasToken,
    serverPort: serverPort,
    portConflict: portConflict,
    detectedBrowser: detectedBrowser,
  );
}
