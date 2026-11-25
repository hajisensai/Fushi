import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/utils/derived_value_listenable.dart';

class _Source extends ChangeNotifier {
  int a = 0;
  int b = 0;

  void bump() => notifyListeners();
}

void main() {
  test('notifies only when the derived value changes', () {
    final _Source src = _Source();
    addTearDown(src.dispose);
    final DerivedValueListenable<int> d = DerivedValueListenable<int>(
      src,
      () => src.a,
    );
    addTearDown(d.dispose);
    int calls = 0;
    void listener() => calls++;
    d.addListener(listener);

    src
      ..b = 5
      ..bump();
    expect(calls, 0, reason: '无关字段变化不应往下通知');

    src
      ..a = 1
      ..bump();
    expect(calls, 1);
    expect(d.value, 1);

    d.removeListener(listener);
  });

  test('unsubscribes from the source when the last listener leaves', () {
    final _Source src = _Source();
    addTearDown(src.dispose);
    final DerivedValueListenable<int> d = DerivedValueListenable<int>(
      src,
      () => src.a,
    );
    addTearDown(d.dispose);
    void listener() {}
    d.addListener(listener);
    // ignore: invalid_use_of_protected_member
    expect(src.hasListeners, isTrue);
    d.removeListener(listener);
    // ignore: invalid_use_of_protected_member
    expect(src.hasListeners, isFalse);

    // 无监听者时 value 仍读最新值。
    src.a = 7;
    expect(d.value, 7);
  });

  test('re-subscribing picks up changes made while unsubscribed', () {
    final _Source src = _Source();
    addTearDown(src.dispose);
    final DerivedValueListenable<int> d = DerivedValueListenable<int>(
      src,
      () => src.a,
    );
    addTearDown(d.dispose);
    int calls = 0;
    void listener() => calls++;
    d.addListener(listener);
    d.removeListener(listener);
    src.a = 3;
    d.addListener(listener);
    expect(d.value, 3);
    src.bump();
    expect(calls, 0, reason: '重新订阅时已取到 3，同值不再通知');
    d.removeListener(listener);
  });
}
