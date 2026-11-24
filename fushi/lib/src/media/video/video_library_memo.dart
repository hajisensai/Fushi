import 'package:fushi/src/media/video/video_home_layout.dart';
import 'package:fushi_core/fushi_core.dart';

/// 视频库页派生数据的记忆化（2026-11-22 UI 线程卡顿根治）。
///
/// 库页的筛选 / 搜索 / 折叠 / 继续观看 / 最近添加都是「输入 → 结果」的纯派生，
/// 此前每次 build 对全库重算一遍；页面又会因封面回填、刮削进度、各种 watcher
/// 频繁重建，每次都是 25–60 ms 的卡帧。改成「输入没变就复用上次的结果」：
/// [keys] 逐项比较，集合 / 行列表这类对象按**身份**（Dart 的 `List` / `Map` /
/// `Set` 默认 `==` 就是身份），枚举 / 字符串 / 带值语义的筛选档位按值。
///
/// 调用方的约定：放进 [keys] 的集合在替换时必须换新对象（页面状态里的映射都是
/// 整张替换，从不原地改），否则改了内容也会命中旧结果。
class DerivationMemo<T> {
  List<Object?>? _keys;
  T? _value;

  /// 输入与上次相同则返回上次的结果，否则调用 [compute] 并记住。
  T of(List<Object?> keys, T Function() compute) {
    final List<Object?>? last = _keys;
    if (last != null && derivationKeysEqual(last, keys)) return _value as T;
    final T value = compute();
    _keys = List<Object?>.unmodifiable(keys);
    _value = value;
    return value;
  }

  /// 丢掉缓存，下次 [of] 必然重算。
  void clear() {
    _keys = null;
    _value = null;
  }
}

/// [DerivationMemo] 的键比较：等长且逐项 `identical || ==`。
bool derivationKeysEqual(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    final Object? x = a[i];
    final Object? y = b[i];
    if (identical(x, y)) continue;
    if (x != y) return false;
  }
  return true;
}

/// 复合键表（`'<kind>|<entryKey>' → V`，见 [MediaKind.compositeKey]）里属于
/// [kind] 的条目，改按裸 entryKey 键控。
///
/// 结果满足：对任意 `uid`，`result[uid] == byCompositeKey[kind.compositeKey(uid)]`。
/// 库页每张卡、每次筛选都要按 uid 查主合集 / 组内序，原写法每查一次就拼一次
/// 复合键字符串；这张表随源表整张替换时重建一次，查询只剩一次哈希。
Map<String, V> entriesOfKind<V>(Map<String, V> byCompositeKey, MediaKind kind) {
  final String prefix = kind.compositeKey('');
  final Map<String, V> out = <String, V>{};
  byCompositeKey.forEach((String key, V value) {
    if (key.startsWith(prefix)) out[key.substring(prefix.length)] = value;
  });
  return out;
}

/// [isVideoRecentlyAdded] 对 [importedAts] 里任一条目的判定**下一次翻转**的
/// 时刻（epoch 微秒）；此后再无翻转时返回 null。
///
/// 「最近添加」行按此缓存：在该时刻之前，对同一批输入重算的结果与缓存逐项相同
/// （窗口判定只依赖 now）。未来入库（`importedAt > now`）的条目在入库时刻进窗；
/// 窗内条目在 `importedAt + 窗口` 之后的第一微秒出窗；已出窗的不会再进。
int? videoRecentlyAddedNextChangeMicros({
  required Iterable<int?> importedAts,
  required DateTime now,
}) {
  final int nowUs = now.microsecondsSinceEpoch;
  final int windowUs = kVideoRecentlyAddedWindow.inMicroseconds;
  int? next;
  for (final int? importedAt in importedAts) {
    if (importedAt == null || importedAt <= 0) continue;
    final int atUs = importedAt * 1000;
    final int? flip;
    if (atUs > nowUs) {
      flip = atUs;
    } else if (nowUs - atUs <= windowUs) {
      flip = atUs + windowUs + 1;
    } else {
      flip = null;
    }
    if (flip != null && (next == null || flip < next)) next = flip;
  }
  return next;
}
