/// galgame Hook 会话的「游戏活动」纯累计器。
///
/// 把 hook 收到的每一行文本（到达时刻 + 字符数）累计成一段「活跃时长 + 字符数」，
/// 供 `GalHookSessionController` 落 `activity_events`。
///
/// **只有字符数会落库**（契约 §3.1）：游玩时长的真相源是 `GalgamePlayTracker`
/// （前台窗口 + 候选进程组计时），hook 文本再写一份时长就是同一次游玩双计。这里
/// 保留的活跃时长只当 [shouldFlush] 的节奏信号——「读了一分钟就先落一条防崩溃
/// 丢账」，不再进 DB。
///
/// 关键约束：相邻两行文本间隔超过 [idleGapMs] 的部分视为挂机/离席，不计入活跃
/// 时长，避免挂机把 flush 节奏拖成假活跃。累计逻辑做成纯类（不依赖时钟/DB），
/// 便于单测覆盖间隔封顶、flush 阈值与字符累加。
class GalHookActivityAccumulator {
  GalHookActivityAccumulator({
    this.idleGapMs = 30000,
    this.flushDurationMs = 60000,
    this.flushChars = 500,
  });

  /// 相邻两行文本间隔（毫秒）超过此值时，该段间隔不计入活跃时长（防挂机虚高）。
  final int idleGapMs;

  /// 中途 flush 阈值：累计活跃时长达到此毫秒数即建议落库一条。
  final int flushDurationMs;

  /// 中途 flush 阈值：累计字符数达到此值即建议落库一条。
  final int flushChars;

  int _charsDelta = 0;
  int _durationMs = 0;
  int? _lastLineMs;

  /// 当前未落库的字符累计。
  int get pendingChars => _charsDelta;

  /// 当前未落库的活跃时长（毫秒）累计。
  int get pendingDurationMs => _durationMs;

  /// 是否有未落库的累计（字符或时长任一 > 0）。
  bool get hasPending => _charsDelta > 0 || _durationMs > 0;

  /// 是否已达到中途 flush 阈值：累计字符 > 0 且（活跃满 [flushDurationMs] 或字符满
  /// [flushChars]）。防崩溃丢账用——命中即由调用方 flush 一条并 [drain]。
  bool get shouldFlush =>
      _charsDelta > 0 &&
      (_durationMs >= flushDurationMs || _charsDelta >= flushChars);

  /// 记一行 hook 文本到达。[chars] = 该行字符数（<=0 忽略字符累加），[nowMs] =
  /// 到达时刻（epoch 毫秒）。与上一行的间隔在 (0, idleGapMs] 内才计入活跃时长。
  void recordLine(int chars, int nowMs) {
    if (chars > 0) _charsDelta += chars;
    final int? last = _lastLineMs;
    if (last != null) {
      final int gap = nowMs - last;
      if (gap > 0 && gap <= idleGapMs) _durationMs += gap;
    }
    _lastLineMs = nowMs;
  }

  /// 取出当前累计并清零（落库后调用）。**保留** [_lastLineMs]，使 flush 之后下一段
  /// 继续按与上一行的真实间隔计时（跨 flush 的连续阅读时长不被人为切断）。
  (int charsDelta, int durationMs) drain() {
    final (int, int) result = (_charsDelta, _durationMs);
    _charsDelta = 0;
    _durationMs = 0;
    return result;
  }

  /// 会话结束/切换游戏时整体复位（含 [_lastLineMs]），下一段从零重新计时。
  void reset() {
    _charsDelta = 0;
    _durationMs = 0;
    _lastLineMs = null;
  }
}
