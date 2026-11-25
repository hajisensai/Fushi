import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_music/fushi_music.dart';
import 'package:test/test.dart';

import 'plugin_host_test.dart'
    show buildPlugin, fakePublicResolve, noRedirectProbe, testVaultKey;

/// 插件种类（docs/specs/2026-11-10-tracking-plugins.md §2）：追踪插件共用沙箱引擎，但音乐宿主
/// 拒装、不列、不开；追踪宿主直接用引擎（[MusicPluginNativeAsync] + [MusicPluginInstance.open]
/// 带 `vaultDomain: 'tracking'`）装和开，凭据与音乐体系互不可解。

const String trackingId = 'moe.test.tracking';

Map<String, Object?> trackingManifest() => <String, Object?>{
  'schema': 1,
  'kind': 'tracking',
  'id': trackingId,
  'name': 'Tracking',
  'version': '0.1.0',
  'api': 1,
  'entry': 'main.js',
  'capabilities': <String>[
    'login',
    'account',
    'trackingEntry',
    'trackingSubject',
  ],
  'permissions': <String>['network', 'credentials'],
  'network': <String, Object?>{
    'domains': <String>['api.example.org'],
    'methods': <String>['GET', 'POST'],
  },
  'tracking': <String, Object?>{
    'siteId': 'example',
    'siteHost': 'example.org',
    'kinds': <String>['anime', 'manga'],
    'defaultKinds': <String>['anime'],
    'modes': <String>['episode', 'chapter'],
    'requestsPerMinute': 30,
  },
};

const String trackingJs = r'''
module.exports = {
  async login(a) {
    if (a.op === 'submit') {
      await fushi.credentials.set('token', a.inputs.token);
      return { state: 'done' };
    }
    return { methods: [] };
  },
  async account() {
    const t = await fushi.credentials.get('token');
    return t ? { loggedIn: true, name: t } : { loggedIn: false };
  },
  trackingEntry(a) {
    if (a.op === 'get') return { status: 'current', progress: a.id * 2 };
    return null;
  },
  trackingSubject(a) { return { id: a.id, name: 'Subject ' + a.id, kind: 'anime' }; },
};
''';

Uint8List trackingZip() =>
    buildPlugin(trackingManifest(), <String, String>{'main.js': trackingJs});

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('fmp-tracking-'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  MusicPluginManager makeManager() => MusicPluginManager(
    rootDir: root,
    vaultKey: testVaultKey,
    httpClientFactory: HttpClient.new,
    resolver: fakePublicResolve,
    mediaProbe: noRedirectProbe,
    log: (_, _, _) {},
  );

  /// 绕过音乐管理器、直接经引擎装进 [root]（追踪宿主的做法）。
  Future<MusicPluginPackageInfo> installDirect(Uint8List zip) async {
    final Map<String, Object?> inspected = await MusicPluginNativeAsync.inspect(
      zip,
    );
    expect(inspected['error'], isNull);
    final MusicPluginPackageInfo info = MusicPluginPackageInfo.fromJson(
      inspected,
    );
    final Map<String, Object?> r = await MusicPluginNativeAsync.install(
      zip,
      root.path,
      info.digest,
    );
    expect(r['error'], isNull);
    return MusicPluginPackageInfo.fromJson(r);
  }

  Future<MusicPluginInstance> openDirect({String? vaultDomain}) =>
      MusicPluginInstance.open(
        dir: '${root.path}/$trackingId',
        storageFile: File('${root.path}/.storage/$trackingId.json'),
        httpClientFactory: HttpClient.new,
        log: (_, _, _) {},
        vaultRoot: root.path,
        vaultKey: testVaultKey,
        vaultDomain: vaultDomain,
        resolver: fakePublicResolve,
        mediaProbe: noRedirectProbe,
      );

  test('summary carries kind: music for old manifests, tracking + tracking '
      'object for tracking ones', () async {
    final MusicPluginPackageInfo info = MusicPluginPackageInfo.fromJson(
      await MusicPluginNativeAsync.inspect(trackingZip()),
    );
    expect(info.manifest.kind, MusicPluginManifest.kindTracking);
    expect(info.manifest.isMusic, isFalse);
    expect(info.manifest.tracking?['siteId'], 'example');
    expect(info.manifest.tracking?['requestsPerMinute'], 30);

    final Uint8List music = buildPlugin(
      <String, Object?>{
        'schema': 1,
        'id': 'moe.test.music',
        'name': 'Music',
        'version': '1.0.0',
        'api': 1,
        'entry': 'main.js',
        'capabilities': <String>['lyrics'],
      },
      <String, String>{'main.js': 'module.exports = { lyrics() {} };'},
    );
    final MusicPluginPackageInfo m = await makeManager().inspect(music);
    expect(m.manifest.kind, MusicPluginManifest.kindMusic);
    expect(m.manifest.isMusic, isTrue);
    expect(m.manifest.tracking, isNull);
  });

  test('music manager refuses a tracking-kind package at inspect and '
      'install', () async {
    final MusicPluginManager m = makeManager();
    final Uint8List zip = trackingZip();
    await expectLater(
      m.inspect(zip),
      throwsA(
        isA<MusicPluginException>().having(
          (MusicPluginException e) => e.message,
          'message',
          contains('tracking'),
        ),
      ),
    );
    final String digest = MusicPluginPackageInfo.fromJson(
      await MusicPluginNativeAsync.inspect(zip),
    ).digest;
    await expectLater(
      m.install(zip, digest),
      throwsA(isA<MusicPluginException>()),
    );
    expect(Directory('${root.path}/$trackingId').existsSync(), isFalse);
    await m.dispose();
  });

  test('music manager does not list or open a tracking plugin found in its '
      'folder', () async {
    await installDirect(trackingZip());
    expect(Directory('${root.path}/$trackingId').existsSync(), isTrue);
    final MusicPluginManager m = makeManager();
    expect(await m.list(), isEmpty);
    await expectLater(
      m.instance(trackingId),
      throwsA(isA<MusicPluginException>()),
    );
    await m.dispose();
  });

  test('tracking plugin installs and opens through the engine directly and a '
      'declared tracking capability runs', () async {
    final MusicPluginPackageInfo info = await installDirect(trackingZip());
    expect(info.manifest.kind, MusicPluginManifest.kindTracking);
    final MusicPluginInstance inst = await openDirect(vaultDomain: 'tracking');
    try {
      expect(inst.info.manifest.kind, MusicPluginManifest.kindTracking);
      expect(
        await inst.invoke('trackingEntry', <String, Object?>{
          'op': 'get',
          'id': 21,
        }),
        <String, Object?>{'status': 'current', 'progress': 42},
      );
      expect(
        await inst.invoke('trackingSubject', <String, Object?>{'id': 3}),
        <String, Object?>{'id': 3, 'name': 'Subject 3', 'kind': 'anime'},
      );
      // 清单没声明的能力照样拒。
      await expectLater(
        inst.invoke('trackingSearch', <String, Object?>{'query': 'x'}),
        throwsA(isA<MusicPluginException>()),
      );
    } finally {
      await inst.close();
    }
  });

  test('credentials written in the tracking vault domain are not readable '
      'without it', () async {
    await installDirect(trackingZip());
    final MusicPluginInstance tracking = await openDirect(
      vaultDomain: 'tracking',
    );
    await tracking.invoke('login', <String, Object?>{
      'op': 'submit',
      'inputs': <String, Object?>{'token': 'alice'},
    });
    expect(
      await tracking.invoke('account', <String, Object?>{}),
      <String, Object?>{'loggedIn': true, 'name': 'alice'},
    );
    await tracking.close();

    final MusicPluginInstance music = await openDirect();
    expect(
      await music.invoke('account', <String, Object?>{}),
      <String, Object?>{'loggedIn': false},
    );
    // 反向：音乐体系写的，追踪体系也读不出。
    await music.invoke('login', <String, Object?>{
      'op': 'submit',
      'inputs': <String, Object?>{'token': 'bob'},
    });
    await music.close();

    final MusicPluginInstance again = await openDirect(vaultDomain: 'tracking');
    expect(
      await again.invoke('account', <String, Object?>{}),
      <String, Object?>{'loggedIn': false},
    );
    await again.close();
  });
}
