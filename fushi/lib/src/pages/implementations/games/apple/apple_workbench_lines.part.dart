part of '../../texthooker_page.dart';

// Cupertino 工作台：中间的纯行台词列表（列表头工具栏 + 线程 / 筛选 + 行）。
//
// - 行动作（试听 / 改轨 / 补录 / 复制 / 收藏）macOS 档只在悬停、选中或焦点落在行内
//   时出现，另有右键菜单；iOS 档不放行内按钮，改左滑露出试听 / 收藏 + 长按菜单。
// - 状态图标（制卡 / 音频 / 已收藏星）常显。
// - 选中行铺强调色淡底。

/// 选中行底色：强调色 14% 淡底（不描边）。
const double _kAppleLineSelectedAlpha = 0.14;

extension _AppleWorkbenchLines on _TexthookerPageState {
  Widget _buildAppleLinesColumn(
    BuildContext context,
    _AppleWorkbench w, {
    required bool mac,
    required bool inspectorOpen,
  }) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final List<TexthookerLineEntry> visibleLines = w.lines
        .where((TexthookerLineEntry e) => lineMatchesFilter(e, _lineFilter))
        .toList(growable: false);
    final Widget threadRow = Row(
      children: <Widget>[
        Expanded(
          child: _buildThreadSelector(w.textThreads, w.selectedTextThreadKey),
        ),
        const SizedBox(width: 4),
        _buildTextProcessEntry(context, w.textThreads, w.selectedTextThreadKey),
      ],
    );
    final Widget list = w.lines.isEmpty
        ? _buildAppleLinesEmpty(context, w)
        : FushiEntranceScope(
            replayKey: (w.selectedTextThreadKey, _lineFilter),
            child: ListView.builder(
              controller: _scroll,
              padding: EdgeInsets.fromLTRB(mac ? 8 : 12, 4, mac ? 8 : 12, 12),
              itemCount: visibleLines.length,
              itemBuilder: fushiStaggeredItemBuilder((
                BuildContext context,
                int i,
              ) {
                final _LineRowModel row = _lineRowModel(visibleLines[i]);
                return _AppleLineRow(
                  key: ValueKey<String>('game-apple-line-${row.line.id}'),
                  row: row,
                  mac: mac,
                  autoLookupAnchorKey: _autoLookupAnchorKey,
                  onSelect: _selectLine,
                  onOpen: (TexthookerLineEntry line) =>
                      unawaited(_pushAppleLinePage(line)),
                  onCharTap: _onCharTap,
                  onToggleFavorite: _toggleLineFavorite,
                  onPreviewAudio: (TexthookerLineEntry l) =>
                      unawaited(_toggleLinePreview(l)),
                  onPickTrack: (TexthookerLineEntry l) =>
                      unawaited(_pickLineTrack(l)),
                  onRecapture: (TexthookerLineEntry l) =>
                      unawaited(_toggleLineRecapture(l)),
                  onCopy: (TexthookerLineEntry _) =>
                      _appModel.copyToClipboard(row.displayText),
                );
              }),
            ),
          );
    final Widget column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(metrics.rowHorizontal, 10, 8, 4),
          child: _buildAppleLinesHeader(
            context,
            w,
            mac: mac,
            inspectorOpen: inspectorOpen,
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(metrics.rowHorizontal, 4, 8, 8),
          child: mac
              ? LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints box) {
                    final Widget filter = _buildAppleFilterSegments(
                      context,
                      w.lines,
                    );
                    if (box.maxWidth >= 640) {
                      return Row(
                        children: <Widget>[
                          SizedBox(width: 320, child: threadRow),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Align(
                              alignment: AlignmentDirectional.centerEnd,
                              child: filter,
                            ),
                          ),
                        ],
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        threadRow,
                        const SizedBox(height: 8),
                        filter,
                      ],
                    );
                  },
                )
              : threadRow,
        ),
        SizedBox(
          height: fushiHairline(context),
          child: ColoredBox(color: apple.separator),
        ),
        Expanded(child: list),
      ],
    );
    if (!mac) return column;
    return FushiAppleGroupSurface(
      key: const ValueKey<String>('game-apple-lines'),
      borderRadius: metrics.groupBorderRadius,
      child: column,
    );
  }

  /// 列表头：标题 + 计数 + 未读；macOS 行尾平铺「跟随实时」「自动查词」开关、
  /// 特殊码下拉与 Inspector 开关；iOS 行尾一个「⋯」（筛选带计数、两个开关、特殊码）。
  Widget _buildAppleLinesHeader(
    BuildContext context,
    _AppleWorkbench w, {
    required bool mac,
    required bool inspectorOpen,
  }) {
    final FushiAppleColors apple = appleColorsOf(context);
    final Widget title = Row(
      children: <Widget>[
        Flexible(
          child: Text(
            t.game_live_lines,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.fushiType.titleLargeEmphasized.copyWith(
              color: apple.label,
            ),
          ),
        ),
        const SizedBox(width: 8),
        _LineCountBadge(count: w.lines.length),
        const SizedBox(width: 8),
        AnimatedSwitcher(
          duration: context.fushiMotion.effectsDefault.duration,
          switchInCurve: context.fushiMotion.effectsDefault.curve,
          switchOutCurve: context.fushiMotion.effectsFast.curve,
          child: _unreadLines > 0
              ? FushiFilledButton.tonal(
                  key: const ValueKey<String>('game-unread-lines'),
                  size: FushiButtonSize.xs,
                  onPressed: _jumpToLatestAndClearUnread,
                  child: Text('${t.game_unread_lines} $_unreadLines'),
                )
              : const SizedBox.shrink(
                  key: ValueKey<String>('game-unread-none'),
                ),
        ),
      ],
    );
    final List<Widget> actions = mac
        ? <Widget>[
            FushiIconButton(
              key: const ValueKey<String>('game-follow-live'),
              icon: FushiIcons.alignBottom,
              tooltip: t.game_follow_live,
              selected: _followLive,
              focusId: const FushiFocusId('game-follow-live'),
              onTap: () => _setFollowLive(!_followLive),
            ),
            FushiIconButton(
              key: const ValueKey<String>('game-auto-lookup'),
              icon: FushiIcons.manageSearch,
              tooltip: t.game_auto_lookup_new_lines_tooltip,
              selected: _autoLookupNewLines,
              focusId: const FushiFocusId('game-auto-lookup'),
              onTap: () => _setAutoLookupNewLines(!_autoLookupNewLines),
            ),
            _buildAppleHookCodeMenu(context),
            FushiIconButton(
              key: const ValueKey<String>('game-inspector-toggle'),
              icon: CupertinoIcons.sidebar_right,
              tooltip: inspectorOpen
                  ? t.game_workbench_detail_close
                  : t.game_workbench_detail_open,
              selected: inspectorOpen,
              focusId: const FushiFocusId('game-inspector-toggle'),
              onTap: () => _toggleAppleInspector(open: inspectorOpen),
            ),
          ]
        : <Widget>[_buildAppleMoreMenu(context, w)];
    return Row(
      children: <Widget>[
        Expanded(child: title),
        const SizedBox(width: 8),
        for (int i = 0; i < actions.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 2),
          actions[i],
        ],
      ],
    );
  }

  /// macOS 档筛选：Apple 分段控件，只写字 + 计数，不带图标。
  Widget _buildAppleFilterSegments(
    BuildContext context,
    List<TexthookerLineEntry> lines,
  ) {
    return KeyedSubtree(
      key: const ValueKey<String>('game-line-filter'),
      child: adaptiveSegmentedButton<TexthookerLineFilter>(
        context: context,
        segments: <ButtonSegment<TexthookerLineFilter>>[
          for (final (TexthookerLineFilter, String, int, IconData) spec
              in _lineFilterSpecs(lines))
            ButtonSegment<TexthookerLineFilter>(
              value: spec.$1,
              label: Text('${spec.$2} ${spec.$3}'),
            ),
        ],
        selected: <TexthookerLineFilter>{_lineFilter},
        onSelectionChanged: (Set<TexthookerLineFilter> picked) {
          if (picked.isEmpty) return;
          _setLineFilter(picked.first);
        },
      ),
    );
  }

  List<Widget> _appleHookCodeItems() => <Widget>[
    for (final (_HookCodeAction, IconData, String) item
        in <(_HookCodeAction, IconData, String)>[
          (
            _HookCodeAction.paste,
            FushiIcons.paste,
            t.game_hook_code_paste_title,
          ),
          (_HookCodeAction.save, FushiIcons.bookmarkAdd, t.dialog_save),
          (_HookCodeAction.import, FushiIcons.download, t.dialog_import),
          (_HookCodeAction.export, FushiIcons.upload, t.dialog_export),
        ])
      MenuItemButton(
        key: ValueKey<String>('game-hook-code-${item.$1.name}'),
        leadingIcon: FushiIcon(item.$2),
        onPressed: () => unawaited(_runHookCodeAction(item.$1)),
        child: Text(item.$3),
      ),
  ];

  /// 特殊码下拉（macOS 档工具栏）：粘贴 / 保存当前线程 / 导入 / 导出。
  Widget _buildAppleHookCodeMenu(BuildContext context) {
    return FushiMenuAnchor(
      menuChildren: _appleHookCodeItems(),
      builder:
          (BuildContext context, MenuController controller, Widget? child) =>
              FushiIconButton(
                key: const ValueKey<String>('game-hook-code-menu'),
                icon: CupertinoIcons.chevron_left_slash_chevron_right,
                tooltip: t.game_workbench_hook_code,
                focusId: const FushiFocusId('game-hook-code-menu'),
                onTap: () =>
                    controller.isOpen ? controller.close() : controller.open(),
              ),
    );
  }

  /// iOS 档「⋯」：筛选（带计数、当前项 ✓）、跟随实时 / 自动查词、特殊码子菜单。
  Widget _buildAppleMoreMenu(BuildContext context, _AppleWorkbench w) {
    return FushiMenuAnchor(
      menuChildren: <Widget>[
        for (final (TexthookerLineFilter, String, int, IconData) spec
            in _lineFilterSpecs(w.lines))
          RadioMenuButton<TexthookerLineFilter>(
            key: ValueKey<String>('game-apple-filter-${spec.$1.name}'),
            value: spec.$1,
            groupValue: _lineFilter,
            onChanged: (TexthookerLineFilter? picked) {
              if (picked != null) _setLineFilter(picked);
            },
            child: Text('${spec.$2} ${spec.$3}'),
          ),
        CheckboxMenuButton(
          key: const ValueKey<String>('game-follow-live'),
          value: _followLive,
          onChanged: (bool? value) => _setFollowLive(value ?? false),
          child: Text(t.game_follow_live),
        ),
        CheckboxMenuButton(
          key: const ValueKey<String>('game-auto-lookup'),
          value: _autoLookupNewLines,
          onChanged: (bool? value) => _setAutoLookupNewLines(value ?? false),
          child: Text(t.game_auto_lookup_new_lines),
        ),
        SubmenuButton(
          key: const ValueKey<String>('game-hook-code-menu'),
          menuChildren: _appleHookCodeItems(),
          child: Text(t.game_workbench_hook_code),
        ),
      ],
      builder:
          (BuildContext context, MenuController controller, Widget? child) =>
              FushiIconButton(
                key: const ValueKey<String>('game-apple-more-menu'),
                icon: CupertinoIcons.ellipsis,
                tooltip: t.common_more_actions,
                focusId: const FushiFocusId('game-apple-more-menu'),
                onTap: () =>
                    controller.isOpen ? controller.close() : controller.open(),
              ),
    );
  }

  /// 列表空态：会话开始前是三条欢迎行（启动 / 附着 / OCR，键与焦点 id 同 M3E
  /// 起点卡）；其余沿用共享空态（已按设计系统分派）。
  Widget _buildAppleLinesEmpty(BuildContext context, _AppleWorkbench w) {
    if (!w.summary.started && w.canStart) {
      final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
      final FushiAppleColors apple = appleColorsOf(context);
      final List<(String, IconData, String, String, VoidCallback)> rows =
          <(String, IconData, String, String, VoidCallback)>[
            (
              'game-action-launch',
              CupertinoIcons.play_fill,
              t.game_launch_and_capture,
              t.game_workbench_launch_hint,
              () => unawaited(_launchGalgameEngineHook()),
            ),
            (
              'game-action-attach',
              CupertinoIcons.link,
              t.game_attach_and_capture,
              t.game_workbench_attach_hint,
              () => unawaited(_attachToRunningGame()),
            ),
            (
              'game-action-ocr',
              FushiIcons.ocr,
              t.game_ocr_capture,
              t.game_workbench_ocr_hint,
              () => unawaited(_startOcrCapture()),
            ),
          ];
      return ListView(
        key: const ValueKey<String>('game-apple-welcome'),
        primary: false,
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
        children: <Widget>[
          Text(
            t.game_workbench_start_title,
            style: context.fushiType.titleLargeEmphasized.copyWith(
              color: apple.label,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            t.game_capture_description,
            style: metrics
                .subtitleStyle(context)
                .copyWith(color: apple.secondaryLabel),
          ),
          const SizedBox(height: 16),
          FushiEntranceScope(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (int i = 0; i < rows.length; i++)
                  FushiStaggeredEntrance(
                    index: i,
                    child: FushiGroupedListItem(
                      key: ValueKey<String>(rows[i].$1),
                      index: i,
                      count: rows.length,
                      focusId: FushiFocusId(rows[i].$1),
                      onTap: rows[i].$5,
                      child: FushiListItem(
                        leading: FushiIcon(
                          rows[i].$2,
                          size: metrics.leadingIconSize,
                          color: apple.accent,
                        ),
                        title: Text(rows[i].$3),
                        subtitle: Text(rows[i].$4, maxLines: 2),
                        trailing: const FushiAppleChevron(),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    }
    return _buildLinesEmptyState(context, w.readiness, w.textThreads);
  }
}

/// 一行台词（Apple 纯行）：行首状态图标常显、正文可逐字查词，动作按设计档位
/// 出现（见文件头）。卡片本身是焦点站点，键 / 焦点 id 与 M3E 相同。
class _AppleLineRow extends ConsumerStatefulWidget {
  const _AppleLineRow({
    required this.row,
    required this.mac,
    required this.autoLookupAnchorKey,
    required this.onSelect,
    required this.onOpen,
    required this.onCharTap,
    required this.onToggleFavorite,
    required this.onPreviewAudio,
    required this.onPickTrack,
    required this.onRecapture,
    required this.onCopy,
    super.key,
  });

  final _LineRowModel row;
  final bool mac;
  final GlobalKey autoLookupAnchorKey;
  final ValueChanged<TexthookerLineEntry> onSelect;

  /// iOS 档点行：推「本句」页。
  final ValueChanged<TexthookerLineEntry> onOpen;
  final void Function(TexthookerLineEntry line, int charIndex, Rect rect)
  onCharTap;
  final ValueChanged<TexthookerLineEntry> onToggleFavorite;
  final ValueChanged<TexthookerLineEntry> onPreviewAudio;
  final ValueChanged<TexthookerLineEntry> onPickTrack;
  final ValueChanged<TexthookerLineEntry> onRecapture;
  final ValueChanged<TexthookerLineEntry> onCopy;

  @override
  ConsumerState<_AppleLineRow> createState() => _AppleLineRowState();
}

class _AppleLineRowState extends ConsumerState<_AppleLineRow>
    with SingleTickerProviderStateMixin {
  final MenuController _menu = MenuController();
  bool _hovering = false;
  bool _focusWithin = false;

  /// iOS 左滑：0 = 收起，1 = 露出全部滑动动作。
  late final AnimationController _swipe = AnimationController(
    vsync: this,
    duration: FushiMotion.short,
  );

  static const double _kSwipeActionWidth = 64;

  TexthookerLineEntry get _line => widget.row.line;

  @override
  void dispose() {
    _swipe.dispose();
    super.dispose();
  }

  void _openMenu() {
    if (_menu.isOpen) {
      _menu.close();
    } else {
      _menu.open();
    }
  }

  /// 行动作的唯一清单：悬停按钮、右键 / 长按菜单与左滑动作都从这里取。
  List<
    ({String id, IconData icon, String label, VoidCallback onTap, Color? color})
  >
  _actions(FushiAppleColors apple) {
    final _LineRowModel row = widget.row;
    final TexthookerLineEntry line = _line;
    return <
      ({
        String id,
        IconData icon,
        String label,
        VoidCallback onTap,
        Color? color,
      })
    >[
      if (line.hasAudio)
        (
          id: 'game-line-preview-${line.id}',
          icon: row.previewingAudio ? FushiIcons.stop : FushiIcons.playCircle,
          label: row.previewingAudio
              ? t.game_track_preview_stop
              : t.game_line_preview_tooltip,
          onTap: () => widget.onPreviewAudio(line),
          color: row.previewingAudio ? apple.accent : null,
        ),
      if (row.canPickTrack)
        (
          id: 'game-line-track-${line.id}',
          icon: FushiIcons.audio,
          label: t.game_line_track_tooltip,
          onTap: () => widget.onPickTrack(line),
          color: null,
        ),
      if (row.canRecapture)
        (
          id: 'game-line-recapture-${line.id}',
          icon: row.recapturing ? FushiIcons.stop : FushiIcons.mic,
          label: row.recapturing
              ? t.game_line_recapture_stop
              : t.game_line_recapture,
          onTap: () => widget.onRecapture(line),
          color: row.recapturing ? apple.destructive : null,
        ),
      (
        id: 'game-line-copy-${line.id}',
        icon: FushiIcons.copyAll,
        label: t.game_line_copy_tooltip,
        onTap: () => widget.onCopy(line),
        color: null,
      ),
      (
        id: 'game-line-favorite-${line.id}',
        icon: line.favorited
            ? FushiIcons.filled(FushiIcons.star)
            : FushiIcons.star,
        label: line.favorited
            ? t.game_line_unfavorite_tooltip
            : t.game_line_favorite_tooltip,
        onTap: () => widget.onToggleFavorite(line),
        color: line.favorited ? apple.warning : null,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final _LineRowModel row = widget.row;
    final TexthookerLineEntry line = _line;
    final TextStyle? wordStyle = ref
        .watch(appProvider)
        .applyGameTextFont(
          metrics.titleStyle(context).copyWith(height: 1.6, color: apple.label),
        );
    final String source =
        line.sourceLabel ?? texthookerLineSourceLabel(line.source);
    final List<
      ({
        String id,
        IconData icon,
        String label,
        VoidCallback onTap,
        Color? color,
      })
    >
    actions = _actions(apple);
    final bool showActions =
        widget.mac && (_hovering || _focusWithin || row.selected);
    final Duration fade = fushiMotionDuration(context, FushiMotion.short);
    final Widget statusIcons = Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiIcon(
          line.hasAudio
              ? CupertinoIcons.waveform
              : CupertinoIcons.text_alignleft,
          size: metrics.chevronSize + 2,
          color: line.hasAudio ? apple.accent : apple.tertiaryLabel,
        ),
        if (line.favorited) ...<Widget>[
          const SizedBox(height: 4),
          FushiIcon(
            FushiIcons.star,
            size: metrics.chevronSize + 2,
            color: apple.warning,
          ),
        ],
      ],
    );
    final Widget body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '${formatGameClockTime(line.receivedAt)} · $source'
                '${line.textThreadLabel == null ? '' : ' · ${line.textThreadLabel}'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: metrics
                    .footnoteStyle(context)
                    .copyWith(color: apple.tertiaryLabel),
              ),
            ),
            if (line.mined) ...<Widget>[
              const _LineMinedChip(),
              const SizedBox(width: 6),
            ],
            _LineAudioChip(
              status: line.audioStatus,
              backend: line.audioBackend,
              fallbackReason: line.fallbackReason,
            ),
          ],
        ),
        const SizedBox(height: 2),
        _TexthookerLineText(
          line: line,
          displayText: row.displayText,
          sourceOffset: row.sourceOffset,
          presentation: row.presentation,
          words: row.words,
          style: wordStyle,
          warningColor: apple.warning,
          hintColor: apple.secondaryLabel,
          onCharTap: widget.onCharTap,
          autoLookupCharIndex: row.autoLookupCharIndex,
          autoLookupAnchorKey: widget.autoLookupAnchorKey,
        ),
      ],
    );
    final Widget hoverActions = !widget.mac
        ? const SizedBox.shrink()
        : ExcludeFocus(
            excluding: !showActions,
            child: IgnorePointer(
              ignoring: !showActions,
              child: AnimatedOpacity(
                opacity: showActions ? 1 : 0,
                duration: fade,
                curve: FushiMotion.standard,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (final action in actions)
                      FushiIconButton(
                        icon: action.icon,
                        tooltip: action.label,
                        size: metrics.chevronSize + 3,
                        enabledColor: action.color ?? apple.secondaryLabel,
                        focusId: FushiFocusId(action.id),
                        onTap: action.onTap,
                      ),
                  ],
                ),
              ),
            ),
          );
    final Widget card = FushiCard(
      key: ValueKey<String>('game-line-${line.id}'),
      focusId: FushiFocusId('game-line-${line.id}'),
      grouped: true,
      color: row.selected
          ? apple.accent.withValues(alpha: _kAppleLineSelectedAlpha)
          : apple.secondaryGroupedBackground.withValues(alpha: 0),
      borderColor: apple.accent.withValues(alpha: 0),
      borderRadius: fushiCardBorderRadius(context),
      margin: const EdgeInsets.symmetric(vertical: 1),
      padding: EdgeInsets.fromLTRB(metrics.rowHorizontal - 4, 8, 6, 8),
      onTap: widget.mac
          ? () => widget.onSelect(line)
          : () => widget.onOpen(line),
      onLongPress: _openMenu,
      onSecondaryTap: _openMenu,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(padding: const EdgeInsets.only(top: 2), child: statusIcons),
          SizedBox(width: metrics.leadingGap - 2),
          Expanded(child: body),
          hoverActions,
        ],
      ),
    );
    final Widget menu = FushiMenuAnchor(
      controller: _menu,
      menuChildren: <Widget>[
        if (!widget.mac)
          MenuItemButton(
            leadingIcon: const FushiIcon(CupertinoIcons.text_quote),
            onPressed: () => widget.onOpen(line),
            child: Text(t.game_stream_line),
          ),
        for (final action in actions)
          MenuItemButton(
            leadingIcon: FushiIcon(action.icon),
            onPressed: action.onTap,
            child: Text(action.label),
          ),
      ],
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (bool focused) {
          if (_focusWithin != focused) setState(() => _focusWithin = focused);
        },
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) => setState(() => _hovering = false),
          child: card,
        ),
      ),
    );
    if (widget.mac) return menu;
    return _buildSwipe(context, menu, actions, apple);
  }

  /// iOS 左滑露出试听 / 收藏（取行动作清单里的这两项），读屏走自定义动作。
  Widget _buildSwipe(
    BuildContext context,
    Widget child,
    List<
      ({
        String id,
        IconData icon,
        String label,
        VoidCallback onTap,
        Color? color,
      })
    >
    actions,
    FushiAppleColors apple,
  ) {
    final List<
      ({
        String id,
        IconData icon,
        String label,
        VoidCallback onTap,
        Color? color,
      })
    >
    swipe = actions
        .where(
          (action) =>
              action.id.startsWith('game-line-preview-') ||
              action.id.startsWith('game-line-favorite-'),
        )
        .toList(growable: false);
    final double reveal = swipe.length * _kSwipeActionWidth;
    void settle(bool open) {
      final Duration duration = fushiMotionDuration(context, FushiMotion.short);
      unawaited(
        _swipe.animateTo(
          open ? 1 : 0,
          duration: duration,
          curve: FushiMotion.release,
        ),
      );
    }

    return Semantics(
      customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
        for (final action in swipe)
          CustomSemanticsAction(label: action.label): action.onTap,
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (DragUpdateDetails details) {
          if (reveal <= 0) return;
          _swipe.value = (_swipe.value - details.primaryDelta! / reveal).clamp(
            0.0,
            1.0,
          );
        },
        onHorizontalDragEnd: (DragEndDetails details) =>
            settle(_swipe.value > 0.4),
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (final action in swipe)
                      SizedBox(
                        width: _kSwipeActionWidth,
                        child: FushiAppleRow(
                          background:
                              action.id.startsWith('game-line-favorite-')
                              ? apple.warning
                              : apple.accent,
                          onTap: () {
                            action.onTap();
                            settle(false);
                          },
                          child: Center(
                            child: FushiIcon(
                              action.icon,
                              color: apple.onAccent,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            AnimatedBuilder(
              animation: _swipe,
              builder: (BuildContext context, Widget? child) =>
                  Transform.translate(
                    offset: Offset(-reveal * _swipe.value, 0),
                    child: child,
                  ),
              child: ColoredBox(color: apple.groupedBackground, child: child),
            ),
          ],
        ),
      ),
    );
  }
}
