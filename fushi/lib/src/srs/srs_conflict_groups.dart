/// 冲突中心「同类都按这个选」的组计数（BUG-4950）。
///
/// 每条冲突卡片都要显示「同类还有几条」。过去页面在 build 里给每张卡片各扫一遍整张
/// 列表（O(n²)）：同步扣住几千条删除时一次重建要在主线程上跑几秒，iOS 退出时主线程
/// 交不回 UIKit，5 秒后被看门狗（0x8BADF00D）杀掉。改为数据载入时一趟算好、build
/// 只查表。
///
/// [groupOf] 对每个元素恰好调用一次。
Map<String, int> srsSameGroupCounts<T>(
  Iterable<T> items,
  String Function(T item) groupOf,
) {
  final Map<String, int> counts = <String, int>{};
  for (final T item in items) {
    counts.update(groupOf(item), (int n) => n + 1, ifAbsent: () => 1);
  }
  return counts;
}
