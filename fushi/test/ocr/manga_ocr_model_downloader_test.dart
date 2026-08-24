import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ocr/manga_ocr_model_downloader.dart';
import 'package:fushi/src/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi/src/ocr/manga_ocr_service.dart';
import 'package:path/path.dart' as p;

/// 本地 HTTP 服务器 fake：按路径提供字节流，可开关 Range 支持，记录请求。
class _ModelServer {
  _ModelServer(this.server, this.payloads) {
    server.listen(_handle);
  }

  final HttpServer server;
  final Map<String, List<int>> payloads;
  final List<String> requestedPaths = <String>[];
  final List<String?> rangeHeaders = <String?>[];
  bool supportRange = true;

  static Future<_ModelServer> start(Map<String, List<int>> payloads) async {
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _ModelServer(server, payloads);
  }

  String urlFor(String path) => 'http://127.0.0.1:${server.port}$path';

  Future<void> close() => server.close(force: true);

  void _handle(HttpRequest request) {
    final String path = request.uri.path;
    requestedPaths.add(path);
    final String? range = request.headers.value(HttpHeaders.rangeHeader);
    rangeHeaders.add(range);
    final List<int>? payload = payloads[path];
    if (payload == null) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.close();
      return;
    }
    if (range != null && supportRange) {
      final RegExpMatch? match =
          RegExp(r'^bytes=(\d+)-$').firstMatch(range.trim());
      final int offset = match == null ? 0 : int.parse(match.group(1)!);
      if (offset >= payload.length) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.partialContent;
      request.response.contentLength = payload.length - offset;
      request.response.add(payload.sublist(offset));
      request.response.close();
      return;
    }
    request.response.statusCode = HttpStatus.ok;
    request.response.contentLength = payload.length;
    request.response.add(payload);
    request.response.close();
  }
}

MangaOcrModelDownloader _downloader({
  int interval = 4,
  List<String> Function(MangaOcrModelFile file)? urlCandidates,
}) =>
    MangaOcrModelDownloader(
      // 测试直连 loopback，绕开环境代理变量（生产默认 findProxyFromEnvironment）。
      createClient: HttpClient.new,
      urlCandidates: urlCandidates,
      progressByteInterval: interval,
    );

List<int> _bytes(int length, [int seed = 0]) =>
    List<int>.generate(length, (int i) => (i + seed) % 251);

void main() {
  late Directory tempDir;
  late _ModelServer server;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('manga_ocr_dl_');
    server = await _ModelServer.start(<String, List<int>>{});
  });

  tearDown(() async {
    await server.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  MangaOcrModelFile file(String name, int size,
          {MangaOcrModelRole role = MangaOcrModelRole.detector}) =>
      MangaOcrModelFile(
        fileName: name,
        url: server.urlFor('/$name'),
        expectedBytes: size,
        role: role,
      );

  test('全新下载：分段进度事件、.part 原子 rename、末尾 done=true', () async {
    final List<int> payload = _bytes(16);
    server.payloads['/a.onnx'] = payload;

    final List<MangaOcrDownloadEvent> events = await _downloader().downloadAll(
      files: <MangaOcrModelFile>[file('a.onnx', 16)],
      targetDir: tempDir,
    ).toList();

    // 首事件 0 字节起步，中途有分段进度，完成事件 received==total。
    expect(events.first.receivedBytes, 0);
    expect(events.first.fileName, 'a.onnx');
    expect(
        events.where((MangaOcrDownloadEvent e) => !e.done).last.receivedBytes,
        16);
    expect(events.length, greaterThanOrEqualTo(3),
        reason: 'progressByteInterval=4 的 16 字节下载必须有中间分段事件');
    // 收尾 done=true 恰好一次且在最后。
    expect(events.last.done, isTrue);
    expect(events.where((MangaOcrDownloadEvent e) => e.done), hasLength(1));

    final File target = File(p.join(tempDir.path, 'a.onnx'));
    expect(target.existsSync(), isTrue);
    expect(target.readAsBytesSync(), payload);
    expect(File('${target.path}.part').existsSync(), isFalse,
        reason: '.part 必须已原子 rename 成最终名');
  });

  test('已就绪文件跳过：不发 HTTP 请求，仍发完成进度 + done', () async {
    final File target = File(p.join(tempDir.path, 'a.onnx'));
    target.writeAsBytesSync(_bytes(16));

    final List<MangaOcrDownloadEvent> events = await _downloader().downloadAll(
      files: <MangaOcrModelFile>[file('a.onnx', 16)],
      targetDir: tempDir,
    ).toList();

    expect(server.requestedPaths, isEmpty, reason: '就绪文件绝不重下');
    expect(events.first.receivedBytes, 16);
    expect(events.first.totalBytes, 16);
    expect(events.last.done, isTrue);
  });

  test('断点续传：.part 残留触发 Range，从偏移续写', () async {
    final List<int> payload = _bytes(32);
    server.payloads['/a.onnx'] = payload;
    File(p.join(tempDir.path, 'a.onnx.part'))
        .writeAsBytesSync(payload.sublist(0, 10));

    final List<MangaOcrDownloadEvent> events = await _downloader().downloadAll(
      files: <MangaOcrModelFile>[file('a.onnx', 32)],
      targetDir: tempDir,
    ).toList();

    expect(server.rangeHeaders.single, 'bytes=10-');
    // 首事件从已存偏移起步（不是 0）。
    expect(events.first.receivedBytes, 10);
    expect(events.first.totalBytes, 32);
    final File target = File(p.join(tempDir.path, 'a.onnx'));
    expect(target.readAsBytesSync(), payload, reason: '续传拼接后内容必须逐字节正确');
  });

  test('服务器不支持 Range（回 200）：截断残留整文件重下，内容仍正确', () async {
    final List<int> payload = _bytes(32);
    server.payloads['/a.onnx'] = payload;
    server.supportRange = false;
    // 故意放一段**错误**残留：若实现未截断，内容校验会揭穿。
    File(p.join(tempDir.path, 'a.onnx.part')).writeAsBytesSync(_bytes(10, 7));

    await _downloader().downloadAll(
      files: <MangaOcrModelFile>[file('a.onnx', 32)],
      targetDir: tempDir,
    ).drain<void>();

    expect(File(p.join(tempDir.path, 'a.onnx')).readAsBytesSync(), payload);
  });

  test('.part 已完整（rename 前中断、服务器回 416）：不重拉流直接转正', () async {
    final List<int> payload = _bytes(32);
    server.payloads['/a.onnx'] = payload;
    File(p.join(tempDir.path, 'a.onnx.part')).writeAsBytesSync(payload);

    final List<MangaOcrDownloadEvent> events = await _downloader().downloadAll(
      files: <MangaOcrModelFile>[file('a.onnx', 32)],
      targetDir: tempDir,
    ).toList();

    expect(File(p.join(tempDir.path, 'a.onnx')).readAsBytesSync(), payload);
    expect(events.last.done, isTrue);
  });

  test('长度不符：流以 error 结束，坏 .part 被清除、不转正', () async {
    server.payloads['/a.onnx'] = _bytes(16);

    await expectLater(
      _downloader().downloadAll(
        // 清单期望 99 字节，服务器只给 16 → 校验失败。
        files: <MangaOcrModelFile>[file('a.onnx', 99)],
        targetDir: tempDir,
      ).drain<void>(),
      throwsA(isA<StateError>()),
    );
    expect(File(p.join(tempDir.path, 'a.onnx')).existsSync(), isFalse);
    expect(File(p.join(tempDir.path, 'a.onnx.part')).existsSync(), isFalse,
        reason: '长度不符的 .part 必须删除，避免下次在坏偏移上续传');
  });

  test('多文件：事件按文件粒度推进，done 只在全部完成后', () async {
    server.payloads['/a.onnx'] = _bytes(8);
    server.payloads['/b.txt'] = _bytes(6, 3);

    final List<MangaOcrDownloadEvent> events = await _downloader().downloadAll(
      files: <MangaOcrModelFile>[
        file('a.onnx', 8),
        file('b.txt', 6, role: MangaOcrModelRole.recognizer),
      ],
      targetDir: tempDir,
    ).toList();

    final int lastAIndex = events.lastIndexWhere(
        (MangaOcrDownloadEvent e) => e.fileName == 'a.onnx' && !e.done);
    final int firstBIndex =
        events.indexWhere((MangaOcrDownloadEvent e) => e.fileName == 'b.txt');
    expect(lastAIndex, lessThan(firstBIndex), reason: '文件按清单顺序串行下载');
    expect(events.last.done, isTrue);
    expect(File(p.join(tempDir.path, 'a.onnx')).lengthSync(), 8);
    expect(File(p.join(tempDir.path, 'b.txt')).lengthSync(), 6);
  });

  test('主源失败换镜像：第二候选下完并转正，第一候选的失败不外泄', () async {
    // 主源路径故意不提供内容（404），镜像路径提供完整字节。
    server.payloads['/mirror-a.onnx'] = _bytes(12);

    final MangaOcrModelFile target = file('a.onnx', 12);
    final List<MangaOcrDownloadEvent> events = await _downloader(
      urlCandidates: (MangaOcrModelFile f) => <String>[
        server.urlFor('/a.onnx'),
        server.urlFor('/mirror-a.onnx'),
      ],
    ).downloadAll(
      files: <MangaOcrModelFile>[target],
      targetDir: tempDir,
    ).toList();

    expect(File(p.join(tempDir.path, 'a.onnx')).lengthSync(), 12);
    expect(events.last.done, isTrue);
    expect(server.requestedPaths, contains('/a.onnx'));
    expect(server.requestedPaths, contains('/mirror-a.onnx'),
        reason: '主源 404 后必须真的去打镜像，而不是直接失败');
  });

  test('全部候选都失败：抛错，不留半个转正文件', () async {
    final MangaOcrModelFile target = file('a.onnx', 12);
    await expectLater(
      _downloader(
        urlCandidates: (MangaOcrModelFile f) => <String>[
          server.urlFor('/missing-1.onnx'),
          server.urlFor('/missing-2.onnx'),
        ],
      )
          .downloadAll(
            files: <MangaOcrModelFile>[target],
            targetDir: tempDir,
          )
          .toList(),
      throwsA(isA<HttpException>()),
    );
    expect(File(p.join(tempDir.path, 'a.onnx')).existsSync(), isFalse);
    expect(server.requestedPaths,
        containsAll(<String>['/missing-1.onnx', '/missing-2.onnx']),
        reason: '候选序列要走完才算失败');
  });

  group('候选 URL 派生', () {
    test('huggingface 主源派生出镜像，顺序是主源在前', () {
      const MangaOcrModelFile model = MangaOcrModelFile(
        fileName: 'x.onnx',
        url: 'https://huggingface.co/owner/repo/resolve/main/x.onnx',
        expectedBytes: 1,
        role: MangaOcrModelRole.detector,
      );
      final List<String> candidates = mangaOcrModelUrlCandidates(model);
      expect(candidates.first, model.url);
      expect(candidates.length, kMangaOcrModelMirrorHosts.length + 1);
      for (int i = 0; i < kMangaOcrModelMirrorHosts.length; i++) {
        expect(
          candidates[i + 1],
          'https://${kMangaOcrModelMirrorHosts[i]}/owner/repo/resolve/main/x.onnx',
          reason: '镜像与主源路径同构，只换 host',
        );
      }
    });

    test('非 huggingface 的 URL 不派生镜像', () {
      const MangaOcrModelFile model = MangaOcrModelFile(
        fileName: 'x.onnx',
        url: 'http://127.0.0.1:8080/x.onnx',
        expectedBytes: 1,
        role: MangaOcrModelRole.detector,
      );
      expect(mangaOcrModelUrlCandidates(model), <String>[model.url]);
    });

    test('真实清单每条都能派生出镜像候选', () {
      for (final MangaOcrModelFile model in kMangaOcrModelManifest) {
        expect(mangaOcrModelUrlCandidates(model).length,
            kMangaOcrModelMirrorHosts.length + 1,
            reason: '${model.fileName} 少了镜像候选');
      }
    });
  });
}
