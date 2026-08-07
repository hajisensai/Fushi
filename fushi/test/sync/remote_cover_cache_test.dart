import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/remote_cover_cache.dart';

/// BUG-847：远端封面读盘缓存单测。命中直接读盘（跨重启不重下）、未命中回退网络。
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('remote_cover_cache_test');
    RemoteCoverCache.debugSetDirResolver(
      () async => Directory('${tmp.path}/cache'),
    );
  });

  tearDown(() async {
    RemoteCoverCache.debugSetDirResolver(null);
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  test('未命中返回 null；write 后 read 命中（读盘 read-through）', () async {
    expect(await RemoteCoverCache.read('vid-1'), isNull);
    final Uint8List bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
    await RemoteCoverCache.write('vid-1', bytes);
    expect(await RemoteCoverCache.read('vid-1'), bytes);
  });

  test('空字节不落盘（拉网返回空不污染缓存）', () async {
    await RemoteCoverCache.write('empty', Uint8List(0));
    expect(await RemoteCoverCache.read('empty'), isNull);
  });

  test('含非法文件名字符的稳定 id（含 URL / 中文）也能读写', () async {
    const String id = 'http://192.168.1.5:8080/api/videos/曖昧/cover?x=1';
    final Uint8List bytes = Uint8List.fromList(<int>[9, 8, 7]);
    await RemoteCoverCache.write(id, bytes);
    expect(await RemoteCoverCache.read(id), bytes);
  });

  test('fileNameFor 对同 id 稳定、对不同 id 不碰撞', () {
    expect(
      RemoteCoverCache.fileNameFor('a'),
      RemoteCoverCache.fileNameFor('a'),
    );
    expect(
      RemoteCoverCache.fileNameFor('a') == RemoteCoverCache.fileNameFor('b'),
      isFalse,
    );
  });
}
