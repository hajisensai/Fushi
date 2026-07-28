import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/interconnect_sync_backend.dart';
import 'package:hibiki/src/sync/remote_library_cache.dart';

/// BUG-1180 根因守卫：远端库列表的 TTL 缓存 + in-flight 去重 + 显式失效。
///
/// 症状——每切一次页面（书架 / 视频 / 首页），互联对端的条目清单就被完整重拉一遍。
/// 真根因：远端列表**没有任何缓存层**（只有封面图有磁盘缓存），而书架与视频页为了让
/// 对端新增内容可见（BUG-992/994）各注册了「切回本 tab 就重拉」的监听器，顶层 tab
/// 保活（BUG-750）省下的重建被原样加了回来。
///
/// 本文件锁住缓存本身的语义；页面接线由 `reader_remote_interconnect_test.dart` /
/// `home_video_remote_interconnect_test.dart` 覆盖。
void main() {
  /// 可控时钟：TTL 相关断言不能依赖真实墙钟（既慢又 flaky）。
  late int now;
  late RemoteLibraryCache cache;

  setUp(() {
    now = 1000000;
    cache = RemoteLibraryCache(
      defaultTtl: const Duration(seconds: 60),
      nowMs: () => now,
    );
  });

  test('TTL 内第二次读命中缓存，不再调 fetch（切页面不重拉的核心）', () async {
    int calls = 0;
    Future<List<String>> fetch() async {
      calls++;
      return <String>['a'];
    }

    expect(await cache.read(key: 'books', fetch: fetch), <String>['a']);
    expect(calls, 1);

    now += 59 * 1000; // 仍在 60s TTL 内
    expect(await cache.read(key: 'books', fetch: fetch), <String>['a']);
    expect(calls, 1, reason: 'TTL 内必须命中缓存，不得再联网');
  });

  test('TTL 过期后重新取数（对端新增内容最终可见）', () async {
    int calls = 0;
    Future<List<String>> fetch() async => <String>['v${++calls}'];

    expect(await cache.read(key: 'books', fetch: fetch), <String>['v1']);
    now += 61 * 1000;
    expect(await cache.read(key: 'books', fetch: fetch), <String>['v2'],
        reason: 'TTL 过期必须重新取数，否则对端新增的书永远看不到');
    expect(calls, 2);
  });

  test('forceRefresh 无条件穿透 TTL（下拉刷新语义）', () async {
    int calls = 0;
    Future<List<String>> fetch() async => <String>['v${++calls}'];

    await cache.read(key: 'books', fetch: fetch);
    expect(
      await cache.read(key: 'books', fetch: fetch, forceRefresh: true),
      <String>['v2'],
    );
    expect(calls, 2);
  });

  test('in-flight 去重：同 key 并发只打一枪，双方拿到同一结果', () async {
    int calls = 0;
    final Completer<List<String>> gate = Completer<List<String>>();
    Future<List<String>> fetch() {
      calls++;
      return gate.future;
    }

    // 书架与首页 dashboard 同帧各问一次远端书清单。
    final Future<List<String>> first = cache.read(key: 'books', fetch: fetch);
    final Future<List<String>> second = cache.read(key: 'books', fetch: fetch);
    expect(calls, 1, reason: '同 key 有请求在途时不得再发一枪');

    gate.complete(<String>['shared']);
    expect(await first, <String>['shared']);
    expect(await second, <String>['shared']);
  });

  test('取数失败不缓存失败，异常原样上抛，下次读必重试', () async {
    int calls = 0;
    Future<List<String>> failing() async {
      calls++;
      throw StateError('offline');
    }

    await expectLater(
      cache.read(key: 'books', fetch: failing),
      throwsA(isA<StateError>()),
    );
    expect(cache.isFresh('books'), isFalse);

    await expectLater(
      cache.read(key: 'books', fetch: failing),
      throwsA(isA<StateError>()),
    );
    expect(calls, 2, reason: '失败不得被当成缓存值，下一次读必须重试');
  });

  test('取数失败保留上一次成功值（离线仍显示最后一次已知列表）', () async {
    bool shouldFail = false;
    Future<List<String>> fetch() async {
      if (shouldFail) throw StateError('offline');
      return <String>['ok'];
    }

    await cache.read(key: 'books', fetch: fetch);
    now += 61 * 1000; // 过期
    shouldFail = true;
    await expectLater(
      cache.read(key: 'books', fetch: fetch),
      throwsA(isA<StateError>()),
    );

    // 失败没有刷新 fetchedAt，也没有抹掉旧值：调用方可继续用上一次快照渲染。
    shouldFail = false;
    expect(await cache.read(key: 'books', fetch: fetch), <String>['ok']);
  });

  test('invalidate 作废单 key，不牵连其它域', () async {
    int bookCalls = 0;
    int videoCalls = 0;

    await cache.read(
      key: RemoteLibraryCacheKeys.books,
      fetch: () async => <String>['b${++bookCalls}'],
    );
    await cache.read(
      key: RemoteLibraryCacheKeys.videos,
      fetch: () async => <String>['v${++videoCalls}'],
    );

    cache.invalidate(RemoteLibraryCacheKeys.books);
    expect(cache.isFresh(RemoteLibraryCacheKeys.books), isFalse);
    expect(cache.isFresh(RemoteLibraryCacheKeys.videos), isTrue,
        reason: '失效一个域不得连带清掉别的域');

    await cache.read(
      key: RemoteLibraryCacheKeys.books,
      fetch: () async => <String>['b${++bookCalls}'],
    );
    expect(bookCalls, 2);
    expect(videoCalls, 1);
  });

  test('invalidateAll 清空全部（换对端 / 管理互联源）', () async {
    await cache.read(
      key: RemoteLibraryCacheKeys.books,
      fetch: () async => <String>['b'],
    );
    await cache.read(
      key: RemoteLibraryCacheKeys.videos,
      fetch: () async => <String>['v'],
    );

    cache.invalidateAll();
    expect(cache.isFresh(RemoteLibraryCacheKeys.books), isFalse);
    expect(cache.isFresh(RemoteLibraryCacheKeys.videos), isFalse);
  });

  test('在途请求被 invalidate 后，其结果不得写回缓存（generation 守卫）', () async {
    final Completer<List<String>> slow = Completer<List<String>>();
    final Future<List<String>> pending = cache.read(
      key: 'books',
      fetch: () => slow.future,
    );

    // 请求还在飞的时候换了对端 → 这一份结果已经不属于当前对端。
    cache.invalidateAll();
    slow.complete(<String>['stale-peer']);
    expect(await pending, <String>['stale-peer'], reason: '发起方仍拿到自己那次取数的结果');
    expect(cache.isFresh('books'), isFalse,
        reason: '过时结果不得写回缓存，否则 TTL 内会拿上一台 host 的清单渲染');
  });

  test('forceRefresh 期间的旧 in-flight 结果不覆盖新结果', () async {
    final Completer<List<String>> slowOld = Completer<List<String>>();
    final Completer<List<String>> fastNew = Completer<List<String>>();

    final Future<List<String>> old = cache.read(
      key: 'books',
      fetch: () => slowOld.future,
    );
    final Future<List<String>> fresh = cache.read(
      key: 'books',
      fetch: () => fastNew.future,
      forceRefresh: true,
    );

    fastNew.complete(<String>['new']);
    expect(await fresh, <String>['new']);

    // 旧请求后到——不得把缓存打回旧值。
    slowOld.complete(<String>['old']);
    expect(await old, <String>['old']);

    final List<String> cached = await cache.read(
      key: 'books',
      fetch: () async => throw StateError('不该重新取数'),
    );
    expect(cached, <String>['new'], reason: '后到的旧请求不得覆盖 forceRefresh 拿到的新结果');
  });

  test('不同 limit 的活动流分槽，互不污染', () async {
    await cache.read(
      key: RemoteLibraryCacheKeys.activity(200),
      fetch: () async => List<int>.generate(200, (int i) => i),
    );
    final List<int> small = await cache.read(
      key: RemoteLibraryCacheKeys.activity(20),
      fetch: () async => List<int>.generate(20, (int i) => i),
    );
    expect(small.length, 20, reason: 'limit 不同即结果集不同，共用一槽会把首页的 200 条截断成 20 条');
  });

  test('各媒体域分属不同 key，互不覆盖', () {
    // 互联与云盘的视频清单**共用** videos 一个槽（TODO-2119 后两种源都实现
    // RemoteVideoSource，元素统一是 RemoteVideoInfo）；域与域之间必须分开。
    final Set<String> keys = <String>{
      RemoteLibraryCacheKeys.books,
      RemoteLibraryCacheKeys.videos,
      RemoteLibraryCacheKeys.audiobooks,
      RemoteLibraryCacheKeys.dictionaries,
      RemoteLibraryCacheKeys.activity(200),
    };
    expect(keys.length, 5, reason: '域 key 不得重名，否则一个域的清单会盖掉另一个域');
  });

  /// BUG-1180 接线守卫：provider 必须订阅「对端身份变了」的信号并整体失效。
  ///
  /// 这条钉的是**接线**，不是缓存类自身的 `invalidateAll`（那条在上面）。删掉
  /// `remoteLibraryCacheProvider` 里的 `addListener(onIdentityChanged)` 本条即红——
  /// 前一版正是漏了这根线，唯一的 `invalidateAll()` 还挂在改不了对端的「源库」
  /// 对话框上，换对端后 TTL 内仍然渲染上一台 host 的清单。
  test('BUG-1180: 缓存随对端身份变化自动失效（provider 已订阅）', () async {
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);

    final RemoteLibraryCache scoped =
        container.read(remoteLibraryCacheProvider);
    await scoped.read(
      key: RemoteLibraryCacheKeys.books,
      fetch: () async => <String>['host-a 的书'],
    );
    expect(scoped.isFresh(RemoteLibraryCacheKeys.books), isTrue);

    // 模拟「对端身份变了」——真实路径是 restoreAuth 里 _sessionSignature 比对失败。
    InterconnectSyncBackend.instance.sessionIdentityRevision.value++;

    expect(scoped.isFresh(RemoteLibraryCacheKeys.books), isFalse,
        reason: 'BUG-1180：换对端后不得再拿上一台 host 的清单渲染');
  });
}
