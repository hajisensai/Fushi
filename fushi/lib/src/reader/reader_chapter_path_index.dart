/// 阅读器「章节文档磁盘路径 → 书脊序号」反查表（路线图 m1 / novel-17e）。
///
/// 拦截器每次章节 HTML 缓存未命中（开书、换章、预取邻章）都要把请求路径反查成章号。
/// 旧实现逐章重算路径（每章两次 `canonicalize`）再比对，开销随章数线性增长：AOT 桌面
/// 实测 1000 章书查末章 7～10 ms、3000 章 19～23 ms（P95 26～31 ms），都在 UI isolate
/// 上，上千章的网文在移动端单次就超一帧。这里按书建一次表，之后 O(1) 查；书的章节表
/// 换了（网文追加章节会换一份新列表）或解包目录变了才重建。纯 Dart，可单测。
library;

class ReaderChapterPathIndex {
  ReaderChapterPathIndex._(this._source, this._count, this._dir, this._byPath);

  /// 逐章取路径（[pathOf] 返回 null 的章不进表）建表。同一路径出现多次时取最小章号，
  /// 与旧的「从第 0 章起线性查找、命中即返回」结果一致。
  factory ReaderChapterPathIndex.build({
    required Object source,
    required int count,
    required String dir,
    required String? Function(int index) pathOf,
  }) {
    final Map<String, int> byPath = <String, int>{};
    for (int i = 0; i < count; i++) {
      final String? path = pathOf(i);
      if (path != null) byPath.putIfAbsent(path, () => i);
    }
    return ReaderChapterPathIndex._(source, count, dir, byPath);
  }

  final Object _source;
  final int _count;
  final String _dir;
  final Map<String, int> _byPath;

  /// 这张表是否仍描述 [source]（章节列表本身，按身份比）+ [count] 章 + 解包目录 [dir]。
  bool describes({
    required Object source,
    required int count,
    required String dir,
  }) => identical(source, _source) && count == _count && dir == _dir;

  /// [path] 对应的章号；不是章节文档时 -1。
  int indexOf(String path) => _byPath[path] ?? -1;
}
