import 'dart:async';

import 'package:fushi/src/media/video/remote_client_teardown.dart';
import 'package:fushi/src/media/video/stream_url_resolver.dart';
import 'package:fushi/src/media/video/url_stream_video.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

class _RecordingResolver extends StreamUrlResolver {
  int closed = 0;

  @override
  Future<String> resolve(String url) async => url;

  @override
  void close() => closed++;
}

class _RecordingHttpClient extends MockClient {
  _RecordingHttpClient()
    : super((http.Request _) async => http.Response('', 204));

  int closed = 0;

  @override
  void close() {
    closed++;
    super.close();
  }
}

/// 不持有任何连接的来源（互联 host 的替身）：关闭时不该被碰。
class _PlainClient implements RemoteVideoClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected ${invocation.memberName}');
}

/// BUG-5012：播放页自建的流客户端（连同来源直链解析器的 SSH / AList 连接）此前从不
/// 关闭；关闭又不能抢在退出收尾（断点落库、停止上报）之前。
void main() {
  test('没有在途收尾：立即关闭', () async {
    final RemoteClientTeardown teardown = RemoteClientTeardown();
    int closed = 0;
    await teardown.closeAfterInFlight(() => closed++);
    expect(closed, 1);
  });

  test('有在途收尾：等它结束再关，结束前不关', () async {
    final RemoteClientTeardown teardown = RemoteClientTeardown();
    final Completer<void> stopReport = Completer<void>();
    final Future<void> tracked = teardown.track(() => stopReport.future);
    int closed = 0;
    final Future<void> closing = teardown.closeAfterInFlight(() => closed++);
    await Future<void>.delayed(Duration.zero);
    expect(closed, 0, reason: 'stop report still needs the client');
    expect(teardown.inFlightCount, 1);
    stopReport.complete();
    await tracked;
    await closing;
    expect(closed, 1);
    expect(teardown.inFlightCount, 0);
  });

  test('在途收尾失败也照样关闭，错误仍交给发起方', () async {
    final RemoteClientTeardown teardown = RemoteClientTeardown();
    final Future<void> tracked = teardown.track<void>(
      () async => throw StateError('offline'),
    );
    int closed = 0;
    final Future<void> closing = teardown.closeAfterInFlight(() => closed++);
    await expectLater(tracked, throwsStateError);
    await closing;
    expect(closed, 1);
  });

  test('关闭流客户端：http 客户端与来源直链解析器都释放', () {
    final _RecordingResolver resolver = _RecordingResolver();
    final _RecordingHttpClient httpClient = _RecordingHttpClient();
    final UrlStreamVideoClient client = UrlStreamVideoClient(
      streamUrl: 'https://nas.example/video.mkv',
      urlResolver: resolver,
      httpClient: httpClient,
    );
    closeOwnedRemoteVideoClient(client);
    expect(resolver.closed, 1);
    expect(httpClient.closed, 1);
  });

  test('不持有连接的客户端：关闭是空操作', () {
    expect(() => closeOwnedRemoteVideoClient(_PlainClient()), returnsNormally);
  });
}
