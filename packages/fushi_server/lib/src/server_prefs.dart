/// 服务端偏好存储：直接落 `preferences` 表（与 app 的 `PreferencesRepository`
/// 同一张表、同一编码 `PrefCodec`），实现引擎的 [PrefStore]。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/pref_store.dart';

class ServerPrefs implements PrefStore {
  ServerPrefs(this._db);

  final FushiDatabase _db;
  final Map<String, Object?> _cache = <String, Object?>{};

  Future<void> warmUp() async {
    for (final PreferenceRow row in await _db.getAllPrefRows()) {
      _cache[row.key] = PrefCodec.decodeUntyped(row.value);
    }
  }

  @override
  dynamic getPref(String key, {dynamic defaultValue}) {
    if (!_cache.containsKey(key)) return defaultValue;
    return _cache[key] ?? defaultValue;
  }

  @override
  Future<void> setPref(String key, dynamic value) async {
    _cache[key] = value;
    await _db.setPref(key, PrefCodec.encode(value));
  }

  /// 读原始字符串（不经 PrefCodec；给 token / id 这类裸字符串键）。
  Future<String?> getRaw(String key) => _db.getPref(key);

  Future<void> setRaw(String key, String value) => _db.setPref(key, value);
}
