import 'package:fushi/src/diagnostics/status_monitor.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:material_ui/material_ui.dart';

/// 全局状态悬浮小窗（设置 › 诊断 › 状态监测 › 显示悬浮小窗）：盖在所有页面之上的一小块
/// 读数。整层 [IgnorePointer]，不抢任何点击 / 拖动；单独一层 [RepaintBoundary]，每秒刷新
/// 只重绘自己，不连带页面。
///
/// 必须作为 [Stack] 的直接子节点（返回 [Positioned.fill]）。
class StatusMonitorOverlayHost extends StatelessWidget {
  const StatusMonitorOverlayHost({super.key, this.monitor});

  /// 测试注入；默认 [StatusMonitor.instance]。
  final StatusMonitor? monitor;

  @override
  Widget build(BuildContext context) {
    final StatusMonitor m = monitor ?? StatusMonitor.instance;
    return Positioned.fill(
      child: IgnorePointer(
        child: ListenableBuilder(
          listenable: m,
          builder: (BuildContext context, Widget? _) {
            if (!m.overlayEnabled) return const SizedBox.shrink();
            return SafeArea(
              child: Align(
                alignment: switch (m.overlayCorner) {
                  StatusMonitorOverlayCorner.topLeft => Alignment.topLeft,
                  StatusMonitorOverlayCorner.topRight => Alignment.topRight,
                  StatusMonitorOverlayCorner.bottomLeft => Alignment.bottomLeft,
                  StatusMonitorOverlayCorner.bottomRight =>
                    Alignment.bottomRight,
                },
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: RepaintBoundary(
                    child: StatusMonitorReadout(sample: m.latest),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 悬浮小窗本体：深色半透明底 + 等宽数字，三行（CPU / 内存 / 帧与 UI 延迟）。
@visibleForTesting
class StatusMonitorReadout extends StatelessWidget {
  const StatusMonitorReadout({required this.sample, super.key});

  final StatusSample? sample;

  @override
  Widget build(BuildContext context) {
    final StatusSample? s = sample;
    const Color normal = Color(0xFFFFFFFF);
    const Color alert = Color(0xFFFF8A80);
    // 字号取排版令牌 labelSmall；颜色固定白字（底是固定的深色半透明，不随主题）。
    final TextStyle base = context.fushiType.labelSmall.copyWith(
      height: 1.3,
      color: normal,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      decoration: TextDecoration.none,
    );
    final List<InlineSpan> lines;
    if (s == null) {
      lines = const <InlineSpan>[TextSpan(text: 'CPU —\nRAM —\nFPS —')];
    } else {
      final String cpu = s.cpuPercent == null
          ? '—'
          : '${s.cpuPercent!.toStringAsFixed(0)}%';
      final bool jank = s.frames.jankFrames > 0;
      final bool lag = s.uiLagMs >= 100;
      lines = <InlineSpan>[
        TextSpan(text: 'CPU $cpu\n'),
        TextSpan(text: 'RAM ${s.rssBytes >> 20} MB\n'),
        TextSpan(
          text: 'FPS ${s.frames.frames}',
          children: <InlineSpan>[
            if (jank)
              TextSpan(
                text: ' ✕${s.frames.jankFrames}',
                style: const TextStyle(color: alert),
              ),
          ],
        ),
        TextSpan(
          text: '  ${s.uiLagMs}ms',
          style: lag ? const TextStyle(color: alert) : null,
        ),
        // 最忙的线程组（单核口径）：一眼看出是 UI 线程、光栅还是后台在占。
        if (s.threads.isNotEmpty)
          TextSpan(text: '\nTOP ${describeThreadGroups(s.threads, max: 1)}'),
      ];
    }
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0xB3000000),
        borderRadius: FushiBorderRadius.chip,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Text.rich(
          TextSpan(style: base, children: lines),
          textScaler: TextScaler.noScaling,
        ),
      ),
    );
  }
}
