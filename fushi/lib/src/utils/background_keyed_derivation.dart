import 'dart:async' show scheduleMicrotask, unawaited;
import 'dart:isolate' show Isolate;

/// 两份输入是否「同一份」（同一份就复用已算好的结果，不再派活）。
typedef DerivationInputEquals<I> = bool Function(I a, I b);

/// 按键缓存、在**后台 isolate** 里批量计算的派生值（BUG-5253 余项：库页卡片 build
/// 不在 UI 线程上做解析 / 排序 / jsonDecode）。
///
/// - 每个键记住「算出它的那份输入」，输入不变（[DerivationInputEquals]）就直接读，
///   一个键对一份输入只算一次；
/// - build 里用 [lookup] 只读：没算好的键记进待办，同一帧里攒到的所有键在一个
///   微任务里打包成一次 [Isolate.run]，build 本身不做计算；
/// - 数据加载 / 变更时用 [prefetch] 提前整批派活，卡片滚进视口时多半已就绪；
/// - 结果回来后只写仍在等这份输入的键（期间输入又变了的丢掉，由新一批覆盖），
///   然后调 [onReady] 让调用方重建一次。
///
/// [compute] 必须是顶层函数或静态方法（要发到别的 isolate），输入 / 输出必须能跨
/// isolate 拷贝（纯数据，不含 ImageProvider、闭包、原生句柄）。
class BackgroundKeyedDerivation<K, I, V> {
  BackgroundKeyedDerivation({
    required V Function(I input) compute,
    required DerivationInputEquals<I> inputEquals,
    required void Function() onReady,
  }) : _compute = compute,
       _inputEquals = inputEquals,
       _onReady = onReady;

  final V Function(I input) _compute;
  final DerivationInputEquals<I> _inputEquals;
  final void Function() _onReady;

  final Map<K, ({I input, V value})> _ready = <K, ({I input, V value})>{};
  final Map<K, I> _inFlight = <K, I>{};
  final Map<K, I> _pending = <K, I>{};
  bool _flushScheduled = false;
  bool _disposed = false;

  /// 测试 / 诊断用：已发往后台的批次数。
  int get debugBatchCount => _batchCount;
  int _batchCount = 0;

  /// 读 [key] 的结果：已按 [input] 算好就返回它；没有则排进待办（下一个微任务
  /// 整批发往后台），这一帧返回 [allowStale] 时的旧结果（同键上一份输入算出的）
  /// 或 null。只做哈希查找与输入比较，不做计算。
  V? lookup(K key, I input, {bool allowStale = false}) {
    final ({I input, V value})? hit = _ready[key];
    if (hit != null && _inputEquals(hit.input, input)) return hit.value;
    _request(key, input);
    return allowStale ? hit?.value : null;
  }

  /// 数据加载 / 变更时整批预取：输入没变的键跳过，其余并进下一批后台计算。
  void prefetch(Map<K, I> inputs) {
    inputs.forEach((K key, I input) {
      final ({I input, V value})? hit = _ready[key];
      if (hit != null && _inputEquals(hit.input, input)) return;
      _request(key, input);
    });
  }

  void dispose() {
    _disposed = true;
    _pending.clear();
    _inFlight.clear();
  }

  void _request(K key, I input) {
    if (_disposed) return;
    final I? flying = _inFlight[key];
    if (flying != null && _inputEquals(flying, input)) return;
    final I? queued = _pending[key];
    if (queued != null && _inputEquals(queued, input)) return;
    _pending[key] = input;
    if (_flushScheduled) return;
    _flushScheduled = true;
    scheduleMicrotask(_flush);
  }

  void _flush() {
    _flushScheduled = false;
    if (_disposed || _pending.isEmpty) return;
    final Map<K, I> batch = Map<K, I>.of(_pending);
    _pending.clear();
    _inFlight.addAll(batch);
    _batchCount++;
    unawaited(_run(batch));
  }

  Future<void> _run(Map<K, I> batch) async {
    final Map<K, V> results = await _computeBatch<K, I, V>(batch, _compute);
    if (_disposed) return;
    bool changed = false;
    batch.forEach((K key, I input) {
      final I? flying = _inFlight[key];
      // 期间同键又派了新输入：这份结果已过时，等新一批。
      if (flying == null || !_inputEquals(flying, input)) return;
      _inFlight.remove(key);
      _ready[key] = (input: input, value: results[key] as V);
      changed = true;
    });
    if (changed) _onReady();
  }

  /// 静态：发往后台的闭包只捕获 [batch] 与 [compute]，不带宿主对象。
  static Future<Map<K, V>> _computeBatch<K, I, V>(
    Map<K, I> batch,
    V Function(I input) compute,
  ) => Isolate.run<Map<K, V>>(
    () => <K, V>{
      for (final MapEntry<K, I> entry in batch.entries)
        entry.key: compute(entry.value),
    },
    debugName: 'BackgroundKeyedDerivation',
  );
}
