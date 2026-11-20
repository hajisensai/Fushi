import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/floating_ball/screen_ocr_recognition_cancellation.dart';

/// BUG-4790：Android 截屏识字识别中的取消令牌。
void main() {
  test('没取消：结果照常回来', () async {
    final ScreenOcrRecognitionCancellation c = ScreenOcrRecognitionCancellation(
      1,
    );
    expect(await c.guard(Future<int>.value(7)), 7);
  });

  test('没取消：识别器的错误照常抛出', () async {
    final ScreenOcrRecognitionCancellation c = ScreenOcrRecognitionCancellation(
      1,
    );
    await expectLater(
      c.guard(Future<int>.error(StateError('boom'))),
      throwsStateError,
    );
  });

  test('识别中取消：立刻以取消结束，不等识别器', () async {
    final ScreenOcrRecognitionCancellation c = ScreenOcrRecognitionCancellation(
      3,
    );
    final Completer<int> slow = Completer<int>();
    final Future<int> guarded = c.guard(slow.future);
    c.cancel();
    await expectLater(
      guarded,
      throwsA(isA<ScreenOcrRecognitionCancelledException>()),
    );
    expect(c.isCancelled, isTrue);
    // 被抛下的识别晚到的错误不能变成未处理异常。
    slow.completeError(StateError('late'));
    await Future<void>.delayed(Duration.zero);
  });

  test('取消后才开始等：直接以取消结束', () async {
    final ScreenOcrRecognitionCancellation c = ScreenOcrRecognitionCancellation(
      2,
    )..cancel();
    await expectLater(
      c.guard(Future<int>.value(1)),
      throwsA(isA<ScreenOcrRecognitionCancelledException>()),
    );
  });

  test('onCancel：取消时执行一次（断开 Lens），重复取消不再执行；取消后登记的立刻执行', () {
    final ScreenOcrRecognitionCancellation c = ScreenOcrRecognitionCancellation(
      4,
    );
    int closed = 0;
    c.onCancel(() => closed++);
    expect(closed, 0);
    c
      ..cancel()
      ..cancel();
    expect(closed, 1);
    c.onCancel(() => closed++);
    expect(closed, 2);
  });
}
