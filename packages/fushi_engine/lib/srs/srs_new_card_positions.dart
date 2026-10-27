/// 「按词频重排新卡」在 Fushi 复习下的位置分配：**只移动必须移动的卡**（纯函数）。
///
/// Fushi 复习里新卡位置（`newPos`，[SrsCardCacheRow.newPosition]）只是出卡排序键：
/// [SrsDbStore.compareNewCardOrder] 按它升序比较，值本身没有别的语义（AnkiConnect 兼容层
/// 原样报成 `due`，apkg 导入原样收 Anki 的 `due`，两边都不要求连续）。而每改一张卡的位置
/// 就是一条要进发件箱、要同步到每台设备的修改记录。
///
/// 所以不能像 Anki 的「重新定位」那样每次都连续编号 1..N：往词频中间插一张新卡，
/// 它后面的每张卡都 +1，挖一个词 = O(N) 条修改记录（2000 张新卡的牌组实测 998 条）。
/// 这里改成：保留现有位置里最多的一批「已经在对的相对次序上、且彼此之间留得下中间
/// 那些卡」的卡不动（锚点），其余的卡在锚点之间均匀落位、末尾的按 [kSrsNewPositionGap]
/// 留间隙追加。插一张新卡通常只写它自己一条。
library;

/// 末尾追加 / 首次排位时相邻两张卡之间的间隙：以后插进来的卡能直接落在间隙里，
/// 同一处连续插约 log2(间隙) 次之后才需要挪邻居（挪也只挪那一小段）。
/// 取 1024：十万张新卡也只到 1e8，远在 32 位整数以内（AnkiConnect 兼容层把它报成 `due`）。
const int kSrsNewPositionGap = 1024;

/// 整组重铺的触发条件：最少移动的结果里，有一段 ≥ [kSrsRelayoutRunLength] 张要移动的卡只能
/// 挤进平均间距 < [kSrsRelayoutMinSpacing] 的空间（旧版连续编号 1..N 的牌组、或被反复插到
/// 同一处的区域）。这时只挪「放不下的那几张」等于把它们照样挤成一团，下一次插进来又要挪
/// 一大段——每次都是 O(N)。不如这一次整组按 [kSrsNewPositionGap] 重铺（一次性 O(N)），之后
/// 插入又回到 O(1)。
const int kSrsRelayoutRunLength = 32;

/// 见 [kSrsRelayoutRunLength]。
const int kSrsRelayoutMinSpacing = 4;

/// 按目标出卡顺序给每张卡分配位置，使写入（与 [current] 不同的项）尽量少。
///
/// [current]：目标顺序下每张卡此刻**落了库**的位置；null = 从没排过（必须写）。
/// 返回与 [current] 同序、严格递增、全部 ≥ 1 的位置；`result[i] == current[i]` 的卡
/// 不必写。顺序没变时一张都不写。
///
/// 1. 锚点（不动的卡）：卡 i 与卡 j（i < j）都不动，要求它们之间的 j - i - 1 张卡有整数
///    位置可落，即 `current[j] - current[i] >= j - i`，等价于 `current[j] - j >=
///    current[i] - i`；第一个锚点前面的卡要落在 [1, current[a]) 里，即 `current[a] - a
///    >= 1`。于是最多不动的卡 = 键 `current[i] - i`（只取 ≥ 1 的）的最长不降子序列，
///    O(n log n)。位置重复 / 次序错乱（两台设备各自重排后的合并结果）在键上自然被排除。
/// 2. 落位：两锚点之间的卡在开区间里均匀落位；最后一个锚点之后的按 [gap] 追加。
/// 3. 整组重铺：结果太挤（见 [kSrsRelayoutRunLength]），或者反正要动一半以上的卡时，改成
///    全部按 [gap] 重铺——代价至多翻倍，换来之后的插入都只写一张。
List<int> srsMinimalMovePositions(
  List<int?> current, {
  int gap = kSrsNewPositionGap,
}) {
  if (gap < 1) throw ArgumentError.value(gap, 'gap', 'must be >= 1');
  final int n = current.length;
  final List<int> relayout = <int>[for (int i = 1; i <= n; i++) i * gap];
  final List<int> anchors = _longestAnchorChain(current);
  final List<int> out = List<int>.filled(n, 0);
  int lastIndex = -1;
  int lastPos = 0;
  for (final int a in anchors) {
    final int right = current[a]!;
    final int m = a - lastIndex - 1;
    final int room = right - lastPos;
    if (m >= kSrsRelayoutRunLength && room < kSrsRelayoutMinSpacing * (m + 1)) {
      return relayout;
    }
    // 键不降保证 room >= m + 1：m 张卡在 (lastPos, right) 里均匀、严格递增地落位。
    for (int j = 0; j < m; j++) {
      out[lastIndex + 1 + j] = lastPos + ((j + 1) * room) ~/ (m + 1);
    }
    out[a] = right;
    lastIndex = a;
    lastPos = right;
  }
  for (int i = lastIndex + 1; i < n; i++) {
    lastPos += gap;
    out[i] = lastPos;
  }
  // 反正要动一半以上：整组重铺至多多写一倍，换一个干净的间隙布局。
  if (2 * (n - anchors.length) > n) return relayout;
  return out;
}

/// 键 `current[i] - i`（current 非空且键 ≥ 1）的最长不降子序列，下标升序。
/// 耐心排序（upper bound）：tails[l] = 长度 l+1 的子序列里末键最小的末尾下标。
List<int> _longestAnchorChain(List<int?> current) {
  final int n = current.length;
  final List<int> tails = <int>[];
  final List<int> prev = List<int>.filled(n, -1);
  int keyOf(int i) => current[i]! - i;
  for (int i = 0; i < n; i++) {
    final int? p = current[i];
    if (p == null) continue;
    final int key = p - i;
    if (key < 1) continue;
    int lo = 0;
    int hi = tails.length;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (keyOf(tails[mid]) <= key) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    prev[i] = lo > 0 ? tails[lo - 1] : -1;
    if (lo == tails.length) {
      tails.add(i);
    } else {
      tails[lo] = i;
    }
  }
  final List<int> chain = <int>[];
  for (int i = tails.isEmpty ? -1 : tails.last; i >= 0; i = prev[i]) {
    chain.add(i);
  }
  return chain.reversed.toList();
}
