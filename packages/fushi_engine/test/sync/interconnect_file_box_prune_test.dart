import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/interconnect_file_box_prune.dart';
import 'package:fushi_engine/sync/sync_reserved_namespaces.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// BUG-4906：互联 host 同步根下旧版本客户端写下、host 从不读回的文件箱书文件夹，host 启动时
// 收走；保留命名空间（还有人读的共享数据）与认不出的东西一律不碰。

Future<int> _put(
  FushiSyncServer server,
  String token,
  String path,
  List<int> body,
) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest req = await client.openUrl(
      'PUT',
      Uri.parse(Uri.encodeFull('http://127.0.0.1:${server.port}/$path')),
    );
    req.headers.set(
      'Authorization',
      'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
    );
    req.contentLength = body.length;
    req.add(body);
    final HttpClientResponse res = await req.close();
    await res.drain<void>();
    return res.statusCode;
  } finally {
    client.close(force: true);
  }
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('file_box_prune_');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('旧客户端经 WebDAV 写进来的书文件夹在 host 下次启动前被收走，保留命名空间原样', () async {
    final String token = FushiSyncServer.generateToken();
    final FushiSyncServer server = FushiSyncServer(
      syncDataDir: tmp.path,
      port: 0,
      token: token,
    );
    await server.start();
    // 旧版本客户端的文件箱写入：书内容、有声书音频、进度 / 有声书断点 JSON、封面。
    final List<String> fileBox = <String>[
      'fushi-data/七つの魔剣が支配する/七つの魔剣が支配する.epub',
      'fushi-data/七つの魔剣が支配する/01 七つの魔剣が支配する.m4b',
      'fushi-data/七つの魔剣が支配する/progress_1_6_1700000000000_0.5.json',
      'fushi-data/七つの魔剣が支配する/audioBook_1_6_1700000000000.json',
      'fushi-data/Re ゼロ/statistics_1_6_1000_2.json',
      'fushi-data/Re ゼロ/cover_1_6.png',
    ];
    // 仍被读取的共享数据：每个保留命名空间都写一份。
    final List<String> reserved = <String>[
      'fushi-data/__pending_mines__/claim-a.json',
      'fushi-data/__settings__/settings-dev1.json',
      'fushi-data/__aggregate__/aggregate-dev1.json',
      'fushi-data/__collections__/collections-dev1.json',
      'fushi-data/__tombstones__/book-x.json',
      'fushi-data/__fonts__/a.ttf',
      'fushi-data/__dictionaries__/jmdict.fushidict',
      'fushi-data/__local_audio__/nhk.fushiaudiolib',
      'fushi-data/__videos__/videos.json',
      'fushi-data/fushi-srs/profile-1/v3/meta.json',
    ];
    for (final String path in <String>[...fileBox, ...reserved]) {
      expect(
        await _put(server, token, path, utf8.encode('x')),
        201,
        reason: path,
      );
    }
    await server.stop();

    final String root = p.join(server.syncDataDir, 'fushi-data');
    // 认不出的东西：带子目录的非保留目录、同步根下直接放的文件——不碰。
    File(p.join(root, 'unknown-tree', 'nested', 'a.bin'))
      ..createSync(recursive: true)
      ..writeAsStringSync('keep');
    File(p.join(root, 'progress_1_6_99999_1.0.json')).writeAsStringSync('{}');
    // 只建了文件夹、一个文件都没写的书文件夹（旧客户端 MKCOL 后中断）。
    Directory(p.join(root, 'Empty Book')).createSync();

    final List<String> removed = await pruneDeadInterconnectFileBox(
      server.syncDataDir,
    );

    expect(removed.toSet(), <String>{'七つの魔剣が支配する', 'Re ゼロ', 'Empty Book'});
    expect(removed, hasLength(3));
    expect(Directory(p.join(root, '七つの魔剣が支配する')).existsSync(), isFalse);
    expect(Directory(p.join(root, 'Empty Book')).existsSync(), isFalse);
    for (final String path in fileBox) {
      expect(
        File(p.join(server.syncDataDir, path)).existsSync(),
        isFalse,
        reason: path,
      );
    }
    for (final String path in reserved) {
      expect(
        File(p.join(server.syncDataDir, path)).existsSync(),
        isTrue,
        reason: path,
      );
    }
    expect(
      File(p.join(root, 'unknown-tree', 'nested', 'a.bin')).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(root, 'progress_1_6_99999_1.0.json')).existsSync(),
      isTrue,
    );

    // 幂等：再跑一遍什么都不删。
    expect(await pruneDeadInterconnectFileBox(server.syncDataDir), isEmpty);
  });

  test('同步根不存在（从没有客户端连过）时什么都不做', () async {
    expect(
      await pruneDeadInterconnectFileBox(p.join(tmp.path, 'sync-data')),
      isEmpty,
    );
  });

  test('保留名判据：__x__ 形状与复习同步命名空间', () {
    for (final String name in <String>[
      '__pending_mines__',
      '__settings__',
      '__anything_new__',
      'fushi-srs',
    ]) {
      expect(isReservedSyncNamespaceName(name), isTrue, reason: name);
    }
    for (final String name in <String>[
      'Book A',
      'fushi-srs-copy',
      '_x',
      '__',
      '____',
      '__init',
    ]) {
      expect(isReservedSyncNamespaceName(name), isFalse, reason: name);
    }
  });

  test('存储页归类：共享 / 复习同步 / 旧版残留 / 其余，旧版残留与清理同一判据', () async {
    final String syncData = p.join(tmp.path, 'sync-data');
    void write(String rel, int bytes) {
      File(p.join(syncData, rel))
        ..createSync(recursive: true)
        ..writeAsBytesSync(List<int>.filled(bytes, 1));
    }

    write('fushi-data/__settings__/s.json', 10);
    write('fushi-data/__pending_mines__/m.json', 20);
    write('fushi-data/fushi-srs/p/v3/seg', 300);
    write('fushi-data/Book A/progress_1.json', 4000);
    write('fushi-data/Book B/b.epub', 50000);
    write('fushi-data/odd/nested/x', 600000);
    write('fushi-data/spill.json', 7000000);
    write('other-dir/x', 80000000);

    final InterconnectSyncDataUsage u = await measureInterconnectSyncData(
      syncData,
    );
    expect(u.sharedBytes, 30);
    expect(u.srsBytes, 300);
    expect(u.deadFileBoxBytes, 54000);
    expect(u.deadFileBoxFolders, 2);
    expect(u.otherBytes, 600000 + 7000000 + 80000000);
    expect(u.totalBytes, 30 + 300 + 54000 + 600000 + 7000000 + 80000000);

    expect((await pruneDeadInterconnectFileBox(syncData)).toSet(), <String>{
      'Book A',
      'Book B',
    });
    final InterconnectSyncDataUsage after = await measureInterconnectSyncData(
      syncData,
    );
    expect(after.deadFileBoxBytes, 0);
    expect(after.deadFileBoxFolders, 0);
    expect(after.sharedBytes, 30);
    expect(after.srsBytes, 300);
  });

  test('sync-data 不存在时归类全 0', () async {
    final InterconnectSyncDataUsage u = await measureInterconnectSyncData(
      p.join(tmp.path, 'nope'),
    );
    expect(u.totalBytes, 0);
  });
}
