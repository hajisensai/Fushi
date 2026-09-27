// 真隧道端到端：同进程两个 iroh 端点，主机 hostListen → 本地 HTTP 服务，
// 客户端 clientForward → 本地转发口，经转发口打并发 HTTP / 多 MB Range / 半关闭。
//
// 需要原生库：`FUSHI_P2P_LIB=<.../fushi_p2p.dll> dart test`；库缺失时整组 skip。
// 用直连地址提示拨号，不依赖 n0 DNS 发现（离线也能跑）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_p2p/fushi_p2p.dart';
import 'package:test/test.dart';

const int _blobSize = 8 * 1024 * 1024;

Uint8List _makeBlob() {
  final Uint8List b = Uint8List(_blobSize);
  int x = 0x12345678;
  for (int i = 0; i < b.length; i++) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    b[i] = x >> 16;
  }
  return b;
}

Future<HttpServer> _startHttp(Uint8List blob) async {
  final HttpServer server = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  server.listen((HttpRequest req) async {
    final HttpResponse res = req.response;
    if (req.uri.path == '/echo') {
      final List<int> body = await req.fold<List<int>>(
        <int>[],
        (List<int> a, List<int> c) => a..addAll(c),
      );
      res.headers.contentType = ContentType.binary;
      res.add(<int>[
        ...utf8.encode('${req.uri.queryParameters['i']}:'),
        ...body,
      ]);
    } else if (req.uri.path == '/blob') {
      final String? range = req.headers.value(HttpHeaders.rangeHeader);
      final RegExpMatch m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range!)!;
      final int start = int.parse(m.group(1)!);
      final int end = int.parse(m.group(2)!);
      res.statusCode = HttpStatus.partialContent;
      res.headers
        ..set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${blob.length}',
        )
        ..contentLength = end - start + 1;
      res.add(Uint8List.sublistView(blob, start, end + 1));
    } else {
      res.statusCode = HttpStatus.notFound;
    }
    await res.close();
  });
  return server;
}

Future<(int, Uint8List)> _request(
  HttpClient client,
  String method,
  Uri uri, {
  List<int>? body,
  Map<String, String> headers = const <String, String>{},
}) async {
  final HttpClientRequest req = await client.openUrl(method, uri);
  headers.forEach(req.headers.set);
  if (body != null) {
    req.contentLength = body.length;
    req.add(body);
  }
  final HttpClientResponse res = await req.close();
  final BytesBuilder bb = BytesBuilder(copy: false);
  await for (final List<int> chunk in res) {
    bb.add(chunk);
  }
  return (res.statusCode, bb.takeBytes());
}

Future<List<String>> _waitDirectAddrs(FushiP2pEndpoint ep) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
  while (true) {
    final List<String> addrs = ep.info().directAddrs;
    if (addrs.isNotEmpty || DateTime.now().isAfter(deadline)) return addrs;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  final FushiP2p? lib = FushiP2p.tryLoad();
  final Object? skip = lib == null
      ? 'fushi_p2p native library not found (set FUSHI_P2P_LIB)'
      : null;

  test(
    '库缺失时 tryLoad 返回 null、isAvailable 为 false（干净子进程）',
    () async {
      final Directory empty = Directory.systemTemp.createTempSync(
        'fp2p_missing',
      );
      try {
        final ProcessResult r = await Process.run(
          Platform.resolvedExecutable,
          <String>['run', 'test/fixtures/missing_lib_probe.dart', empty.path],
          environment: const <String, String>{kFushiP2pLibEnv: ''},
        );
        expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
        expect(r.stdout as String, contains('tryLoad=null'));
        expect(r.stdout as String, contains('isAvailable=false'));
      } finally {
        empty.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test('候选顺序：显式路径 → 环境变量 → exe 同级 → bin/../lib → 裸名', () {
    final String sep = Platform.pathSeparator;
    final String name = FushiP2p.defaultLibraryName();
    final String root = '${Directory.systemTemp.path}${sep}fp2p_order';
    final List<String> c = FushiP2p.libraryCandidates(
      libraryPath: 'explicit',
      environment: const <String, String>{kFushiP2pLibEnv: 'from_env'},
      executablePath: '$root${sep}bin${sep}fushi_server',
    );
    expect(c, <String>[
      'explicit',
      'from_env',
      '$root${sep}bin$sep$name',
      File('$root${sep}bin$sep..${sep}lib$sep$name').absolute.path,
      name,
    ]);
  });

  group(
    'iroh 隧道',
    () {
      late Uint8List blob;
      late HttpServer http;
      late FushiP2pEndpoint host;
      late FushiP2pEndpoint client;
      late int forwardPort;
      late HttpClient httpClient;

      setUpAll(() async {
        blob = _makeBlob();
        http = await _startHttp(blob);
        host = FushiP2pEndpoint.create(library: lib);
        client = FushiP2pEndpoint.create(library: lib);
        host.hostListen(http.port);
        final List<String> addrs = await _waitDirectAddrs(host);
        expect(addrs, isNotEmpty, reason: 'host has no direct addrs');
        forwardPort = client.clientForward(
          host.info().nodeId,
          directAddrs: addrs,
        );
        httpClient = HttpClient()..maxConnectionsPerHost = 16;
      });

      tearDownAll(() async {
        httpClient.close(force: true);
        await Future.wait(<Future<void>>[
          client.closeAsync(),
          host.closeAsync(),
        ]);
        expect(client.isClosed && host.isClosed, isTrue);
        expect(() => host.info(), throwsA(isA<FushiP2pException>()));
        await http.close(force: true);
      });

      test('端点信息与私钥往返', () {
        final FushiP2pInfo info = host.info();
        expect(info.nodeId, matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(info.secretKeyHex, matches(RegExp(r'^[0-9a-f]{64}$')));
        final FushiP2pEndpoint again = FushiP2pEndpoint.create(
          library: lib,
          secretKeyHex: info.secretKeyHex,
        );
        try {
          expect(again.info().nodeId, info.nodeId);
        } finally {
          again.close();
        }
        expect(
          () => FushiP2pEndpoint.create(library: lib, secretKeyHex: 'zz'),
          throwsA(isA<FushiP2pException>()),
        );
      });

      test('并发 HTTP 请求逐字节正确', () async {
        final Uri base = Uri.parse('http://127.0.0.1:$forwardPort');
        final List<Future<void>> jobs = <Future<void>>[
          for (int i = 0; i < 24; i++)
            () async {
              final List<int> payload = List<int>.generate(
                1000 + i * 997,
                (int k) => (k * 31 + i) & 0xff,
              );
              final (int code, Uint8List got) = await _request(
                httpClient,
                'POST',
                base.replace(
                  path: '/echo',
                  queryParameters: <String, String>{'i': '$i'},
                ),
                body: payload,
              );
              expect(code, 200);
              expect(got, <int>[...utf8.encode('$i:'), ...payload]);
            }(),
        ];
        await Future.wait(jobs);
      });

      test('多 MB 请求体回显 + Range 取块逐字节正确', () async {
        final Uri base = Uri.parse('http://127.0.0.1:$forwardPort');
        final Uint8List upload = Uint8List.sublistView(
          blob,
          0,
          3 * 1024 * 1024,
        );
        final (int c1, Uint8List echoed) = await _request(
          httpClient,
          'POST',
          base.replace(
            path: '/echo',
            queryParameters: <String, String>{'i': 'big'},
          ),
          body: upload,
        );
        expect(c1, 200);
        expect(echoed.length, upload.length + 4);
        expect(Uint8List.sublistView(echoed, 4), upload);

        final List<(int, int)> ranges = <(int, int)>[
          (0, _blobSize - 1),
          (1000001, 6000000),
          (_blobSize - 12345, _blobSize - 1),
        ];
        final List<(int, Uint8List)> results = await Future.wait(
          <Future<(int, Uint8List)>>[
            for (final (int s, int e) in ranges)
              _request(
                httpClient,
                'GET',
                base.replace(path: '/blob'),
                headers: <String, String>{'Range': 'bytes=$s-$e'},
              ),
          ],
        );
        for (int i = 0; i < ranges.length; i++) {
          final (int s, int e) = ranges[i];
          expect(results[i].$1, 206);
          expect(results[i].$2.length, e - s + 1);
          expect(results[i].$2, Uint8List.sublistView(blob, s, e + 1));
        }
      });

      test('半关闭：客户端先关写端，仍能收完服务端回写', () async {
        // 原始 TCP 回显：读到 EOF 后才把全部内容反转写回。
        final ServerSocket echo = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        echo.listen((Socket s) async {
          final BytesBuilder bb = BytesBuilder();
          await for (final Uint8List c in s) {
            bb.add(c);
          }
          s.add(bb.takeBytes().reversed.toList());
          await s.flush();
          await s.close();
        });
        host.hostListen(echo.port);
        try {
          final Socket s = await Socket.connect(
            InternetAddress.loopbackIPv4,
            forwardPort,
          );
          final Uint8List payload = Uint8List.sublistView(blob, 0, 512 * 1024);
          s.add(payload);
          await s.flush();
          await s.close(); // 只关写端。
          final BytesBuilder got = BytesBuilder();
          await for (final Uint8List c in s) {
            got.add(c);
          }
          expect(got.takeBytes(), payload.reversed.toList());
        } finally {
          host.hostListen(http.port);
          await echo.close();
        }
      });

      test('连接状态：同机直连', () {
        final FushiP2pConnStatus st = client.status(host.info().nodeId);
        expect(st.connected, isTrue);
        expect(st.directPaths, greaterThan(0));
        expect(st.path, anyOf(FushiP2pPathKind.direct, FushiP2pPathKind.mixed));
        final FushiP2pConnStatus unknown = client.status(client.info().nodeId);
        expect(unknown.connected, isFalse);
        expect(unknown.path, FushiP2pPathKind.none);
        // ignore: avoid_print
        print(
          'status: path=${st.path.name} rtt=${st.rttMs}ms '
          'direct=${st.directPaths} relay=${st.relayPaths}',
        );
      });

      test('停止转发口后本地端口不再接受连接', () async {
        final int port = client.clientForward(
          host.info().nodeId,
          directAddrs: host.info().directAddrs,
        );
        expect(client.stopForward(port), isTrue);
        expect(client.stopForward(port), isFalse);
        await expectLater(
          Socket.connect(
            InternetAddress.loopbackIPv4,
            port,
            timeout: const Duration(seconds: 2),
          ),
          throwsA(isA<SocketException>()),
        );
      });
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
