import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/import/quick_import_section.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_add_flow.dart';
import 'package:fushi/src/pages/implementations/galgame_home_page.dart';
import 'package:fushi/src/pages/implementations/game_diagnostics_page.dart';
import 'package:fushi/src/pages/implementations/game_shared.dart';
import 'package:fushi/src/pages/implementations/game_statistics_page.dart';
import 'package:fushi/src/pages/implementations/games_library_page.dart';
import 'package:fushi/src/pages/implementations/module_settings_view.dart';
import 'package:fushi/src/pages/implementations/texthooker_page.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';

// GameSection / gameSectionNotifier 已迁到 game_shared.dart（三页共享），
// 这里 re-export 保持既有 import 站点（如原生浮窗控制器）零改动。
export 'package:fushi/src/pages/implementations/game_shared.dart'
    show GameSection, gameSectionNotifier;

typedef GameMonitorBuilder = Widget Function(
  BuildContext context,
  VoidCallback onShowLibrary,
);
typedef GameLibraryBuilder = Widget Function(
  BuildContext context,
  GalHookSessionController controller,
  VoidCallback onLaunched,
);

/// 游戏首页（仪表盘）子页构造器；测试可注入桩，绕开 [GalgameHomePage] 对
/// `appProvider`（Drift DB / 仓储）的依赖。
typedef GameDashboardBuilder = Widget Function(
  BuildContext context,
  VoidCallback onShowLibrary,
);
typedef GameSettingsBuilder = Widget Function(
  BuildContext context,
  Widget navigation,
);

/// 首页一级「游戏」模块。
///
/// 集成持久化游戏库、Hook 监控工作台与兼容性诊断。内部使用 [IndexedStack]，
/// 从工作台返回游戏库不会销毁
/// [TexthookerPage] 所持有的文本、音频和窗口捕获会话。
class HomeGamePage extends StatefulWidget {
  const HomeGamePage({
    super.key,
    this.monitorBuilder,
    this.libraryBuilder,
    this.dashboardBuilder,
    this.settingsBuilder,
    this.controller,
  });

  final GameMonitorBuilder? monitorBuilder;
  final GameLibraryBuilder? libraryBuilder;
  final GameDashboardBuilder? dashboardBuilder;
  final GameSettingsBuilder? settingsBuilder;
  final GalHookSessionController? controller;

  static const Key dashboardKey = ValueKey<String>('game-dashboard');
  static const Key libraryKey = ValueKey<String>('game-library');
  static const Key monitorKey = ValueKey<String>('game-monitor');
  static const Key diagnosticsKey = ValueKey<String>('game-diagnostics');
  static const Key settingsKey = ValueKey<String>('game-settings');
  static const Key importKey = ValueKey<String>('game-import');

  /// 库页顶部会话状态带（原两张总览大卡的收敛替身），整条可点进入捕获工作台。
  static const Key captureStatusKey = ValueKey<String>('game-capture-status');

  @override
  State<HomeGamePage> createState() => _HomeGamePageState();
}

class _HomeGamePageState extends State<HomeGamePage> {
  late GameSection _section = gameSectionNotifier.value;
  late final GalHookSessionController _controller =
      widget.controller ?? GalHookSessionController.instance;

  @override
  void initState() {
    super.initState();
    gameSectionNotifier.addListener(_onSectionRequested);
  }

  @override
  void dispose() {
    gameSectionNotifier.removeListener(_onSectionRequested);
    // HomeGamePage 生命周期结束后不要把一次外部导航请求泄漏给下一次挂载（也避免
    // profile/窗口重建后意外停在旧工作台）。回落到默认首屏（游戏首页）。运行中的
    // 页面仍由 notifier 正常保态。
    gameSectionNotifier.value = GameSection.dashboard;
    super.dispose();
  }

  void _onSectionRequested() {
    final GameSection requested = gameSectionNotifier.value;
    if (requested == _section || !mounted) return;
    setState(() => _section = requested);
  }

  void _showSection(GameSection section) {
    if (gameSectionNotifier.value != section) {
      gameSectionNotifier.value = section;
      return;
    }
    _onSectionRequested();
  }

  void _showDashboard() => _showSection(GameSection.dashboard);
  void _showLibrary() => _showSection(GameSection.library);
  void _showMonitor() => _showSection(GameSection.monitor);
  void _showDiagnostics() => _showSection(GameSection.diagnostics);
  void _showSettings() => _showSection(GameSection.settings);

  Future<void> _openStatistics() => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => const GameStatisticsPage(),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final GameMonitorBuilder monitorBuilder = widget.monitorBuilder ??
        (BuildContext context, VoidCallback onShowLibrary) => TexthookerPage(
              embedded: true,
              captureSetupEnabled: _section == GameSection.monitor,
              onShowLibrary: onShowLibrary,
              onShowDiagnostics: _showDiagnostics,
            );
    final GameDashboardBuilder dashboardBuilder = widget.dashboardBuilder ??
        (BuildContext context, VoidCallback onShowLibrary) => GalgameHomePage(
              sessionController: _controller,
              onShowLibrary: onShowLibrary,
              onShowMonitor: _showMonitor,
              onShowDiagnostics: _showDiagnostics,
              onLaunched: _showMonitor,
            );
    return Material(
      type: MaterialType.transparency,
      child: IndexedStack(
        index: _section.index,
        children: <Widget>[
          KeyedSubtree(
            key: HomeGamePage.dashboardKey,
            child: dashboardBuilder(context, _showLibrary),
          ),
          KeyedSubtree(
            key: HomeGamePage.libraryKey,
            child: _buildLibrary(context),
          ),
          KeyedSubtree(
            key: HomeGamePage.monitorKey,
            child: monitorBuilder(context, _showLibrary),
          ),
          KeyedSubtree(
            key: HomeGamePage.diagnosticsKey,
            child: GameDiagnosticsPage(
              controller: _controller,
              onShowLibrary: _showLibrary,
              onShowCapture: _showMonitor,
            ),
          ),
          KeyedSubtree(
            key: HomeGamePage.settingsKey,
            child: Builder(
              builder: (BuildContext context) {
                final Widget navigation = GameSectionTabs(
                  selected: GameSection.settings,
                  focusIdPrefix: 'game-settings-tab',
                  onSelectDashboard: _showDashboard,
                  onSelectLibrary: _showLibrary,
                  onSelectMonitor: _showMonitor,
                  onSelectSettings: _showSettings,
                );
                return widget.settingsBuilder?.call(context, navigation) ??
                    ModuleSettingsView(
                      destinationId: SettingsDestinationId.game,
                      navigation: navigation,
                    );
              },
            ),
          ),
          KeyedSubtree(
            key: HomeGamePage.importKey,
            child: _buildImport(context),
          ),
        ],
      ),
    );
  }

  /// 游戏「导入」视图：与书 / 漫画 / 视频库页的「导入」视图同构同位（快速导入
  /// 区收纳单件入口；游戏暂无扫描根概念，故本页只有快速导入一区）。
  Widget _buildImport(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          FushiPageHeader.customTitle(
            title: GameSectionTabs(
              selected: GameSection.importGames,
              focusIdPrefix: 'game-import-tab',
              onSelectDashboard: _showDashboard,
              onSelectLibrary: _showLibrary,
              onSelectMonitor: _showMonitor,
              onSelectSettings: _showSettings,
            ),
            actions: const <Widget>[],
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Builder(
                    builder: (BuildContext context) {
                      return QuickImportSection(
                        actions: <QuickImportAction>[
                          QuickImportAction(
                            icon: Icons.videogame_asset_outlined,
                            label: t.game_add,
                            // IndexedStack 急切构建全部子区，本视图在无
                            // ProviderScope 的 widget 测试里也会被 build——
                            // 容器只在点按时解析，构建期零 provider 依赖。
                            onTap: () => addGameViaFilePicker(
                              ProviderScope.containerOf(context, listen: false)
                                  .read(appProvider)
                                  .galgameRepo,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  Text(
                    t.game_import_drop_hint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLibrary(BuildContext context) {
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          FushiPageHeader.customTitle(
            actions: <Widget>[
              FushiIconButton(
                icon: Icons.bar_chart_outlined,
                tooltip: t.game_statistics,
                label: t.game_statistics,
                onTap: _openStatistics,
              ),
            ],
            title: GameSectionTabs(
              selected: GameSection.library,
              focusIdPrefix: 'game-library-tab',
              onSelectDashboard: _showDashboard,
              onSelectLibrary: _showLibrary,
              onSelectMonitor: _showMonitor,
              onSelectSettings: _showSettings,
            ),
            // 顶部不再放「捕获工作台」图标钮——它与下方 GameSectionTabs 的
            // 「捕获工作台」分段去向完全相同，纯冗余；入口收敛到分段导航 + 状态带。
          ),
          Expanded(
            child: Column(
              children: <Widget>[
                // 顶部一条紧凑会话状态带（原两张总览大卡的收敛替身）：只留库页独有
                // 的会话摘要，整条可点进入捕获工作台。诊断细节（序号缺口 / 端点连通）
                // 归诊断页，不再挤占库页面积。
                AnimatedBuilder(
                  animation: _controller,
                  builder: (BuildContext context, Widget? child) {
                    final GalHookSessionState state = _controller.state;
                    final lines = _controller.lines;
                    final GalWorkbenchReadiness readiness =
                        galWorkbenchReadiness(
                      state: state,
                      hasEngineSource: _controller.hasEngineSource,
                      selectedTextThreadKey: _controller.selectedTextThreadKey,
                    );
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: _CaptureStatusStrip(
                        lineCount: lines.length,
                        latestLine: lines.isEmpty ? null : lines.last.text,
                        state: state,
                        readiness: readiness,
                        onOpen: _showMonitor,
                      ),
                    );
                  },
                ),
                const Divider(height: 1),
                Expanded(
                  child: widget.libraryBuilder?.call(
                        context,
                        _controller,
                        _showMonitor,
                      ) ??
                      GamesLibraryPage(
                        embedded: true,
                        sessionController: _controller,
                        onLaunched: _showMonitor,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 库页顶部的紧凑会话状态带：把此前两张总览大卡（捕获总览 + 诊断总览）收敛成
/// 一条单/两行高的 surface 容器，横向排列库页独有的会话摘要。整条可点进入捕获
/// 工作台（保留快捷入口但不再放显式大按钮 / 冗余图标钮）；序号缺口、端点连通数
/// 这类诊断细节留给诊断页，库页不再展示。
class _CaptureStatusStrip extends StatelessWidget {
  const _CaptureStatusStrip({
    required this.lineCount,
    required this.latestLine,
    required this.state,
    required this.readiness,
    required this.onOpen,
  });

  final int lineCount;
  final String? latestLine;
  final GalHookSessionState state;
  final GalWorkbenchReadiness readiness;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    // 有台词、或会话阶段非 idle/error，都算「在捕获」——阶段已 running 但尚未
    // 产出台词时仍显示活动态，而不是回落到「尚未开始」。
    final bool active =
        readiness != GalWorkbenchReadiness.idle || lineCount > 0;
    final Color accent = active ? colors.primary : colors.onSurfaceVariant;

    final Widget detail = active
        ? readiness == GalWorkbenchReadiness.waitingForThread
            ? _buildWaitingForThreadDetail(theme, colors)
            : _buildActiveDetail(theme, colors)
        : Text(
            '${t.game_session_idle}  ·  ${t.game_open_capture_workspace}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          );

    return FushiCard(
      key: HomeGamePage.captureStatusKey,
      focusId: const FushiFocusId('game-capture-status'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: active ? colors.primaryContainer.withValues(alpha: 0.45) : null,
      onTap: onOpen,
      child: Row(
        children: <Widget>[
          Icon(
            active ? Icons.sensors : Icons.sensors_off_outlined,
            color: accent,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(child: detail),
          const SizedBox(width: 8),
          Icon(Icons.chevron_right, color: colors.onSurfaceVariant, size: 20),
        ],
      ),
    );
  }

  Widget _buildWaitingForThreadDetail(
    ThemeData theme,
    ColorScheme colors,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          t.game_session_waiting_thread,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelLarge,
        ),
        const SizedBox(height: 4),
        Text(
          t.game_text_thread_unset,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// 活动态：横向排关键状态（正在捕获 · 台词数 · 音频来源 · Hook 阶段），
  /// 下方一行截断的最新台词。
  Widget _buildActiveDetail(ThemeData theme, ColorScheme colors) {
    final String meta = <String>[
      t.game_capture_active,
      '${t.game_captured_lines} $lineCount',
      galHookAudioBackendLabel(state.audioBackend),
      galHookSessionPhaseLabel(state.phase),
    ].join('  ·  ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          meta,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelLarge,
        ),
        const SizedBox(height: 4),
        Text(
          latestLine ?? t.game_waiting_for_text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
