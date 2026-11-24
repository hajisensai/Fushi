part of '../../texthooker_page.dart';

// Cupertino 工作台：macOS 档左侧浮动侧栏 + iOS 档顶部会话摘要 / 「会话」页的分区。
//
// 「停止监听」与游戏内查词在捕获期间始终在视口内：macOS 侧栏把会话卡（含停止与
// 「＋」）钉在顶部、游戏内查词钉在底部，只有中间的信号 / 工具区滚动；iOS 档的
// 摘要行钉在台词列表上方，行内带停止与游戏内查词状态。

extension _AppleWorkbenchSidebar on _TexthookerPageState {
  Widget _buildAppleSidebar(BuildContext context, _AppleWorkbench w) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    return FushiGlassSurface(
      key: const ValueKey<String>('game-apple-sidebar'),
      grouped: true,
      borderRadius: metrics.groupBorderRadius,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final List<Widget> scrolling = _appleSessionSections(context, w);
          return Column(
            key: const ValueKey<String>('game-session-actions'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
                child: _buildAppleSessionCard(context, w),
              ),
              Expanded(
                // 侧栏中段是次级滚动区：通知不冒泡到页头、不认领主滚动控制器
                // （台词列表才是主滚动，同 M3E 侧栏）。
                child: NotificationListener<Notification>(
                  onNotification: (Notification n) =>
                      n is ScrollNotification || n is ScrollMetricsNotification,
                  child: SingleChildScrollView(
                    key: const ValueKey<String>('game-session-side'),
                    primary: false,
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                    child: FushiEntranceScope(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          for (int i = 0; i < scrolling.length; i++)
                            FushiStaggeredEntrance(
                              index: i,
                              child: scrolling[i],
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (_hookCapture)
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: box.maxHeight * 0.45),
                  child: SingleChildScrollView(
                    primary: false,
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                    child: _buildAppleLookupSection(context, w),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// 侧栏 / 「会话」页的中段：处置提示、实时信号、会话工具、危险操作。
  List<Widget> _appleSessionSections(
    BuildContext context,
    _AppleWorkbench w, {
    bool includeHealthPopover = true,
  }) {
    final GalHookSessionState state = w.state;
    final List<_SessionTool> regular = w.regularTools;
    final List<_SessionTool> dangerous = w.dangerousTools;
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    return <Widget>[
      if (state.knifeTextServiceIniPath != null)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: _buildKnifeTextServiceNotice(state),
        ),
      if (w.summary.signals.isNotEmpty) ...<Widget>[
        _AppleSectionTitle(t.game_workbench_signals_title),
        FushiAppleGroupSurface(
          borderRadius: metrics.groupBorderRadius,
          child: Column(
            children: <Widget>[
              for (int i = 0; i < w.summary.signals.length; i++)
                _AppleSignalRow(
                  signal: w.summary.signals[i],
                  last: i == w.summary.signals.length - 1,
                ),
            ],
          ),
        ),
      ],
      if (regular.isNotEmpty)
        Column(
          key: const ValueKey<String>('game-session-tools'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _AppleSectionTitle(t.game_workbench_tools_title),
            for (int i = 0; i < regular.length; i++)
              if (includeHealthPopover &&
                  regular[i].id == 'game-toolbar-health' &&
                  fushiAppleUsesMacMetrics(context))
                _buildAppleHealthPopoverTile(
                  context,
                  regular[i],
                  index: i,
                  count: regular.length,
                  ankiConfigured: w.ankiConfigured,
                )
              else
                regular[i].tile(index: i, count: regular.length),
          ],
        ),
      if (dangerous.isNotEmpty) ...<Widget>[
        const SizedBox(height: 14),
        for (int i = 0; i < dangerous.length; i++)
          dangerous[i].tile(index: i, count: dangerous.length),
      ],
    ];
  }

  /// 健康状态（macOS 档）：工具行就地弹 popover，内容随会话实时刷新。
  Widget _buildAppleHealthPopoverTile(
    BuildContext context,
    _SessionTool tool, {
    required int index,
    required int count,
    required bool ankiConfigured,
  }) {
    return FushiMenuAnchor(
      menuChildren: <Widget>[
        SizedBox(
          key: const ValueKey<String>('game-health-popover'),
          width: 320,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    t.game_health,
                    style: FushiAppleMetrics.of(
                      context,
                    ).titleStyle(context).copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                ListenableBuilder(
                  listenable: _session,
                  builder: (BuildContext context, Widget? child) =>
                      _CaptureHealthCard(
                        state: _session.state,
                        endpoints: _session.endpointStatuses,
                        ankiConfigured: ankiConfigured,
                      ),
                ),
              ],
            ),
          ),
        ),
      ],
      builder:
          (BuildContext context, MenuController controller, Widget? child) =>
              tool
                  .copyWith(
                    onTap: () => controller.isOpen
                        ? controller.close()
                        : controller.open(),
                  )
                  .tile(index: index, count: count),
    );
  }

  /// 会话卡：中性底 + 阶段圆点 / 系统色胶囊（不整块着色）；捕获中带「停止监听」
  /// 与「＋」（启动 / 附着 / OCR）。
  Widget _buildAppleSessionCard(BuildContext context, _AppleWorkbench w) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final GalHookSessionState state = w.state;
    final _SessionSummary summary = w.summary;
    final Color toneColor = summary.waitingForThread
        ? apple.warning
        : state.phase == GalHookSessionPhase.idle
        ? apple.tertiaryLabel
        : _appleSessionToneColor(context, summary.statusTone);
    final bool showStop = w.embedded && state.isActive;
    return FushiAppleGroupSurface(
      key: const ValueKey<String>('game-session-overview'),
      borderRadius: metrics.groupBorderRadius,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          metrics.rowHorizontal,
          12,
          metrics.rowHorizontal,
          12,
        ),
        child: FushiAnimatedSize(
          duration: context.fushiMotion.effectsDefault.duration,
          curve: context.fushiMotion.effectsDefault.curve,
          alignment: AlignmentDirectional.topStart,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  _AppleStatusDot(color: toneColor),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      summary.eyebrow,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: metrics
                          .footnoteStyle(context)
                          .copyWith(color: apple.secondaryLabel),
                    ),
                  ),
                  if (state.phase != GalHookSessionPhase.idle)
                    _AppleStatusCapsule(
                      key: const ValueKey<String>('game-session-status-chip'),
                      label: summary.statusLabel,
                      color: _appleSessionToneColor(
                        context,
                        summary.statusTone,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                summary.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.fushiType.titleMediumEmphasized.copyWith(
                  color: apple.label,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                summary.subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: metrics
                    .subtitleStyle(context)
                    .copyWith(color: apple.secondaryLabel),
              ),
              if (state.japaneseLocaleApplied ||
                  summary.localeSkippedHint != null ||
                  state.isOcrMode) ...<Widget>[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    if (state.japaneseLocaleApplied)
                      FushiTooltip(
                        message: t.game_session_japanese_locale_hint,
                        child: _AppleStatusCapsule(
                          label: t.game_session_japanese_locale,
                          color: apple.accent,
                        ),
                      )
                    else if (summary.localeSkippedHint != null)
                      FushiTooltip(
                        message: summary.localeSkippedHint!,
                        child: _AppleStatusCapsule(
                          label: t.game_session_japanese_locale_skipped,
                          color: apple.secondaryLabel,
                        ),
                      ),
                    if (state.isOcrMode)
                      FushiTooltip(
                        message: t.game_workbench_ocr_hint,
                        child: _AppleStatusCapsule(
                          label: t.game_ocr_mode_chip,
                          color: apple.accent,
                        ),
                      ),
                  ],
                ),
              ],
              for (final _SessionHint hint in summary.hints)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    hint.text,
                    maxLines: hint.maxLines,
                    overflow: TextOverflow.ellipsis,
                    style: metrics
                        .footnoteStyle(context)
                        .copyWith(
                          color: hint.emphasized
                              ? apple.warning
                              : apple.secondaryLabel,
                        ),
                  ),
                ),
              if (showStop) ...<Widget>[
                const SizedBox(height: 10),
                Row(
                  children: <Widget>[
                    Expanded(child: _buildAppleStopButton()),
                    if (_hookCapture) ...<Widget>[
                      const SizedBox(width: 6),
                      _buildAppleStartMenu(context),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAppleStopButton() {
    return FushiPressScale(
      child: FushiFilledButton.tonalIcon(
        key: const ValueKey<String>('game-action-stop'),
        onPressed: () => unawaited(_session.stopCapture()),
        icon: const FushiIcon(FushiIcons.stop, size: 18),
        label: Text(t.game_stop_listening),
      ),
    );
  }

  /// 「＋」下拉：捕获中换一个游戏重新捕获的三个起点（启动 / 附着 / OCR）。
  Widget _buildAppleStartMenu(BuildContext context) {
    return FushiMenuAnchor(
      menuChildren: <Widget>[
        MenuItemButton(
          key: const ValueKey<String>('game-apple-start-launch'),
          leadingIcon: const FushiIcon(CupertinoIcons.play_fill),
          onPressed: () => unawaited(_launchGalgameEngineHook()),
          child: Text(t.game_launch_and_capture),
        ),
        MenuItemButton(
          key: const ValueKey<String>('game-apple-start-attach'),
          leadingIcon: const FushiIcon(CupertinoIcons.link),
          onPressed: () => unawaited(_attachToRunningGame()),
          child: Text(t.game_attach_and_capture),
        ),
        MenuItemButton(
          key: const ValueKey<String>('game-apple-start-ocr'),
          leadingIcon: const FushiIcon(FushiIcons.ocr),
          onPressed: () => unawaited(_startOcrCapture()),
          child: Text(t.game_ocr_capture),
        ),
      ],
      builder:
          (BuildContext context, MenuController controller, Widget? child) =>
              FushiIconButton(
                key: const ValueKey<String>('game-apple-start-menu'),
                icon: CupertinoIcons.add,
                tooltip: t.game_workbench_start_title,
                focusId: const FushiFocusId('game-apple-start-menu'),
                onTap: () =>
                    controller.isOpen ? controller.close() : controller.open(),
              ),
    );
  }

  /// 游戏内查词分区（侧栏底部钉住 / 「会话」页）。
  Widget _buildAppleLookupSection(BuildContext context, _AppleWorkbench w) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _AppleSectionTitle(t.game_lookup_attached_title),
        GalAttachedLookupWorkbench(
          controller: GalHookTextOverlayController.instance.attachedText,
          hasSelectedBodyThread: w.hasSelectedBodyThread,
          bodyPreview: _selectedThreadPreview(
            w.textThreads,
            w.selectedTextThreadKey,
          ),
        ),
      ],
    );
  }

  /// iOS 档台词列表上方的会话摘要行：圆点 + 标题 / 副标题，行尾停止与「＋」；
  /// 捕获中另起一行游戏内查词状态（点开推「会话」页）。点摘要推「会话」页。
  Widget _buildAppleSessionSummaryRow(BuildContext context, _AppleWorkbench w) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final GalHookSessionState state = w.state;
    final _SessionSummary summary = w.summary;
    final Color toneColor = summary.waitingForThread
        ? apple.warning
        : state.phase == GalHookSessionPhase.idle
        ? apple.tertiaryLabel
        : _appleSessionToneColor(context, summary.statusTone);
    final bool showStop = w.embedded && state.isActive;
    final GalAttachedTextController attached =
        GalHookTextOverlayController.instance.attachedText;
    return FushiAppleGroupSurface(
      key: const ValueKey<String>('game-session-overview'),
      borderRadius: metrics.groupBorderRadius,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiAppleRow(
            onTap: () => unawaited(_pushAppleSessionPage()),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: metrics.rowHorizontal,
                vertical: 10,
              ),
              child: Row(
                children: <Widget>[
                  _AppleStatusDot(color: toneColor, size: 10),
                  SizedBox(width: metrics.leadingGap),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          summary.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: metrics
                              .titleStyle(context)
                              .copyWith(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          summary.started ? summary.eyebrow : summary.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: metrics
                              .subtitleStyle(context)
                              .copyWith(color: apple.secondaryLabel),
                        ),
                      ],
                    ),
                  ),
                  if (showStop) ...<Widget>[
                    const SizedBox(width: 8),
                    _buildAppleStopButton(),
                    if (_hookCapture) _buildAppleStartMenu(context),
                  ] else
                    const FushiAppleChevron(),
                ],
              ),
            ),
          ),
          if (_hookCapture && state.isActive) ...<Widget>[
            Padding(
              padding: EdgeInsetsDirectional.only(start: metrics.rowHorizontal),
              child: SizedBox(
                height: fushiHairline(context),
                child: ColoredBox(color: apple.separator),
              ),
            ),
            ListenableBuilder(
              listenable: attached,
              builder: (BuildContext context, Widget? child) => FushiAppleRow(
                key: const ValueKey<String>('game-apple-lookup-status'),
                onTap: () => unawaited(_pushAppleSessionPage()),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: metrics.rowHorizontal,
                    vertical: 8,
                  ),
                  child: Row(
                    children: <Widget>[
                      FushiIcon(
                        galAttachedTextStatusIcon(attached.status),
                        size: metrics.leadingIconSize,
                        color: apple.accent,
                      ),
                      SizedBox(width: metrics.leadingGap),
                      Expanded(
                        child: Text(
                          t.game_lookup_attached_title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: metrics.titleStyle(context),
                        ),
                      ),
                      Text(
                        galAttachedTextStatusLabel(attached.status),
                        style: metrics
                            .subtitleStyle(context)
                            .copyWith(color: apple.secondaryLabel),
                      ),
                      const SizedBox(width: 6),
                      const FushiAppleChevron(),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 一格实时信号（Apple）：行首圆点（就绪系统绿 / 未就绪三级灰）+ 名称 + 行尾值。
class _AppleSignalRow extends StatelessWidget {
  const _AppleSignalRow({required this.signal, required this.last});

  final _SessionSignal signal;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final Widget row = Container(
      key: signal.key,
      constraints: BoxConstraints(minHeight: metrics.rowMinHeight),
      padding: EdgeInsets.symmetric(horizontal: metrics.rowHorizontal),
      decoration: last
          ? null
          : BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: apple.separator,
                  width: fushiHairline(context),
                ),
              ),
            ),
      child: Row(
        children: <Widget>[
          _AppleStatusDot(
            color: signal.ready ? apple.success : apple.tertiaryLabel,
          ),
          SizedBox(width: metrics.leadingGap),
          Expanded(
            child: Text(signal.label, style: metrics.titleStyle(context)),
          ),
          Flexible(
            child: Text(
              signal.value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: metrics
                  .subtitleStyle(context)
                  .copyWith(color: apple.secondaryLabel),
            ),
          ),
        ],
      ),
    );
    final String? tooltip = signal.tooltip;
    return tooltip == null ? row : FushiTooltip(message: tooltip, child: row);
  }
}
