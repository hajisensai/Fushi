import 'package:flutter/material.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/mining/galgame_audio_encode.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import 'package:hibiki/src/pages/implementations/game_shared.dart';
import 'package:hibiki/src/pages/implementations/stat_kpi_strip.dart';
import 'package:hibiki/src/sync/texthooker_ws_client.dart';
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
                  HibikiIconButton(
                    icon: Icons.refresh,
                    tooltip: t.game_refresh_tracks,
                    label: t.game_refresh_tracks,
                    onTap: _controller.refreshAudioTracks,
                  ),
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
                      const SizedBox(height: 16),
                      LayoutBuilder(
                        builder: (BuildContext context, BoxConstraints box) {
                          final Widget pipeline = _PipelineCard(state: state);
                          final Widget endpoints = _EndpointCard(
                            endpoints: _controller.endpointStatuses,
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
                        onSelectVoice: _controller.selectVoiceTrack,
                        onToggleExcluded: _controller.setTrackExcluded,
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
  const _EndpointCard({required this.endpoints});

  final List<TexthookerEndpointStatus> endpoints;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: t.game_text_endpoints,
      icon: Icons.hub_outlined,
      child: endpoints.isEmpty
          ? Text(
              t.game_status_not_configured,
              style: Theme.of(context).textTheme.bodyMedium,
            )
          : Column(
              children: <Widget>[
                for (final TexthookerEndpointStatus endpoint in endpoints)
                  _DiagnosticRow(
                    label: endpoint.url,
                    value: texthookerEndpointPhaseLabel(endpoint.phase),
                    ok: endpoint.phase == TexthookerEndpointPhase.connected,
                    detail: endpoint.lastError,
                  ),
              ],
            ),
    );
  }
}

class _AudioTracksCard extends StatelessWidget {
  const _AudioTracksCard({
    required this.state,
    required this.onSelectVoice,
    required this.onToggleExcluded,
  });

  final GalHookSessionState state;
  final ValueChanged<int> onSelectVoice;
  final void Function(int sourcePtr, bool excluded) onToggleExcluded;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: t.game_audio_tracks,
      icon: Icons.multitrack_audio_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          RadioListTile<int>(
            contentPadding: EdgeInsets.zero,
            value: 0,
            groupValue: state.selectedAudioSourcePtr,
            onChanged: (int? value) => onSelectVoice(value ?? 0),
            title: Text(t.game_track_auto),
            secondary: const Icon(Icons.auto_awesome_outlined),
          ),
          if (state.audioTracks.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(t.game_no_tracks),
            )
          else
            for (final GalAudioTrack track in state.audioTracks)
              _TrackTile(
                track: track,
                selected: state.selectedAudioSourcePtr == track.sourcePtr,
                excluded:
                    state.excludedAudioSourcePtrs.contains(track.sourcePtr),
                onSelect: () => onSelectVoice(track.sourcePtr),
                onToggleExcluded: (bool excluded) =>
                    onToggleExcluded(track.sourcePtr, excluded),
              ),
        ],
      ),
    );
  }
}

class _TrackTile extends StatelessWidget {
  const _TrackTile({
    required this.track,
    required this.selected,
    required this.excluded,
    required this.onSelect,
    required this.onToggleExcluded,
  });

  final GalAudioTrack track;
  final bool selected;
  final bool excluded;
  final VoidCallback onSelect;
  final ValueChanged<bool> onToggleExcluded;

  @override
  Widget build(BuildContext context) {
    final PcmFormat format = track.format;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(excluded ? Icons.music_off_outlined : Icons.graphic_eq),
      title: Text(
        '${t.game_track_voice} ${track.orderIndex + 1} · ${format.sampleRate} Hz · ${format.channels} ch',
      ),
      subtitle: Text(
        '0x${track.sourcePtr.toRadixString(16)} · '
        '${t.game_track_clips} ${track.clipCount} · '
        '${t.game_track_energy} ${track.avgEnergy.toStringAsFixed(1)}',
      ),
      trailing: Wrap(
        spacing: 4,
        children: <Widget>[
          HibikiIconButton(
            icon: selected ? Icons.check_circle : Icons.circle_outlined,
            tooltip: t.game_track_select_as_voice,
            enabled: !excluded,
            onTap: onSelect,
          ),
          HibikiIconButton(
            icon: excluded ? Icons.undo : Icons.music_off_outlined,
            tooltip: excluded ? t.game_track_restore : t.game_track_exclude_bgm,
            onTap: () => onToggleExcluded(!excluded),
          ),
        ],
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
    this.detail,
  });

  final String label;
  final String value;
  final bool ok;
  final String? detail;

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
              message: detail ?? value,
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
