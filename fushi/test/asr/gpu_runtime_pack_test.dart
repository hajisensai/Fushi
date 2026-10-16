import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr_host/gpu_runtime_pack.dart';
import 'package:path/path.dart' as p;

/// 只回 Range 请求的本地文件服务；可让第一次取大块数据时中途断开（测续传）。
class _RangeServer {
  _RangeServer(this.body);

  final Uint8List body;
  late HttpServer _server;
  final List<String> ranges = <String>[];

  /// >0 时：第一个长度超过它的范围请求只回这么多字节就断开。
  int truncateOnceAfter = 0;

  /// true 时无视 Range，回 200 整包。
  bool ignoreRange = false;

  String get url => 'http://127.0.0.1:${_server.port}/pkg.zip';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((HttpRequest r) async {
      final String? range = r.headers.value(HttpHeaders.rangeHeader);
      ranges.add(range ?? '');
      final RegExpMatch? m = range == null
          ? null
          : RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range);
      if (ignoreRange || m == null) {
        r.response
          ..statusCode = 200
          ..contentLength = body.length
          ..add(body);
        await r.response.close();
        return;
      }
      final int start = int.parse(m.group(1)!);
      final int end = int.parse(m.group(2)!);
      final Uint8List slice = Uint8List.sublistView(body, start, end + 1);
      r.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${body.length}',
        )
        ..contentLength = slice.length;
      if (truncateOnceAfter > 0 && slice.length > truncateOnceAfter) {
        final int cut = truncateOnceAfter;
        truncateOnceAfter = 0;
        // 先摘下 socket（顺带写出头部），再写半截正文后直接掐断连接。
        final Socket socket = await r.response.detachSocket();
        socket.add(Uint8List.sublistView(slice, 0, cut));
        await socket.flush();
        socket.destroy();
        return;
      }
      r.response.add(slice);
      await r.response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

/// 固定种子的伪随机字节：deflate 压不动，压缩体与原文同量级。
Uint8List _bytes(int n, int seed) {
  final Random random = Random(seed);
  return Uint8List.fromList(
    List<int>.generate(n, (int _) => random.nextInt(256)),
  );
}

void main() {
  late Directory temp;
  late _RangeServer server;
  late Map<String, ZipFileHeader> headers;
  final Uint8List a = _bytes(200000, 31);
  final Uint8List b = _bytes(3000, 7);

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('gpu_runtime_pack_');
    final Archive zip = Archive()
      ..addFile(ArchiveFile('pkg/bin/a.dll', a.length, a))
      ..addFile(ArchiveFile.noCompress('pkg/bin/b.dll', b.length, b))
      ..addFile(ArchiveFile('pkg/bin/unused.dll', 2, <int>[7, 7]));
    final Uint8List zipBytes = Uint8List.fromList(ZipEncoder().encode(zip)!);
    headers = <String, ZipFileHeader>{
      for (final ZipFileHeader h in ZipDirectory.read(
        InputStream(zipBytes),
      ).fileHeaders)
        h.filename: h,
    };
    server = _RangeServer(zipBytes);
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  GpuRuntimeMember member(String path, Uint8List data, {String? sha}) =>
      GpuRuntimeMember(
        path: path,
        bytes: data.length,
        compressedBytes: headers[path]!.compressedSize!,
        sha256: sha ?? sha256.convert(data).toString(),
      );

  GpuRuntimeStore store({String? shaA}) => GpuRuntimeStore(
    temp,
    GpuRuntimeEnvironment(
      kind: GpuRuntimeKind.directml,
      version: 'test-1',
      archives: <GpuRuntimeArchive>[
        GpuRuntimeArchive(
          url: server.url,
          members: <GpuRuntimeMember>[
            member('pkg/bin/a.dll', a, sha: shaA),
            member('pkg/bin/b.dll', b),
          ],
        ),
      ],
    ),
    httpClient: HttpClient.new,
  );

  test('只按范围取清单成员（deflate + stored），核 sha256 后落到目录根', () async {
    final GpuRuntimeStore s = store();
    expect(s.isReady, isFalse);
    final List<GpuRuntimeInstallProgress> events = await s.install().toList();
    expect(events.last.phase, GpuRuntimeInstallPhase.done);
    expect(s.isReady, isTrue);
    expect(File(p.join(s.dir.path, 'a.dll')).readAsBytesSync(), a);
    expect(File(p.join(s.dir.path, 'b.dll')).readAsBytesSync(), b);
    expect(File(p.join(s.dir.path, 'unused.dll')).existsSync(), isFalse);
    expect(
      s.dir.listSync().map((FileSystemEntity e) => p.basename(e.path)),
      unorderedEquals(<String>['a.dll', 'b.dll', '.complete']),
    );
    // 每个请求都是范围请求，没有整包下载。
    expect(server.ranges, everyElement(startsWith('bytes=')));
    expect(s.dir.path, p.join(temp.path, 'directml', 'test-1'));
    expect(s.ortCorePath, p.join(s.dir.path, 'onnxruntime.dll'));
  });

  test('sha256 不符：抛错、删掉坏文件与压缩残留、不算就绪', () async {
    final GpuRuntimeStore s = store(shaA: '00' * 32);
    await expectLater(
      s.install().drain<void>(),
      throwsA(isA<GpuRuntimeCorruptException>()),
    );
    expect(s.isReady, isFalse);
    expect(File(p.join(s.dir.path, 'a.dll')).existsSync(), isFalse);
    expect(File(p.join(s.dir.path, 'a.dll.part')).existsSync(), isFalse);
    expect(
      File(p.join(s.dir.path, 'a.dll.deflate.part')).existsSync(),
      isFalse,
    );
  });

  test('中央目录与清单的大小不符：视为来源被换过，不下载数据', () async {
    final GpuRuntimeStore s = GpuRuntimeStore(
      temp,
      GpuRuntimeEnvironment(
        kind: GpuRuntimeKind.cuda,
        version: 'test-1',
        archives: <GpuRuntimeArchive>[
          GpuRuntimeArchive(
            url: server.url,
            members: <GpuRuntimeMember>[
              GpuRuntimeMember(
                path: 'pkg/bin/a.dll',
                bytes: a.length,
                compressedBytes: headers['pkg/bin/a.dll']!.compressedSize! + 1,
                sha256: sha256.convert(a).toString(),
              ),
            ],
          ),
        ],
      ),
      httpClient: HttpClient.new,
    );
    await expectLater(
      s.install().drain<void>(),
      throwsA(isA<GpuRuntimeCorruptException>()),
    );
    expect(
      File(p.join(s.dir.path, 'a.dll.deflate.part')).existsSync(),
      isFalse,
    );
  });

  test('下载中途断开：再装一次从断点续传', () async {
    expect(
      headers['pkg/bin/a.dll']!.compressedSize,
      greaterThan(100000),
      reason: '压缩体不超过断开点就不会断，本测试会空跑',
    );
    // 断开点要大于读中央目录时取的文件尾（≤ 65577 字节），只断成员数据。
    server.truncateOnceAfter = 100000;
    final GpuRuntimeStore s = store();
    await expectLater(s.install().drain<void>(), throwsA(anything));
    final File part = File(p.join(s.dir.path, 'a.dll.deflate.part'));
    expect(part.existsSync(), isTrue);
    final int have = part.lengthSync();
    expect(have, greaterThan(0));
    server.ranges.clear();
    await s.install().drain<void>();
    expect(s.isReady, isTrue);
    expect(File(p.join(s.dir.path, 'a.dll')).readAsBytesSync(), a);
    final int dataStart =
        headers['pkg/bin/a.dll']!.localHeaderOffset! +
        30 +
        'pkg/bin/a.dll'.length;
    expect(
      server.ranges.any(
        (String r) => r.startsWith('bytes=${dataStart + have}-'),
      ),
      isTrue,
      reason: '${server.ranges}',
    );
  });

  test('服务器不支持 Range：明确报错，不当成功', () async {
    server.ignoreRange = true;
    await expectLater(
      store().install().drain<void>(),
      throwsA(isA<HttpException>()),
    );
  });

  test('装好后某个 DLL 被截断：不再算就绪', () async {
    final GpuRuntimeStore s = store();
    await s.install().drain<void>();
    File(p.join(s.dir.path, 'b.dll')).writeAsBytesSync(<int>[9]);
    expect(s.isReady, isFalse);
  });

  test('真清单：成员名不重复、sha256 合法、关键 DLL 齐全', () {
    for (final GpuRuntimeEnvironment env in <GpuRuntimeEnvironment>[
      kCudaRuntimeEnvironment,
      kDirectMlRuntimeEnvironment,
    ]) {
      final Set<String> names = <String>{};
      for (final GpuRuntimeMember m in env.members) {
        expect(m.sha256, matches(RegExp(r'^[0-9a-f]{64}$')), reason: m.path);
        expect(m.compressedBytes, inInclusiveRange(1, m.bytes));
        expect(names.add(m.fileName), isTrue, reason: m.path);
      }
      expect(gpuRuntimeEnvironmentOf(env.kind), same(env));
    }
    expect(
      kCudaRuntimeEnvironment.members.map((GpuRuntimeMember m) => m.fileName),
      containsAll(<String>[
        'onnxruntime_providers_cuda.dll',
        'cublasLt64_13.dll',
        'cudnn64_9.dll',
      ]),
    );
    expect(
      kDirectMlRuntimeEnvironment.members.map(
        (GpuRuntimeMember m) => m.fileName,
      ),
      unorderedEquals(<String>['onnxruntime.dll', 'DirectML.dll']),
    );
  });
}
