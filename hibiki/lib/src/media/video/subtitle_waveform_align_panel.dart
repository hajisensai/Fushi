import 'package:flutter/material.dart';

import 'package:hibiki/src/media/video/audio_energy_probe.dart';
import 'package:hibiki/src/media/video/subtitle_waveform_painter.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// 字幕对轴的「音频波形可视化 + 拖动预览」面板（TODO-1051 阶段B）。
///
/// 挂在视频快速设置面板的「字幕调轴」区，把音频响度波形 + 字幕 cue 边界画在一条时间轴上，
/// 让用户拖一根滑条实时预览字幕整体平移到哪、松手才落盘（唯一写回点是 [onCommitDelay]，
/// 即页面既有的 setDelay）。cue 的 start/end 不可变，延迟只在可视化时叠加，滑动期间不落盘。
///
/// 零新持久化：面板不引入任何新的偏好/DB 字段，delayMs 仍走既有落盘路径。
///
/// 优雅降级：波形数据来自 loadWaveform（页面经 ffmpeg 抽音频能量包络）。移动端拿不到逐帧行
/// 返回空包络；此时面板退化成纯 delay stepper（步进按钮 + 数值标签 + 拖动滑条），不崩不空白。
///
/// 不在 paint 里跑 ffmpeg：loadWaveform 在 initState 只调一次，缓存原始逐帧包络；
/// 降采样（downsampleEnergyEnvelope，纯函数）随面板宽度在 build 里算，painter 只读 0..1 桶。
class SubtitleWaveformAlignPanel extends StatefulWidget {
  const SubtitleWaveformAlignPanel({
    required this.initialDelayMs,
    required this.clampMs,
    required this.cues,
    required this.durationMs,
    required this.loadWaveform,
    required this.onCommitDelay,
    this.positionListenable,
    this.currentPositionMs,
    this.height = 96.0,
    super.key,
  });

  /// 当前已落盘的字幕延迟（毫秒，正=字幕延后）。面板打开时的初值。
  final int initialDelayMs;

  /// 延迟 clamp 范围（正负 clampMs），与调用方 setDelay 一致。
  final int clampMs;

  /// 当前字幕 cue 列表（取 start/end 画边界线）。不可变，面板只读，绝不改 cue 本体。
  final List<AudioCue> cues;

  /// 视频总时长（毫秒）。<=0 时波形时间窗退化，painter 据此不画时间相关层（降级）。
  final int durationMs;

  /// 抽音频能量包络（原始逐帧 dB 序列）。由页面提供（经 extractAudioEnergyEnvelope）；
  /// 返回空列表 = 拿不到波形（移动端降级）。面板在 initState 只调一次。
  final Future<List<double>> Function() loadWaveform;

  /// 提交延迟落盘（松手才调）。即页面既有的 setDelay。
  final Future<void> Function(int delayMs) onCommitDelay;

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
  /// 拖动预览中的延迟（毫秒），不落盘；松手才 [_commit]。初值 = 已落盘延迟。
  late int _previewDelayMs = widget.initialDelayMs;

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

  Future<void> _loadWaveformOnce() async {
    try {
      final List<double> raw = await widget.loadWaveform();
      if (!mounted) return;
      setState(() {
        _rawEnvelope = raw;
        _loaded = true;
      });
    } catch (_) {
      // 抽取失败一律降级（纯 stepper），不崩不空白。
      if (!mounted) return;
      setState(() {
        _rawEnvelope = const <double>[];
        _loaded = true;
      });
    }
  }

  /// cue 边界（start/end 混合，未加延迟）。painter 内部叠加 [_previewDelayMs]。
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

  void _preview(int next) {
    final int clamped = next.clamp(-widget.clampMs, widget.clampMs);
    if (clamped == _previewDelayMs) return;
    setState(() => _previewDelayMs = clamped);
  }

  Future<void> _commit(int next) async {
    final int clamped = next.clamp(-widget.clampMs, widget.clampMs);
    setState(() => _previewDelayMs = clamped);
    await widget.onCommitDelay(clamped);
  }

  String _delayLabel(int ms) {
    return ms >= 0 ? '+$ms ms' : '$ms ms';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;

    // 波形柱状可视化：仅当加载完且拿到非空包络时画；否则降级（纯 stepper）。
    final bool hasWaveform = _loaded && (_rawEnvelope?.isNotEmpty ?? false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (!_loaded)
          SizedBox(
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
          )
        else if (hasWaveform)
          _buildWaveform(cs)
        else
          const SizedBox.shrink(),
        const SizedBox(height: 8),
        _buildPreviewSlider(cs),
      ],
    );
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
              previewDelayMs: _previewDelayMs,
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

  /// 预览滑条 + 步进：拖动实时更新 [_previewDelayMs]（painter 里 cue 线整体平移），
  /// 松手才 [_commit] 落盘。滑条范围与快速设置面板的字幕调轴滑条一致（正负 10s 细调），
  /// 超出仍可经上方面板的数值输入框设置（本面板只负责可视化 + 细调）。
  Widget _buildPreviewSlider(ColorScheme cs) {
    final int sliderRangeMs = widget.clampMs < 10000 ? widget.clampMs : 10000;
    final double sliderValue =
        _previewDelayMs.clamp(-sliderRangeMs, sliderRangeMs).toDouble();
    final String label = _delayLabel(_previewDelayMs);
    return Row(
      children: <Widget>[
        IconButton(
          icon: const Icon(Icons.chevron_left),
          tooltip: '-50ms',
          onPressed: () => _commit(_previewDelayMs - 50),
        ),
        Expanded(
          child: Slider(
            value: sliderValue,
            min: -sliderRangeMs.toDouble(),
            max: sliderRangeMs.toDouble(),
            divisions: sliderRangeMs > 0 ? sliderRangeMs ~/ 50 : null,
            label: label,
            onChanged: (double v) => _preview(v.round()),
            onChangeEnd: (double v) => _commit(v.round()),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right),
          tooltip: '+50ms',
          onPressed: () => _commit(_previewDelayMs + 50),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 72, maxWidth: 110),
          child: Text(
            label,
            textAlign: TextAlign.end,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: _previewDelayMs == 0 ? cs.onSurfaceVariant : cs.primary,
            ),
          ),
        ),
      ],
    );
  }
}
