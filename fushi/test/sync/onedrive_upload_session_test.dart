// 反馈 xQVvACx8mY：OneDrive 每次同步都把整本有声书重传。根因是大文件走单请求
// `PUT :/content`，一次断流整份作废、远端始终没有该资产。这里钉死改走 Graph 上传会话
// 后的协议行为：分片、断流后按服务端 nextExpectedRanges 续传、不重传已确认字节。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fushi/src/sync/onedrive_upload_session.dart';
import 'package:fushi/src/sync/sync_backend.dart';

/// 按 Graph 上传会话语义行事的假服务端。
class _FakeSession {
  _FakeSession(this.total);

  final int total;
  final BytesBuilder received = BytesBuilder(copy: true);
  final List<String> ranges = <String>[];
  final List<String> methods = <String>[];
  final List<Map<String, String>> putHeaders = <Map<String, String>>[];

  /// 第 N 次 PUT（从 0 计）的故障注入：
  /// 'dropAfterAccept' = 字节已落地但响应丢失（连接重置）；
  /// 'dropBeforeAccept' = 字节没落地就断；'500' = 服务端 5xx。
  final Map<int, String> faults = <int, String>{};
  bool sessionGone = false;
  bool alwaysDrop = false;
  int _puts = 0;

  int get got => received.length;

  String _status() => jsonEncode(<String, Object>{
    'expirationDateTime': '2099-01-01T00:00:00Z',
    'nextExpectedRanges': <String>['$got-'],
  });

  Future<http.Response> handle(http.Request req) async {
    methods.add(req.method);
    if (sessionGone) return http.Response('', 404);
    if (req.method == 'GET') return http.Response(_status(), 200);
    if (req.method == 'DELETE') return http.Response('', 204);
    expect(req.method, 'PUT');
    final int n = _puts++;
    putHeaders.add(Map<String, String>.of(req.headers));
    final String range = req.headers['content-range']!;
    ranges.add(range);
    final RegExpMatch m = RegExp(
      r'^bytes (\d+)-(\d+)/(\d+)$',
    ).firstMatch(range)!;
    final int start = int.parse(m.group(1)!);
    final int end = int.parse(m.group(2)!);
    expect(int.parse(m.group(3)!), total);
    expect(req.bodyBytes.length, end - start + 1);
    final String? fault = alwaysDrop ? 'dropBeforeAccept' : faults[n];
    if (fault == 'dropBeforeAccept') {
      throw http.ClientException('Connection reset by peer');
    }
    if (fault == '500') return http.Response('busy', 503);
    if (start != got) return http.Response('out of order', 416);
    received.add(req.bodyBytes);
    if (fault == 'dropAfterAccept') {
      throw http.ClientException('Broken pipe');
    }
    if (got == total) {
      return http.Response(
        jsonEncode(<String, Object>{'id': 'item1', 'size': total}),
        201,
      );
    }
    return http.Response(_status(), 202);
  }
}

void main() {
  late Directory tmp;
  late File file;
  late Uint8List content;
  const int chunk = 320 * 1024;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('onedrive_session_test');
    content = Uint8List.fromList(
      List<int>.generate(chunk * 3 + 1234, (int i) => (i * 31) & 0xff),
    );
    file = File('${tmp.path}/audiobook.fushiaudio')..writeAsBytesSync(content);
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  test('大文件阈值与分片大小符合 Graph 约束（320 KiB 整数倍、< 60 MiB）', () {
    expect(kOneDriveUploadChunkBytes % (320 * 1024), 0);
    expect(kOneDriveUploadChunkBytes, lessThan(60 * 1024 * 1024));
    expect(kOneDriveSimpleUploadMaxBytes, lessThanOrEqualTo(250 * 1000 * 1000));
  });

  test('分片顺序上传完整文件，uploadUrl 请求不带 Authorization', () async {
    final _FakeSession s = _FakeSession(content.length);
    final List<double> progress = <double>[];
    final Map<String, dynamic> item = await uploadFileToOneDriveSession(
      client: MockClient(s.handle),
      uploadUrl: Uri.parse('https://up.example/session'),
      file: file,
      chunkBytes: chunk,
      onProgress: (double f, [int? _]) => progress.add(f),
      sleep: (_) async {},
    );
    expect(item['id'], 'item1');
    expect(s.received.toBytes(), content);
    expect(s.ranges, <String>[
      'bytes 0-${chunk - 1}/${content.length}',
      'bytes $chunk-${2 * chunk - 1}/${content.length}',
      'bytes ${2 * chunk}-${3 * chunk - 1}/${content.length}',
      'bytes ${3 * chunk}-${content.length - 1}/${content.length}',
    ]);
    for (final Map<String, String> h in s.putHeaders) {
      expect(
        h.keys.map((String k) => k.toLowerCase()),
        isNot(contains('authorization')),
      );
    }
    expect(progress.last, 1);
    for (int i = 1; i < progress.length; i++) {
      expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
    }
  });

  test('断流后按服务端 nextExpectedRanges 续传，已确认字节不重传', () async {
    final _FakeSession s = _FakeSession(content.length)
      ..faults[1] =
          'dropAfterAccept' // 第二片落地但响应丢失
      ..faults[2] =
          'dropBeforeAccept' // 第三片没落地就断
      ..faults[3] = '500';
    final List<Duration> sleeps = <Duration>[];
    await uploadFileToOneDriveSession(
      client: MockClient(s.handle),
      uploadUrl: Uri.parse('https://up.example/session'),
      file: file,
      chunkBytes: chunk,
      sleep: (Duration d) async => sleeps.add(d),
    );
    expect(s.received.toBytes(), content);
    // 第二片落地后不会再传一次 `bytes chunk-...`：续传直接从第三片开始。
    expect(
      s.ranges.where((String r) => r.startsWith('bytes $chunk-')).length,
      1,
    );
    // 断流后都先 GET 会话状态再续传。
    expect(s.methods.where((String m) => m == 'GET').length, 3);
    expect(sleeps, hasLength(1)); // 只有 5xx 退避
  });

  test('持续无进展时放弃并取消会话，抛 SyncBackendError', () async {
    final _FakeSession s = _FakeSession(content.length)..alwaysDrop = true;
    await expectLater(
      uploadFileToOneDriveSession(
        client: MockClient(s.handle),
        uploadUrl: Uri.parse('https://up.example/session'),
        file: file,
        chunkBytes: chunk,
        maxStalledAttempts: 3,
        sleep: (_) async {},
      ),
      throwsA(isA<SyncBackendError>()),
    );
    expect(s.ranges, hasLength(3));
    expect(s.methods.last, 'DELETE');
  });

  test('会话 404（已失效）直接失败，不在死会话上打转', () async {
    final _FakeSession s = _FakeSession(content.length)..sessionGone = true;
    await expectLater(
      uploadFileToOneDriveSession(
        client: MockClient(s.handle),
        uploadUrl: Uri.parse('https://up.example/session'),
        file: file,
        chunkBytes: chunk,
        sleep: (_) async {},
      ),
      throwsA(isA<SyncBackendError>()),
    );
    expect(s.methods.where((String m) => m == 'PUT').length, 1);
    expect(s.methods, isNot(contains('GET')));
  });

  test('parseOneDriveNextExpectedOffset', () {
    expect(
      parseOneDriveNextExpectedOffset('{"nextExpectedRanges":["26-"]}'),
      26,
    );
    expect(
      parseOneDriveNextExpectedOffset('{"nextExpectedRanges":["5-99","200-"]}'),
      5,
    );
    expect(parseOneDriveNextExpectedOffset('{}'), isNull);
    expect(parseOneDriveNextExpectedOffset('not json'), isNull);
  });
}
