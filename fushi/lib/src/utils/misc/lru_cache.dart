import 'dart:collection';

/// 估算缓存值常驻内存占用（字节）的函数；只用于封顶决策，宁可高估。
typedef LruSizeOf<V> = int Function(V value);

/// 简单 LRU 缓存。
///
/// 始终按条数（[_maxSize]）封顶；可选再按估算字节数封顶：构造时成对传入
/// [maxBytes] 与 [sizeOf]，put 时按 [sizeOf] 估算并累计，超过 [maxBytes]
/// 从最久未用端逐条淘汰（条数上限保留作兜底）。不传则行为与旧版逐字节一致。
class LruCache<K, V extends Object> {
  LruCache(this._maxSize, {int? maxBytes, LruSizeOf<V>? sizeOf})
      : assert(
          (maxBytes == null) == (sizeOf == null),
          'maxBytes and sizeOf must be provided together',
        ),
        _maxBytes = maxBytes,
        _sizeOf = sizeOf,
        _map = LinkedHashMap<K, V>(),
        _entryBytes = sizeOf == null ? null : HashMap<K, int>();

  final int _maxSize;
  final LruSizeOf<V>? _sizeOf;
  final LinkedHashMap<K, V> _map;

  /// 每个 key 在插入时的估算字节数（字节模式才分配）。淘汰/覆盖时按记录值
  /// 回减，避免对可能已被就地变更的 value 重算 [_sizeOf] 导致账目漂移。
  final HashMap<K, int>? _entryBytes;

  int? _maxBytes;
  int _totalBytes = 0;

  int get length => _map.length;

  /// 当前累计的估算字节数；纯条数模式恒为 0。
  int get totalBytes => _totalBytes;

  int? get maxBytes => _maxBytes;

  /// 运行时调整字节上限（如低内存模式切换），立即按新上限淘汰；`null`
  /// 关闭字节封顶。仅字节模式（构造时传过 sizeOf）可设非空值。
  set maxBytes(int? value) {
    assert(
      value == null || _sizeOf != null,
      'cannot set maxBytes on a count-only LruCache (no sizeOf)',
    );
    _maxBytes = value;
    _evictOverByteBudget();
  }

  V? operator [](K key) {
    final V? value = _map.remove(key);
    if (value != null) {
      _map[key] = value;
    }
    return value;
  }

  void operator []=(K key, V value) {
    _removeTracked(key);
    _map[key] = value;
    final HashMap<K, int>? entryBytes = _entryBytes;
    if (entryBytes != null) {
      final int bytes = _sizeOf!(value);
      entryBytes[key] = bytes;
      _totalBytes += bytes;
    }
    while (_map.length > _maxSize) {
      _removeTracked(_map.keys.first);
    }
    _evictOverByteBudget();
  }

  bool containsKey(K key) => _map.containsKey(key);

  V putIfAbsent(K key, V Function() ifAbsent) {
    final V? existing = this[key];
    if (existing != null) return existing;
    final V value = ifAbsent();
    this[key] = value;
    return value;
  }

  void clear() {
    _map.clear();
    _entryBytes?.clear();
    _totalBytes = 0;
  }

  void _removeTracked(K key) {
    final V? removed = _map.remove(key);
    if (removed != null) {
      final int? bytes = _entryBytes?.remove(key);
      if (bytes != null) _totalBytes -= bytes;
    }
  }

  /// 超出字节预算时从最久未用端淘汰；单条超预算的条目也会被淘汰（缓存宁可
  /// 不命中也不能突破内存上限）。
  void _evictOverByteBudget() {
    final int? cap = _maxBytes;
    if (cap == null) return;
    while (_map.isNotEmpty && _totalBytes > cap) {
      _removeTracked(_map.keys.first);
    }
  }
}
