import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_exit_flush.dart';

/// BUG-2119：退出不能被落库成败绑架。
void main() {
  test('落库永不完成：退出仍同步发生', () {
    final Completer<void> never = Completer<void>();
    int exits = 0;
    final List<Object> errors = <Object>[];
    exitAfterPersist(
      persist: () => never.future,
      exit: () => exits++,
      onPersistError: (Object e, StackTrace s) => errors.add(e),
    );
    expect(exits, 1, reason: 'persist 挂死时 exit 必须已经同步执行');
    expect(errors, isEmpty);
  });

  test('落库异步抛错：退出仍发生，错误交给 onPersistError', () async {
    int exits = 0;
    final List<Object> errors = <Object>[];
    exitAfterPersist(
      persist: () async => throw StateError('cannot commit transaction'),
      exit: () => exits++,
      onPersistError: (Object e, StackTrace s) => errors.add(e),
    );
    expect(exits, 1);
    await Future<void>.delayed(Duration.zero);
    expect(errors, hasLength(1));
    expect(errors.single, isA<StateError>());
  });

  test('落库同步抛错：退出仍发生，错误交给 onPersistError', () {
    int exits = 0;
    final List<Object> errors = <Object>[];
    exitAfterPersist(
      persist: () => throw StateError('sync boom'),
      exit: () => exits++,
      onPersistError: (Object e, StackTrace s) => errors.add(e),
    );
    expect(exits, 1);
    expect(errors, hasLength(1));
  });

  test('落库成功：exit 恰好一次、无错误上报，且 persist 先于 exit 启动', () async {
    final List<String> order = <String>[];
    final List<Object> errors = <Object>[];
    exitAfterPersist(
      persist: () async {
        order.add('persist-start');
      },
      exit: () => order.add('exit'),
      onPersistError: (Object e, StackTrace s) => errors.add(e),
    );
    await Future<void>.delayed(Duration.zero);
    expect(order, <String>['persist-start', 'exit']);
    expect(errors, isEmpty);
  });
}
