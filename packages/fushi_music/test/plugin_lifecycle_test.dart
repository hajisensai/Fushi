import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_music/fushi_music.dart';
import 'package:test/test.dart';

import 'plugin_host_test.dart'
    show
        buildPlugin,
        manifest,
        fakePublicResolve,
        noRedirectProbe,
        testVaultKey;

/// 插件宿主的生命周期边界：停用 / 卸载后不再调用、调用墙钟超时、存储并发写、实例重建竞态。
const String _js = r'''
module.exports = {
  async search(a) {
    if (a.query === 'hang') { await new Promise(() => {}); }
    if (a.query === 'store') {
      // 一次并发发出多个存储写：宿主必须串行执行，最后每个键都在。
      await Promise.all(Array.from({ length: 20 }, (_, i) =>
        fushi.storage.set('k' + i, 'v' + i)));
      return { items: [], hasMore: false, total: 20 };
    }
    return { items: [], hasMore: false, total: 0 };
  },
  async album() { return null; },
  async stream(a) { return { url: 'https://m1.cdn.example.com/' + a.id + '.mp3' }; },
  async lyrics() { return null; },
};
''';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('fmp-life-'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<MusicPluginManager> installed() async {
    final MusicPluginManager m = MusicPluginManager(
      rootDir: root,
      vaultKey: testVaultKey,
      httpClientFactory: HttpClient.new,
      resolver: fakePublicResolve,
      mediaProbe: noRedirectProbe,
      log: (_, _, _) {},
    );
    final Uint8List zip = buildPlugin(manifest(), <String, String>{
      'main.js': _js,
    });
    await m.install(zip, (await m.inspect(zip)).digest);
    return m;
  }

  Matcher unavailable(MusicPluginUnavailableReason reason) => throwsA(
    isA<MusicPluginUnavailableException>().having(
      (MusicPluginUnavailableException e) => e.reason,
      'reason',
      reason,
    ),
  );

  test('停用后不再开实例、不调插件；重新启用恢复', () async {
    final MusicPluginManager m = await installed();
    final MusicPluginSource src = m.source('moe.test.fake');
    expect((await src.stream('1')).url, 'https://m1.cdn.example.com/1.mp3');
    await m.setEnabled('moe.test.fake', false);
    await expectLater(
      src.stream('1'),
      unavailable(MusicPluginUnavailableReason.disabled),
    );
    await expectLater(
      m.instance('moe.test.fake'),
      unavailable(MusicPluginUnavailableReason.disabled),
    );
    // 停用状态落盘：新开的管理器（重启后）同样拒绝。
    final MusicPluginManager reopened = MusicPluginManager(
      rootDir: root,
      vaultKey: testVaultKey,
      httpClientFactory: HttpClient.new,
      resolver: fakePublicResolve,
      mediaProbe: noRedirectProbe,
      log: (_, _, _) {},
    );
    await expectLater(
      reopened.source('moe.test.fake').stream('1'),
      unavailable(MusicPluginUnavailableReason.disabled),
    );
    await m.setEnabled('moe.test.fake', true);
    expect((await src.stream('2')).url, 'https://m1.cdn.example.com/2.mp3');
    await m.dispose();
    await reopened.dispose();
  });

  test('停用时正在等实例的调用方也被拒，不会重开一份', () async {
    final MusicPluginManager m = await installed();
    final Future<MusicPluginInstance> opening = m.instance('moe.test.fake');
    final Future<void> disabling = m.setEnabled('moe.test.fake', false);
    // 打开中的那份照常交回（随后被停用关掉）；之后的调用一律被拒。
    final MusicPluginInstance first = await opening;
    await disabling;
    expect(first.isAlive, isFalse);
    await expectLater(
      m.instance('moe.test.fake'),
      unavailable(MusicPluginUnavailableReason.disabled),
    );
    await m.dispose();
  });

  test('没装 / 卸载后：类型化的「未安装」', () async {
    final MusicPluginManager m = await installed();
    await expectLater(
      m.source('moe.test.other').stream('1'),
      unavailable(MusicPluginUnavailableReason.notInstalled),
    );
    await m.uninstall('moe.test.fake');
    await expectLater(
      m.source('moe.test.fake').stream('1'),
      unavailable(MusicPluginUnavailableReason.notInstalled),
    );
    await m.dispose();
  });

  test('能力调用超过墙钟时限：抛超时、该次作废，实例照常可用', () async {
    final MusicPluginManager m = await installed();
    final MusicPluginInstance inst = await m.instance('moe.test.fake');
    final Stopwatch sw = Stopwatch()..start();
    await expectLater(
      inst.invoke('search', <String, Object?>{
        'query': 'hang',
        'type': 'song',
      }, timeout: const Duration(milliseconds: 300)),
      throwsA(
        isA<MusicPluginTimeoutException>()
            .having(
              (MusicPluginTimeoutException e) => e.method,
              'method',
              'search',
            )
            .having(
              (MusicPluginTimeoutException e) => e.timeout,
              'timeout',
              const Duration(milliseconds: 300),
            ),
      ),
    );
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    expect(inst.isAlive, isTrue);
    expect(
      ((await inst.invoke('search', <String, Object?>{
            'query': 'ok',
            'type': 'song',
          }))!
          as Map<Object?, Object?>)['total'],
      0,
    );
    expect(musicPluginInvokeTimeout('stream'), kMusicPluginStreamTimeout);
    expect(musicPluginInvokeTimeout('search'), kMusicPluginInvokeTimeout);
    await m.dispose();
  });

  test('插件并发写存储：串行落盘，一个键都不丢，不留临时文件', () async {
    final MusicPluginManager m = await installed();
    final MusicPluginInstance inst = await m.instance('moe.test.fake');
    await inst.invoke('search', <String, Object?>{
      'query': 'store',
      'type': 'song',
    });
    final Map<String, Object?> stored =
        jsonDecode(m.storageFileFor('moe.test.fake').readAsStringSync())
            as Map<String, Object?>;
    expect(stored, <String, Object?>{
      for (int i = 0; i < 20; i++) 'k$i': 'v$i',
    });
    expect(
      m
          .storageFileFor('moe.test.fake')
          .parent
          .listSync()
          .where((FileSystemEntity e) => e.path.endsWith('.tmp')),
      isEmpty,
    );
    await m.dispose();
  });

  test('实例作废后并发取用：只重建一份，没有泄漏的第二份', () async {
    final MusicPluginManager m = await installed();
    final MusicPluginInstance dead = await m.instance('moe.test.fake');
    await dead.close();
    final List<MusicPluginInstance> got = await Future.wait(
      <Future<MusicPluginInstance>>[
        for (int i = 0; i < 5; i++) m.instance('moe.test.fake'),
      ],
    );
    expect(got.every((MusicPluginInstance i) => i.isAlive), isTrue);
    expect(got.toSet(), hasLength(1), reason: '同时发现旧实例已死的调用方必须共用同一个新实例');
    await m.dispose();
    expect(got.first.isAlive, isFalse, reason: 'dispose 关掉了唯一那份');
  });
}
