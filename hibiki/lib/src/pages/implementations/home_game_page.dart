import 'package:flutter/material.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/pages/implementations/game_diagnostics_page.dart';
import 'package:hibiki/src/pages/implementations/texthooker_page.dart';
import 'package:hibiki/utils.dart';

typedef GameMonitorBuilder = Widget Function(
  BuildContext context,
  VoidCallback onShowLibrary,
);

enum GameSection { library, monitor, diagnostics }

/// App 级游戏页子区导航。原生 Hook 浮窗可在主窗最小化时请求回到捕获工作台。
final ValueNotifier<GameSection> gameSectionNotifier =
    ValueNotifier<GameSection>(GameSection.library);

/// 首页一级「游戏」模块。
///
/// M0 先提供真实的 Hook 状态入口和监控工作台；游戏配置/兼容性历史尚未落库时显示
/// 明确空状态，不伪造游戏数据。内部使用 [IndexedStack]，从工作台返回游戏库不会销毁
/// [TexthookerPage] 所持有的文本、音频和窗口捕获会话。
class HomeGamePage extends StatefulWidget {
  const HomeGamePage({
    super.key,
    this.monitorBuilder,
    this.controller,
  });

  final GameMonitorBuilder? monitorBuilder;
  final GalHookSessionController? controller;

  static const Key libraryKey = ValueKey<String>('game-library');
  static const Key monitorKey = ValueKey<String>('game-monitor');
  static const Key diagnosticsKey = ValueKey<String>('game-diagnostics');
  static const Key openCaptureKey = ValueKey<String>('game-open-capture');
  static const Key openDiagnosticsKey =
      ValueKey<String>('game-open-diagnostics');

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
    // profile/窗口重建后意外停在旧工作台）。运行中的页面仍由 notifier 正常保态。
    gameSectionNotifier.value = GameSection.library;
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

  void _showLibrary() => _showSection(GameSection.library);
  void _showMonitor() => _showSection(GameSection.monitor);
  void _showDiagnostics() => _showSection(GameSection.diagnostics);

  @override
  Widget build(BuildContext context) {
    final GameMonitorBuilder monitorBuilder = widget.monitorBuilder ??
        (BuildContext context, VoidCallback onShowLibrary) => TexthookerPage(
              embedded: true,
              onShowLibrary: onShowLibrary,
              onShowDiagnostics: _showDiagnostics,
            );
    return Material(
      type: MaterialType.transparency,
      child: IndexedStack(
        index: _section.index,
        children: <Widget>[
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
        ],
      ),
    );
  }

  Widget _buildLibrary(BuildContext context) {
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          HibikiPageHeader(
            title: t.nav_game,
            subtitle: t.game_home_subtitle,
            actions: <Widget>[
              HibikiIconButton(
                icon: Icons.sensors_outlined,
                tooltip: t.game_open_capture_workspace,
                label: t.game_capture_workbench,
                onTap: _showMonitor,
              ),
            ],
            bottom: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  HibikiSelectableChip(
                    label: t.game_library,
                    leadingIcon: Icons.sports_esports_outlined,
                    selected: true,
                    focusId: const HibikiFocusId('game-library-tab-library'),
                    onSelected: (_) => _showLibrary(),
                  ),
                  const SizedBox(width: 8),
                  HibikiSelectableChip(
                    label: t.game_capture_workbench,
                    leadingIcon: Icons.sensors_outlined,
                    selected: false,
                    focusId: const HibikiFocusId('game-library-tab-capture'),
                    onSelected: (_) => _showMonitor(),
                  ),
                  const SizedBox(width: 8),
                  HibikiSelectableChip(
                    label: t.game_diagnostics,
                    leadingIcon: Icons.monitor_heart_outlined,
                    selected: false,
                    focusId:
                        const HibikiFocusId('game-library-tab-diagnostics'),
                    onSelected: (_) => _showDiagnostics(),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (BuildContext context, Widget? child) {
                final GalHookSessionState state = _controller.state;
                final lines = _controller.lines;
                return LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final bool wide = constraints.maxWidth >= 980;
                    return SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      child: wide
                          ? IntrinsicHeight(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: <Widget>[
                                  Expanded(
                                    child: _CaptureOverviewCard(
                                      lineCount: lines.length,
                                      latestLine: lines.isEmpty
                                          ? null
                                          : lines.last.text,
                                      state: state,
                                      onOpen: _showMonitor,
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  const Expanded(
                                      child: _GameLibraryEmptyCard()),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: _DiagnosticsOverviewCard(
                                      controller: _controller,
                                      onOpen: _showDiagnostics,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                _CaptureOverviewCard(
                                  lineCount: lines.length,
                                  latestLine:
                                      lines.isEmpty ? null : lines.last.text,
                                  state: state,
                                  onOpen: _showMonitor,
                                ),
                                const SizedBox(height: 16),
                                const _GameLibraryEmptyCard(),
                                const SizedBox(height: 16),
                                _DiagnosticsOverviewCard(
                                  controller: _controller,
                                  onOpen: _showDiagnostics,
                                ),
                              ],
                            ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CaptureOverviewCard extends StatelessWidget {
  const _CaptureOverviewCard({
    required this.lineCount,
    required this.latestLine,
    required this.state,
    required this.onOpen,
  });

  final int lineCount;
  final String? latestLine;
  final GalHookSessionState state;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return HibikiCard(
      color: colors.primaryContainer.withValues(alpha: 0.55),
      onTap: onOpen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.sensors, color: colors.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  lineCount == 0 ? t.game_capture_ready : t.game_capture_active,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
          const SizedBox(height: 14),
          Text(t.game_capture_description),
          const SizedBox(height: 20),
          Text(
            '${t.game_captured_lines}  $lineCount',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          Text(
            '${t.game_health_audio}  ${_audioBackendLabel(state.audioBackend)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Text(
            latestLine ?? t.game_waiting_for_text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 18),
          FilledButton.tonalIcon(
            key: HomeGamePage.openCaptureKey,
            onPressed: onOpen,
            icon: const Icon(Icons.arrow_forward),
            label: Text(t.game_open_capture_workspace),
          ),
        ],
      ),
    );
  }
}

class _DiagnosticsOverviewCard extends StatelessWidget {
  const _DiagnosticsOverviewCard({
    required this.controller,
    required this.onOpen,
  });

  final GalHookSessionController controller;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final GalHookSessionState state = controller.state;
    final int connected = controller.endpointStatuses
        .where((endpoint) => endpoint.phase.name == 'connected')
        .length;
    return HibikiCard(
      onTap: onOpen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.monitor_heart_outlined,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  t.game_diagnostics,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
          const SizedBox(height: 14),
          Text(t.game_diagnostics_subtitle),
          const SizedBox(height: 20),
          Text('${t.game_health_helper}  ${state.phase.name}'),
          const SizedBox(height: 8),
          Text(
            '${t.game_text_endpoints}  $connected/${controller.endpointStatuses.length}',
          ),
          const SizedBox(height: 8),
          Text('${t.game_text_gaps}  ${state.textGapCount}'),
          const SizedBox(height: 18),
          FilledButton.tonalIcon(
            key: HomeGamePage.openDiagnosticsKey,
            onPressed: onOpen,
            icon: const Icon(Icons.arrow_forward),
            label: Text(t.game_open_diagnostics),
          ),
        ],
      ),
    );
  }
}

String _audioBackendLabel(GalHookAudioBackend backend) => switch (backend) {
      GalHookAudioBackend.none => t.game_audio_backend_none,
      GalHookAudioBackend.gameResource => t.game_audio_backend_resource,
      GalHookAudioBackend.enginePcm => t.game_audio_backend_engine,
      GalHookAudioBackend.systemLoopback => t.game_audio_backend_loopback,
    };

class _GameLibraryEmptyCard extends StatelessWidget {
  const _GameLibraryEmptyCard();

  @override
  Widget build(BuildContext context) {
    return HibikiCard(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(
            Icons.sports_esports_outlined,
            size: 42,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            t.game_library_empty_title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            t.game_library_empty_body,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}
