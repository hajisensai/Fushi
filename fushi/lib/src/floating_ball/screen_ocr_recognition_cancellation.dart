/// Android 截屏识字识别中的取消令牌（BUG-4790）。
///
/// 原生把定格帧交给 Dart 侧识别器（本机模型 / Lens）后，用户可以在识别中的通知上
/// 取消。原生随即收尾流程，同时发 `cancelScreenOcrRecognition {flow}` 过来：这里让
/// 那次识别立刻以 [ScreenOcrRecognitionCancelledException] 结束，宿主回
/// `{cancelled: true}`。底层识别停不停得下来看引擎——Lens 由 [onCancel] 断开连接；
/// 本机模型推理跑完为止，结果被丢掉（错误也一并吞掉，不进错误日志）。
library;

import 'dart:async';

/// 那次识别被用户取消了。
class ScreenOcrRecognitionCancelledException implements Exception {
  const ScreenOcrRecognitionCancelledException();

  @override
  String toString() => 'ScreenOcrRecognitionCancelledException';
}

/// 一次截屏识字流程（原生流程编号 [flow]）的取消令牌。
class ScreenOcrRecognitionCancellation {
  ScreenOcrRecognitionCancellation(this.flow);

  /// 原生 `ScreenOcrRecognitionGate` 给这次流程的编号；取消按它点名。
  final int flow;

  final Completer<void> _cancelled = Completer<void>();
  final List<void Function()> _onCancel = <void Function()>[];

  bool get isCancelled => _cancelled.isCompleted;

  /// 取消时要做的事（例如断开 Lens 连接）。已经取消的立刻执行。
  void onCancel(void Function() action) {
    if (isCancelled) {
      action();
      return;
    }
    _onCancel.add(action);
  }

  /// 取消这次识别；重复调用无效果。
  void cancel() {
    if (isCancelled) return;
    _cancelled.complete();
    final List<void Function()> actions = List<void Function()>.of(_onCancel);
    _onCancel.clear();
    for (final void Function() action in actions) {
      action();
    }
  }

  /// 等 [work]，但一取消就以 [ScreenOcrRecognitionCancelledException] 结束；被抛下的
  /// [work] 之后的结果与错误都丢掉。
  Future<T> guard<T>(Future<T> work) {
    if (isCancelled) {
      work.ignore();
      return Future<T>.error(const ScreenOcrRecognitionCancelledException());
    }
    final Completer<T> result = Completer<T>();
    work.then(
      (T value) {
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    _cancelled.future.then((_) {
      if (!result.isCompleted) {
        result.completeError(const ScreenOcrRecognitionCancelledException());
      }
    });
    return result.future;
  }
}
