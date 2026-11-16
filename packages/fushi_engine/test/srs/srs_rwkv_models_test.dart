// RWKV 权重下载：换源、校验、钉点形态。服务器是本机 HttpServer，不碰外网。
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fushi_asr_core/asr_core.dart';
import 'package:fushi_engine/srs/srs_rwkv_models.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late Directory dir;
  final Uint8List weights = Uint8List.fromList(
    List<int>.generate(4096, (int i) => (i * 31) & 0xff),
  );
  final String weightsSha = sha256.convert(weights).toString();
  final List<String> requested = <String>[];

  setUp(() async {
    requested.clear();
    dir = Directory.systemTemp.createTempSync('rwkv_models_dl');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      requested.add(request.uri.path);
      switch (request.uri.path) {
        case '/good':
          request.response.contentLength = weights.length;
          request.response.add(weights);
        case '/wrong':
          // 同长度、内容不同：只有哈希能发现。
          request.response.contentLength = weights.length;
          request.response.add(Uint8List(weights.length));
        default:
          request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    dir.deleteSync(recursive: true);
  });

  SrsRwkvModels models(
    String primary, [
    List<String> fallbacks = const <String>[],
  ]) {
    String url(String path) => 'http://127.0.0.1:${server.port}$path';
    return SrsRwkvModels(
      dir: dir,
      createClient: HttpClient.new,
      file: SrsRwkvModelFile(
        fileName: 'w.int8.bin',
        url: url(primary),
        expectedBytes: weights.length,
        sha256: weightsSha,
        fallbackUrls: fallbacks.map(url).toList(),
      ),
    );
  }

  test('首选源下载并校验后就绪', () async {
    final SrsRwkvModels m = models('/good');
    expect(m.isReady, isFalse);
    final List<ModelDownloadEvent> events = await m.download().toList();
    expect(events.last.done, isTrue);
    expect(m.isReady, isTrue);
    expect(m.weightsFile.readAsBytesSync(), weights);
    expect(requested, <String>['/good']);
  });

  test('首选源 404 时换到备用源', () async {
    final SrsRwkvModels m = models('/gone', <String>['/good']);
    await m.download().drain<void>();
    expect(m.isReady, isTrue);
    expect(m.weightsFile.readAsBytesSync(), weights);
    expect(requested, containsAllInOrder(<String>['/gone', '/good']));
  });

  test('字节数对但内容不对：删掉文件并报 SHA-256 不符', () async {
    final SrsRwkvModels m = models('/wrong');
    await expectLater(
      m.download().drain<void>(),
      throwsA(
        isA<SrsRwkvModelException>().having(
          (SrsRwkvModelException e) => e.message,
          'message',
          contains('SHA-256 mismatch'),
        ),
      ),
    );
    expect(m.isReady, isFalse);
    expect(m.weightsFile.existsSync(), isFalse);
  });

  test('钉点不指向可被原地替换的上游 release 资产', () {
    // 上游 2026-11-13 原地替换过所有旧 release 的 zip，钉在那里的版本从此下载失败。
    // 允许的只有：本仓库的内容寻址镜像、钉死提交的 raw 文件。
    const SrsRwkvModelFile file = kSrsRwkvSmallWeights;
    final String prefix = file.sha256.substring(0, 16);
    expect(
      file.url,
      startsWith(
        'https://github.com/hajisensai/Fushi/releases/download/rwkv-models/$prefix-',
      ),
    );
    expect(file.fallbackUrls, isNotEmpty);
    for (final String url in file.fallbackUrls) {
      expect(
        url,
        matches(
          RegExp(
            r'^https://raw\.githubusercontent\.com/[^/]+/[^/]+/[0-9a-f]{40}/',
          ),
        ),
      );
    }
    expect(file.expectedBytes, kSrsRwkvSmallWeightsBytes);
  });
}
