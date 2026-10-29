// KavitaOpenBooks：阅读器持有登记 + 关书推送完成信号（系列页等它再重取，替代固定延时轮询）。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/kavita/kavita_open_books.dart';

void main() {
  test('settled completes immediately for a book that is not open', () async {
    expect(KavitaOpenBooks.isOpen('none'), isFalse);
    await KavitaOpenBooks.settled('none');
  });

  test(
    'settled waits for the reader to close and its flush to finish',
    () async {
      KavitaOpenBooks.opened('b');
      expect(KavitaOpenBooks.isOpen('b'), isTrue);
      bool settled = false;
      unawaited(KavitaOpenBooks.settled('b').then((_) => settled = true));
      await pumpEventQueue();
      expect(settled, isFalse, reason: 'reader still open');

      final Completer<void> flush = Completer<void>();
      KavitaOpenBooks.closed('b', flush: flush.future);
      expect(KavitaOpenBooks.isOpen('b'), isFalse);
      await pumpEventQueue();
      expect(settled, isFalse, reason: 'push still in flight');

      flush.complete();
      await pumpEventQueue();
      expect(settled, isTrue);
    },
  );

  test(
    'a failing flush still settles; two readers need both to close',
    () async {
      KavitaOpenBooks.opened('c');
      KavitaOpenBooks.opened('c');
      bool settled = false;
      unawaited(KavitaOpenBooks.settled('c').then((_) => settled = true));
      KavitaOpenBooks.closed('c', flush: Future<void>.error(StateError('x')));
      await pumpEventQueue();
      expect(settled, isFalse);
      expect(KavitaOpenBooks.isOpen('c'), isTrue);
      KavitaOpenBooks.closed('c');
      await pumpEventQueue();
      expect(settled, isTrue);
      // 多余的 closed 是空操作。
      KavitaOpenBooks.closed('c');
      expect(KavitaOpenBooks.isOpen('c'), isFalse);
    },
  );
}
