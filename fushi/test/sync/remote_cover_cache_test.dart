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

  test('超龄条目按未命中处理并删除（BUG-1693 批：host 换封面后客户端永不自愈）', () async {
    final Uint8List bytes = Uint8List.fromList(<int>[1, 2, 3]);
    await RemoteCoverCache.write('stale', bytes);
    // 把文件 mtime 拨回 TTL 之前。
    final File f =
        File('${tmp.path}/cache/${RemoteCoverCache.fileNameFor('stale')}');
    f.setLastModifiedSync(DateTime.now()
        .subtract(RemoteCoverCache.maxEntryAge + const Duration(hours: 1)));
    expect(await RemoteCoverCache.read('stale'), isNull,
        reason: '超龄必须按未命中走网络重拉（不存在「host 封面变了」的失效信号）');
    expect(f.existsSync(), isFalse, reason: '超龄条目顺带删除');
  });

  test('容量上限：超过 maxEntries 时修剪最旧条目', () async {
    // 直接造小文件绕过 write 的概率性抽查，用 debugTrimNow 强制修剪。
    final Directory dir = Directory('${tmp.path}/cache');
    await dir.create(recursive: true);
    final DateTime base = DateTime.now().subtract(const Duration(hours: 2));
    for (int i = 0; i < RemoteCoverCache.maxEntries + 8; i++) {
      final File f = File('${dir.path}/${RemoteCoverCache.fileNameFor('k$i')}');
      f.writeAsBytesSync(<int>[1]);
      // 递增 mtime：k0 最旧。
      f.setLastModifiedSync(base.add(Duration(seconds: i)));
    }
    await RemoteCoverCache.debugTrimNow();
    final int remaining = dir.listSync().whereType<File>().length;
    expect(remaining, RemoteCoverCache.maxEntries, reason: '缓存不再无界增长');
    expect(
        File('${dir.path}/${RemoteCoverCache.fileNameFor('k0')}').existsSync(),
        isFalse,
        reason: '修剪按 mtime 淘汰最旧');
    expect(
        File('${dir.path}/${RemoteCoverCache.fileNameFor('k${RemoteCoverCache.maxEntries + 7}')}')
            .existsSync(),
        isTrue,
        reason: '最新条目保留');
  });
}
