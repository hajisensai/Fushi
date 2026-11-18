// 关闭 RWKV 服务时在途的权重下载要停干净（CI 偶发红：fushi_server 的测试收尾删了临时目录之后，没停下的下载还去
// 写 `<权重>.verified`，PathNotFoundException 落到 zone）。服务关闭 = 等下载真的停下才返回；之后删目录不会有任何
// 收尾撞上来。权重来源是本地 HttpServer（不碰外网）；文件做大（128 MB），让「收尾」（读回整文件算 SHA-256、写校验
// 标记）有足够长的窗口，关闭恰好落在收尾途中。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_rwkv_models.dart';
import 'package:fushi_engine/srs/srs_rwkv_service.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/srs_fake_engine.dart';
import 'support/srs_test_storage.dart';

const String _profile = '01928c3e-0000-7000-8000-00000000c0c0';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('下载收尾途中关闭服务：close 返回后不再碰文件，随后删目录不抛异常、目录不被重建', () async {
    final Uint8List weights = Uint8List(128 * 1024 * 1024);
    for (int i = 0; i < weights.length; i += 4096) {
      weights[i] = i ~/ 4096 % 251;
    }
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));
    server.listen((HttpRequest request) async {
      request.response.contentLength = weights.length;
      request.response.add(weights);
      await request.response.close();
    });

    final SrsStorage storage = await openTestSrsStorage();
    final SrsDbStore store = await SrsDbStore.open(
      core: storage.core,
      profileUid: _profile,
      deviceId: 'dev',
      engine: const SrsFakeEngine(),
    );
    final Directory root = Directory.systemTemp.createTempSync('srs_rwkv_dl');
    final Directory modelDir = Directory(p.join(root.path, 'models'));
    final SrsRwkvModels models = SrsRwkvModels(
      dir: modelDir,
      model: SrsRwkvModelFile(
        fileName: 'test_weights.int8.bin',
        urls: <String>['http://127.0.0.1:${server.port}/w.bin'],
        expectedBytes: weights.length,
        sha256: sha256.convert(weights).toString(),
      ),
      createClient: HttpClient.new,
    );
    final SrsRwkvService service = SrsRwkvService(
      store: store,
      models: models,
      snapshotDir: Directory(p.join(root.path, 'state')),
      openBackend: (File _) async =>
          throw StateError('the service is closed before weights are used'),
    );

    final List<Object> uncaught = <Object>[];
    bool closedInTail = false;
    // 用例体里的同步失败（旧实现下：关闭后收尾还占着文件，删目录失败）也记进 uncaught 并照常收尾，不让
    // runZonedGuarded 的 future 永远不完成、变成看不出原因的超时。
    final Completer<void> finished = Completer<void>();
    runZonedGuarded(() async {
      try {
        final Completer<void> received = Completer<void>();
        final StreamSubscription<SrsRwkvStatus> sub = service.statusChanges
            .listen((SrsRwkvStatus s) {
              if (s.phase == SrsRwkvPhase.downloading &&
                  s.total > 0 &&
                  s.done >= s.total &&
                  !received.isCompleted) {
                received.complete();
              }
            });
        final Future<void> started = service.start().then<void>(
          (_) {},
          onError: (Object _) {},
        );
        await received.future;
        await sub.cancel();
        // 字节都到了、校验标记还没写：关闭落在收尾途中。
        closedInTail = !models.isReady;
        await service.close();
        await started;
        modelDir.deleteSync(recursive: true);
        // 旧实现的收尾（读回 128 MB、算哈希、写标记）在这段时间里跑完并撞上已删的目录。
        await Future<void>.delayed(const Duration(seconds: 2));
      } on Object catch (error) {
        uncaught.add(error);
      } finally {
        finished.complete();
      }
    }, (Object error, StackTrace stack) => uncaught.add(error));
    await finished.future;
    expect(closedInTail, isTrue, reason: '关闭要落在下载收尾途中，用例才有意义');
    expect(uncaught, isEmpty);
    expect(modelDir.existsSync(), isFalse, reason: '关闭之后没有人再往目录里写');
    root.deleteSync(recursive: true);
  });
}
