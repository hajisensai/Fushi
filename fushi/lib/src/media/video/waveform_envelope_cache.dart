/// TODO-1244：字幕对轴「音频波形能量包络」的进程内缓存。
///
/// 抽一次逐帧能量包络（`extractAudioEnergyEnvelope`，经 ffmpeg，对 2h REMUX 要数十秒）
/// 后按 [key]（通常 `videoPath|audioStreamIndex`）记住结果；之后同 key 直接复用，不再
/// 重跑 ffmpeg——解决「每次打开对轴面板都重新生成波形」。
///
/// **失效即换 key**：切视频 / 切音轨时 key 变化 → miss → 重抽（绝不显示旧音频的波形）。
/// 单槽位（只留最近一次），换 key 覆盖旧值，内存占用有界。
///
/// **只缓存非空结果**：空包络 = 移动端拿不到逐帧行 / 超时 / ffmpeg 不可用等降级，缓存空
/// 会永久钉死降级态；故空结果不写缓存，下次同 key 仍会重试。
class WaveformEnvelopeCache {
  String? _key;
  List<double>? _envelope;

  /// 命中同 [key] 的已缓存非空包络 → 直接返回；否则调 [load] 抽取，非空则缓存后返回，
  /// 空则原样返回（不缓存，允许下次重试）。
  Future<List<double>> resolve(
    String key,
    Future<List<double>> Function() load,
  ) async {
    if (_key == key) {
      final List<double>? cached = _envelope;
      if (cached != null) return cached;
    }
    final List<double> envelope = await load();
    if (envelope.isNotEmpty) {
      _key = key;
      _envelope = envelope;
    }
    return envelope;
  }

  /// 当前是否已缓存指定 [key] 的非空包络（诊断 / 测试用）。
  bool hasCached(String key) => _key == key && _envelope != null;

  /// 丢弃缓存（如媒体释放时）。
  void clear() {
    _key = null;
    _envelope = null;
  }
}
