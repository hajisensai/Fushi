import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/video_collection_open_request.dart';

/// 「请视频库打开某个视频合集」请求：只有最后一次请求算数，接单即清空（同一个请求
/// 不会被打开两次）。
void main() {
  tearDown(() => videoCollectionOpenRequest.value = null);

  test('接单取走最后一次请求并清空', () {
    requestVideoCollectionOpen(3);
    requestVideoCollectionOpen(13);
    expect(takeVideoCollectionOpenRequest(), 13);
    expect(videoCollectionOpenRequest.value, isNull);
    expect(takeVideoCollectionOpenRequest(), isNull);
  });

  test('发请求会通知订阅者（视频库页靠它接单）', () {
    int notified = 0;
    void listener() => notified++;
    videoCollectionOpenRequest.addListener(listener);
    addTearDown(() => videoCollectionOpenRequest.removeListener(listener));
    requestVideoCollectionOpen(42);
    expect(notified, 1);
  });
}
