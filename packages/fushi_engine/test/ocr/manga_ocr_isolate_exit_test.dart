import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/ocr/manga_ocr_service_impl.dart';
import 'package:fushi_engine/ocr/ocr_host_bindings.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// BUG-3997 同根因：宿主 bootstrap（app 里是
/// `BackgroundIsolateBinaryMessenger.ensureInitialized`）在后台 isolate 里留下一个
/// 没有关闭入口的 `ReceivePort`，靠「入口返回即退出」的 isolate 永远不退。
///
/// 这里的 bootstrap 原样复刻这一点：开一个永不关闭的端口，并在 isolate 自己身上
/// 挂退出监听（在 isolate 内注册，不会与「已经退出」赛跑）。修复前两条 OCR isolate 都等不到退出（页级会话的 close()
/// 也永远不完成）；修复后入口显式 `Isolate.exit`。

/// bootstrap 留下的「关不掉」的端口（存成全局，确保它在 isolate 里一直活着）。
final List<ReceivePort> _leakedPorts = <ReceivePort>[];

/// 顶层函数：随 isolate 参数跨 isolate 发送。参数是测试端收退出通知的 [SendPort]。
void _leakingBootstrap(Object? arg) {
  _leakedPorts.add(ReceivePort());
  Isolate.current.addOnExitListener(arg! as SendPort);
}

/// 在后台 isolate 里直接抛，模拟 ORT 建会话失败（走到入口的收尾路径即可）。
OcrSessionFactory _throwingFactoryBuilder() =>
    throw StateError('no ORT in unit test');

MangaOcrModelPaths _modelPaths(Directory dir) => MangaOcrModelPaths(
  detectorPath: p.join(dir.path, 'detector.onnx'),
  ppDetPath: p.join(dir.path, 'pp_det.onnx'),
  ppRecPath: p.join(dir.path, 'ctc_rec.onnx'),
  ppRecDictPath: p.join(dir.path, 'inference.yml'),
  ctcRecPath: p.join(dir.path, 'ctc_rec.onnx'),
);

/// 收后台 isolate 的退出通知；返回端口与「已退出」的 Future。
({ReceivePort exits, Future<void> exited}) _watchExit() {
  final ReceivePort exits = ReceivePort();
  final Completer<void> exited = Completer<void>();
  exits.listen((_) {
    if (!exited.isCompleted) exited.complete();
  });
  return (exits: exits, exited: exited.future);
}

void main() {
  late Directory dir;
  OcrSessionFactory Function()? savedBuilder;
  OcrIsolateBootstrap? savedBootstrap;
  Object? savedBootstrapArg;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ocr_isolate_exit_');
    savedBuilder = ocrSessionFactoryBuilder;
    savedBootstrap = ocrIsolateBootstrap;
    savedBootstrapArg = ocrIsolateBootstrapArg;
    ocrSessionFactoryBuilder = _throwingFactoryBuilder;
    ocrIsolateBootstrap = _leakingBootstrap;
  });

  tearDown(() {
    ocrSessionFactoryBuilder = savedBuilder;
    ocrIsolateBootstrap = savedBootstrap;
    ocrIsolateBootstrapArg = savedBootstrapArg;
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('整卷任务收尾后 isolate 退出（bootstrap 留着打开的端口也一样）', () async {
    final ({ReceivePort exits, Future<void> exited}) watch = _watchExit();
    addTearDown(watch.exits.close);
    ocrIsolateBootstrapArg = watch.exits.sendPort;

    final MangaOcrVolumeJob job = const IsolateMangaOcrVolumeJobRunner().start(
      MangaOcrVolumeJobRequest(
        imageDirPath: dir.path,
        modelPaths: _modelPaths(dir),
      ),
      onProgress: (int done, int total, int pageIndex) {},
    );
    await expectLater(
      job.result,
      throwsA(
        isA<StateError>().having(
          (StateError e) => e.message,
          'message',
          contains('no ORT in unit test'),
        ),
      ),
    );
    await watch.exited.timeout(
      const Duration(seconds: 20),
      onTimeout: () => fail('整卷 OCR isolate 没有退出'),
    );
  });

  test('页级会话 close() 完成且 isolate 退出（bootstrap 留着打开的端口也一样）', () async {
    final ({ReceivePort exits, Future<void> exited}) watch = _watchExit();
    addTearDown(watch.exits.close);
    ocrIsolateBootstrapArg = watch.exits.sendPort;

    final MangaOcrPageSession session = const IsolateMangaOcrPageSessionRunner()
        .open(
          MangaOcrPageSessionRequest(
            imageDirPath: dir.path,
            modelPaths: _modelPaths(dir),
            engineSignature: 'test-signature',
          ),
        );
    await expectLater(session.ocrPage('p1.png'), throwsA(isA<StateError>()));
    await session.close().timeout(
      const Duration(seconds: 20),
      onTimeout: () => fail('页级会话 close() 没有完成'),
    );
    await watch.exited.timeout(
      const Duration(seconds: 20),
      onTimeout: () => fail('页级会话 OCR isolate 没有退出'),
    );
  });
}
