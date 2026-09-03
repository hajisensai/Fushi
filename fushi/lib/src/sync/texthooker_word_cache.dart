/// 台词行分词结果缓存（工作台实时台词列表用）。
///
/// 旧实现按行 id 缓存并假设「行文本按 id 不可变」。这个假设在渐进折叠
/// （[TexthookerService.foldProgressiveLines]）下不成立：引擎逐段重绘同一句时，
/// 折叠会**复用最早那条的 id 并把文本换成合并后的整句**。缓存只认 id，于是列表
/// 永远显示第一次入缓存的前缀（真机：本句音轨面板已是「エル・プサイ・コングルゥ」，
/// 列表那条还停在「エル・プ」）。判据改成「id + 文本」：文本变了就重新分词，
/// 同 id 同文本仍然只分一次。
class TexthookerWordCache {
  TexthookerWordCache({
    required List<String> Function(String text) tokenize,
    int maxEntries = 800,
  })  : _tokenize = tokenize,
        _maxEntries = maxEntries;

  final List<String> Function(String text) _tokenize;
  final int _maxEntries;
  final Map<String, _CachedWords> _cache = <String, _CachedWords>{};

  int get length => _cache.length;

  /// [id] 行、当前文本为 [text] 的分词结果。文本与缓存不一致时重算并覆盖。
  List<String> wordsFor(String id, String text) {
    final _CachedWords? cached = _cache[id];
    if (cached != null && cached.text == text) return cached.words;
    final List<String> words = _tokenize(text);
    // 覆盖同 id 旧项时先删再插，保持「最近写入在末尾」的淘汰序。
    _cache.remove(id);
    _cache[id] = _CachedWords(text, words);
    if (_cache.length > _maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    return words;
  }
}

class _CachedWords {
  const _CachedWords(this.text, this.words);

  final String text;
  final List<String> words;
}
