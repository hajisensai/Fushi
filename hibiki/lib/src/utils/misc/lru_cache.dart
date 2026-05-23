import 'dart:collection';

class LruCache<K, V extends Object> {
  LruCache(this._maxSize) : _map = LinkedHashMap<K, V>();

  final int _maxSize;
  final LinkedHashMap<K, V> _map;

  int get length => _map.length;

  V? operator [](K key) {
    final V? value = _map.remove(key);
    if (value != null) {
      _map[key] = value;
    }
    return value;
  }

  void operator []=(K key, V value) {
    _map.remove(key);
    _map[key] = value;
    while (_map.length > _maxSize) {
      _map.remove(_map.keys.first);
    }
  }

  bool containsKey(K key) => _map.containsKey(key);

  V putIfAbsent(K key, V Function() ifAbsent) {
    final V? existing = this[key];
    if (existing != null) return existing;
    final V value = ifAbsent();
    this[key] = value;
    return value;
  }

  void clear() => _map.clear();
}
