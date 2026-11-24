// 审查遗留（拍板台 review-merge-1124-leftovers #1，BUG-5387 后续）：换库 / 数据根迁移
// 关库时，登记过的后台写库工作里在途的网络请求与 FFmpeg 子进程必须被中断，关库不必
// 等它们自然跑完，子进程打开的文件随之释放。
import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

FushiDatabase _memoryDb() => FushiDatabase.forTesting(NativeDatabase.memory());

void main() {
  test('后台工作里经应用出站 client 发的请求，关库时被中止', () async {
    // 一个收了请求却永不回包的服务器：模拟慢网络 / 挂住的刮削源。
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final Completer<void> requestArrived = Completer<void>();
    final List<HttpRequest> held = <HttpRequest>[];
    server.listen((HttpRequest request) {
      held.add(request);
      if (!requestArrived.isCompleted) requestArrived.complete();
    });
    addTearDown(() async {
      for (final HttpRequest r in held) {
        try {
          await r.response.close();
        } on Object {
          // 客户端已中止。
        }
      }
      await server.close(force: true);
    });

    final http.Client client = createAppHttpIoClient();
    addTearDown(client.close);
    final FushiDatabase db = _memoryDb();
    final Uri uri = Uri.parse('http://127.0.0.1:${server.port}/slow');
    final Future<Object?> work = db
        .runBackgroundWork<http.Response>(
          'test.scrape',
          (DatabaseWorkToken _) => client.post(uri, body: 'q=1'),
        )
        .then<Object?>((http.Response r) => r, onError: (Object e) => e);

    await requestArrived.future;
    final Stopwatch sw = Stopwatch()..start();
    await db.close().timeout(const Duration(seconds: 10));
    sw.stop();
    expect(await work, isA<http.RequestAbortedException>());
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('不在后台工作里的请求不受影响（请求体与头原样到达）', () async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));
    server.listen((HttpRequest request) async {
      final String body = await request
          .cast<List<int>>()
          .transform(const SystemEncoding().decoder)
          .join();
      request.response.write('${request.headers.contentType?.mimeType}|$body');
      await request.response.close();
    });
    final http.Client client = createAppHttpIoClient();
    addTearDown(client.close);
    final Uri uri = Uri.parse('http://127.0.0.1:${server.port}/echo');

    final http.Response plain = await client.post(
      uri,
      body: <String, String>{'a': '1'},
    );
    expect(plain.body, 'application/x-www-form-urlencoded|a=1');

    // 在后台工作里（被换成可中止请求）也原样到达。
    final FushiDatabase db = _memoryDb();
    final http.Response inWork = await db.runBackgroundWork<http.Response>(
      'test.echo',
      (DatabaseWorkToken _) =>
          client.post(uri, body: <String, String>{'b': '2'}),
    );
    expect(inWork.body, 'application/x-www-form-urlencoded|b=2');
    expect(db.backgroundWork.pendingCancelListenerCount, 0);
    await db.close();
  });

  test('后台工作里的 FFmpeg 子进程，关库时被杀掉并回收', () async {
    // 用一个会跑很久的系统命令代替 ffmpeg：进程模型与 ffmpeg 抽帧一致。
    final (String exe, List<String> args) = Platform.isWindows
        ? ('ping', <String>['-n', '60', '127.0.0.1'])
        : ('sleep', <String>['60']);
    final FushiDatabase db = _memoryDb();
    final Completer<void> started = Completer<void>();
    final Future<FfmpegRunResult> work = db.runBackgroundWork<FfmpegRunResult>(
      'test.coverFrame',
      (DatabaseWorkToken _) {
        final Future<FfmpegRunResult> run = runFfmpegProcess(
          exe,
          args,
          const Duration(minutes: 5),
        );
        started.complete();
        return run;
      },
    );
    await started.future;
    // 等子进程真正起来再关库。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final Stopwatch sw = Stopwatch()..start();
    await db.close().timeout(const Duration(seconds: 20));
    sw.stop();
    final FfmpegRunResult result = await work;
    expect(result.returnCode, isNull);
    expect(result.output, contains('database is closing'));
    expect(sw.elapsed, lessThan(const Duration(seconds: 15)));
  });
}
