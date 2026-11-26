/// `fushi_server ctl device-backups`：动词 → admin 请求（路径段编码）、删整台要 `--yes`、列表的文本渲染。
/// 用一个假的 admin HTTP 服务记录收到的请求，不起真 host。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_server/src/ctl/admin_client.dart';
import 'package:fushi_server/src/ctl/ctl_commands.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late AdminClient client;
  late List<String> seen;
  late Object? nextBody;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() async {
    seen = <String>[];
    nextBody = const <String, Object?>{'ok': true};
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      await request.drain<void>();
      // uri.path 保留百分号编码，能核对路径段的编码。
      seen.add('${request.method} ${request.uri.path}');
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(nextBody));
      await request.response.close();
    });
    client = AdminClient(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      token: 'tok',
    );
    out = StringBuffer();
    err = StringBuffer();
  });

  tearDown(() async {
    client.close();
    await server.close(force: true);
  });

  Future<int> ctl(List<String> args) => runCtlAction(
    client,
    buildCtlParser().parse(<String>['device-backups', ...args]),
    out: out,
    err: err,
  );

  const String key = '0123456789abcdef';
  const String id = '20261124-030000-000-fushi-scheduled';

  test('ls / rm 一份 / rm 整台 --yes 对应的请求', () async {
    expect(await ctl(<String>[]), 0, reason: '$err');
    expect(await ctl(<String>['ls']), 0, reason: '$err');
    expect(await ctl(<String>['rm', key, id]), 0, reason: '$err');
    expect(await ctl(<String>['rm', key, '--yes']), 0, reason: '$err');
    expect(await ctl(<String>['rm', 'a/b', id]), 0, reason: '$err');
    expect(seen, <String>[
      'GET /api/admin/device-backups',
      'GET /api/admin/device-backups',
      'DELETE /api/admin/device-backups/$key/$id',
      'DELETE /api/admin/device-backups/$key',
      'DELETE /api/admin/device-backups/a%2Fb/$id',
    ]);
  });

  test('删整台没给 --yes、参数不对：用法错误 64，不发请求', () async {
    expect(await ctl(<String>['rm', key]), 64);
    expect(err.toString(), contains('--yes'));
    expect(await ctl(<String>['rm']), 64);
    expect(await ctl(<String>['rm', key, id, 'extra']), 64);
    expect(await ctl(<String>['get']), 64);
    expect(seen, isEmpty);
  });

  test('列表渲染：设备名 / 键 / 份数 / 每份 id', () async {
    nextBody = <String, Object?>{
      'root': 'interconnect/sync-data/fushi-data/__backups__',
      'devices': <Object?>[
        <String, Object?>{
          'device': key,
          'name': 'Pixel 9',
          'count': 1,
          'bytes': 2048,
          'newestAtMs': 1000,
          'incomplete': 1,
          'copies': <Object?>[
            <String, Object?>{
              'id': id,
              'createdAtMs': 1000,
              'bytes': 1024,
              'schema': 180,
              'appVersion': '1.2.3',
            },
          ],
        },
      ],
    };
    expect(await ctl(<String>[]), 0, reason: '$err');
    final String text = out.toString();
    expect(text, contains('Pixel 9'));
    expect(text, contains('[$key]'));
    expect(text, contains('2.0 KB'));
    expect(text, contains('  $id'));
    expect(text, contains('Fushi 1.2.3'));

    // 设备报上来的名字 / 版本里带控制字符（ESC 序列、换行）：进终端前去掉。
    out.clear();
    nextBody = <String, Object?>{
      'devices': <Object?>[
        <String, Object?>{
          'device': key,
          'name': 'Evil\u001b[2J\nFAKE LINE',
          'count': 1,
          'bytes': 1,
          'copies': <Object?>[
            <String, Object?>{
              'id': id,
              'createdAtMs': 1000,
              'bytes': 1,
              'appVersion': '1.0\u001b]0;pwned\u0007',
            },
          ],
        },
      ],
    };
    expect(await ctl(<String>[]), 0, reason: '$err');
    final String evil = out.toString();
    expect(evil, isNot(contains('\u001b')));
    expect(evil, isNot(contains('\u0007')));
    expect(evil.trim().split('\n'), hasLength(2), reason: '一台设备一行 + 一份一行');
    expect(evil, contains('Evil [2J FAKE LINE'));

    out.clear();
    nextBody = <String, Object?>{'devices': <Object?>[]};
    expect(await ctl(<String>['ls']), 0);
    expect(out.toString().trim(), isNotEmpty);
  });
}
