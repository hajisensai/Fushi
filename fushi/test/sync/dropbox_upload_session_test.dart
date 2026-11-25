// Dropbox 大文件走 upload session：单次 `files/upload` 上限 150 MB，超过门槛的文件
// 改成 `upload_session/start` → 逐块 `append_v2` → `finish`。这里用测试注入把门槛与
// 块大小调到几个字节，钉住：小文件仍是一次 `files/upload`；大文件的偏移 / 块大小 /
// commit 字段；`incorrect_offset` 按 `correct_offset` 续传（append 与 finish 两种
// 形状）；瞬时 5xx 重试同一块并采信 `Retry-After`；持续 5xx 有界放弃。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/dropbox_sync_backend.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_http.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 一次被假客户端收到的请求。
class _Call {
  _Call(this.endpoint, this.arg, this.body);

  /// `/2/` 之后的路径，如 `files/upload_session/append_v2`。
  final String endpoint;
  final Map<String, dynamic> arg;
  final Uint8List body;

  int? get offset =>
      ((arg['cursor'] as Map<String, dynamic>?)?['offset'] as num?)?.toInt();
}

typedef _Responder = http.Response? Function(_Call call, int index);

http.Response _json(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

http.Response _incorrectOffset(int correct) => _json(<String, Object>{
  'error_summary': 'incorrect_offset/..',
  'error': <String, Object>{
    '.tag': 'incorrect_offset',
    'correct_offset': correct,
  },
}, status: 409);

void main() {
  late Directory tmp;
  late List<_Call> calls;
  late List<Duration> sleeps;

  /// 装上假客户端：[responder] 返回 null 时按正常成功应答。
  void install([_Responder? responder]) {
    debugSetSyncHttpClient(
      MockClient((http.Request req) async {
        final String endpoint = req.url.path.replaceFirst('/2/', '');
        expect(req.url.host, 'content.dropboxapi.com');
        expect(req.headers['Authorization'], 'Bearer t');
        expect(req.headers['Content-Type'], 'application/octet-stream');
        final _Call call = _Call(
          endpoint,
          jsonDecode(req.headers['Dropbox-API-Arg']!) as Map<String, dynamic>,
          req.bodyBytes,
        );
        calls.add(call);
        final http.Response? custom = responder?.call(call, calls.length - 1);
        if (custom != null) return custom;
        if (endpoint == 'files/upload_session/start') {
          return _json(<String, Object>{'session_id': 'sess-1'});
        }
        return _json(<String, Object>{'name': 'x'});
      }),
    );
  }

  Future<File> writeFile(int length) async {
    final File f = File('${tmp.path}/data.bin');
    await f.writeAsBytes(
      List<int>.generate(length, (int i) => i % 251, growable: false),
    );
    return f;
  }

  Future<void> upload(
    File file, {
    void Function(double fraction, [int? bytes])? onProgress,
  }) => DropboxSyncBackend.instance.uploadContentFile(
    folderId: '/fushi-data/backups',
    fileName: 'backup.zip',
    file: file,
    onProgress: onProgress,
  );

  const Map<String, Object> expectedCommit = <String, Object>{
    'path': '/fushi-data/backups/backup.zip',
    'mode': 'overwrite',
    'autorename': false,
    'mute': true,
  };

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dbx_session_test');
    calls = <_Call>[];
    sleeps = <Duration>[];
    DropboxSyncBackend.instance.debugSetAccessToken('t');
    DropboxSyncBackend.debugUploadSessionThresholdBytes = 16;
    DropboxSyncBackend.debugUploadSessionChunkBytes = 8;
    DropboxSyncBackend.debugUploadRetrySleep = (Duration d) async {
      sleeps.add(d);
    };
  });

  tearDown(() async {
    debugSetSyncHttpClient(null);
    DropboxSyncBackend.instance.debugSetAccessToken(null);
    DropboxSyncBackend.debugUploadSessionThresholdBytes = null;
    DropboxSyncBackend.debugUploadSessionChunkBytes = null;
    DropboxSyncBackend.debugUploadRetrySleep = (Duration d) =>
        Future<void>.delayed(d);
    await tmp.delete(recursive: true);
  });

  test('门槛以内：仍是一次 files/upload，Dropbox-API-Arg 字段不变', () async {
    install();
    final File file = await writeFile(16);
    await upload(file);
    expect(calls.map((_Call c) => c.endpoint), <String>['files/upload']);
    expect(calls.single.arg, expectedCommit);
    expect(calls.single.body, await file.readAsBytes());
  });

  test('超过门槛：start → 按块 append_v2 → finish，偏移 / 块大小 / commit 正确', () async {
    install();
    final File file = await writeFile(22);
    final List<int> progress = <int>[];
    await upload(file, onProgress: (double f, [int? b]) => progress.add(b!));

    expect(calls.map((_Call c) => c.endpoint), <String>[
      'files/upload_session/start',
      'files/upload_session/append_v2',
      'files/upload_session/append_v2',
      'files/upload_session/append_v2',
      'files/upload_session/finish',
    ]);
    expect(calls[0].arg, <String, Object>{'close': false});
    expect(calls[0].body, isEmpty);
    final List<_Call> appends = calls.sublist(1, 4);
    expect(appends.map((_Call c) => c.offset), <int>[0, 8, 16]);
    expect(appends.map((_Call c) => c.body.length), <int>[8, 8, 6]);
    for (final _Call c in appends) {
      expect((c.arg['cursor'] as Map<String, dynamic>)['session_id'], 'sess-1');
      expect(c.arg['close'], false);
    }
    expect(
      appends.expand((_Call c) => c.body).toList(),
      await file.readAsBytes(),
    );
    final _Call finish = calls[4];
    expect(finish.arg['cursor'], <String, Object>{
      'session_id': 'sess-1',
      'offset': 22,
    });
    expect(finish.arg['commit'], expectedCommit);
    expect(finish.body, isEmpty);
    expect(progress.last, 22);
  });

  test('append_v2 报 incorrect_offset：按 correct_offset 续传', () async {
    // 第二块（offset 8）服务端说其实已收到 16 字节。
    install((_Call c, int i) {
      if (c.endpoint.endsWith('append_v2') && c.offset == 8) {
        return _incorrectOffset(16);
      }
      return null;
    });
    final File file = await writeFile(22);
    await upload(file);
    final List<_Call> appends = calls
        .where((_Call c) => c.endpoint.endsWith('append_v2'))
        .toList();
    expect(appends.map((_Call c) => c.offset), <int>[0, 8, 16]);
    expect(appends.last.body.length, 6);
    expect(calls.last.endpoint, 'files/upload_session/finish');
    expect(calls.last.offset, 22);
  });

  test(
    'finish 报 lookup_failed/incorrect_offset：回到 correct_offset 补传再 finish',
    () async {
      bool finishFailed = false;
      install((_Call c, int i) {
        if (c.endpoint.endsWith('finish') && !finishFailed) {
          finishFailed = true;
          return _json(<String, Object>{
            'error': <String, Object>{
              '.tag': 'lookup_failed',
              'lookup_failed': <String, Object>{
                '.tag': 'incorrect_offset',
                'correct_offset': 16,
              },
            },
          }, status: 409);
        }
        return null;
      });
      final File file = await writeFile(22);
      await upload(file);
      expect(calls.map((_Call c) => '${c.endpoint}@${c.offset}'), <String>[
        'files/upload_session/start@null',
        'files/upload_session/append_v2@0',
        'files/upload_session/append_v2@8',
        'files/upload_session/append_v2@16',
        'files/upload_session/finish@22',
        'files/upload_session/append_v2@16',
        'files/upload_session/finish@22',
      ]);
    },
  );

  test('某块 append_v2 瞬时 503：同一偏移重试，采信 Retry-After', () async {
    bool failed = false;
    install((_Call c, int i) {
      if (c.endpoint.endsWith('append_v2') && c.offset == 8 && !failed) {
        failed = true;
        return http.Response(
          'busy',
          503,
          headers: <String, String>{'retry-after': '2'},
        );
      }
      return null;
    });
    final File file = await writeFile(22);
    await upload(file);
    final List<_Call> appends = calls
        .where((_Call c) => c.endpoint.endsWith('append_v2'))
        .toList();
    expect(appends.map((_Call c) => c.offset), <int>[0, 8, 8, 16]);
    expect(appends[2].body, appends[1].body);
    expect(sleeps, <Duration>[const Duration(seconds: 2)]);
    expect(calls.last.endpoint, 'files/upload_session/finish');
  });

  test('持续 5xx：有界重试后抛可重试的 SyncBackendError，不进 finish', () async {
    install((_Call c, int i) {
      if (c.endpoint.endsWith('append_v2')) return http.Response('down', 500);
      return null;
    });
    final File file = await writeFile(22);
    await expectLater(
      upload(file),
      throwsA(
        isA<SyncBackendError>().having(
          (SyncBackendError e) => e.isRetryable,
          'isRetryable',
          isTrue,
        ),
      ),
    );
    final int appendCalls = calls
        .where((_Call c) => c.endpoint.endsWith('append_v2'))
        .length;
    expect(appendCalls, 5);
    expect(sleeps.length, 4);
    expect(calls.any((_Call c) => c.endpoint.endsWith('finish')), isFalse);
  });
}
