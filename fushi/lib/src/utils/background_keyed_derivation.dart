import 'dart:async' show scheduleMicrotask, unawaited;
import 'dart:isolate' show Isolate;

import 'package:flutter/foundation.dart'
    show ErrorDescription, FlutterError, FlutterErrorDetails;

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
///   然后调 [onReady] 让调用方重建一次；
/// - 某个键的计算抛错（或整批发不出去）时，这个键按这份输入记为失败并经
///   [FlutterError.reportError] 报出，不再对同一份输入反复派活；输入变了才重算。
///   不会卡在「在算」里永远不出结果。
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

  /// 按这份输入算失败过的键：同一份输入不再派活（避免每帧重派一个必抛的批）。
  final Map<K, I> _failed = <K, I>{};
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
    _failed.clear();
  }

  void _request(K key, I input) {
    if (_disposed) return;
    final I? flying = _inFlight[key];
    if (flying != null && _inputEquals(flying, input)) return;
    final I? queued = _pending[key];
    if (queued != null && _inputEquals(queued, input)) return;
    final I? failed = _failed[key];
    if (failed != null && _inputEquals(failed, input)) return;
    _failed.remove(key);
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
    _BatchResult<K, V> result;
    bool reported = false;
    try {
      result = await _computeBatch<K, I, V>(batch, _compute);
    } catch (error, stack) {
      // 整批没算成（发不出去 / 结果拷不回来）：每个键都按这份输入记失败。
      result = (
        values: <K, V>{},
        errors: <K, String>{for (final K key in batch.keys) key: '$error'},
      );
      _report(error, stack, batch.length);
      reported = true;
    }
    if (!reported && result.errors.isNotEmpty) {
      final MapEntry<K, String> first = result.errors.entries.first;
      _report(
        'compute failed for ${result.errors.length} key(s); '
        'first ${first.key}: ${first.value}',
        null,
        batch.length,
      );
    }
    if (_disposed) return;
    bool changed = false;
    batch.forEach((K key, I input) {
      final I? flying = _inFlight[key];
      // 期间同键又派了新输入：这份结果已过时，等新一批。
      if (flying == null || !_inputEquals(flying, input)) return;
      _inFlight.remove(key);
      if (result.errors.containsKey(key)) {
        _failed[key] = input;
        return;
      }
      _ready[key] = (input: input, value: result.values[key] as V);
      changed = true;
    });
    if (changed) _onReady();
  }

  void _report(Object error, StackTrace? stack, int batchSize) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'fushi background derivation',
        context: ErrorDescription('computing a batch of $batchSize key(s)'),
      ),
    );
  }

  /// 静态：发往后台的闭包只捕获 [batch] 与 [compute]，不带宿主对象。单个键抛错
  /// 只记进 errors（带堆栈文本），不连累同批其它键。
  static Future<_BatchResult<K, V>> _computeBatch<K, I, V>(
    Map<K, I> batch,
    V Function(I input) compute,
  ) => Isolate.run<_BatchResult<K, V>>(() {
    final Map<K, V> values = <K, V>{};
    final Map<K, String> errors = <K, String>{};
    for (final MapEntry<K, I> entry in batch.entries) {
      try {
        values[entry.key] = compute(entry.value);
      } catch (error, stack) {
        errors[entry.key] = '$error\n$stack';
      }
    }
    return (values: values, errors: errors);
  }, debugName: 'BackgroundKeyedDerivation');
}

typedef _BatchResult<K, V> = ({Map<K, V> values, Map<K, String> errors});
