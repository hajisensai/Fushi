import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/mining/gal_audio_tracks_panel.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/pages/implementations/game_shared.dart';
import 'package:fushi/src/pages/implementations/stat_kpi_strip.dart';
import 'package:fushi/src/settings/settings_kit.dart'
    show SettingsEmptyState, SettingsSectionJumpBar;
import 'package:fushi/src/sync/texthooker_ws_client.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiFloatingChromeOverlay, FushiFloatingChromeScrollInset;
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_section_anchor.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/desktop_audio_playback.dart';
import 'package:fushi/utils.dart';

/// Galgame 捕获链路的只读诊断面板。
///
/// 只展示控制器实际观察到的阶段、端点、音轨和事件。没有采样数据时明确显示空状态，
/// 不用装饰性波形或虚构成功状态掩盖尚未接通的 native 能力。
class GameDiagnosticsPage extends StatefulWidget {
  const GameDiagnosticsPage({
    super.key,
    required this.onShowLibrary,
    required this.onShowCapture,
    this.controller,
  });

  final VoidCallback onShowLibrary;
  final VoidCallback onShowCapture;
  final GalHookSessionController? controller;

  @override
  State<GameDiagnosticsPage> createState() => _GameDiagnosticsPageState();
}

class _GameDiagnosticsPageState extends State<GameDiagnosticsPage> {
  late final GalHookSessionController _controller =
      widget.controller ?? GalHookSessionController.instance;
  bool _warningsOnly = false;

  /// 正在试听的音轨 sourcePtr；null = 未在试听。
  int? _previewingSourcePtr;

  /// 试听片段播完后把按钮从「停止」复位回「试听」的定时器（时长精确来自 PCM 长度）。
  Timer? _previewResetTimer;

  /// 正文滚动 + 分组锚点登记（settings kit 的分组跳转条用）。
  final ScrollController _scroll = ScrollController();
  final SettingsSectionSpy _spy = SettingsSectionSpy();

  @override
  void initState() {
    super.initState();
    // BUG-1027：进入诊断页即自动拉一次音轨快照；会话未激活时 controller 侧自行
    // 归一为空快照，无需在页面再判 engine。
    if (_controller.state.isActive) {
      unawaited(_controller.refreshAudioTracks());
    }
    _spy.attach(_scroll);
  }

  @override
  void dispose() {
    _previewResetTimer?.cancel();
    _spy.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 选轨需要引擎 hook 会话；无 engine 时明确 toast 而非静默无反应（BUG-1027）。
  ///
  /// BUG-1102：有 engine 不等于选轨生效——资源模式与 Loopback 后端根本不消费
  /// `selectedAudioSourcePtr`。控件此时已被禁用，这里保留一条兜底提示，防止将来
  /// 有别的入口绕过禁用又变回静默无反应。
  void _handleSelectVoice(int sourcePtr) {
    if (!_controller.hasEngineSource) {
      FushiToast.show(
        msg: t.game_track_select_requires_engine,
        severity: ToastSeverity.error,
      );
    } else if (!galTrackSelectionAffectsCapture(
      _controller.state.audioBackend,
    )) {
      FushiToast.show(
        msg: t.game_tracks_pcm_only_hint,
        severity: ToastSeverity.warning,
      );
      return;
    }
    _controller.selectVoiceTrack(sourcePtr);
  }

  /// 试听/停止指定音轨：经 controller 抓该轨最近整句 PCM 写临时 WAV 后播放；
  /// 播放中再次点击立即停止。任何失败 toast 反馈，不静默。
  Future<void> _handlePreviewTrack(GalAudioTrack track) async {
    if (_previewingSourcePtr == track.sourcePtr) {
      _previewResetTimer?.cancel();
      setState(() => _previewingSourcePtr = null);
      await DesktopAudioPlayback.stop();
      return;
    }
    final GalTrackPreview? preview =
        await _controller.exportTrackPreview(track.sourcePtr);
    if (!mounted) return;
    if (preview == null) {
      FushiToast.show(
        msg: t.game_track_preview_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    final bool started = await DesktopAudioPlayback.playFile(preview.filePath);
    if (!mounted) return;
    if (!started) {
      FushiToast.show(
        msg: t.game_track_preview_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    _previewResetTimer?.cancel();
    setState(() => _previewingSourcePtr = track.sourcePtr);
    _previewResetTimer = Timer(
      Duration(milliseconds: preview.durationMs + 300),
      () {
        if (mounted) setState(() => _previewingSourcePtr = null);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, Widget? child) {
          final GalHookSessionState state = _controller.state;
          final List<GalHookEvent> events = _warningsOnly
              ? _controller.events
                  .where(
                    (GalHookEvent event) =>
                        event.severity == GalHookEventSeverity.warning ||
                        event.severity == GalHookEventSeverity.error,
                  )
                  .toList(growable: false)
              : _controller.events;
          return Column(
            children: <Widget>[
              FushiPageHeader.customTitle(
                // 在游戏外壳里页签由浮动工具栏画：主位给零尺寸占位，页头整行
                // 零高度（动作登记进外壳动作组），不留一条钉死的空白带。
                title: GameSectionTabsHostScope.hostedOf(context)
                    ? const SizedBox.shrink()
                    : GameSectionTabs(
                        selected: GameSection.settings,
                        focusIdPrefix: 'game-diagnostics-tab',
                        onSelectLibrary: widget.onShowLibrary,
                        onSelectMonitor: widget.onShowCapture,
                        onSelectSettings: () =>
                            gameSectionNotifier.value = GameSection.settings,
                      ),
                actions: <Widget>[
                  FushiIconButton(
                    key: const ValueKey<String>(
                      'game-diagnostics-back-to-settings',
                    ),
                    icon: FushiIcons.back,
                    tooltip: t.settings,
                    onTap: () =>
                        gameSectionNotifier.value = GameSection.settings,
                  ),
                  // BUG-1027：「刷新音轨」已就近移入「活跃音轨」卡片标题行；
                  // 页头只保留全局性的清事件动作。
                  FushiIconButton(
                    icon: FushiIcons.deleteSweep,
                    tooltip: t.game_clear_events,
                    onTap: _controller.clearEvents,
                  ),
                ],
              ),
              Expanded(
                // 分组跳转条叠进库页外壳的浮动工具区（嵌套
                // [FushiFloatingChromeOverlay]，与书架搜索行同构）：往下滚跟外壳
                // 页签一起收起，正文滚到它底下；正文滚动视图经
                // [FushiFloatingChromeScrollInset] 拿到 MediaQuery 顶部 padding
                // 自己让位，工具区收起后顶部不留空白。不在外壳里时退化成「跳转条
                // + 正文」竖排。
                child: FushiFloatingChromeOverlay(
                  // settings kit 的分组跳转条：分段卡片经 [SettingsSectionAnchor]
                  // 自动登记，滚动时当前分组的胶囊弹簧变宽填色。
                  chrome: ListenableBuilder(
                    listenable: _spy,
                    builder: (BuildContext context, Widget? _) {
                      if (_spy.sections.length < 3) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: SettingsSectionJumpBar(
                          sections: _spy.sections,
                          activeId: _spy.activeId,
                          onSelected: (String id) => _spy.jumpTo(
                            id,
                            duration:
                                context.fushiMotion.spatialDefault.duration,
                          ),
                        ),
                      );
                    },
                  ),
                  child: FushiFloatingChromeScrollInset(
                    child: SettingsSectionSpyScope(
                      spy: _spy,
                      // 本页由 HomeGamePage 的 IndexedStack 急切构建：切到诊断
                      // 子区时重开进场窗口，错峰进场才落在用户眼前。
                      child: FushiEntranceScope(
                        replayKey: gameSectionNotifier.value ==
                            GameSection.diagnostics,
                        // 必须在 Builder 里读让位：外层 builder 的 context 在
                        // [FushiFloatingChromeScrollInset] 之上。吃掉后从子树
                        // 摘掉，卡片里的列表不再让一遍。
                        child: Builder(
                          builder: (BuildContext context) {
                            final double chromeTop =
                                MediaQuery.paddingOf(context).top;
                            return MediaQuery.removePadding(
                              context: context,
                              removeTop: true,
                              child: SingleChildScrollView(
                                controller: _scroll,
                                padding: EdgeInsets.fromLTRB(
                                  16,
                                  8 + chromeTop,
                                  16,
                                  24,
                                ),
                                child: _buildBody(context, state, events),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 正文：KPI 条 + 分段卡片（流水线 / 端点、音轨、事件），整体错峰进场。
  Widget _buildBody(
    BuildContext context,
    GalHookSessionState state,
    List<GalHookEvent> events,
  ) {
    final List<Widget> blocks = <Widget>[
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          StatKpiStrip(
            items: <StatKpiItem>[
              StatKpiItem(
                icon: FushiIcons.quote,
                value: '${_controller.lines.length}',
                label: t.game_captured_lines,
              ),
              // 文本来自引擎 Hook 时，「0/3 文本端点」是外部工具的可选
              // 接入口而非健康指标——KPI 改为显示真实文本来源（BUG-1027）。
              if (_controller.hasEngineSource)
                StatKpiItem(
                  icon: FushiIcons.link,
                  value: t.game_text_source_engine,
                  label: t.game_health_text,
                )
              else
                StatKpiItem(
                  icon: FushiIcons.link,
                  value:
                      '${_controller.endpointStatuses.where((e) => e.phase == TexthookerEndpointPhase.connected).length}/${_controller.endpointStatuses.length}',
                  label: t.game_text_endpoints,
                ),
              StatKpiItem(
                icon: FushiIcons.warning,
                value: '${state.textGapCount}',
                label: t.game_text_gaps,
              ),
              StatKpiItem(
                icon: FushiIcons.volumeUp,
                value: galHookAudioBackendLabel(state.audioBackend),
                label: t.game_health_audio,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            // 「序号缺口」是 hook 文本环丢行计数——0 为正常，非告警。
            child: Text(
              t.game_text_gaps_hint,
              style: context.fushiType.bodySmall.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
      LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final Widget pipeline = _PipelineCard(state: state);
          final Widget endpoints = _EndpointCard(
            endpoints: _controller.endpointStatuses,
            engineHookActive: _controller.hasEngineSource,
          );
          if (box.maxWidth < 840) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                pipeline,
                const SizedBox(height: 16),
                endpoints,
              ],
            );
          }
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(child: pipeline),
                const SizedBox(width: 16),
                Expanded(child: endpoints),
              ],
            ),
          );
        },
      ),
      _AudioTracksCard(
        state: state,
        onRefresh: _controller.refreshAudioTracks,
        onSelectVoice: _handleSelectVoice,
        onToggleExcluded: _controller.setTrackExcluded,
        onPreviewTrack: _handlePreviewTrack,
        previewingSourcePtr: _previewingSourcePtr,
      ),
      _EventsCard(
        events: events,
        warningsOnly: _warningsOnly,
        onWarningsOnlyChanged: (bool value) {
          setState(() => _warningsOnly = value);
        },
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < blocks.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: 16),
          FushiStaggeredEntrance(index: i, child: blocks[i]),
        ],
      ],
    );
  }
}

/// 诊断状态的语义层级：就绪 / 等待（降级、未接通）/ 出错。
enum _DiagnosticLevel { ok, waiting, error }

/// 状态行行首形状图标的配色。M3E：就绪 primary、等待 tertiary、出错 error 饱和
/// 色块。Apple 的 tertiary 落在系统绿上，所以 Apple 下就绪取 tertiary（绿）、
/// 等待取 neutral（灰），保持「绿 = 健康」的 iOS 语义。
FushiCardTone _diagnosticTone(BuildContext context, _DiagnosticLevel level) {
  final bool apple = isGlassDesign(context);
  return switch (level) {
    _DiagnosticLevel.ok =>
      apple ? FushiCardTone.tertiary : FushiCardTone.primary,
    _DiagnosticLevel.waiting =>
      apple ? FushiCardTone.neutral : FushiCardTone.tertiary,
    _DiagnosticLevel.error => FushiCardTone.error,
  };
}

IconData _diagnosticIcon(_DiagnosticLevel level) => switch (level) {
      _DiagnosticLevel.ok => FushiIcons.success,
      _DiagnosticLevel.waiting => FushiIcons.pending,
      _DiagnosticLevel.error => FushiIcons.error,
    };

class _PipelineCard extends StatelessWidget {
  const _PipelineCard({required this.state});

  final GalHookSessionState state;

  @override
  Widget build(BuildContext context) {
    final bool active = state.isActive;
    return _SectionCard(
      title: t.game_pipeline,
      icon: FushiIcons.hub,
      child: Column(
        children: <Widget>[
          _DiagnosticRow(
            label: t.game_health_process,
            value: state.gamePid == null
                ? t.game_status_waiting
                : 'PID ${state.gamePid}',
            ok: state.gamePid != null,
          ),
          _DiagnosticRow(
            label: t.game_health_helper,
            value: active
                ? galHookSessionPhaseLabel(state.phase)
                : t.game_status_waiting,
            ok: active && state.phase != GalHookSessionPhase.error,
            error: state.phase == GalHookSessionPhase.error,
          ),
          _DiagnosticRow(
            label: t.game_health_window,
            value: state.boundWindow == null
                ? t.game_window_missing
                : (state.boundWindow!.title.isEmpty
                    ? '#${state.boundWindow!.hwnd}'
                    : state.boundWindow!.title),
            ok: state.boundWindow != null,
          ),
          _DiagnosticRow(
            label: t.game_health_text,
            value: state.hasText ? t.game_status_ready : t.game_status_waiting,
            ok: state.hasText,
          ),
          _DiagnosticRow(
            label: t.game_health_audio,
            value: galHookAudioBackendLabel(state.audioBackend),
            ok: state.hasAudio,
          ),
          if (state.fallbackReason != null)
            _DetailBox(
              icon: FushiIcons.info,
              text: state.fallbackReason!,
            ),
          if (state.lastError != null)
            _DetailBox(
              icon: FushiIcons.error,
              text: state.lastError!,
              error: true,
            ),
        ],
      ),
    );
  }
}

class _EndpointCard extends StatelessWidget {
  const _EndpointCard({
    required this.endpoints,
    required this.engineHookActive,
  });

  final List<TexthookerEndpointStatus> endpoints;

  /// 当前会话文本是否已由引擎 Hook 供给。为 true 时端点只是外部工具的可选接入口，
  /// 整卡降级为默认收起的次要样式（BUG-1027 降噪）。
  final bool engineHookActive;

  @override
  Widget build(BuildContext context) {
    final TextStyle hintStyle = context.fushiType.bodySmall.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    // 端点是 Textractor / agent / LunaTranslator 等外部工具的兼容接入口；普通用户
    // 永远处于「连接中/重试中」循环属正常，解释文案常驻，且重试态不再用告警观感
    //（_EndpointRow 的未连接态统一中性图标/中性色）。
    final Widget hint = Text(t.game_endpoints_hint, style: hintStyle);
    final Widget rows = endpoints.isEmpty
        ? Text(
            t.game_status_not_configured,
            style: context.fushiType.bodyMedium,
          )
        : Column(
            children: <Widget>[
              for (final TexthookerEndpointStatus endpoint in endpoints)
                _EndpointRow(endpoint: endpoint),
            ],
          );
    if (!engineHookActive) {
      return _SectionCard(
        title: t.game_text_endpoints,
        icon: FushiIcons.link,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[hint, const SizedBox(height: 8), rows],
        ),
      );
    }
    return SettingsSectionAnchor(
      title: t.game_text_endpoints,
      child: FushiCard(
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: FushiExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            initiallyExpanded: false,
            leading: const FushiListLeadingIcon(
              FushiIcons.link,
              shape: FushiLeadingShape.square,
              tone: FushiCardTone.neutral,
            ),
            title: Text(
              t.game_text_endpoints,
              style: context.fushiType.titleMediumEmphasized,
            ),
            subtitle: Text(t.game_endpoints_engine_active, style: hintStyle),
            children: <Widget>[
              const SizedBox(height: 4),
              hint,
              const SizedBox(height: 8),
              rows,
            ],
          ),
        ),
      ),
    );
  }
}

/// 单条文本端点状态行。与 [_DiagnosticRow] 的差别：未连接（连接中/重试中/已停止）
/// 用中性的同步图标与中性色，不再暗示健康问题——这些端点没接外部工具时本就
/// 不会连上（BUG-1027 降噪）。
class _EndpointRow extends StatelessWidget {
  const _EndpointRow({required this.endpoint});

  final TexthookerEndpointStatus endpoint;

  @override
  Widget build(BuildContext context) {
    final bool connected = endpoint.phase == TexthookerEndpointPhase.connected;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: <Widget>[
          FushiListLeadingIcon(
            connected ? FushiIcons.success : FushiIcons.sync,
            // 已连接 = 健康语义（与流水线行的「就绪」同一口径）；未连接保持中性。
            tone: connected
                ? _diagnosticTone(context, _DiagnosticLevel.ok)
                : FushiCardTone.neutral,
            size: 32,
            iconSize: 18,
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(endpoint.url)),
          const SizedBox(width: 12),
          Flexible(
            child: FushiTooltip(
              message: endpoint.lastError ??
                  texthookerEndpointPhaseLabel(endpoint.phase),
              child: Text(
                texthookerEndpointPhaseLabel(endpoint.phase),
                textAlign: TextAlign.end,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.fushiType.bodySmall,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AudioTracksCard extends StatelessWidget {
  const _AudioTracksCard({
    required this.state,
    required this.onRefresh,
    required this.onSelectVoice,
    required this.onToggleExcluded,
    required this.onPreviewTrack,
    required this.previewingSourcePtr,
  });

  final GalHookSessionState state;
  final VoidCallback onRefresh;
  final ValueChanged<int> onSelectVoice;
  final void Function(int sourcePtr, bool excluded) onToggleExcluded;
  final ValueChanged<GalAudioTrack> onPreviewTrack;
  final int? previewingSourcePtr;

  @override
  Widget build(BuildContext context) {
    // 轨列表/选轨/排除/试听的内容体抽到共享组件 [GalAudioTracksPanel]（捕获工作台
    // 顶栏的音轨对话框复用同一份），这里只保留诊断页的卡片壳与刷新入口。
    return _SectionCard(
      title: t.game_audio_tracks,
      icon: FushiIcons.audio,
      trailing: FushiIconButton(
        icon: FushiIcons.refresh,
        tooltip: t.game_refresh_tracks,
        onTap: onRefresh,
      ),
      child: GalAudioTracksPanel(
        state: state,
        onSelectVoice: onSelectVoice,
        onToggleExcluded: onToggleExcluded,
        onPreviewTrack: onPreviewTrack,
        previewingSourcePtr: previewingSourcePtr,
      ),
    );
  }
}

class _EventsCard extends StatelessWidget {
  const _EventsCard({
    required this.events,
    required this.warningsOnly,
    required this.onWarningsOnlyChanged,
  });

  final List<GalHookEvent> events;
  final bool warningsOnly;
  final ValueChanged<bool> onWarningsOnlyChanged;

  @override
  Widget build(BuildContext context) {
    final List<GalHookEvent> newest = events.reversed.toList(growable: false);
    return _SectionCard(
      title: t.game_session_events,
      icon: FushiIcons.history,
      trailing: Wrap(
        spacing: 8,
        children: <Widget>[
          FushiSelectableChip(
            label: t.game_event_all,
            selected: !warningsOnly,
            focusId: const FushiFocusId('game-diagnostics-event-all'),
            onSelected: (_) => onWarningsOnlyChanged(false),
          ),
          FushiSelectableChip(
            label: t.game_event_warnings,
            selected: warningsOnly,
            focusId: const FushiFocusId('game-diagnostics-event-warnings'),
            onSelected: (_) => onWarningsOnlyChanged(true),
          ),
        ],
      ),
      child: newest.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: SettingsEmptyState(
                icon: FushiIcons.history,
                title: t.game_no_events,
              ),
            )
          : Column(
              children: <Widget>[
                for (final GalHookEvent event in newest)
                  _EventTile(event: event),
              ],
            ),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event});

  final GalHookEvent event;

  @override
  Widget build(BuildContext context) {
    // 严重度圆点走语义状态色（info 中性灰 / 成功绿 / 警告橙 / 错误红），
    // 不再借 secondary / primary / tertiary 色槽——那三个在 MD3 里是同一色相族的
    // tonal 变体、在 Apple 下都塌成单色强调，四档读不出区别。
    final Color color = switch (event.severity) {
      GalHookEventSeverity.info => fushiNeutralSecondaryForeground(context),
      GalHookEventSeverity.success =>
        fushiStatusColor(context, FushiStatusTone.success),
      GalHookEventSeverity.warning =>
        fushiStatusColor(context, FushiStatusTone.warning),
      GalHookEventSeverity.error =>
        fushiStatusColor(context, FushiStatusTone.error),
    };
    // eink 下彩色圆点塌缩成同一灰阶（巡检 G5）：改成形状可辨的语义图标区分严重度。
    final Widget leading = isEinkTheme(context)
        ? FushiIcon(
            switch (event.severity) {
              GalHookEventSeverity.info => FushiIcons.info,
              GalHookEventSeverity.success => FushiIcons.success,
              GalHookEventSeverity.warning => FushiIcons.warning,
              GalHookEventSeverity.error => FushiIcons.error,
            },
            size: 18,
          )
        : SizedBox.square(
            dimension: 10,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: color,
                shape: const CircleBorder(),
              ),
            ),
          );
    return FushiListTileControl(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: leading,
      title: Text(event.summary),
      subtitle: Text(
        '${formatGameClockTime(event.timestamp)} · ${event.stage} · ${event.code}'
        '${event.details.isEmpty ? '' : '\n${event.details}'}',
      ),
      isThreeLine: event.details.isNotEmpty,
    );
  }
}

/// 诊断页的分段卡片：M3E 卡（20 圆角）+ 行首方圆角形状图标 + 强调标题；经
/// [SettingsSectionAnchor] 登记进页顶的分组跳转条。
class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.child,
    this.trailing,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return SettingsSectionAnchor(
      title: title,
      child: FushiCard(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                FushiListLeadingIcon(
                  icon,
                  shape: FushiLeadingShape.square,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: context.fushiType.titleMediumEmphasized,
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _DiagnosticRow extends StatelessWidget {
  const _DiagnosticRow({
    required this.label,
    required this.value,
    required this.ok,
    this.error = false,
  });

  final String label;
  final String value;
  final bool ok;

  /// 该环节明确出错（而不只是尚未就绪）：行首换 error 色块。
  final bool error;

  @override
  Widget build(BuildContext context) {
    final _DiagnosticLevel level = error
        ? _DiagnosticLevel.error
        : ok
            ? _DiagnosticLevel.ok
            : _DiagnosticLevel.waiting;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: <Widget>[
          FushiListLeadingIcon(
            _diagnosticIcon(level),
            tone: _diagnosticTone(context, level),
            size: 32,
            iconSize: 18,
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
          const SizedBox(width: 12),
          Flexible(
            child: FushiTooltip(
              message: value,
              child: Text(
                value,
                textAlign: TextAlign.end,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.fushiType.bodySmall,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailBox extends StatelessWidget {
  const _DetailBox(
      {required this.icon, required this.text, this.error = false});

  final IconData icon;
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    // 中性信息块；错误语义只上在单色图标上（不再整块 error / secondary 容器色）。
    final Color foreground = fushiNeutralBlockForeground(context);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: fushiNeutralBlockDecoration(context),
      child: Row(
        children: <Widget>[
          FushiIcon(
            icon,
            color: error
                ? fushiStatusColor(context, FushiStatusTone.error)
                : fushiNeutralSecondaryForeground(context),
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(color: foreground))),
        ],
      ),
    );
  }
}
