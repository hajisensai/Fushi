import 'package:flutter/material.dart';
import 'package:hibiki/src/pages/implementations/texthooker_page.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/utils.dart';

typedef GameMonitorBuilder = Widget Function(
  BuildContext context,
  VoidCallback onShowLibrary,
);

/// 首页一级「游戏」模块。
///
/// M0 先提供真实的 Hook 状态入口和监控工作台；游戏配置/兼容性历史尚未落库时显示
/// 明确空状态，不伪造游戏数据。内部使用 [IndexedStack]，从工作台返回游戏库不会销毁
/// [TexthookerPage] 所持有的文本、音频和窗口捕获会话。
class HomeGamePage extends StatefulWidget {
  const HomeGamePage({super.key, this.monitorBuilder});

  final GameMonitorBuilder? monitorBuilder;

  static const Key libraryKey = ValueKey<String>('game-library');
  static const Key monitorKey = ValueKey<String>('game-monitor');
  static const Key openCaptureKey = ValueKey<String>('game-open-capture');

  @override
  State<HomeGamePage> createState() => _HomeGamePageState();
}

enum _GameSection { library, monitor }

class _HomeGamePageState extends State<HomeGamePage> {
  _GameSection _section = _GameSection.library;

  void _showLibrary() => setState(() => _section = _GameSection.library);
  void _showMonitor() => setState(() => _section = _GameSection.monitor);

  @override
  Widget build(BuildContext context) {
    final GameMonitorBuilder monitorBuilder = widget.monitorBuilder ??
        (BuildContext context, VoidCallback onShowLibrary) => TexthookerPage(
              embedded: true,
              onShowLibrary: onShowLibrary,
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
                    onSelected: (_) => _showLibrary(),
                  ),
                  const SizedBox(width: 8),
                  HibikiSelectableChip(
                    label: t.game_capture_workbench,
                    leadingIcon: Icons.sensors_outlined,
                    selected: false,
                    onSelected: (_) => _showMonitor(),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: AnimatedBuilder(
              animation: TexthookerService.instance,
              builder: (BuildContext context, Widget? child) {
                final List<String> lines = TexthookerService.instance.lines;
                return LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final bool wide = constraints.maxWidth >= 720;
                    final List<Widget> cards = <Widget>[
                      Expanded(
                        child: _CaptureOverviewCard(
                          lineCount: lines.length,
                          latestLine: lines.isEmpty ? null : lines.last,
                          onOpen: _showMonitor,
                        ),
                      ),
                      SizedBox(width: wide ? 16 : 0, height: wide ? 0 : 16),
                      const Expanded(child: _GameLibraryEmptyCard()),
                    ];
                    return SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      child: wide
                          ? IntrinsicHeight(child: Row(children: cards))
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                _CaptureOverviewCard(
                                  lineCount: lines.length,
                                  latestLine: lines.isEmpty ? null : lines.last,
                                  onOpen: _showMonitor,
                                ),
                                const SizedBox(height: 16),
                                const _GameLibraryEmptyCard(),
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
    required this.onOpen,
  });

  final int lineCount;
  final String? latestLine;
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
