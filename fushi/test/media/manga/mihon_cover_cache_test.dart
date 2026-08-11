import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cover_cache.dart';

void main() {
  test('漫画封面跨缓存实例命中磁盘且不重复联网', () async {
    final Directory root =
        await Directory.systemTemp.createTemp('fushi-mihon-cover-cache-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    int fetches = 0;
    Future<Uint8List> fetch(bool Function() stillWanted) async {
      fetches++;
      return Uint8List.fromList(<int>[1, 2, 3, 4]);
    }

    final MihonCoverCache first = MihonCoverCache(root);
    expect(
      await first.load(
        extensionPackage: 'org.example.raw',
        sourceId: '42',
        url: 'https://example.test/cover.jpg',
        fetch: fetch,
      ),
      <int>[1, 2, 3, 4],
    );

    final MihonCoverCache afterRestart = MihonCoverCache(root);
    expect(
      await afterRestart.load(
        extensionPackage: 'org.example.raw',
        sourceId: '42',
        url: 'https://example.test/cover.jpg',
        fetch: fetch,
      ),
      <int>[1, 2, 3, 4],
    );
    expect(fetches, 1);
  });

  test('共享 in-flight 请求不被单个订阅者的退场打成失败', () async {
    final Directory root =
        await Directory.systemTemp.createTemp('fushi-mihon-cover-shared-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    final Completer<void> queueGate = Completer<void>();
    int fetches = 0;
    Future<Uint8List> fetch(bool Function() stillWanted) async {
      fetches++;
      // 模拟并发队列：拿到名额之前先挂起，期间发起方的格子滚出屏幕。
      await queueGate.future;
      if (!stillWanted()) throw StateError('cancelled');
      return Uint8List.fromList(<int>[7, 7, 7]);
    }

    final MihonCoverCache cache = MihonCoverCache(root);
    bool firstAlive = true;
    final Future<Uint8List> first = cache.load(
      extensionPackage: 'org.example.raw',
      sourceId: '42',
      url: 'https://example.test/shared.jpg',
      isActive: () => firstAlive,
      fetch: fetch,
    );
    final Future<Uint8List> second = cache.load(
      extensionPackage: 'org.example.raw',
      sourceId: '42',
      url: 'https://example.test/shared.jpg',
      isActive: () => true,
      fetch: fetch,
    );

    // 发起方的 widget 被 dispose，但第二个格子还在等同一张封面。
    firstAlive = false;
    queueGate.complete();

    expect(await second, <int>[7, 7, 7]);
    expect(await first, <int>[7, 7, 7]);
    expect(fetches, 1);
  });

  test('所有订阅者都退场后共享请求才真的取消', () async {
    final Directory root =
        await Directory.systemTemp.createTemp('fushi-mihon-cover-cancel-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    final Completer<void> queueGate = Completer<void>();
    bool reachedNetwork = false;
    Future<Uint8List> fetch(bool Function() stillWanted) async {
      await queueGate.future;
      if (!stillWanted()) throw StateError('cancelled');
      reachedNetwork = true;
      return Uint8List.fromList(<int>[1]);
    }

    final MihonCoverCache cache = MihonCoverCache(root);
    bool alive = true;
    final Future<Uint8List> pending = cache.load(
      extensionPackage: 'org.example.raw',
      sourceId: '42',
      url: 'https://example.test/gone.jpg',
      isActive: () => alive,
      fetch: fetch,
    );
    alive = false;
    queueGate.complete();

    await expectLater(pending, throwsA(isA<StateError>()));
    expect(reachedNetwork, isFalse);
  });

  test('扩展、来源或 URL 不同不会错误共用封面', () {
    final String original = mihonCoverCacheKey(
      extensionPackage: 'org.example.raw',
      sourceId: '42',
      url: 'https://example.test/cover.jpg',
    );
    expect(
      mihonCoverCacheKey(
        extensionPackage: 'org.example.other',
        sourceId: '42',
        url: 'https://example.test/cover.jpg',
      ),
      isNot(original),
    );
    expect(
      mihonCoverCacheKey(
        extensionPackage: 'org.example.raw',
        sourceId: '43',
        url: 'https://example.test/cover.jpg',
      ),
      isNot(original),
    );
    expect(
      mihonCoverCacheKey(
        extensionPackage: 'org.example.raw',
        sourceId: '42',
        url: 'https://example.test/new-cover.jpg',
      ),
      isNot(original),
    );
  });
}
