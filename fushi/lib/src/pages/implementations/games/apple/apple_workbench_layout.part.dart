part of '../../texthooker_page.dart';

// Cupertino（iOS 27 / macOS 27）捕获工作台的版面骨架。
//
// - macOS 档（桌面平台 + 窗宽 ≥ [kGalWorkbenchWideBreakpoint]）：三栏——左浮动
//   侧栏（会话状态 / 实时信号 / 游戏内查词 / 会话工具）、中间纯行台词列表、右侧
//   「本句」Inspector（无选中行时收起，工具栏按钮可手动展开）。
// - iOS 档（其余）：台词列表是根页，顶部一条会话摘要（行内停止 / 「＋」），点摘要
//   推「会话」页，点台词推「本句」页。
//
// 业务状态与动作只在 [_TexthookerPageState]；这里只摆放同一份数据与回调。

/// macOS 档左侧浮动侧栏宽度。
const double _kAppleSidebarWidth = 300;

/// macOS 档右侧 Inspector 宽度。
const double _kAppleInspectorWidth = 340;

/// 一行台词的展示数据（M3E 分段卡与 Cupertino 列表行共用同一份判据，见
/// [_TexthookerPageState._lineRowModel]）。
class _LineRowModel {
  const _LineRowModel({
    required this.line,
    required this.displayText,
    required this.sourceOffset,
    required this.presentation,
    required this.words,
    required this.selected,
    required this.previewingAudio,
    required this.canPickTrack,
    required this.canRecapture,
    required this.recapturing,
    required this.autoLookupCharIndex,
  });

  final TexthookerLineEntry line;
  final String displayText;
  final int sourceOffset;
  final TexthookerLinePresentation presentation;
  final List<String> words;
  final bool selected;
  final bool previewingAudio;
  final bool canPickTrack;
  final bool canRecapture;
  final bool recapturing;
  final int? autoLookupCharIndex;
}

/// 一帧工作台的数据快照：版面、侧栏、会话页都从这一份取。
class _AppleWorkbench {
  const _AppleWorkbench({
    required this.state,
    required this.lines,
    required this.textThreads,
    required this.selectedTextThreadKey,
    required this.readiness,
    required this.selectedLine,
    required this.sessionTools,
    required this.canStart,
    required this.embedded,
    required this.game,
    required this.ankiConfigured,
    required this.summary,
  });

  final GalHookSessionState state;
  final List<TexthookerLineEntry> lines;
  final List<TexthookerTextThread> textThreads;
  final String? selectedTextThreadKey;
  final GalWorkbenchReadiness readiness;
  final TexthookerLineEntry? selectedLine;
  final List<List<_SessionTool>> sessionTools;
  final bool canStart;
  final bool embedded;
  final GalgameEntry? game;
  final bool ankiConfigured;
  final _SessionSummary summary;

  /// 会话工具（不含起点动作——那三项捕获中在「＋」里、未开始时在欢迎行里）。
  List<_SessionTool> get regularTools => <_SessionTool>[
    for (final List<_SessionTool> group in sessionTools)
      for (final _SessionTool tool in group)
        if (!tool.danger && !tool.start) tool,
  ];

  List<_SessionTool> get dangerousTools => <_SessionTool>[
    for (final List<_SessionTool> group in sessionTools)
      for (final _SessionTool tool in group)
        if (tool.danger) tool,
  ];

  bool get hasSelectedBodyThread =>
      selectedTextThreadKey != null &&
      textThreads.any(
        (TexthookerTextThread thread) => thread.key == selectedTextThreadKey,
      );
}

extension _AppleWorkbenchLayout on _TexthookerPageState {
  /// 按当前会话 / 台词现算一份快照（推出去的「会话」「本句」页随会话刷新时用；
  /// 主体 build 走 [_buildMonitorBody] 已算好的同一组值）。
  _AppleWorkbench _appleWorkbenchSnapshot() {
    final GalHookSessionState state = _session.state;
    final List<TexthookerLineEntry> lines = _session.workbenchLines;
    final String? selectedKey = _session.selectedTextThreadKey;
    final GalWorkbenchReadiness readiness = galWorkbenchReadiness(
      state: state,
      requiresTextThread: _session.requiresTextThreadSelection,
      selectedTextThreadKey: selectedKey,
    );
    final bool embedded = widget.embedded;
    final bool canStart = embedded && _hookCapture && !state.isActive;
    final String? launchExe = state.launchExe;
    final GalgameEntry? game =
        launchExe == null ||
            launchExe.trim().isEmpty ||
            !_appModel.isInitialised
        ? null
        : findGalgameByExePath(_appModel.galgameRepo.games, launchExe);
    final bool ankiConfigured = ref.read(ankiViewModelProvider).isConfigured;
    return _AppleWorkbench(
      state: state,
      lines: lines,
      textThreads: _session.textThreads,
      selectedTextThreadKey: selectedKey,
      readiness: readiness,
      selectedLine: _selectedLine(lines),
      sessionTools: embedded
          ? _buildToolbarActions(embedded: true)
          : const <List<_SessionTool>>[],
      canStart: canStart,
      embedded: embedded,
      game: game,
      ankiConfigured: ankiConfigured,
      summary: _SessionSummary.of(
        state: state,
        readiness: readiness,
        game: game,
        compact: false,
        hasStart: canStart,
        ankiConfigured: ankiConfigured,
      ),
    );
  }

  Widget _buildAppleMonitorBody(
    BuildContext context,
    List<TexthookerLineEntry> lines,
    List<TexthookerTextThread> textThreads,
    String? selectedTextThreadKey, {
    required GalWorkbenchReadiness readiness,
    required TexthookerLineEntry? selectedLine,
    required List<List<_SessionTool>> sessionTools,
    required bool canStart,
    required bool embeddedSession,
    required GalgameEntry? sessionGame,
    required bool ankiConfigured,
  }) {
    final GalHookSessionState state = _session.state;
    final _AppleWorkbench w = _AppleWorkbench(
      state: state,
      lines: lines,
      textThreads: textThreads,
      selectedTextThreadKey: selectedTextThreadKey,
      readiness: readiness,
      selectedLine: selectedLine,
      sessionTools: sessionTools,
      canStart: canStart,
      embedded: embeddedSession,
      game: sessionGame,
      ankiConfigured: ankiConfigured,
      summary: _SessionSummary.of(
        state: state,
        readiness: readiness,
        game: sessionGame,
        compact: false,
        hasStart: canStart,
        ankiConfigured: ankiConfigured,
      ),
    );
    // 与 M3E 同理：固定版面，滚轮停在侧栏 / 列表头 / 空白处时转给台词列表。
    return WheelScrollForwarder(
      controller: _scroll,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (state.externalWindowMode) _buildExternalWindowBar(context),
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints box) {
                final bool mac =
                    fushiAppleUsesMacMetrics(context) &&
                    box.maxWidth >= kGalWorkbenchWideBreakpoint;
                return mac
                    ? _buildAppleMacLayout(context, w)
                    : _buildAppleCompactLayout(context, w);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppleMacLayout(BuildContext context, _AppleWorkbench w) {
    final bool inspectorOpen = w.selectedLine != null || _appleInspectorPinned;
    return Padding(
      key: const ValueKey<String>('game-apple-workbench-mac'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            width: _kAppleSidebarWidth,
            child: _buildAppleSidebar(context, w),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildAppleLinesColumn(
              context,
              w,
              mac: true,
              inspectorOpen: inspectorOpen,
            ),
          ),
          GalWorkbenchDetailPane(
            open: inspectorOpen,
            width: _kAppleInspectorWidth,
            child: _buildAppleInspector(context, w),
          ),
        ],
      ),
    );
  }

  Widget _buildAppleCompactLayout(BuildContext context, _AppleWorkbench w) {
    return Column(
      key: const ValueKey<String>('game-apple-workbench-compact'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: _buildAppleSessionSummaryRow(context, w),
        ),
        Expanded(
          child: _buildAppleLinesColumn(
            context,
            w,
            mac: false,
            inspectorOpen: false,
          ),
        ),
      ],
    );
  }
}

/// Apple 分区标题（侧栏 / 会话页 / Inspector 共用）：footnote 字阶、secondaryLabel、
/// 半粗，与 macOS 侧栏分区头同形。与设计系统分派无关——只在 Apple 分支用。
class _AppleSectionTitle extends StatelessWidget {
  const _AppleSectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final FushiAppleColors apple = appleColorsOf(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(metrics.rowHorizontal, 14, 8, 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: metrics
                  .footnoteStyle(context)
                  .copyWith(
                    color: apple.secondaryLabel,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 状态小圆点（会话阶段 / 信号就绪）：只着点，不铺整块底。
class _AppleStatusDot extends StatelessWidget {
  const _AppleStatusDot({required this.color, this.size = 8});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

/// 系统色胶囊（会话阶段签）：淡底 + 同色字，不整块着色。
class _AppleStatusCapsule extends StatelessWidget {
  const _AppleStatusCapsule({
    required this.label,
    required this.color,
    super.key,
  });

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: color.withValues(alpha: 0.16),
        shape: const StadiumBorder(),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: metrics
              .footnoteStyle(context)
              .copyWith(color: color, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

/// 会话阶段对应的系统色（错误 / 降级·等线程 / 监听中 / 空闲）。
Color _appleSessionToneColor(BuildContext context, FushiTagTone tone) {
  final FushiAppleColors apple = appleColorsOf(context);
  return switch (tone) {
    FushiTagTone.error => apple.destructive,
    FushiTagTone.warning => apple.warning,
    FushiTagTone.success => apple.success,
    _ => apple.secondaryLabel,
  };
}
