import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/mining/gal_audio_tracks_panel.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import 'package:hibiki/src/pages/implementations/game_shared.dart';
import 'package:hibiki/src/pages/implementations/stat_kpi_strip.dart';
import 'package:hibiki/src/sync/texthooker_ws_client.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_playback.dart';
import 'package:hibiki/utils.dart';

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

  @override
  void initState() {
    super.initState();
    // BUG-1027：进入诊断页即自动拉一次音轨快照；会话未激活时 controller 侧自行
    // 归一为空快照，无需在页面再判 engine。
    if (_controller.state.isActive) {
      unawaited(_controller.refreshAudioTracks());
    }
  }

  @override
  void dispose() {
    _previewResetTimer?.cancel();
    super.dispose();
  }

  /// 选轨需要引擎 hook 会话；无 engine 时明确 toast 而非静默无反应（BUG-1027）。
  ///
  /// BUG-1102：有 engine 不等于选轨生效——资源模式与 Loopback 后端根本不消费
  /// `selectedAudioSourcePtr`。控件此时已被禁用，这里保留一条兜底提示，防止将来
  /// 有别的入口绕过禁用又变回静默无反应。
  void _handleSelectVoice(int sourcePtr) {
    if (!_controller.hasEngineSource) {
      HibikiToast.show(msg: t.game_track_select_requires_engine);
    } else if (!galTrackSelectionAffectsCapture(
      _controller.state.audioBackend,
    )) {
      HibikiToast.show(msg: t.game_tracks_pcm_only_hint);
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
      HibikiToast.show(msg: t.game_track_preview_failed);
      return;
    }
    final bool started = await DesktopAudioPlayback.playFile(preview.filePath);
    if (!mounted) return;
    if (!started) {
      HibikiToast.show(msg: t.game_track_preview_failed);
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
              HibikiPageHeader(
                title: t.game_diagnostics,
                subtitle: t.game_diagnostics_subtitle,
                leading: HibikiIconButton(
                  icon: Icons.arrow_back,
                  tooltip: t.game_back_to_capture,
                  onTap: widget.onShowCapture,
                ),
                actions: <Widget>[
                  // BUG-1027：「刷新音轨」已就近移入「活跃音轨」卡片标题行；
                  // 页头只保留全局性的清事件动作。
                  HibikiIconButton(
                    icon: Icons.delete_sweep_outlined,
                    tooltip: t.game_clear_events,
                    onTap: _controller.clearEvents,
                  ),
                ],
                bottom: GameSectionTabs(
                  selected: GameSection.diagnostics,
                  focusIdPrefix: 'game-diagnostics-tab',
                  onSelectLibrary: widget.onShowLibrary,
                  onSelectMonitor: widget.onShowCapture,
                  onSelectDiagnostics: () {},
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      StatKpiStrip(
                        items: <StatKpiItem>[
                          StatKpiItem(
                            icon: Icons.format_quote_outlined,
                            value: '${_controller.lines.length}',
                            label: t.game_captured_lines,
                          ),
                          // 文本来自引擎 Hook 时，「0/3 文本端点」是外部工具的可选
                          // 接入口而非健康指标——KPI 改为显示真实文本来源（BUG-1027）。
                          if (_controller.hasEngineSource)
                            StatKpiItem(
                              icon: Icons.link_outlined,
                              value: t.game_text_source_engine,
                              label: t.game_health_text,
                            )
                          else
                            StatKpiItem(
                              icon: Icons.link_outlined,
                              value:
                                  '${_controller.endpointStatuses.where((e) => e.phase == TexthookerEndpointPhase.connected).length}/${_controller.endpointStatuses.length}',
                              label: t.game_text_endpoints,
                            ),
                          StatKpiItem(
                            icon: Icons.warning_amber_outlined,
                            value: '${state.textGapCount}',
                            label: t.game_text_gaps,
                          ),
                          StatKpiItem(
                            icon: Icons.graphic_eq,
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
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                        ),
                      ),
                      const SizedBox(height: 16),
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
                      const SizedBox(height: 16),
                      _AudioTracksCard(
                        state: state,
                        onRefresh: _controller.refreshAudioTracks,
                        onSelectVoice: _handleSelectVoice,
                        onToggleExcluded: _controller.setTrackExcluded,
                        onPreviewTrack: _handlePreviewTrack,
                        previewingSourcePtr: _previewingSourcePtr,
                      ),
                      const SizedBox(height: 16),
                      _EventsCard(
                        events: events,
                        warningsOnly: _warningsOnly,
                        onWarningsOnlyChanged: (bool value) {
                          setState(() => _warningsOnly = value);
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PipelineCard extends StatelessWidget {
  const _PipelineCard({required this.state});

  final GalHookSessionState state;

  @override
  Widget build(BuildContext context) {
    final bool active = state.isActive;
    return _SectionCard(
      title: t.game_pipeline,
      icon: Icons.account_tree_outlined,
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
              icon: Icons.info_outline,
              text: state.fallbackReason!,
            ),
          if (state.lastError != null)
            _DetailBox(
              icon: Icons.error_outline,
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
    final TextStyle? hintStyle = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    // 端点是 Textractor / agent / LunaTranslator 等外部工具的兼容接入口；普通用户
    // 永远处于「连接中/重试中」循环属正常，解释文案常驻，且重试态不再用告警观感
    //（_EndpointRow 的未连接态统一中性图标/中性色）。
    final Widget hint = Text(t.game_endpoints_hint, style: hintStyle);
    final Widget rows = endpoints.isEmpty
        ? Text(
            t.game_status_not_configured,
            style: Theme.of(context).textTheme.bodyMedium,
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
        icon: Icons.hub_outlined,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[hint, const SizedBox(height: 8), rows],
        ),
      );
    }
    return HibikiCard(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          initiallyExpanded: false,
          leading: const Icon(Icons.hub_outlined, size: 20),
          title: Text(
            t.game_text_endpoints,
            style: Theme.of(context).textTheme.titleMedium,
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
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool connected = endpoint.phase == TexthookerEndpointPhase.connected;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            connected ? Icons.check_circle_outline : Icons.sync_outlined,
            size: 18,
            color: connected ? colors.primary : colors.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(endpoint.url)),
          const SizedBox(width: 12),
          Flexible(
            child: Tooltip(
              message: endpoint.lastError ??
                  texthookerEndpointPhaseLabel(endpoint.phase),
              child: Text(
                texthookerEndpointPhaseLabel(endpoint.phase),
                textAlign: TextAlign.end,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
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
      icon: Icons.multitrack_audio_outlined,
      trailing: HibikiIconButton(
        icon: Icons.refresh,
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
      icon: Icons.receipt_long_outlined,
      trailing: Wrap(
        spacing: 8,
        children: <Widget>[
          HibikiSelectableChip(
            label: t.game_event_all,
            selected: !warningsOnly,
            focusId: const HibikiFocusId('game-diagnostics-event-all'),
            onSelected: (_) => onWarningsOnlyChanged(false),
          ),
          HibikiSelectableChip(
            label: t.game_event_warnings,
            selected: warningsOnly,
            focusId: const HibikiFocusId('game-diagnostics-event-warnings'),
            onSelected: (_) => onWarningsOnlyChanged(true),
          ),
        ],
      ),
      child: newest.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(t.game_no_events),
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
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color color = switch (event.severity) {
      GalHookEventSeverity.info => colors.secondary,
      GalHookEventSeverity.success => colors.primary,
      GalHookEventSeverity.warning => colors.tertiary,
      GalHookEventSeverity.error => colors.error,
    };
    // eink 下彩色圆点塌缩成同一灰阶（巡检 G5）：改成形状可辨的语义图标区分严重度。
    final Widget leading = isEinkTheme(context)
        ? Icon(
            switch (event.severity) {
              GalHookEventSeverity.info => Icons.info_outline,
              GalHookEventSeverity.success => Icons.check_circle_outline,
              GalHookEventSeverity.warning => Icons.warning_amber_outlined,
              GalHookEventSeverity.error => Icons.error_outline,
            },
            size: 18,
          )
        : Icon(Icons.circle, size: 10, color: color);
    return ListTile(
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
    return HibikiCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _DiagnosticRow extends StatelessWidget {
  const _DiagnosticRow({
    required this.label,
    required this.value,
    required this.ok,
  });

  final String label;
  final String value;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            ok ? Icons.check_circle_outline : Icons.schedule_outlined,
            size: 18,
            color: ok ? colors.primary : colors.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(label)),
          const SizedBox(width: 12),
          Flexible(
            child: Tooltip(
              message: value,
              child: Text(
                value,
                textAlign: TextAlign.end,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
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
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color background =
        error ? colors.errorContainer : colors.secondaryContainer;
    final Color foreground =
        error ? colors.onErrorContainer : colors.onSecondaryContainer;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, color: foreground, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(color: foreground))),
        ],
      ),
    );
  }
}
