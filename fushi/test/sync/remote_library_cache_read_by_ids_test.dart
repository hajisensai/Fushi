import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/remote_library_cache.dart';

/// [RemoteLibraryCache.readByIds]：打开一个合集只问它的成员 id，不等、也不冒充
/// 整份远端清单。
///
/// 起因：视频页首轮 Jellyfin 全库枚举很慢，合集详情此前复用那次在途请求，整页
/// 骨架屏陪它转到底。按 id 查的条目进同一份缓存（同一套失效），但 [peek] /
/// [RemoteLibraryCache.wouldReadImmediately] / [read] 永远只认整份清单。
void main() {
  late int now;
  late RemoteLibraryCache cache;
  const String src = 'jellyfin:http://nas:8096|u1';
  const String key = 'videos';

  setUp(() {
    now = 1000000;
    cache = RemoteLibraryCache(
      defaultTtl: const Duration(seconds: 60),
      nowMs: () => now,
    );
  });

  /// 计数版按 id 查询：记下每次被问的 id；服务器上只有 [onServer] 里的条目。
  ({
    List<List<String>> calls,
    Future<List<String>> Function(List<String>) fetch,
  })
  lookup(Set<String> onServer) {
    final List<List<String>> calls = <List<String>>[];
    return (
      calls: calls,
      fetch: (List<String> ids) async {
        calls.add(List<String>.of(ids));
        return <String>[
          for (final String id in ids)
            if (onServer.contains(id)) id,
        ];
      },
    );
  }

  Future<List<String>> readByIds(
    List<String> ids,
    Future<List<String>> Function(List<String>) fetch,
  ) => cache.readByIds<String>(
    sourceId: src,
    key: key,
    ids: ids,
    idOf: (String v) => v,
    fetch: fetch,
  );

  test('整份清单新鲜时从清单里挑，不发按 id 查询；清单里没有的 id 就是没有', () async {
    await cache.read<List<String>>(
      sourceId: src,
      key: key,
      fetch: () async => <String>['a', 'b', 'c'],
    );
    final l = lookup(<String>{'a', 'b', 'c', 'z'});
    expect(await readByIds(<String>['c', 'z', 'a'], l.fetch), <String>[
      'c',
      'a',
    ]);
    expect(l.calls, isEmpty);
  });

  test('整库请求在途时不等它：按 id 查询照发并先返回', () async {
    final Completer<List<String>> fullList = Completer<List<String>>();
    final Future<List<String>> full = cache.read<List<String>>(
      sourceId: src,
      key: key,
      fetch: () => fullList.future,
    );
    final l = lookup(<String>{'a', 'b'});
    expect(await readByIds(<String>['b', 'a'], l.fetch), <String>['b', 'a']);
    expect(l.calls, <List<String>>[
      <String>['b', 'a'],
    ]);
    expect(fullList.isCompleted, isFalse, reason: '整库请求仍在途，没有被等');
    fullList.complete(<String>['a', 'b', 'c']);
    expect(await full, <String>['a', 'b', 'c']);
  });

  test('按 id 查到的条目不冒充整份清单', () async {
    final l = lookup(<String>{'a'});
    await readByIds(<String>['a'], l.fetch);
    expect(cache.peek<List<String>>(sourceId: src, key: key), isNull);
    expect(cache.wouldReadImmediately(sourceId: src, key: key), isFalse);
    expect(cache.isFresh(src, key), isFalse);
    int listCalls = 0;
    await cache.read<List<String>>(
      sourceId: src,
      key: key,
      fetch: () async {
        listCalls++;
        return <String>['a', 'b'];
      },
    );
    expect(listCalls, 1, reason: '库页读整份清单照常取数，不被单查记录挡住');
  });

  test('TTL 内重复打开只问缺的 id；服务器上没有的 id 也记住，不反复问', () async {
    final l = lookup(<String>{'a', 'b'});
    expect(await readByIds(<String>['a', 'gone'], l.fetch), <String>['a']);
    expect(await readByIds(<String>['a', 'gone', 'b'], l.fetch), <String>[
      'a',
      'b',
    ]);
    expect(l.calls, <List<String>>[
      <String>['a', 'gone'],
      <String>['b'],
    ]);
    now += const Duration(seconds: 61).inMilliseconds;
    await readByIds(<String>['a'], l.fetch);
    expect(l.calls.last, <String>['a'], reason: '过了 TTL 重新问');
  });

  test('并发打开的重叠 id 共用一次在途查询', () async {
    final Completer<void> gate = Completer<void>();
    final List<List<String>> calls = <List<String>>[];
    Future<List<String>> fetch(List<String> ids) async {
      calls.add(List<String>.of(ids));
      await gate.future;
      return ids;
    }

    final Future<List<String>> first = readByIds(<String>['a', 'b'], fetch);
    final Future<List<String>> second = readByIds(<String>['b', 'c'], fetch);
    gate.complete();
    expect(await first, <String>['a', 'b']);
    expect(await second, <String>['b', 'c']);
    expect(calls, <List<String>>[
      <String>['a', 'b'],
      <String>['c'],
    ]);
  });

  test('失效信号同样清掉单查记录；整份清单写入后单查记录作废', () async {
    final l = lookup(<String>{'a'});
    await readByIds(<String>['a'], l.fetch);
    cache.invalidateSource(src);
    await readByIds(<String>['a'], l.fetch);
    expect(l.calls.length, 2, reason: 'invalidateSource 之后重新问');

    cache.invalidate(src, key);
    await readByIds(<String>['a'], l.fetch);
    expect(l.calls.length, 3, reason: 'invalidate 之后重新问');

    cache.invalidateAll();
    await readByIds(<String>['a'], l.fetch);
    expect(l.calls.length, 4, reason: 'invalidateAll 之后重新问');

    // 整份清单到手：之后在清单新鲜期内只认清单（清单里 a 已被删）。
    await cache.read<List<String>>(
      sourceId: src,
      key: key,
      fetch: () async => <String>['b'],
    );
    expect(await readByIds(<String>['a'], l.fetch), isEmpty);
    expect(l.calls.length, 4);
  });

  test('在途期间被失效：结果照样交给调用方，但不写回缓存', () async {
    final Completer<List<String>> pending = Completer<List<String>>();
    int calls = 0;
    Future<List<String>> fetch(List<String> ids) {
      calls++;
      return calls == 1 ? pending.future : Future<List<String>>.value(ids);
    }

    final Future<List<String>> first = readByIds(<String>['a'], fetch);
    cache.invalidateSource(src);
    pending.complete(<String>['a']);
    expect(await first, <String>['a']);
    await readByIds(<String>['a'], fetch);
    expect(calls, 2, reason: '失效前发出的查询不该把旧结果写回');
  });

  test('查询失败原样上抛、不缓存失败；下次照常重试', () async {
    int calls = 0;
    Future<List<String>> fetch(List<String> ids) async {
      calls++;
      if (calls == 1) throw StateError('offline');
      return ids;
    }

    await expectLater(readByIds(<String>['a'], fetch), throwsStateError);
    expect(await readByIds(<String>['a'], fetch), <String>['a']);
    expect(calls, 2);
  });

  test('来源之间不串：别的来源的单查记录与清单都不命中', () async {
    final l = lookup(<String>{'a'});
    await cache.read<List<String>>(
      sourceId: 'other',
      key: key,
      fetch: () async => <String>['a'],
    );
    await cache.readByIds<String>(
      sourceId: 'other',
      key: key,
      ids: const <String>['a'],
      idOf: (String v) => v,
      fetch: l.fetch,
    );
    expect(l.calls, isEmpty);
    await readByIds(<String>['a'], l.fetch);
    expect(l.calls, <List<String>>[
      <String>['a'],
    ]);
  });
}
