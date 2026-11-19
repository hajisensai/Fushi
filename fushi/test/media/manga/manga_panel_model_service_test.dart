import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_panel_model_service.dart';

import '../../helpers/engine_storage_sandbox.dart';

/// 把模型下载的 GET 改发到本机回环上的假服务器，其余成员不实现（下载只用到
/// `getUrl` 与 `close`）。
class _LoopbackClient implements HttpClient {
  _LoopbackClient(this._port);

  final int _port;
  final HttpClient _inner = HttpClient();
  bool closed = false;

  @override
  Future<HttpClientRequest> getUrl(Uri url) =>
      _inner.getUrl(Uri.parse('http://127.0.0.1:$_port/model.onnx'));

  @override
  void close({bool force = false}) {
    closed = true;
    _inner.close(force: force);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('downloadMangaPanelModel', () {
    useEngineStorageSandbox();

    late HttpServer server;
    final List<HttpResponse> held = <HttpResponse>[];

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() async {
      for (final HttpResponse response in held) {
        unawaited(response.close().catchError((Object _) {}));
      }
      held.clear();
      await server.close(force: true);
    });

    Future<File> partFile() async =>
        File('${(await mangaPanelModelFile()).path}.part');

    test('a body that stalls ends with a timeout, closes the client and leaves '
        'no .part', () async {
      // 发出响应头和一块数据后不再写、也不关：旧实现的 await for 会永远等下去。
      server.listen((HttpRequest request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..bufferOutput = false
          ..add(List<int>.filled(4096, 7));
        await request.response.flush();
        held.add(request.response);
      });
      late _LoopbackClient client;
      final List<int> progress = <int>[];
      Object? error;
      try {
        await for (final int received in downloadMangaPanelModel(
          clientFactory: () => client = _LoopbackClient(server.port),
          stallTimeout: const Duration(milliseconds: 300),
        )) {
          progress.add(received);
        }
      } on Object catch (e) {
        error = e;
      }
      expect(error, isA<TimeoutException>());
      expect(progress, isNotEmpty, reason: 'the first chunk did arrive');
      expect(client.closed, isTrue);
      expect((await partFile()).existsSync(), isFalse);
      expect((await mangaPanelModelFile()).existsSync(), isFalse);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a body that fails validation leaves no .part', () async {
      server.listen((HttpRequest request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..add(<int>[1, 2, 3]);
        await request.response.close();
      });
      await expectLater(
        downloadMangaPanelModel(
          clientFactory: () => _LoopbackClient(server.port),
        ).drain<void>(),
        throwsA(isA<StateError>()),
      );
      expect((await partFile()).existsSync(), isFalse);
      expect((await mangaPanelModelFile()).existsSync(), isFalse);
    });
  });
}
