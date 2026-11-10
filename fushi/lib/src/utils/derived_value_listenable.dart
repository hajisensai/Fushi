/// 从一个粗粒度 [Listenable]（典型是广播所有偏好变化的 PreferencesRepository）
/// 派生出单个值的 [ValueListenable]：源每次通知都重算，只有值真的变了（`==`）才往下
/// 通知。让只关心一项设置的 widget 精确订阅，不随无关偏好写入重建。
///
/// 没有监听者时不挂在源上（首个监听者加入时订阅并取一次值，最后一个离开时退订），
/// 所以可以当长寿对象的 `late final` 字段用，不需要显式 dispose。
library;

import 'package:flutter/foundation.dart';

class DerivedValueListenable<T> extends ChangeNotifier
    implements ValueListenable<T> {
  DerivedValueListenable(this._source, this._compute);

  final Listenable _source;
  final T Function() _compute;

  bool _subscribed = false;
  late T _value;

  @override
  T get value => _subscribed ? _value : _compute();

  @override
  void addListener(VoidCallback listener) {
    if (!_subscribed) {
      _value = _compute();
      _source.addListener(_onSourceChanged);
      _subscribed = true;
    }
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (_subscribed && !hasListeners) _unsubscribe();
  }

  @override
  void dispose() {
    if (_subscribed) _unsubscribe();
    super.dispose();
  }

  void _unsubscribe() {
    _source.removeListener(_onSourceChanged);
    _subscribed = false;
  }

  void _onSourceChanged() {
    final T next = _compute();
    if (next == _value) return;
    _value = next;
    notifyListeners();
  }
}
