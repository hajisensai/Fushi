// SrsRwkvModels.download：按来源顺序（镜像 → 上游）下载，每个来源都只认字节数 + SHA-256，失败换下一个；
// 全部失败时错误信息逐个写明哪个来源、为什么失败。本地 HttpServer 充当两个来源，不碰网络。
// 另测模型档位（Small sm98 / Tiny sm101）：钉死的权重、设置文件的读写与缺省、每档的快照目录。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fushi_asr_core/asr_core.dart' show ModelDownloadEvent;
import 'package:fushi_engine/srs/srs_rwkv_attach.dart';
import 'package:fushi_engine/srs/srs_rwkv_models.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late Directory dir;
  late Uint8List good;
  final List<String> requested = <String>[];

  /// 路径 → 回应：字节内容，或 null = 404。
  final Map<String, Uint8List?> routes = <String, Uint8List?>{};

  setUp(() async {
    good = Uint8List.fromList(List<int>.generate(4096, (int i) => i * 7 % 251));
    dir = Directory.systemTemp.createTempSync('rwkv_models_dl');
    requested.clear();
    routes.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      requested.add(request.uri.path);
      final Uint8List? body = routes[request.uri.path];
      if (body == null) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response.contentLength = body.length;
        request.response.add(body);
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    dir.deleteSync(recursive: true);
  });

  String url(String path) => 'http://127.0.0.1:${server.port}$path';

  SrsRwkvModels models() => SrsRwkvModels(
    dir: dir,
    model: SrsRwkvModelFile(
      fileName: 'test_weights.int8.bin',
      urls: <String>[url('/mirror/w.bin'), url('/upstream/w.bin')],
      expectedBytes: good.length,
      sha256: sha256.convert(good).toString(),
    ),
    createClient: HttpClient.new,
  );

  test('首选来源可用时只用它', () async {
    routes['/mirror/w.bin'] = good;
    routes['/upstream/w.bin'] = good;
    final SrsRwkvModels m = models();
    await m.download().drain<void>();
    expect(m.isReady, isTrue);
    expect(m.weightsFile.readAsBytesSync(), good);
    expect(requested, <String>['/mirror/w.bin']);
  });

  test('首选来源 404 → 用备用来源', () async {
    routes['/upstream/w.bin'] = good;
    final SrsRwkvModels m = models();
    await m.download().drain<void>();
    expect(m.isReady, isTrue);
    expect(requested, <String>['/mirror/w.bin', '/upstream/w.bin']);
  });

  test('首选来源字节数对但内容不符（SHA-256 不对）→ 丢掉、用备用来源', () async {
    routes['/mirror/w.bin'] = Uint8List(good.length);
    routes['/upstream/w.bin'] = good;
    final SrsRwkvModels m = models();
    await m.download().drain<void>();
    expect(m.isReady, isTrue);
    expect(m.weightsFile.readAsBytesSync(), good);
  });

  // 不能出网的服务端：按 README 把权重手动放进目录（没有校验标记）。校验通过就用，不联网、不删文件。
  test('目录里已有正确权重但没有校验标记 → 验收后直接就绪，不发任何请求', () async {
    int clients = 0;
    final SrsRwkvModels m = SrsRwkvModels(
      dir: dir,
      model: SrsRwkvModelFile(
        fileName: 'test_weights.int8.bin',
        // 两个来源都不可用：联网就只能失败。
        urls: <String>[url('/mirror/w.bin'), url('/upstream/w.bin')],
        expectedBytes: good.length,
        sha256: sha256.convert(good).toString(),
      ),
      createClient: () {
        clients++;
        return HttpClient();
      },
    );
    m.weightsFile.writeAsBytesSync(good);
    expect(m.isReady, isFalse);
    await m.download().drain<void>();
    expect(m.isReady, isTrue);
    expect(m.weightsFile.readAsBytesSync(), good);
    expect(clients, 0);
    expect(requested, isEmpty);
  });

  test('目录里已有权重字节数对但内容不符（无标记）→ 丢掉、走来源下载', () async {
    routes['/mirror/w.bin'] = good;
    final SrsRwkvModels m = models();
    m.weightsFile.writeAsBytesSync(Uint8List(good.length));
    await m.download().drain<void>();
    expect(m.isReady, isTrue);
    expect(m.weightsFile.readAsBytesSync(), good);
    expect(requested, <String>['/mirror/w.bin']);
  });

  // 预验收也守取消契约：读文件期间被取消，之后不写标记、不删文件。
  test('验收已有权重期间取消：不写校验标记、不删文件、不联网', () async {
    final SrsRwkvModels m = models();
    final Uint8List bad = Uint8List(good.length);
    for (final Uint8List content in <Uint8List>[bad, good]) {
      m.weightsFile.writeAsBytesSync(content);
      // listen 同步跑到读文件的 await，cancel 在读完之前置位。
      await m.download().listen((_) {}).cancel();
      expect(m.weightsFile.readAsBytesSync(), content);
      expect(File('${m.weightsFile.path}.verified').existsSync(), isFalse);
    }
    expect(requested, isEmpty);
  });

  // CI 偶发红的复现：宿主在下载收尾前取消（服务关闭）、随即删掉目录（测试 tearDown）。取消必须等到下载真的停下
  // 才返回，之后不再碰文件（不写校验标记、不读权重），目录删掉后也没有任何异常漏到 zone。
  test('下载收尾前取消：取消返回时已停下、不写校验标记；随后删目录不抛异常', () async {
    routes['/mirror/w.bin'] = good;
    final List<Object> uncaught = <Object>[];
    await runZonedGuarded(() async {
      final SrsRwkvModels m = models();
      final Completer<void> sawAll = Completer<void>();
      late final StreamSubscription<ModelDownloadEvent> sub;
      sub = m.download().listen((ModelDownloadEvent e) {
        if (e.done && !sawAll.isCompleted) {
          sawAll.complete();
        }
      }, onError: uncaught.add);
      await sawAll.future;
      await sub.cancel();
      expect(m.isReady, isFalse, reason: '取消后不得再写校验标记');
      expect(File('${m.weightsFile.path}.verified').existsSync(), isFalse);
      dir.deleteSync(recursive: true);
      // 给可能还在跑的收尾留足机会：它若还在，就会在这里撞上已删的目录。
      for (int i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      dir.createSync(); // tearDown 还要删它
    }, (Object error, StackTrace stack) => uncaught.add(error));
    expect(uncaught, isEmpty);
  });

  test('下载中途取消：取消返回时连接已停，不留校验标记', () async {
    // 只发一半就停住不结束：取消必须把在途的连接收掉，而不是等它自然结束。
    final HttpServer stall = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => stall.close(force: true));
    final Completer<void> halfSent = Completer<void>();
    stall.listen((HttpRequest request) async {
      request.response.contentLength = good.length;
      request.response.add(good.sublist(0, good.length ~/ 2));
      await request.response.flush();
      if (!halfSent.isCompleted) halfSent.complete();
    });
    final SrsRwkvModels m = SrsRwkvModels(
      dir: dir,
      model: SrsRwkvModelFile(
        fileName: 'test_weights.int8.bin',
        urls: <String>['http://127.0.0.1:${stall.port}/w.bin'],
        expectedBytes: good.length,
        sha256: sha256.convert(good).toString(),
      ),
      createClient: HttpClient.new,
    );
    final StreamSubscription<ModelDownloadEvent> sub = m.download().listen(
      (_) {},
    );
    await halfSent.future;
    await sub.cancel().timeout(const Duration(seconds: 10));
    expect(m.isReady, isFalse);
    expect(File('${m.weightsFile.path}.verified').existsSync(), isFalse);
  });

  test('全部来源失败：抛错并写明每个来源的失败原因，不留文件', () async {
    routes['/mirror/w.bin'] = Uint8List(good.length);
    final SrsRwkvModels m = models();
    Object? error;
    try {
      await m.download().drain<void>();
    } on SrsRwkvModelException catch (e) {
      error = e;
    }
    expect(error, isA<SrsRwkvModelException>());
    final String message = (error! as SrsRwkvModelException).message;
    expect(message, contains(url('/mirror/w.bin')));
    expect(message, contains('SHA-256'));
    expect(message, contains(url('/upstream/w.bin')));
    expect(m.isReady, isFalse);
    expect(m.weightsFile.existsSync(), isFalse);
    expect(File('${m.weightsFile.path}.part').existsSync(), isFalse);
  });

  test('默认权重：镜像首选、上游钉提交备用，退役清单含 sm72e25', () {
    expect(kSrsRwkvSmallWeights.urls, hasLength(2));
    expect(kSrsRwkvSmallWeights.url, startsWith(kSrsRwkvMirrorBase));
    expect(
      kSrsRwkvSmallWeights.urls.first,
      endsWith(
        '/${kSrsRwkvSmallWeightsSha256.substring(0, 16)}-sm98-weights.int8.bin',
      ),
    );
    expect(
      kSrsRwkvSmallWeights.urls.last,
      '$kSrsRwkvUpstreamBase/sm98/weights.int8.bin',
    );
    expect(kSrsRwkvRetiredWeightsNames, contains('sm72e25_weights.int8.bin'));
    expect(
      kSrsRwkvRetiredWeightsNames,
      isNot(contains(kSrsRwkvSmallWeightsName)),
    );
  });

  test('Tiny 档：sm101 权重，镜像首选、上游钉提交备用；与 Small 不同文件', () {
    expect(SrsRwkvModelSize.small.weights, same(kSrsRwkvSmallWeights));
    expect(SrsRwkvModelSize.tiny.weights, same(kSrsRwkvTinyWeights));
    expect(kSrsRwkvTinyWeights.fileName, 'sm101_weights.int8.bin');
    expect(kSrsRwkvTinyWeights.expectedBytes, 409483);
    expect(kSrsRwkvTinyWeights.urls, <String>[
      '$kSrsRwkvMirrorBase/${kSrsRwkvTinyWeightsSha256.substring(0, 16)}-sm101-weights.int8.bin',
      '$kSrsRwkvUpstreamBase/sm101/weights.int8.bin',
    ]);
    expect(
      kSrsRwkvRetiredWeightsNames,
      isNot(contains(kSrsRwkvTinyWeightsName)),
    );
    final SrsRwkvModels tiny = SrsRwkvModels(
      dir: dir,
      size: SrsRwkvModelSize.tiny,
    );
    expect(tiny.model, same(kSrsRwkvTinyWeights));
    expect(tiny.weightsFile.path, endsWith(kSrsRwkvTinyWeightsName));
    expect(SrsRwkvModels(dir: dir).size, SrsRwkvModelSize.small);
  });

  test('档位设置文件：缺失 / 认不出 → Small；写了就读回；每档一个快照目录', () async {
    expect(readSrsRwkvModelSize(dir), SrsRwkvModelSize.small);
    await writeSrsRwkvModelSize(dir, SrsRwkvModelSize.tiny);
    expect(srsRwkvModelSizeFile(dir).readAsStringSync(), 'tiny');
    expect(readSrsRwkvModelSize(dir), SrsRwkvModelSize.tiny);
    await writeSrsRwkvModelSize(dir, SrsRwkvModelSize.small);
    expect(readSrsRwkvModelSize(dir), SrsRwkvModelSize.small);
    srsRwkvModelSizeFile(dir).writeAsStringSync('huge\n');
    expect(readSrsRwkvModelSize(dir), SrsRwkvModelSize.small);
    expect(SrsRwkvModelSize.fromPersisted(' tiny\n'), SrsRwkvModelSize.tiny);
    expect(
      srsRwkvStateDir(dir).path,
      srsRwkvStateDir(dir, SrsRwkvModelSize.small).path,
    );
    expect(
      srsRwkvStateDir(dir, SrsRwkvModelSize.tiny).path,
      isNot(srsRwkvStateDir(dir).path),
    );
  });
}
