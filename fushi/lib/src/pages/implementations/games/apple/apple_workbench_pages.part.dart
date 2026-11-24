part of '../../texthooker_page.dart';

// Cupertino 工作台推出去的页面与弹层：iOS 档的「会话」「本句」整页；健康状态 /
// 音频降级档位在 macOS 档是窗口 sheet，iOS 档是整页。内容都随会话实时刷新。

extension _AppleWorkbenchPages on _TexthookerPageState {
  /// 推一张 Apple 整页（iOS 档）。正文自己处理顶部页头让位（masthead 把页头高度
  /// 注入成 MediaQuery.padding.top）。
  Future<void> _pushApplePage({
    required String title,
    required Widget Function(BuildContext context, EdgeInsets padding) body,
  }) {
    return Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext pageContext) => FushiMastheadScaffold(
          title: title,
          body: Builder(
            builder: (BuildContext context) => ListenableBuilder(
              listenable: Listenable.merge(<Listenable>[
                _session,
                TexthookerService.instance,
              ]),
              builder: (BuildContext context, Widget? child) => body(
                context,
                EdgeInsets.fromLTRB(
                  16,
                  MediaQuery.paddingOf(context).top + 8,
                  16,
                  MediaQuery.paddingOf(context).bottom + 16,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// macOS 档窗口 sheet / iOS 档整页（健康状态、音频降级档位）。
  Future<void> _presentAppleSurface({
    required String title,
    required WidgetBuilder content,
  }) {
    if (fushiAppleUsesMacMetrics(context)) {
      return adaptiveModalSheet<void>(
        context: context,
        builder: (BuildContext sheetContext) => FushiModalSheetFrame(
          title: title,
          scrollable: true,
          body: ListenableBuilder(
            listenable: _session,
            builder: (BuildContext context, Widget? child) => content(context),
          ),
          footer: FushiTextButton(
            onPressed: () => Navigator.of(sheetContext).maybePop(),
            child: Text(t.dialog_close),
          ),
        ),
      );
    }
    return _pushApplePage(
      title: title,
      body: (BuildContext context, EdgeInsets padding) => ListView(
        primary: false,
        padding: padding,
        children: <Widget>[content(context)],
      ),
    );
  }

  Future<void> _showAppleHealth() => _presentAppleSurface(
    title: t.game_health,
    content: (BuildContext context) => _CaptureHealthCard(
      state: _session.state,
      endpoints: _session.endpointStatuses,
      ankiConfigured: ref.read(ankiViewModelProvider).isConfigured,
    ),
  );

  /// 音频降级三档：Apple 分组列表，当前档行尾 ✓，每档写清代价。
  Future<void> _showAppleAudioFallbackPolicy() => _presentAppleSurface(
    title: t.game_audio_fallback_policy,
    content: (BuildContext context) {
      final GalAudioFallbackPolicy current = _session.state.audioFallbackPolicy;
      const List<GalAudioFallbackPolicy> values = GalAudioFallbackPolicy.values;
      return Column(
        key: const ValueKey<String>('game-audio-fallback-apple'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < values.length; i++)
            FushiGroupedListItem(
              key: ValueKey<String>('game-audio-fallback-${values[i].name}'),
              index: i,
              count: values.length,
              selected: values[i] == current,
              onTap: () => _session.setAudioFallbackPolicy(values[i]),
              child: FushiListItem(
                title: Text(_audioFallbackPolicyLabel(values[i])),
                subtitle: Text(_audioFallbackPolicyDescription(values[i])),
                trailing: values[i] == current
                    ? const FushiAppleCheckmark()
                    : null,
              ),
            ),
        ],
      );
    },
  );

  /// iOS 档「本句」页：同一张 [_LineTracksCard]（Apple 外观）+ 动作条。
  Future<void> _pushAppleLinePage(TexthookerLineEntry line) async {
    _selectLine(line);
    await _pushApplePage(
      title: t.game_stream_line,
      body: (BuildContext context, EdgeInsets padding) {
        final TexthookerLineEntry? current = _selectedLine(
          _session.workbenchLines,
        );
        return Padding(
          padding: padding,
          child: _LineTracksCard(
            session: _session,
            line: current,
            actions: current == null ? null : _buildAppleLineActionBar(current),
          ),
        );
      },
    );
  }

  /// iOS 档「会话」页：会话卡 + 信号 + 游戏内查词 + 工具（与 macOS 侧栏同一组分区）。
  Future<void> _pushAppleSessionPage() {
    final GalgameEntry? game = _appleWorkbenchSnapshot().game;
    return _pushApplePage(
      title: game?.displayName ?? t.game_capture_workbench,
      body: (BuildContext context, EdgeInsets padding) {
        final _AppleWorkbench w = _appleWorkbenchSnapshot();
        final List<Widget> sections = <Widget>[
          _buildAppleSessionCard(context, w),
          ..._appleSessionSections(context, w, includeHealthPopover: false),
          if (_hookCapture) _buildAppleLookupSection(context, w),
        ];
        return FushiEntranceScope(
          child: ListView(
            key: const ValueKey<String>('game-apple-session-page'),
            primary: false,
            padding: padding,
            children: <Widget>[
              for (int i = 0; i < sections.length; i++)
                FushiStaggeredEntrance(index: i, child: sections[i]),
            ],
          ),
        );
      },
    );
  }
}
