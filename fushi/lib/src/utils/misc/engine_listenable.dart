/// 引擎通知器 → Flutter `Listenable` 适配。
///
/// `fushi_engine` 里的长驻控制器（发现页下载队列、追番状态计数）继承的是纯 Dart 的
/// `EngineChangeNotifier`，`addListener` / `removeListener` 与 Flutter 同名同义，
/// 但类型上不是 `Listenable`，喂不进 `ListenableBuilder` / `ValueListenableBuilder`。
/// 这两个薄壳只做类型桥接，不缓存、不持有额外状态；每次 build 新建一个也没关系
/// （`ListenableBuilder` 按 `==` 判断是否换监听，这里按被包对象相等）。
library;

import 'package:flutter/foundation.dart';
import 'package:fushi_engine/foundation/engine_notifier.dart';

class EngineListenable implements Listenable {
  const EngineListenable(this.notifier);

  final EngineChangeNotifier notifier;

  @override
  void addListener(VoidCallback listener) => notifier.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      notifier.removeListener(listener);

  @override
  bool operator ==(Object other) =>
      other is EngineListenable && other.notifier == notifier;

  @override
  int get hashCode => notifier.hashCode;
}

class EngineValueListenableAdapter<T> implements ValueListenable<T> {
  const EngineValueListenableAdapter(this.source);

  final EngineValueListenable<T> source;

  @override
  T get value => source.value;

  @override
  void addListener(VoidCallback listener) => source.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      source.removeListener(listener);

  @override
  bool operator ==(Object other) =>
      other is EngineValueListenableAdapter<T> && other.source == source;

  @override
  int get hashCode => source.hashCode;
}
