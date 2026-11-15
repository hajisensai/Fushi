import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi/src/media/video/subtitle_auto_align.dart';

/// 浏览器扩展「自动对轴」（反馈 0wkJImhZUp）的服务端算法入口。
///
/// app 内视频页的自动对轴（[bestOffsetMsByCrossCorrelation]）从 ffmpeg 抽出的**整段**能量
/// 包络起算（t = 0 起、等间隔、无空洞）。网页视频没有可读的媒体文件：扩展只能在用户播放时
/// 从 `<video>.captureStream()` 边播边听，攒下的是**媒体时间上的一段窗口**，中间还可能因为
/// 拖动进度条留下没听过的空洞。这里把这份「窗口 + 空洞」的包络对齐到 app 那套纯算法的输入
/// 形状上，算法本体（归一化 VAD、cue 栅格化、Rust 互相关）一行不复制：
///
/// - 窗口平移：cue 统一减去 [startMs]，于是窗口起点就是 app 算法里的 t = 0；
/// - 空洞屏蔽：没听过的格音频记 NaN（[normalizeAudioEnergyEnvelope] 按 0 处理），同一格的
///   cue 活动也清零——否则「没听到」会被当成「这段有字幕却没声音」，把置信度压低、把峰值
///   推歪；
/// - 结果语义与 app 一致：[SubtitleAutoAlignResult.offsetMs] 是让**传入的 cue**（扩展传的是
///   已套上当前偏移的 cue）整体再平移多少毫秒，正值 = 字幕延后，与扩展 `trackOffsets` 同号。
///
/// [rmsDb] 第 i 格覆盖媒体时间 `[startMs + i·binMs, startMs + (i+1)·binMs)`，值是该格的 RMS
/// 电平（dBFS，与 ffmpeg astats `RMS_level` 同义，静音用一个很低的有限值）；null = 没听到。
/// 有效（非 null）格少于 [minCapturedBins] 时直接 noData，不拿几秒钟的声音乱平移。
SubtitleAutoAlignResult alignCuesToCapturedEnvelope({
  required List<double?> rmsDb,
  required int startMs,
  required List<({int startMs, int endMs})> cues,
  int binMs = kSubtitleAutoAlignBinMs,
  int maxShiftMs = kSubtitleAutoAlignMaxShiftMs,
  int minCapturedBins = kCaptureAlignMinCapturedBins,
}) {
  if (binMs <= 0 || rmsDb.isEmpty || cues.isEmpty) {
    return SubtitleAutoAlignResult.noData;
  }
  int captured = 0;
  final List<double> raw = List<double>.filled(rmsDb.length, double.nan);
  for (int i = 0; i < rmsDb.length; i++) {
    final double? v = rmsDb[i];
    if (v == null || !v.isFinite) continue;
    raw[i] = v;
    captured++;
  }
  if (captured < minCapturedBins) return SubtitleAutoAlignResult.noData;

  final int windowMs = rmsDb.length * binMs;
  final List<AudioCue> shifted = <AudioCue>[
    for (final ({int startMs, int endMs}) c in cues)
      if (c.endMs > c.startMs)
        AudioCue()
          ..bookKey = ''
          ..chapterHref = ''
          ..sentenceIndex = 0
          ..textFragmentId = ''
          ..text = ''
          ..startMs = c.startMs - startMs
          ..endMs = c.endMs - startMs
          ..audioFileIndex = 0,
  ];
  final List<double> cueActivity = buildCueActivityEnvelope(
    shifted,
    windowMs,
    binMs: binMs,
  );
  if (cueActivity.isEmpty) return SubtitleAutoAlignResult.noData;
  for (int i = 0; i < cueActivity.length && i < raw.length; i++) {
    if (raw[i].isNaN) cueActivity[i] = 0.0;
  }
  final List<double> audioActivity = normalizeAudioEnergyEnvelope(raw);
  return bestOffsetMsByCrossCorrelation(
    audioActivity,
    cueActivity,
    binMs: binMs,
    maxShiftMs: maxShiftMs,
  );
}

/// 扩展自动对轴至少要听到多少格（[kSubtitleAutoAlignBinMs] 一格）才算：20 秒。少于这个量
/// 互相关只是在几句对白上碰运气，宁可回 noData 让扩展继续听。扩展侧
/// `subtitle-align.js` 的 `AUTO_MIN_CAPTURED_MS` 必须 ≥ 这个量（守卫在 Dart 测试里交叉比对）。
const int kCaptureAlignMinCapturedBins = 200;

/// `/api/subtitle/align` 请求体上限：最多 20 分钟的包络（与 app 自动对轴的本地探测上界同一
/// 量级）、最多 20000 条 cue。超出 400，防止一个畸形请求把互相关拖成几秒的 CPU 活。
const int kCaptureAlignMaxBins = 12000;
const int kCaptureAlignMaxCues = 20000;

/// `/api/subtitle/align` 的请求体解析 + 计算 + 响应体。body：
/// `{binMs, startMs, rmsDb: [number|null…], cues: [{startMs, endMs}…]}`。
/// 体不合契约返回 null（调用方回 400）；否则回
/// `{status: 'aligned'|'lowConfidence'|'noData', offsetMs, confidence}`。
/// [binMs] 必须是 [kSubtitleAutoAlignBinMs]：置信阈值、最小样本量都是按这个栅格标定的。
Map<String, dynamic>? buildCaptureAlignResponse(Map<String, dynamic> body) {
  final Object? binRaw = body['binMs'];
  final Object? startRaw = body['startMs'];
  final Object? rmsRaw = body['rmsDb'];
  final Object? cuesRaw = body['cues'];
  if (binRaw is! num ||
      startRaw is! num ||
      rmsRaw is! List ||
      cuesRaw is! List) {
    return null;
  }
  if (!binRaw.isFinite || !startRaw.isFinite) return null;
  final int binMs = binRaw.round();
  if (binMs != kSubtitleAutoAlignBinMs) return null;
  if (rmsRaw.length > kCaptureAlignMaxBins ||
      cuesRaw.length > kCaptureAlignMaxCues) {
    return null;
  }
  final List<double?> rms = <double?>[
    for (final Object? v in rmsRaw) v is num ? v.toDouble() : null,
  ];
  final List<({int startMs, int endMs})> cues = <({int startMs, int endMs})>[];
  for (final Object? c in cuesRaw) {
    if (c is! Map) return null;
    final Object? s = c['startMs'];
    final Object? e = c['endMs'];
    if (s is! num || e is! num || !s.isFinite || !e.isFinite) return null;
    cues.add((startMs: s.round(), endMs: e.round()));
  }
  final SubtitleAutoAlignResult r = alignCuesToCapturedEnvelope(
    rmsDb: rms,
    startMs: startRaw.round(),
    cues: cues,
    binMs: binMs,
  );
  return <String, dynamic>{
    'status': switch (r.status) {
      SubtitleAutoAlignStatus.aligned => 'aligned',
      SubtitleAutoAlignStatus.lowConfidence => 'lowConfidence',
      SubtitleAutoAlignStatus.noData => 'noData',
    },
    'offsetMs': r.offsetMs,
    'confidence': r.confidence,
  };
}
