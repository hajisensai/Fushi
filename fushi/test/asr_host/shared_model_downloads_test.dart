import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr_host/shared_model_downloads.dart';
import 'package:fushi_asr_core/asr_core.dart' show ModelDownloadEvent;

/// kZZmXQBv7E：模型下载以前挂在弹层上，关掉再开、再点一次就起第二条写者，两条流
/// 同时往同一个 `.part` 里 append，之后每次 Range 续传都是 HTTP 416。
void main() {
  ModelDownloadEvent ev(int received) => ModelDownloadEvent(
    fileName: 'model.onnx_data',
    receivedBytes: received,
    totalBytes: 100,
  );

  test('已在下载时再 join 不另起写者，只挂上去', () async {
    final SharedModelDownloads shared = SharedModelDownloads();
    final StreamController<ModelDownloadEvent> source =
        StreamController<ModelDownloadEvent>();
    int starts = 0;
    Stream<ModelDownloadEvent> start() {
      starts++;
      return source.stream;
    }

    final List<int> first = <int>[];
    final StreamSubscription<ModelDownloadEvent> a = shared
        .join('asr:p', start)
        .listen((ModelDownloadEvent e) => first.add(e.receivedBytes));
    source.add(ev(10));
    await pumpEventQueue();

    final List<int> second = <int>[];
    final Completer<void> secondDone = Completer<void>();
    shared
        .join('asr:p', start)
        .listen(
          (ModelDownloadEvent e) => second.add(e.receivedBytes),
          onDone: secondDone.complete,
        );
    await pumpEventQueue();
    expect(starts, 1, reason: '同一个键同一时刻只能有一条写者');
    expect(second, <int>[10], reason: '后挂上的先补最近一条进度');

    source.add(ev(20));
    await source.close();
    await secondDone.future;
    expect(first, <int>[10, 20]);
    expect(second, <int>[10, 20]);
    expect(shared.isActive('asr:p'), isFalse);
    await a.cancel();
  });

  test('监听方取消（关弹层）不停下载；attach 接回进行中的那条', () async {
    final SharedModelDownloads shared = SharedModelDownloads();
    bool sourceCancelled = false;
    final StreamController<ModelDownloadEvent> source =
        StreamController<ModelDownloadEvent>(
          onCancel: () => sourceCancelled = true,
        );

    final StreamSubscription<ModelDownloadEvent> sheet = shared
        .join('moss', () => source.stream)
        .listen((_) {});
    source.add(ev(30));
    await pumpEventQueue();
    await sheet.cancel();
    expect(sourceCancelled, isFalse);
    expect(shared.isActive('moss'), isTrue);
    expect(shared.latestOf('moss')?.receivedBytes, 30);

    final Stream<ModelDownloadEvent>? resumed = shared.attach('moss');
    expect(resumed, isNotNull);
    final List<int> seen = <int>[];
    final Completer<void> done = Completer<void>();
    resumed!.listen(
      (ModelDownloadEvent e) => seen.add(e.receivedBytes),
      onDone: done.complete,
    );
    source.add(ev(100));
    await source.close();
    await done.future;
    expect(seen, <int>[30, 100]);
    expect(shared.attach('moss'), isNull, reason: '下完就从登记表里摘掉');
  });

  test('cancel 才真正停下载；监听方收到 done', () async {
    final SharedModelDownloads shared = SharedModelDownloads();
    bool sourceCancelled = false;
    final StreamController<ModelDownloadEvent> source =
        StreamController<ModelDownloadEvent>(
          onCancel: () => sourceCancelled = true,
        );
    final Completer<void> done = Completer<void>();
    shared
        .join('asr:p', () => source.stream)
        .listen((_) {}, onDone: done.complete);
    await pumpEventQueue();
    await shared.cancel('asr:p');
    await done.future;
    expect(sourceCancelled, isTrue);
    expect(shared.isActive('asr:p'), isFalse);
  });

  test('失败转给监听方并释放键，下一次 join 重新起', () async {
    final SharedModelDownloads shared = SharedModelDownloads();
    final StreamController<ModelDownloadEvent> source =
        StreamController<ModelDownloadEvent>();
    final Completer<Object> failed = Completer<Object>();
    shared
        .join('asr:p', () => source.stream)
        .listen((_) {}, onError: (Object e) => failed.complete(e));
    source.addError(StateError('HTTP 503'));
    expect(await failed.future, isA<StateError>());
    await pumpEventQueue();
    expect(shared.isActive('asr:p'), isFalse);

    int starts = 0;
    final StreamSubscription<ModelDownloadEvent> again = shared
        .join('asr:p', () {
          starts++;
          return const Stream<ModelDownloadEvent>.empty();
        })
        .listen((_) {});
    await pumpEventQueue();
    expect(starts, 1);
    await again.cancel();
  });
}
