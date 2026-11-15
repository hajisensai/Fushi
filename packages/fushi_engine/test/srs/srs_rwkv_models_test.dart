// SrsRwkvModels.download：按来源顺序（镜像 → 上游）下载，每个来源都只认字节数 + SHA-256，失败换下一个；
// 全部失败时错误信息逐个写明哪个来源、为什么失败。本地 HttpServer 充当两个来源，不碰网络。
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
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
}
