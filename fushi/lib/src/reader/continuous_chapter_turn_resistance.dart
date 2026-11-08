/// 连续（滚动）模式「拉过章首 / 章末切章」的阻尼档（反馈 R7k887yaJI：切章阻尼太强、
/// 希望能自己调）。
///
/// 跨章的唯一判据是：正文已贴在章首 / 章末之后，手指还沿同一方向再拉 [pullPx]（CSS px）。
/// 三档的差别只在两件事上（JS 侧连续 shell 的触摸控制器按 `C.continuousTurnPullPx` /
/// `C.continuousTurnPinMidGesture` 读，纯函数影子见
/// `ReaderPaginationScripts.continuousBoundaryCrossDir`）：
///
/// - [pinMidGesture] = false：只认「手势起点就贴在边界」——滚到章末那一下不跨章，要松手
///   再滑一次（TODO-656 的既有行为，[standard] 档逐字保持）。
/// - [pinMidGesture] = true：同一手势里正文滚到边界后手指继续推 [pullPx] 也算，不必松手
///   重来（[low] 档）。贴边界的那一刻起才开始计拉动距离，所以惯性 / 回弹的瞬态不会替用户
///   跨章——松手后惯性滚到边界不算（手指已离屏）。
///
/// 存字符串 [key]（`continuous_chapter_turn_resistance`），未知值回落 [standard]。
enum ContinuousChapterTurnResistance {
  low('low', pullPx: 20, pinMidGesture: true),
  standard('standard', pullPx: 20, pinMidGesture: false),
  high('high', pullPx: 96, pinMidGesture: false);

  const ContinuousChapterTurnResistance(
    this.key, {
    required this.pullPx,
    required this.pinMidGesture,
  });

  /// 持久化值。
  final String key;

  /// 贴边界之后还要沿同方向拉动的手指距离（CSS px）。也是手势判为「主轴滑动」的最短
  /// 主轴位移。
  final int pullPx;

  /// 是否允许同一手势中途贴到边界后继续拉动即跨章。
  final bool pinMidGesture;

  static ContinuousChapterTurnResistance fromKey(String? key) {
    for (final ContinuousChapterTurnResistance value
        in ContinuousChapterTurnResistance.values) {
      if (value.key == key) return value;
    }
    return ContinuousChapterTurnResistance.standard;
  }
}
