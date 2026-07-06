import 'package:flutter/material.dart';

import 'package:hibiki/src/media/video/audio_energy_probe.dart';
import 'package:hibiki/src/media/video/subtitle_waveform_painter.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// 字幕对轴的「音频波形可视化」面板（TODO-1051 阶段B；TODO-1207 收敛为纯可视化）。
///
/// 挂在视频快速设置面板的「字幕调轴」区，把音频响度波形 + 字幕 cue 边界画在一条时间轴上，
/// 让用户直观看到字幕整体平移到哪。cue 的 start/end 不可变，延迟只在可视化时叠加。
///
/// TODO-1207：本面板原先自带一条「拖动预览 + 步进」滑条，与上方快速设置的音画延迟行
/// （滑条 / ± 步进 / 归零 / 自动对轴 / 数值输入框）完全冗余，已删除。现面板不再写回延迟，
/// 只做可视化：要平移的延迟经 [initialDelayMs] 从上方权威 `_delayMs` 传入，面板在
/// [didUpdateWidget] 里同步——上方任意手动调轴 / 自动对轴改延迟后，波形 cue 线随之整体平移。
///
/// 零新持久化：面板不引入任何新的偏好/DB 字段，delayMs 仍全程由上方面板落盘。
///
/// 优雅降级：波形数据来自 loadWaveform（页面经 ffmpeg 抽音频能量包络）。移动端拿不到逐帧行
/// 返回空包络；此时面板收起（纯可视化、无控件），不崩不空白。
///
/// 不在 paint 里跑 ffmpeg：loadWaveform 在 initState 只调一次，缓存原始逐帧包络；
/// 降采样（downsampleEnergyEnvelope，纯函数）随面板宽度在 build 里算，painter 只读 0..1 桶。
class SubtitleWaveformAlignPanel extends StatefulWidget {
  const SubtitleWaveformAlignPanel({
    required this.initialDelayMs,
    required this.cues,
    required this.durationMs,
    required this.loadWaveform,
    this.positionListenable,
    this.currentPositionMs,
    this.height = 96.0,
    super.key,
  });

  /// 要在波形上可视化的字幕延迟（毫秒，正=字幕延后）。由上方快速设置面板的权威 `_delayMs`
  /// 传入；变化时经 [didUpdateWidget] 同步，cue 线整体平移。
  final int initialDelayMs;

  /// 当前字幕 cue 列表（取 start/end 画边界线）。不可变，面板只读，绝不改 cue 本体。
  final List<AudioCue> cues;

  /// 视频总时长（毫秒）。<=0 时波形时间窗退化，painter 据此不画时间相关层（降级）。
  final int durationMs;

  /// 抽音频能量包络（原始逐帧 dB 序列）。由页面提供（经 extractAudioEnergyEnvelope）；
  /// 返回空列表 = 拿不到波形（移动端降级）。面板在 initState 只调一次。
  final Future<List<double>> Function() loadWaveform;

  /// 可选：播放位置变化的通知源（如 VideoPlayerController），用于重绘播放头。
  final Listenable? positionListenable;

  /// 可选：读当前播放位置（毫秒）。null 时不画播放头。
  final int Function()? currentPositionMs;

  /// 波形区高度（逻辑像素）。
  final double height;

  @override
  State<SubtitleWaveformAlignPanel> createState() =>
      _SubtitleWaveformAlignPanelState();
}

class _SubtitleWaveformAlignPanelState
    extends State<SubtitleWaveformAlignPanel> {
  /// 波形上可视化的延迟（毫秒），painter 据此把 cue 线整体平移。跟随 [initialDelayMs]
  /// （上方权威 `_delayMs`），经 [didUpdateWidget] 同步。
  late int _renderDelayMs = widget.initialDelayMs;

  /// 原始逐帧音频能量包络（[loadWaveform] 一次性抽出）。null = 加载中；空 = 拿不到（降级）。
  List<double>? _rawEnvelope;

  /// 波形是否已加载完成（含空结果的降级态）。
  bool _loaded = false;

  /// 每根波形柱的目标像素宽（含间隙），用来据面板宽度算降采样桶数。
  static const double _barSlotPx = 3.0;

  @override
  void initState() {
    super.initState();
    _loadWaveformOnce();
  }

  @override
  void didUpdateWidget(SubtitleWaveformAlignPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // TODO-1206/1207：上方面板（手动调轴 / 自动对轴）改延迟后 setState 用新 initialDelayMs
    // 重建本面板；同步 [_renderDelayMs] 让波形 cue 线立即随之整体平移。
    if (oldWidget.initialDelayMs != widget.initialDelayMs &&
        _renderDelayMs != widget.initialDelayMs) {
      setState(() => _renderDelayMs = widget.initialDelayMs);
    }
  }

  Future<void> _loadWaveformOnce() async {
    try {
      final List<double> raw = await widget.loadWaveform();
      if (!mounted) return;
      setState(() {
        _rawEnvelope = raw;
        _loaded = true;
      });
    } catch (_) {
      // 抽取失败一律降级（收起面板），不崩不空白。
      if (!mounted) return;
      setState(() {
        _rawEnvelope = const <double>[];
        _loaded = true;
      });
    }
  }

  /// cue 边界（start/end 混合，未加延迟）。painter 内部叠加 [_renderDelayMs]。
  List<int> get _cueBoundariesMs {
    final List<int> out = <int>[];
    for (final AudioCue cue in widget.cues) {
      out.add(cue.startMs);
      out.add(cue.endMs);
    }
    return out;
  }

  /// 波形时间窗上界（毫秒）：与 extractAudioEnergyEnvelope 的探测上界同源
  /// （前 N 分钟截断），取 min(durationMs, probeLimit)；durationMs 未知时用探测上界。
  int get _windowEndMs {
    const int limit = kSubtitleAutoAlignProbeLimitMs;
    if (widget.durationMs <= 0) return limit;
    return widget.durationMs < limit ? widget.durationMs : limit;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;

    // 波形柱状可视化：仅当加载完且拿到非空包络时画；否则收起（纯可视化，无控件）。
    final bool hasWaveform = _loaded && (_rawEnvelope?.isNotEmpty ?? false);

    if (!_loaded) {
      return SizedBox(
        height: widget.height,
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: cs.primary,
            ),
          ),
        ),
      );
    }
    if (!hasWaveform) return const SizedBox.shrink();
    return _buildWaveform(cs);
  }

  Widget _buildWaveform(ColorScheme cs) {
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double width = constraints.maxWidth;
          final int targetBuckets =
              width > 0 ? (width / _barSlotPx).floor().clamp(1, 100000) : 1;
          final List<double> buckets = downsampleEnergyEnvelope(
            _rawEnvelope ?? const <double>[],
            targetBuckets,
          );
          SubtitleWaveformPainter buildPainter(int positionMs) {
            return SubtitleWaveformPainter(
              buckets: buckets,
              windowStartMs: 0,
              windowEndMs: _windowEndMs,
              cueBoundariesMs: _cueBoundariesMs,
              previewDelayMs: _renderDelayMs,
              currentPositionMs: positionMs,
              waveColor: cs.primary.withValues(alpha: 0.55),
              cueLineColor: cs.secondary,
              playheadColor: cs.tertiary,
              centerLineColor: cs.outlineVariant,
            );
          }

          if (widget.positionListenable != null &&
              widget.currentPositionMs != null) {
            return AnimatedBuilder(
              animation: widget.positionListenable!,
              builder: (BuildContext _, __) => CustomPaint(
                size: Size(width, widget.height),
                painter: buildPainter(widget.currentPositionMs!.call()),
              ),
            );
          }
          return CustomPaint(
            size: Size(width, widget.height),
            painter: buildPainter(widget.currentPositionMs?.call() ?? -1),
          );
        },
      ),
    );
  }
}
