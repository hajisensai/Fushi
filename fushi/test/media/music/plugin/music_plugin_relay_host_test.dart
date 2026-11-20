// 互联「插件中继」host 实现（AppMusicPluginRelayHost）在真实 MusicPluginManager 上的判据：
// 目录只出已装、启用、是音乐插件、主人勾选共享的，且去掉 login；调用把「不可用」映射成
// plugin_not_available、插件自己报错映射成 plugin_error、没声明 / 不经中继的能力拒绝。
// 对端假 host 测不到这些映射（见 test/sync/interconnect_plugin_relay_test.dart）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:fushi/src/media/music/plugin/music_plugin_relay_host.dart';
import 'package:fushi_engine/sync/interconnect_plugin_relay.dart';
import 'package:fushi_music/fushi_music.dart';

const String _js = r'''
module.exports = {
  async search(a) {
    if (a.query === 'boom') throw new Error('平台报错');
    return { items: [{ id: '1', title: 'T' }], hasMore: false, total: 1 };
  },
  async album() { return null; },
  async stream(a) { return { url: 'https://m1.cdn.example.com/' + a.id + '.mp3' }; },
  async lyrics() { return null; },
  async login() { return { state: 'done' }; },
  async account() { return { loggedIn: false }; },
};
''';

Uint8List _plugin(String id, List<String> caps) {
  final Map<String, Object?> manifest = <String, Object?>{
    'schema': 1,
    'id': id,
    'name': 'Plugin $id',
    'version': '1.0.0',
    'api': 1,
    'entry': 'main.js',
    'capabilities': caps,
    'searchTypes': <String>['song'],
    'permissions': <String>['network', 'credentials', 'webAuth'],
    'network': <String, Object?>{
      'domains': <String>['api.example.com', '*.cdn.example.com'],
      'methods': <String>['GET'],
    },
  };
  final Map<String, List<int>> files = <String, List<int>>{
    'manifest.json': utf8.encode(jsonEncode(manifest)),
    'main.js': utf8.encode(_js),
  };
  final Archive a = Archive();
  for (final MapEntry<String, List<int>> e in files.entries) {
    a.addFile(ArchiveFile(e.key, e.value.length, e.value));
  }
  final List<int> listing = utf8.encode(
    jsonEncode(<String, Object?>{
      'files': <String, String>{
        for (final MapEntry<String, List<int>> e in files.entries)
          e.key: sha256.convert(e.value).toString(),
      },
    }),
  );
  a.addFile(ArchiveFile('files.json', listing.length, listing));
  return Uint8List.fromList(ZipEncoder().encode(a)!);
}

Matcher _relayError(String code) => throwsA(
  isA<InterconnectPluginRelayError>().having(
    (InterconnectPluginRelayError e) => e.code,
    'code',
    code,
  ),
);

void main() {
  late Directory root;
  late MusicPluginManager manager;
  late Set<String> shared;
  late AppMusicPluginRelayHost host;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('relay-host-');
    manager = MusicPluginManager(
      rootDir: root,
      vaultKey: Platform.isWindows
          ? null
          : () async => Uint8List.fromList(List<int>.filled(32, 7)),
      httpClientFactory: HttpClient.new,
      resolver: (String _) async => <InternetAddress>[
        InternetAddress('93.184.216.34'),
      ],
      mediaProbe: (Uri _, Map<String, String> _) async => null,
      log: (_, _, _) {},
    );
    for (final String id in <String>[
      'moe.test.a',
      'moe.test.b',
      'moe.test.c',
    ]) {
      final Uint8List zip = _plugin(id, <String>[
        'search',
        'album',
        'stream',
        'lyrics',
        'login',
        'account',
      ]);
      await manager.install(zip, (await manager.inspect(zip)).digest);
    }
    // b 停用；c 没勾选共享。
    await manager.setEnabled('moe.test.b', false);
    shared = <String>{'musicPlugin/moe.test.a', 'musicPlugin/moe.test.b'};
    host = AppMusicPluginRelayHost(
      manager: () => manager,
      enabled: () async => true,
      isOwnerDevicePeer: (String _) async => true,
      httpClientFactory: HttpClient.new,
      sharedItems: () async => shared,
    );
  });

  tearDown(() async {
    await manager.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('目录：只出启用且勾选共享的音乐插件，去掉 login', () async {
    final List<Map<String, Object?>> catalog = await host.pluginRelayCatalog();
    final List<MusicPluginPackageInfo> infos = <MusicPluginPackageInfo>[
      for (final Map<String, Object?> j in catalog)
        MusicPluginPackageInfo.fromJson(j),
    ];
    expect(infos.map((MusicPluginPackageInfo i) => i.manifest.id), <String>[
      'moe.test.a',
    ]);
    expect(
      infos.single.manifest.can(MusicPluginCapability.login),
      isFalse,
      reason: '登录不经中继',
    );
    expect(infos.single.manifest.can(MusicPluginCapability.account), isTrue);
  });

  test('调用：停用 / 没勾选 / 没装都是 plugin_not_available', () async {
    final Map<String, Object?> args = <String, Object?>{
      'query': 'x',
      'type': 'song',
      'page': 0,
      'pageSize': 10,
    };
    await expectLater(
      host.pluginRelayInvoke('moe.test.b', 'search', args),
      _relayError(kPluginRelayNotAvailable),
    );
    await expectLater(
      host.pluginRelayInvoke('moe.test.c', 'search', args),
      _relayError(kPluginRelayNotAvailable),
    );
    shared.add('musicPlugin/moe.test.none');
    await expectLater(
      host.pluginRelayInvoke('moe.test.none', 'search', args),
      _relayError(kPluginRelayNotAvailable),
    );
  });

  test('调用：login 与没声明的能力拒绝；插件报错是 plugin_error；正常返回原值', () async {
    await expectLater(
      host.pluginRelayInvoke('moe.test.a', 'login', const <String, Object?>{}),
      _relayError(kPluginRelayUnsupported),
    );
    await expectLater(
      host.pluginRelayInvoke('moe.test.a', 'home', const <String, Object?>{}),
      _relayError(kPluginRelayUnsupported),
    );
    await expectLater(
      host.pluginRelayInvoke('moe.test.a', 'search', <String, Object?>{
        'query': 'boom',
        'type': 'song',
        'page': 0,
        'pageSize': 10,
      }),
      _relayError(kPluginRelayPluginError),
    );
    final Object? value = await host.pluginRelayInvoke(
      'moe.test.a',
      'search',
      <String, Object?>{
        'query': 'ok',
        'type': 'song',
        'page': 0,
        'pageSize': 10,
      },
    );
    expect((value! as Map<Object?, Object?>)['total'], 1);
  });

  test('取消勾选后目录与调用立即收回', () async {
    shared.remove('musicPlugin/moe.test.a');
    expect(await host.pluginRelayCatalog(), isEmpty);
    await expectLater(
      host.pluginRelayCheckCovers('moe.test.a', const <String>[]),
      _relayError(kPluginRelayNotAvailable),
    );
  });
}
