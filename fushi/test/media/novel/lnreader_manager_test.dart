import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/novel/online/lnreader_manager.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';

import 'fake_lnreader_runtime.dart';

void main() {
  late Directory root;
  late HttpServer server;
  late String base;
  late List<Map<String, Object?>> index;
  final Map<String, String> scripts = <String, String>{};

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lnreader_manager_test');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    index = <Map<String, Object?>>[
      <String, Object?>{
        'id': 'yomou.syosetu',
        'name': 'Syosetu',
        'site': 'https://yomou.syosetu.com/',
        'lang': '日本語',
        'version': '1.1.4',
        'url': '$base/Syosetu.js',
        'iconUrl': '',
      },
      <String, Object?>{'id': 'broken'}, // 缺字段的坏条目要被跳过
    ];
    scripts['/Syosetu.js'] = 'exports.default = {};';
    server.listen((HttpRequest request) async {
      final HttpResponse response = request.response;
      if (request.uri.path == '/builtin.json') {
        response.write('[]');
      } else if (request.uri.path == '/plugins.min.json') {
        response.write(jsonEncode(index));
      } else if (request.uri.path == '/evil.json') {
        // 第三方仓库：与官方插件同 id、版本号更高（插件没有签名）。
        response.write(
          jsonEncode(<Map<String, Object?>>[
            <String, Object?>{
              'id': 'yomou.syosetu',
              'name': 'Syosetu',
              'site': 'https://yomou.syosetu.com/',
              'lang': '日本語',
              'version': '9.9.9',
              'url': '$base/Evil.js',
              'iconUrl': '',
            },
          ]),
        );
      } else if (request.uri.path == '/not-a-repo') {
        response.write('<html>repo home page</html>');
      } else if (scripts.containsKey(request.uri.path)) {
        response.write(scripts[request.uri.path]);
      } else {
        response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await root.delete(recursive: true);
  });

  LnReaderManager manager(FakeLnReaderRuntime runtime) => LnReaderManager(
    rootDirectory: root,
    runtime: runtime,
    httpClientFactory: HttpClient.new,
    builtinStoreUrl: '$base/builtin.json',
    clock: () => 42,
  );

  Future<LnReaderManager> ready({FakeLnReaderRuntime? runtime}) async {
    final LnReaderManager m = manager(runtime ?? FakeLnReaderRuntime());
    await m.initialise();
    await m.addStore('$base/plugins.min.json');
    return m;
  }

  test('生产内置的是官方仓库', () {
    final LnReaderManager m = LnReaderManager(
      rootDirectory: root,
      runtime: FakeLnReaderRuntime(),
      httpClientFactory: HttpClient.new,
    );
    expect(m.builtinStoreUrl, kLnReaderOfficialStoreUrl);
    expect(m.refreshOnInitialise, isFalse, reason: '单测默认不碰外网。');
  });

  test('内置仓库：恒在第一位、不可删改、不落盘', () async {
    final String builtin = '$base/builtin.json';
    final LnReaderManager m = manager(FakeLnReaderRuntime());
    await m.initialise();
    expect(m.stores.first.indexUrl, builtin);
    expect(m.isBuiltinStore(m.stores.first), isTrue);

    await m.removeStore(m.stores.first);
    await m.editStore(m.stores.first, '$base/plugins.min.json');
    expect(m.stores.first.indexUrl, builtin);

    await m.addStore('$base/plugins.min.json');
    final String state = await File('${root.path}/state.json').readAsString();
    expect(state, isNot(contains(builtin)));
    expect(state, contains('$base/plugins.min.json'));

    // 重启后仍然恒在、仍排第一，用户仓库跟在后面。
    final LnReaderManager reopened = manager(FakeLnReaderRuntime());
    await reopened.initialise();
    expect(reopened.stores.map((LnReaderStore s) => s.indexUrl), <String>[
      builtin,
      '$base/plugins.min.json',
    ]);
  });

  test('刷新仓库：坏条目跳过，失败仓库只记在自己身上', () async {
    final LnReaderManager m = await ready();
    await m.addStore('$base/not-a-repo');
    expect(
      m.available.map((LnReaderRepoPlugin p) => p.id),
      contains('yomou.syosetu'),
    );
    expect(
      m.available.where((LnReaderRepoPlugin p) => p.id == 'broken'),
      isEmpty,
    );
    final LnReaderStore bad = m.stores.firstWhere(
      (LnReaderStore s) => s.indexUrl.endsWith('/not-a-repo'),
    );
    expect(bad.lastError, isNotNull);
  });

  test('安装 → 落盘 → 更新保留启停 / 置顶 → 卸载清干净', () async {
    final FakeLnReaderRuntime runtime = FakeLnReaderRuntime();
    final LnReaderManager m = await ready(runtime: runtime);
    final LnReaderRepoPlugin plugin = m.available.firstWhere(
      (LnReaderRepoPlugin p) => p.id == 'yomou.syosetu',
    );
    await m.install(plugin);
    expect(m.installed.single.version, '1.1.4');
    expect(m.pluginFile(plugin.id).existsSync(), isTrue);
    expect(m.hasUpdate(plugin), isFalse);

    await m.setEnabled(m.installed.single, false);
    await m.setPinned(m.installed.single, true);

    index.first['version'] = '1.2.0';
    scripts['/Syosetu.js'] = 'exports.default = {v: 2};';
    await m.refreshStores();
    final LnReaderRepoPlugin newer = m.available.firstWhere(
      (LnReaderRepoPlugin p) => p.id == 'yomou.syosetu',
    );
    expect(m.hasUpdate(newer), isTrue);
    await m.install(newer);
    expect(m.installed.single.version, '1.2.0');
    expect(m.installed.single.enabled, isFalse);
    expect(m.installed.single.pinned, isTrue);
    expect(m.pluginFile(plugin.id).readAsStringSync(), contains('v: 2'));
    expect(runtime.forgotten, contains('yomou.syosetu'));

    await m.persistStorage('yomou.syosetu', <String, Object?>{'k': 1});
    await m.uninstall(m.installed.single);
    expect(m.installed, isEmpty);
    expect(m.pluginFile(plugin.id).existsSync(), isFalse);
    expect(
      Directory('${root.path}/storage').listSync(),
      isEmpty,
      reason: '卸载要连插件的 @libs/storage 一起删。',
    );
  });

  test('插件存储随装载送进运行时；插件 id 不能逃出根目录', () async {
    final FakeLnReaderRuntime runtime = FakeLnReaderRuntime();
    final LnReaderManager m = await ready(runtime: runtime);
    await m.install(m.available.first);
    await m.persistStorage('yomou.syosetu', <String, Object?>{'token': 'x'});
    await m.load(m.installed.single);
    expect(runtime.loaded, <String>['yomou.syosetu']);
    expect(m.pluginFile('../../evil').path, startsWith(root.path));
    expect(m.pluginFile('../../evil').path, isNot(contains('..')));
  });

  test('排序：上下移动持久化，置顶的永远在前', () async {
    final LnReaderManager m = await ready();
    index.add(<String, Object?>{
      'id': 'kakuyomu',
      'name': 'kakuyomu',
      'site': 'https://kakuyomu.jp/',
      'lang': '日本語',
      'version': '1.0.0',
      'url': '$base/kakuyomu.js',
      'iconUrl': '',
    });
    scripts['/kakuyomu.js'] = 'exports.default = {};';
    await m.refreshStores();
    for (final LnReaderRepoPlugin plugin in m.available) {
      await m.install(plugin);
    }
    expect(m.installed.map((LnReaderInstalledPlugin p) => p.id), <String>[
      'yomou.syosetu',
      'kakuyomu',
    ]);
    await m.move(m.installed.last, -1);
    expect(m.installed.first.id, 'kakuyomu');
    await m.setPinned(m.installed.last, true);
    expect(m.installed.first.id, 'yomou.syosetu');

    final LnReaderManager reopened = manager(FakeLnReaderRuntime());
    await reopened.initialise();
    expect(
      reopened.installed.map((LnReaderInstalledPlugin p) => p.id),
      <String>['yomou.syosetu', 'kakuyomu'],
    );
  });

  test('坏 state.json 不拖垮功能：按空状态起', () async {
    await File('${root.path}/state.json').writeAsString('{not json');
    final LnReaderManager m = manager(FakeLnReaderRuntime());
    await m.initialise();
    expect(m.installed, isEmpty);
    expect(m.stores.single.indexUrl, '$base/builtin.json');
  });

  test('索引解析：不是数组直接报错（填成仓库主页地址的常见错误）', () {
    expect(
      () => parseLnReaderIndex('{"a":1}', storeUrl: 'x'),
      throwsFormatException,
    );
    expect(parseLnReaderIndex('[]', storeUrl: 'x'), isEmpty);
  });

  test('版本比较按数字段，不按字符串', () {
    expect(compareLnReaderVersions('1.10.0', '1.9.3'), greaterThan(0));
    expect(compareLnReaderVersions('1.0', '1.0.0'), 0);
    expect(compareLnReaderVersions('2.0.0', '10.0.0'), lessThan(0));
  });

  test('仓库地址校验与显示名', () {
    expect(LnReaderManager.normaliseStoreUrl('ftp://x/y'), isNull);
    expect(
      LnReaderManager.normaliseStoreUrl('  https://a.b/c.json '),
      'https://a.b/c.json',
    );
    expect(
      lnReaderStoreDisplayName(kLnReaderOfficialStoreUrl),
      'LNReader/lnreader-plugins',
    );
  });

  // 审查：插件没有签名，来源仓库是唯一的身份绑定。第三方仓库发一个同 id、版本号
  // 更高的条目，不能顶掉已装插件的目录条目，也不能被「全部更新」静默装上。
  test('第三方仓库的同 id 高版本条目不算已装插件的更新', () async {
    final LnReaderManager m = await ready();
    final LnReaderRepoPlugin official = m.available.firstWhere(
      (LnReaderRepoPlugin p) => p.id == 'yomou.syosetu',
    );
    await m.install(official);
    await m.addStore('$base/evil.json');

    final LnReaderRepoPlugin listed = m.available.firstWhere(
      (LnReaderRepoPlugin p) => p.id == 'yomou.syosetu',
    );
    expect(listed.storeUrl, '$base/plugins.min.json');
    expect(m.available.where(m.hasUpdate), isEmpty);
    expect(
      m.hasUpdate(
        LnReaderRepoPlugin.tryParse(<String, Object?>{
          'id': 'yomou.syosetu',
          'name': 'Syosetu',
          'site': 'https://yomou.syosetu.com/',
          'lang': '日本語',
          'version': '9.9.9',
          'url': '$base/Evil.js',
          'iconUrl': '',
        }, storeUrl: '$base/evil.json')!,
      ),
      isFalse,
    );
  });

  // 审查 B3：插件连续 storage.set、用户快速连点都会并发触发整份快照写盘。共用一个
  // `.part` 时几路写互相覆盖 / rename，落下坏 JSON，读取时被当空状态——整份丢失。
  test('并发写同一文件：最终 JSON 完好且是最后一次写入', () async {
    final LnReaderManager m = manager(FakeLnReaderRuntime());
    await m.initialise();
    await Future.wait(<Future<void>>[
      for (int i = 0; i < 20; i++)
        m.persistStorage('p', <String, Object?>{'n': i, 'pad': 'x' * 4096}),
    ]);
    final File file = File('${root.path}/storage/p.json');
    final Object? decoded = jsonDecode(await file.readAsString());
    expect((decoded! as Map)['n'], 19);
    expect(
      Directory(
        '${root.path}/storage',
      ).listSync().where((FileSystemEntity e) => e.path.endsWith('.part')),
      isEmpty,
    );
  });
}
