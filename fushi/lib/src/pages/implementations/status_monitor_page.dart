import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/diagnostics/status_monitor.dart';
import 'package:fushi/src/diagnostics/thread_cpu_sampler.dart';
import 'package:fushi/src/diagnostics/ui_activity_probe.dart';
import 'package:fushi/src/settings/settings_kit_core.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// 设置 › 诊断 › 状态监测：实时 CPU / 内存 / 帧耗时 / UI 线程延迟 + 最近 2 分钟曲线，
/// 以及全局悬浮小窗的开关。页面打开期间持有 [StatusMonitor]（关页即停采样，除非悬浮小窗
/// 开着）。
class StatusMonitorPage extends StatefulWidget {
  const StatusMonitorPage({super.key, this.monitor});

  /// 测试注入；默认 [StatusMonitor.instance]。
  final StatusMonitor? monitor;

  @override
  State<StatusMonitorPage> createState() => _StatusMonitorPageState();
}

class _StatusMonitorPageState extends State<StatusMonitorPage> {
  late final StatusMonitor _monitor = widget.monitor ?? StatusMonitor.instance;

  @override
  void initState() {
    super.initState();
    _monitor.acquire();
  }

  @override
  void dispose() {
    _monitor.release();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _monitor.describeHistory()));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(FushiSnackBar(content: Text(t.copied_to_clipboard)));
  }

  @override
  Widget build(BuildContext context) {
    return SettingsKitScaffold(
      leadingIcon: FushiIcons.speed,
      leadingTone: SettingsIconTone.gray,
      title: t.settings_status_monitor_title,
      actions: <Widget>[
        FushiIconButton(
          icon: FushiIcons.copy,
          tooltip: t.status_monitor_copy,
          onTap: _copy,
        ),
      ],
      bodyConsumesTopPadding: true,
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) {
            final double top = MediaQuery.paddingOf(context).top;
            return ListenableBuilder(
              listenable: _monitor,
              builder: (BuildContext context, Widget? _) {
                final List<Widget> sections = <Widget>[
                  _LiveSection(monitor: _monitor),
                  _ThreadsSection(sample: _monitor.latest),
                  _StuttersSection(monitor: _monitor),
                  _DetailsSection(sample: _monitor.latest),
                  _OverlaySection(monitor: _monitor),
                ];
                return FushiEntranceScope(
                  child: ListView.builder(
                    controller: controller,
                    padding: EdgeInsets.fromLTRB(12, top, 12, 24),
                    itemCount: sections.length,
                    itemBuilder: fushiStaggeredItemBuilder(
                      (BuildContext context, int index) => sections[index],
                    ),
                  ),
                );
              },
            );
          },
    );
  }
}

String _fmtPercent(double? v) =>
    v == null ? t.status_monitor_unavailable : '${v.toStringAsFixed(1)}%';

String _fmtMb(int? bytes) =>
    bytes == null ? t.status_monitor_unavailable : '${bytes >> 20} MB';

class _LiveSection extends StatelessWidget {
  const _LiveSection({required this.monitor});

  final StatusMonitor monitor;

  @override
  Widget build(BuildContext context) {
    final List<StatusSample> history = monitor.history;
    final StatusSample? s = monitor.latest;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final List<Widget> tiles = <Widget>[
      _MetricTile(
        label: t.status_monitor_cpu,
        value: s == null ? '—' : _fmtPercent(s.cpuPercent),
        detail: s == null || s.cpuPercentOfOneCore == null
            ? null
            : t.status_monitor_cpu_detail(
                cores: s.cores,
                oneCore: s.cpuPercentOfOneCore!.toStringAsFixed(0),
              ),
        values: <double?>[for (final StatusSample h in history) h.cpuPercent],
        floor: 25,
        color: cs.primary,
      ),
      _MetricTile(
        label: t.status_monitor_memory,
        value: s == null ? '—' : _fmtMb(s.rssBytes),
        detail: t.status_monitor_rss,
        values: <double?>[
          for (final StatusSample h in history) (h.rssBytes >> 20).toDouble(),
        ],
        floor: 64,
        color: cs.tertiary,
      ),
      _MetricTile(
        label: t.status_monitor_frames,
        value: s == null ? '—' : '${s.frames.frames}',
        detail: s == null
            ? null
            : t.status_monitor_frames_detail(
                jank: s.frames.jankFrames,
                budget: s.frameBudgetMs.toStringAsFixed(1),
              ),
        warn: s != null && s.frames.jankFrames > 0,
        values: <double?>[
          for (final StatusSample h in history) h.frames.jankFrames.toDouble(),
        ],
        floor: 5,
        color: cs.error,
      ),
      _MetricTile(
        label: t.status_monitor_ui_lag,
        value: s == null ? '—' : '${s.uiLagMs} ms',
        detail: t.status_monitor_ui_lag_hint,
        warn: s != null && s.uiLagMs >= 100,
        values: <double?>[
          for (final StatusSample h in history) h.uiLagMs.toDouble(),
        ],
        floor: 100,
        color: cs.secondary,
      ),
    ];
    return AdaptiveSettingsSection(
      title: t.status_monitor_section_live,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(12),
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) {
              final int columns = c.maxWidth >= 640 ? 2 : 1;
              const double gap = 12;
              final double width = (c.maxWidth - gap * (columns - 1)) / columns;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (s == null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        t.status_monitor_waiting,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: <Widget>[
                      for (final Widget tile in tiles)
                        SizedBox(width: width, child: tile),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.value,
    required this.values,
    required this.floor,
    required this.color,
    this.detail,
    this.warn = false,
  });

  final String label;
  final String value;
  final String? detail;
  final List<double?> values;

  /// 纵轴上限的下限：数值小的时候曲线不至于被放大成满屏抖动。
  final double floor;
  final Color color;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    return FushiCard(
      pressScale: false,
      stateLayer: false,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: warn ? cs.error : cs.onSurface,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          if (detail != null)
            Text(
              detail!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: 8),
          SizedBox(
            height: 40,
            width: double.infinity,
            child: CustomPaint(
              painter: StatusSparklinePainter(
                values: values,
                capacity: kStatusMonitorHistoryLength,
                floor: floor,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 迷你折线：最新的点贴右边缘，[capacity] 个点铺满宽度；null 断线。
@visibleForTesting
class StatusSparklinePainter extends CustomPainter {
  StatusSparklinePainter({
    required this.values,
    required this.capacity,
    required this.floor,
    required this.color,
  });

  final List<double?> values;
  final int capacity;
  final double floor;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty || capacity < 2) return;
    double maxV = floor;
    for (final double? v in values) {
      if (v != null && v > maxV) maxV = v;
    }
    final double step = size.width / (capacity - 1);
    final int offset = capacity - values.length;
    final Paint line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeJoin = StrokeJoin.round;
    final Paint fill = Paint()
      ..color = color.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill;
    Path? stroke;
    Path? area;
    double lastX = 0;
    void flush() {
      if (stroke == null) return;
      area!
        ..lineTo(lastX, size.height)
        ..close();
      canvas
        ..drawPath(area!, fill)
        ..drawPath(stroke!, line);
      stroke = null;
      area = null;
    }

    for (int i = 0; i < values.length; i++) {
      final double? v = values[i];
      final double x = (offset + i) * step;
      if (v == null) {
        flush();
        continue;
      }
      final double y = size.height - (math.max(0, v) / maxV) * size.height;
      if (stroke == null) {
        stroke = Path()..moveTo(x, y);
        area = Path()
          ..moveTo(x, size.height)
          ..lineTo(x, y);
      } else {
        stroke!.lineTo(x, y);
        area!.lineTo(x, y);
      }
      lastX = x;
    }
    flush();
  }

  @override
  bool shouldRepaint(StatusSparklinePainter old) =>
      !identical(old.values, values) ||
      old.color != color ||
      old.floor != floor ||
      old.capacity != capacity;
}

class _DetailsSection extends StatelessWidget {
  const _DetailsSection({required this.sample});

  final StatusSample? sample;

  @override
  Widget build(BuildContext context) {
    final StatusSample? s = sample;
    final List<Widget> rows = <Widget>[
      _ValueRow(
        title: t.status_monitor_rss,
        value: s == null ? '—' : _fmtMb(s.rssBytes),
      ),
      if (s?.privateBytes != null)
        _ValueRow(
          title: t.status_monitor_private,
          value: _fmtMb(s!.privateBytes),
        ),
      if (s?.nativeHeapMb != null)
        _ValueRow(
          title: t.status_monitor_native_heap,
          value: '${s!.nativeHeapMb} MB',
        ),
      if (s?.systemAvailBytes != null && s?.systemTotalBytes != null)
        _ValueRow(
          title: t.status_monitor_system_memory,
          value: t.status_monitor_system_memory_value(
            avail: s!.systemAvailBytes! >> 20,
            total: s.systemTotalBytes! >> 20,
          ),
        ),
      _ValueRow(
        title: t.status_monitor_image_cache,
        value: s == null
            ? '—'
            : t.status_monitor_image_cache_value(
                mb: s.imageCacheBytes >> 20,
                live: s.imageCacheLive,
              ),
      ),
      _ValueRow(
        title: t.status_monitor_frame_worst,
        subtitle: t.status_monitor_frames_hint,
        value: s == null
            ? '—'
            : t.status_monitor_frame_worst_value(
                build: s.frames.worstBuildMs.toStringAsFixed(1),
                raster: s.frames.worstRasterMs.toStringAsFixed(1),
              ),
      ),
      if (s != null && s.memoryNotes.isNotEmpty)
        AdaptiveSettingsRow(
          title: t.status_monitor_memory_notes,
          subtitle: s.memoryNotes.join('\n'),
          subtitleMaxLines: 8,
        ),
    ];
    return AdaptiveSettingsSection(
      title: t.status_monitor_section_details,
      children: rows,
    );
  }
}

class _ValueRow extends StatelessWidget {
  const _ValueRow({required this.title, required this.value, this.subtitle});

  final String title;
  final String value;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsRow(
      title: title,
      subtitle: subtitle,
      trailing: Text(
        value,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _OverlaySection extends StatelessWidget {
  const _OverlaySection({required this.monitor});

  final StatusMonitor monitor;

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsSection(
      title: t.status_monitor_section_overlay,
      children: <Widget>[
        AdaptiveSettingsSwitchRow(
          title: t.status_monitor_overlay_toggle,
          subtitle: t.status_monitor_overlay_toggle_hint,
          value: monitor.overlayEnabled,
          onChanged: (bool v) => monitor.setOverlayEnabled(v),
        ),
        if (monitor.overlayEnabled)
          AdaptiveSettingsSegmentedRow<StatusMonitorOverlayCorner>(
            title: t.status_monitor_overlay_corner,
            selected: monitor.overlayCorner,
            onChanged: (StatusMonitorOverlayCorner c) =>
                monitor.setOverlayCorner(c),
            segments: <ButtonSegment<StatusMonitorOverlayCorner>>[
              ButtonSegment<StatusMonitorOverlayCorner>(
                value: StatusMonitorOverlayCorner.topLeft,
                label: Text(t.status_monitor_corner_top_left),
              ),
              ButtonSegment<StatusMonitorOverlayCorner>(
                value: StatusMonitorOverlayCorner.topRight,
                label: Text(t.status_monitor_corner_top_right),
              ),
              ButtonSegment<StatusMonitorOverlayCorner>(
                value: StatusMonitorOverlayCorner.bottomLeft,
                label: Text(t.status_monitor_corner_bottom_left),
              ),
              ButtonSegment<StatusMonitorOverlayCorner>(
                value: StatusMonitorOverlayCorner.bottomRight,
                label: Text(t.status_monitor_corner_bottom_right),
              ),
            ],
          ),
      ],
    );
  }
}

/// 线程类别的人话说明；认不出的返回 null。
String? describeThreadKind(ThreadKind kind) => switch (kind) {
  ThreadKind.flutterUi => t.status_monitor_thread_flutter_ui,
  ThreadKind.flutterRaster => t.status_monitor_thread_flutter_raster,
  ThreadKind.flutterIo => t.status_monitor_thread_flutter_io,
  ThreadKind.dartWorker => t.status_monitor_thread_dart_worker,
  ThreadKind.video => t.status_monitor_thread_video,
  ThreadKind.rust => t.status_monitor_thread_rust,
  ThreadKind.flutterEngine => t.status_monitor_thread_flutter_engine,
  ThreadKind.system => t.status_monitor_thread_system,
  ThreadKind.unnamed => t.status_monitor_thread_unnamed_hint,
  ThreadKind.other => null,
};

class _ThreadsSection extends StatelessWidget {
  const _ThreadsSection({required this.sample});

  final StatusSample? sample;

  @override
  Widget build(BuildContext context) {
    final List<ThreadGroupUsage> threads =
        sample?.threads ?? const <ThreadGroupUsage>[];
    final TextStyle? valueStyle = Theme.of(context).textTheme.bodyMedium
        ?.copyWith(
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        );
    return AdaptiveSettingsSection(
      title: t.status_monitor_section_threads,
      children: <Widget>[
        AdaptiveSettingsRow(
          title: t.status_monitor_threads_hint,
          titleMaxLines: 3,
        ),
        if (threads.isEmpty)
          AdaptiveSettingsRow(title: t.status_monitor_threads_waiting)
        else
          for (final ThreadGroupUsage g in threads)
            AdaptiveSettingsRow(
              title: g.group.isEmpty
                  ? t.status_monitor_thread_unnamed
                  : g.group,
              subtitle: <String>[
                ?describeThreadKind(classifyThread(g.group)),
                if (g.threads > 1) t.status_monitor_thread_count(n: g.threads),
              ].join(' · '),
              subtitleMaxLines: 3,
              trailing: Text(
                '${g.percentOfOneCore.toStringAsFixed(0)}%',
                style: valueStyle,
              ),
            ),
      ],
    );
  }
}

class _StuttersSection extends StatelessWidget {
  const _StuttersSection({required this.monitor});

  final StatusMonitor monitor;

  @override
  Widget build(BuildContext context) {
    final List<StutterEvent> events = monitor.stutters;
    String two(int v) => v.toString().padLeft(2, '0');
    return AdaptiveSettingsSection(
      title: t.status_monitor_section_stutters,
      children: <Widget>[
        if (events.isEmpty)
          AdaptiveSettingsRow(
            title: t.status_monitor_stutters_empty,
            titleMaxLines: 5,
          )
        else ...<Widget>[
          for (final StutterEvent e in events)
            AdaptiveSettingsRow(
              title: t.status_monitor_stutter_title(
                time:
                    '${two(e.sample.time.hour)}:${two(e.sample.time.minute)}:${two(e.sample.time.second)}',
                lag: e.sample.uiLagMs,
                jank: e.sample.frames.jankFrames,
                worst:
                    (e.sample.frames.worstBuildMs >
                                e.sample.frames.worstRasterMs
                            ? e.sample.frames.worstBuildMs
                            : e.sample.frames.worstRasterMs)
                        .toStringAsFixed(0),
              ),
              titleMaxLines: 3,
              subtitle: <String>[
                if (e.pages.isNotEmpty)
                  t.status_monitor_stutter_page(pages: e.pages.join(' › ')),
                if (e.tickers.isNotEmpty)
                  t.status_monitor_stutter_animations(
                    names: describeTickerOwners(e.tickers, separator: ', '),
                  ),
                if (e.sample.threads.isNotEmpty)
                  t.status_monitor_stutter_threads(
                    threads: describeThreadGroups(e.sample.threads, max: 3),
                  ),
              ].join('\n'),
              subtitleMaxLines: 8,
            ),
          AdaptiveSettingsRow(
            title: t.status_monitor_stutters_clear,
            onTap: monitor.clearStutters,
          ),
        ],
      ],
    );
  }
}
