/// 纯 Dart 的 `ChangeNotifier` / `ValueNotifier` 替身。
///
/// 引擎里几个长驻控制器（发现页下载队列、刮削任务控制器、追番状态计数）原来
/// 继承 Flutter 的 `ChangeNotifier`；引擎不能依赖 Flutter，但 app 侧调用方只用
/// `addListener` / `removeListener`（没有 `ListenableBuilder` 用法，已 grep 核实），
/// 所以这里提供同名同语义的最小实现，调用方一行不改。
///
/// 语义对齐 Flutter：
/// - 监听器按注册顺序同步调用；通知期间增删监听器不影响本轮。
/// - 单个监听器抛异常不阻断其余监听器，异常经 [engineLog] 记录后吞掉
///   （Flutter 是交给 `FlutterError.reportError`，同样不向上抛）。
/// - `dispose()` 后再 `notifyListeners()` 是编程错误，与 Flutter 一样 assert。
library;

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:meta/meta.dart';

class EngineChangeNotifier {
  List<void Function()> _listeners = <void Function()>[];
  bool _disposed = false;

  /// 是否还有监听器（与 `ChangeNotifier.hasListeners` 同语义）。
  @protected
  bool get hasListeners => _listeners.isNotEmpty;

  void addListener(void Function() listener) {
    assert(!_disposed, 'addListener called after dispose on $runtimeType');
    _listeners = <void Function()>[..._listeners, listener];
  }

  void removeListener(void Function() listener) {
    final List<void Function()> next = List<void Function()>.of(_listeners);
    next.remove(listener);
    _listeners = next;
  }

  @protected
  void notifyListeners() {
    assert(!_disposed, 'notifyListeners called after dispose on $runtimeType');
    // 快照迭代：通知期间 add/remove 不影响本轮。
    final List<void Function()> snapshot = _listeners;
    for (final void Function() listener in snapshot) {
      try {
        listener();
      } catch (e, stack) {
        engineLog.log('$runtimeType.notifyListeners', e, stack);
      }
    }
  }

  @mustCallSuper
  void dispose() {
    _disposed = true;
    _listeners = const <void Function()>[];
  }
}

/// 只读视图（与 `ValueListenable<T>` 同语义）。
abstract interface class EngineValueListenable<T> {
  T get value;
  void addListener(void Function() listener);
  void removeListener(void Function() listener);
}

class EngineValueNotifier<T> extends EngineChangeNotifier
    implements EngineValueListenable<T> {
  EngineValueNotifier(this._value);

  T _value;

  @override
  T get value => _value;

  set value(T next) {
    if (_value == next) return;
    _value = next;
    notifyListeners();
  }
}
