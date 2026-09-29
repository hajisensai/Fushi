import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/source_guard.dart';

/// 客户端候选地址列表（`sync_hibiki_client_urls`）的所有读改写都必须经
/// [SyncRepository.updateFushiClientUrls] 串行：后台地址学习、链接配对、设置页编辑
/// 与 TOFU 落指纹会并发改同一个键，任何一处直接「读 → 改 → set」都会拿过期快照
/// 覆盖别人刚写的条目（docs/specs/2026-09-28-interconnect-remote-reach.md §9）。
void main() {
  FushiClientUrl url(String u) => FushiClientUrl(url: u);

  group('moveInterconnectUrlBefore', () {
    final List<FushiClientUrl> list = <FushiClientUrl>[
      url('a'),
      url('b'),
      url('c'),
    ];
    List<String> urls(List<FushiClientUrl> l) =>
        l.map((FushiClientUrl u) => u.url).toList();

    test('挪到指定条目前面', () {
      expect(urls(moveInterconnectUrlBefore(list, 'c', 'a')), <String>[
        'c',
        'a',
        'b',
      ]);
    });

    test('beforeUrl 为 null 或已不在列表 → 挪到末尾', () {
      expect(urls(moveInterconnectUrlBefore(list, 'a', null)), <String>[
        'b',
        'c',
        'a',
      ]);
      expect(urls(moveInterconnectUrlBefore(list, 'a', 'gone')), <String>[
        'b',
        'c',
        'a',
      ]);
    });

    test('被挪的条目已不在 → 原样返回同一实例（不写盘）', () {
      expect(moveInterconnectUrlBefore(list, 'gone', 'a'), same(list));
    });

    test('拖动期间学习器插入的条目保持原位', () {
      // 本页快照是 [a, b]，用户把 b 拖到 a 前；库里此时已是 [a, x(learned), b]。
      final List<FushiClientUrl> stored = <FushiClientUrl>[
        url('a'),
        url('x'),
        url('b'),
      ];
      expect(urls(moveInterconnectUrlBefore(stored, 'b', 'a')), <String>[
        'b',
        'a',
        'x',
      ]);
    });
  });

  group('SyncRepository 写入串行', () {
    late FushiDatabase db;
    late SyncRepository repo;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      repo = SyncRepository(db);
    });
    tearDown(() => db.close());

    test('并发 addFushiClientUrl 不互相覆盖', () async {
      await Future.wait(<Future<Object?>>[
        repo.addFushiClientUrl('http://a:1'),
        repo.addFushiClientUrl('http://b:1'),
        repo.setFushiClientTokenForUrl('http://a:1', 'T'),
      ]);
      final List<FushiClientUrl> stored = await repo.getFushiClientUrls();
      expect(stored.map((FushiClientUrl u) => u.url).toSet(), <String>{
        'http://a:1',
        'http://b:1',
      });
      expect(
        stored.firstWhere((FushiClientUrl u) => u.url == 'http://a:1').token,
        'T',
      );
    });

    test('TOFU 指纹冲突照样抛出，且不阻塞后续写入', () async {
      await repo.addFushiClientUrl('https://a:1', fingerprint: 'aa');
      await expectLater(
        repo.addFushiClientUrl('https://a:1', fingerprint: 'bb'),
        throwsA(isA<FushiFingerprintMismatchException>()),
      );
      await repo.addFushiClientUrl('https://b:1');
      expect(await repo.getFushiClientUrls(), hasLength(2));
      expect(await repo.clearFushiClientFingerprint('https://a:1'), isTrue);
      expect(await repo.clearFushiClientFingerprint('https://a:1'), isFalse);
    });
  });

  test('lib/ 里只有串行入口本身直接写地址列表', () {
    final List<String> offenders = <String>[];
    for (final FileSystemEntity e in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      // 注释里提到 setFushiClientUrls 不算；块注释 / 行尾注释一并剥掉。
      final List<String> lines = maskComments(e.readAsStringSync()).split('\n');
      for (int i = 0; i < lines.length; i++) {
        final String line = lines[i];
        if (!line.contains('setFushiClientUrls(')) continue;
        // 定义处与 updateFushiClientUrls 内部那一次调用是唯一允许的两处。
        if (line.contains('Future<void> setFushiClientUrls(') ||
            line.contains('await setFushiClientUrls(after)')) {
          continue;
        }
        offenders.add('${e.path}:${i + 1}: ${line.trim()}');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '改地址列表请用 SyncRepository.updateFushiClientUrls',
    );
  });
}
