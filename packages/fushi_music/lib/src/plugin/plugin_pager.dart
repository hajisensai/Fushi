/// 宿主侧的插件分页状态（插件按页号翻页：`page` 0 起，`hasMore` 为 true 才有下一页）。
///
/// 规则（HBK-AUDIT-026）：
/// - **续页只认插件的 `hasMore`**。一页解析后没有新条目（插件自己过滤成空页、宿主丢掉了
///   解析不了的条目、或整页都是已经显示过的条目）不等于到头，后面的页仍可能有结果。
/// - **无进展保护**：没有新条目的一页之后 [stalled] 为 true，调用方停止「滚到底 / 首屏没满」
///   这类自动续载，改成让用户点「加载更多」（[resume] 后再取），插件一直回空页也不会无限请求。
/// - **同一页重复则停**：非空页的条目序列与本列表之前某页完全相同（插件忽略了页号，
///   再翻只会得到同样的内容），视为到头，[hasMore] 置 false。
/// - 条目按 [keyOf] 去重，跨页重复的条目只追加一次。
final class MusicPluginPager<T> {
  MusicPluginPager(this.keyOf);

  /// 条目身份（同一插件、同一列表内唯一）。
  final String Function(T item) keyOf;

  int _nextPage = 0;
  bool _hasMore = true;
  bool _stalled = false;
  final Set<String> _seen = <String>{};
  final Set<String> _pageSignatures = <String>{};

  /// 下一次要请求的页号（0 起）。
  int get nextPage => _nextPage;

  /// 是否已收过至少一页。
  bool get started => _nextPage > 0;

  /// 插件说还有下一页、且没有被「同一页重复」判停。
  bool get hasMore => _hasMore;

  /// 上一页没有带来新条目：自动续载暂停，等用户显式继续（[resume]）。
  bool get stalled => _stalled;

  /// 可以不经用户操作自动取下一页。
  bool get canAutoLoad => _hasMore && !_stalled;

  /// 用户显式要求继续加载（「加载更多」）：解除 [stalled]，由调用方接着请求 [nextPage]。
  void resume() => _stalled = false;

  /// 收下第 [nextPage] 页（插件原始条目 [items] 已经过宿主解析，及插件的 [hasMore]），
  /// 返回要追加到列表末尾的新条目。
  List<T> accept(List<T> items, {required bool hasMore}) {
    _nextPage++;
    final List<String> keys = <String>[for (final T x in items) keyOf(x)];
    if (keys.isNotEmpty && !_pageSignatures.add(keys.join('\u0000'))) {
      _hasMore = false;
      _stalled = false;
      return <T>[];
    }
    final List<T> fresh = <T>[
      for (int i = 0; i < items.length; i++)
        if (_seen.add(keys[i])) items[i],
    ];
    _hasMore = hasMore;
    _stalled = hasMore && fresh.isEmpty;
    return fresh;
  }
}
