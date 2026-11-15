/// TODO-1244：字幕对轴「音频波形能量包络」的进程内缓存（反馈 EUvw-RjUE4 起按段）。
///
/// 波形视图按段懒抽包络（`subtitle_waveform_segments.dart`，每段经 ffmpeg 抽一次）；
/// 本缓存按「音源 key（通常 `音频路径|音轨`）+ 段区间」记住抽到的段，之后再打开对轴
/// 视图、滚回已看过的段直接复用，不再重跑 ffmpeg / 重拉流。
///
/// **失效即换 key**：切视频 / 切音轨时音源 key 变化 → 整槽清空 → 重抽（绝不显示旧音频
/// 的波形）。只留最近一个音源的段，内存有界（2h 电影全抽完 @20ms 约 36 万个 double）。
///
/// **只缓存非空结果**：空包络 = 无音轨 / 超时 / ffmpeg 不可用等降级，缓存空会永久钉死
/// 降级态；故空结果不写缓存，下次同段仍会重试。
class WaveformEnvelopeCache {
  String? _sourceKey;
  final Map<(int, int), List<double>> _segments = <(int, int), List<double>>{};

  /// 命中同音源 [sourceKey] 同区间 `[startMs, endMs)` 的已缓存非空包络 → 直接返回；
  /// 否则调 [load] 抽取，非空则缓存后返回，空则原样返回（不缓存，允许下次重试）。
  /// [sourceKey] 与当前槽不同时先清空旧音源的全部段。
  Future<List<double>> resolve(
    String sourceKey,
    int startMs,
    int endMs,
    Future<List<double>> Function() load,
  ) async {
    if (_sourceKey != sourceKey) {
      _sourceKey = sourceKey;
      _segments.clear();
    }
    final List<double>? cached = _segments[(startMs, endMs)];
    if (cached != null) return cached;
    final List<double> envelope = await load();
    // 抽取期间换了音源（切音轨）：结果属于旧音源，不写进新槽。
    if (envelope.isNotEmpty && _sourceKey == sourceKey) {
      _segments[(startMs, endMs)] = envelope;
    }
    return envelope;
  }

  /// 当前是否已缓存指定音源、指定区间的非空包络（诊断 / 测试用）。
  bool hasCached(String sourceKey, int startMs, int endMs) =>
      _sourceKey == sourceKey && _segments.containsKey((startMs, endMs));

  /// 丢弃缓存（如媒体释放时）。
  void clear() {
    _sourceKey = null;
    _segments.clear();
  }
}
