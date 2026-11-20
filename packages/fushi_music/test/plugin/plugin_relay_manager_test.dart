import 'dart:async';
import 'dart:io';

import 'package:fushi_music/fushi_music.dart';
import 'package:test/test.dart';

MusicPluginPackageInfo _info(
  String id, {
  List<String> caps = const <String>['search', 'stream', 'login', 'account'],
  String digest = 'd1',
}) => MusicPluginPackageInfo(
  manifest: MusicPluginManifest(
    id: id,
    name: id.toUpperCase(),
    version: '1.0.0',
    api: 1,
    capabilities: caps,
    searchTypes: const <String>['song'],
    permissions: const <String>['webAuth'],
    networkDomains: const <String>['example.com'],
    author: 'someone',
  ),
  digest: digest,
  signer: null,
  files: const <String>['main.js'],
);

/// 中继替身：一次调用一条记录，结果按方法名给。
class _FakeRuntime implements MusicPluginRuntime {
  _FakeRuntime(this.info);

  @override
  final MusicPluginPackageInfo info;

  final List<String> calls = <String>[];

  @override
  bool get isAlive => true;

  @override
  Future<Object?> invoke(
    String method,
    Map<String, Object?> args, {
    Duration? timeout,
  }) async {
    calls.add(method);
    return switch (method) {
      'search' => <String, Object?>{
        'items': <Object?>[
          <String, Object?>{
            'id': 't1',
            'title': 'Song',
            'coverUrl': 'https://img.example.com/a.jpg',
          },
          <String, Object?>{
            'id': 't2',
            'title': 'Other',
            'coverUrl': 'https://evil.example.org/b.jpg',
          },
        ],
        'hasMore': false,
      },
      'stream' => <String, Object?>{
        'url': 'https://cdn.example.com/x.flac',
        'headers': <String, Object?>{'Referer': 'https://example.com/'},
      },
      _ => null,
    };
  }

  @override
  Map<String, String> checkRequestUrls(Iterable<String> urls) =>
      const <String, String>{};

  @override
  Future<Map<String, String>> checkCoverUrls(Iterable<String> urls) async =>
      <String, String>{
        for (final String u in urls)
          if (u.startsWith('https://img.')) u: 'https://relay/cover?u=$u',
      };

  @override
  Future<({String url, Map<String, String> headers})> resolveMediaStream(
    String url,
    Map<String, String> headers,
  ) async => (
    url: 'https://host:1/api/interconnect/plugin-relay/stream/T',
    headers: const <String, String>{},
  );
}

class _FakeRelay implements MusicPluginRelay {
  final StreamController<void> controller = StreamController<void>.broadcast();
  List<MusicPluginRelayedPlugin> plugins = <MusicPluginRelayedPlugin>[];
  final Map<String, _FakeRuntime> opened = <String, _FakeRuntime>{};

  @override
  Stream<void> get changes => controller.stream;

  @override
  Future<List<MusicPluginRelayedPlugin>> list() async => plugins;

  @override
  Future<MusicPluginRuntime> open(String id) async {
    for (final MusicPluginRelayedPlugin p in plugins) {
      if (p.id == id) return opened[id] ??= _FakeRuntime(p.info);
    }
    throw MusicPluginUnavailableException(
      'gone',
      pluginId: id,
      reason: MusicPluginUnavailableReason.notInstalled,
    );
  }
}

void main() {
  test('清单 / 包摘要 toJson 与 fromJson 对称；去掉登录能力其余原样', () {
    final MusicPluginPackageInfo info = _info('demo');
    final MusicPluginPackageInfo back = MusicPluginPackageInfo.fromJson(
      info.toJson(),
    );
    expect(back.digest, 'd1');
    expect(back.signer, isNull);
    expect(back.files, <String>['main.js']);
    expect(back.manifest.id, 'demo');
    expect(back.manifest.name, 'DEMO');
    expect(back.manifest.capabilities, info.manifest.capabilities);
    expect(back.manifest.networkDomains, <String>['example.com']);
    expect(back.manifest.permissions, <String>['webAuth']);
    expect(back.manifest.author, 'someone');
    expect(back.manifest.isMusic, isTrue);

    final MusicPluginManifest relayed = info.manifest.withoutCapabilities(
      kMusicPluginRelayExcludedCapabilities,
    );
    expect(relayed.can(MusicPluginCapability.login), isFalse);
    expect(relayed.capabilities, <String>['search', 'stream', 'account']);
    expect(relayed.id, 'demo');
  });

  group('MusicPluginManager + relay', () {
    late Directory root;
    late _FakeRelay relay;
    late MusicPluginManager manager;

    setUp(() {
      root = Directory.systemTemp.createTempSync('plugin_relay_');
      relay = _FakeRelay()
        ..plugins = <MusicPluginRelayedPlugin>[
          MusicPluginRelayedPlugin(info: _info('zeta'), via: 'Desk'),
          MusicPluginRelayedPlugin(info: _info('alpha'), via: 'Desk'),
          MusicPluginRelayedPlugin(info: _info('Bad Id'), via: 'Desk'),
        ];
      manager = MusicPluginManager(
        rootDir: Directory('${root.path}/music_plugins'),
        httpClientFactory: HttpClient.new,
        log: (String _, String _, String _) {},
        relay: relay,
      );
    });

    tearDown(() async {
      await manager.dispose();
      root.deleteSync(recursive: true);
    });

    test('list 带上中继插件（按名排序、标出代跑设备、丢掉非法 id）；管理页只列本机装的', () async {
      final List<InstalledMusicPlugin> all = await manager.list();
      expect(all.map((InstalledMusicPlugin p) => p.id), <String>[
        'alpha',
        'zeta',
      ]);
      expect(all.every((InstalledMusicPlugin p) => p.isRelayed), isTrue);
      expect(all.first.relayedVia, 'Desk');
      expect(all.first.isMusicSource, isTrue);
      expect(await manager.listInstalled(), isEmpty);
    });

    test('source 经中继：类型化解析与封面核对照常，取流拿到 host 的流票地址', () async {
      final MusicPluginSource source = manager.source('alpha');
      final MusicPluginPage<MusicPluginTrack> page = await source.searchTracks(
        'q',
      );
      expect(page.items.map((MusicPluginTrack t) => t.id), <String>[
        't1',
        't2',
      ]);
      expect(
        page.items.first.coverUrl,
        'https://relay/cover?u=https://img.example.com/a.jpg',
      );
      expect(page.items.last.coverUrl, isNull, reason: '没过核对的封面当没有');

      final MusicPluginStream s = await source.stream('t1');
      expect(s.url, 'https://host:1/api/interconnect/plugin-relay/stream/T');
      expect(s.headers, isEmpty);
      expect(relay.opened['alpha']!.calls, <String>['search', 'stream']);
    });

    test('中继里没有的插件：notInstalled', () async {
      await expectLater(
        manager.source('nope').searchTracks('q'),
        throwsA(
          isA<MusicPluginUnavailableException>().having(
            (MusicPluginUnavailableException e) => e.reason,
            'reason',
            MusicPluginUnavailableReason.notInstalled,
          ),
        ),
      );
    });

    test('中继目录变了：管理器转发变更事件', () async {
      final Future<void> fired = manager.changes.first;
      relay.controller.add(null);
      await fired.timeout(const Duration(seconds: 2));
    });
  });
}
