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

/// 互联「来源共享」的前提（拍板台 wOMR4_Er7s）：host 上已装、已运行过（写过存储）的插件
/// 目录经 [MusicPluginManager.exportPackage] 打回包后，原生 inspect 算出的摘要必须等于 host
/// 已装那份，另一台设备能原样装上。宿主若往包目录里写了任何额外文件，这里会红——那样
/// 所有共享插件每轮都会报 digest mismatch、永远装不上。
const String _js = r'''
module.exports = {
  async search(a) {
    await fushi.storage.set('k', 'v');
    return { items: [], hasMore: false, total: 0 };
  },
  async album() { return null; },
  async stream(a) { return { url: 'https://m1.cdn.example.com/' + a.id + '.mp3' }; },
  async lyrics() { return null; },
};
''';

MusicPluginManager _manager(Directory root) => MusicPluginManager(
  rootDir: root,
  vaultKey: testVaultKey,
  httpClientFactory: HttpClient.new,
  resolver: fakePublicResolve,
  mediaProbe: noRedirectProbe,
  log: (_, _, _) {},
);

void main() {
  late Directory hostRoot;
  late Directory phoneRoot;

  setUp(() {
    hostRoot = Directory.systemTemp.createTempSync('fmp-share-host-');
    phoneRoot = Directory.systemTemp.createTempSync('fmp-share-phone-');
  });
  tearDown(() {
    for (final Directory d in <Directory>[hostRoot, phoneRoot]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });

  test('已装并运行过的插件：打包 → inspect 摘要不变 → 另一台装上摘要一致', () async {
    final MusicPluginManager host = _manager(hostRoot);
    final Uint8List original = buildPlugin(manifest(), <String, String>{
      'main.js': _js,
    });
    await host.install(original, (await host.inspect(original)).digest);
    // 跑一次插件，让宿主写下插件存储（在包目录之外）。
    final MusicPluginInstance inst = await host.instance('moe.test.fake');
    await inst.invoke('search', <String, Object?>{
      'query': 'x',
      'type': 'song',
    });
    expect(host.storageFileFor('moe.test.fake').existsSync(), isTrue);

    final InstalledMusicPlugin installed = (await host.list()).single;
    final String digest = installed.info!.digest;

    final Uint8List zip = (await host.exportPackage('moe.test.fake'))!;
    final MusicPluginPackageInfo inspected = await host.inspect(zip);
    expect(inspected.digest, digest);
    expect(inspected.signer, installed.info!.signer);

    final MusicPluginManager phone = _manager(phoneRoot);
    await phone.install(zip, inspected.digest);
    expect((await phone.list()).single.info!.digest, digest);

    // 装好的那份再打一次包，摘要仍不变（client 也可能再当 host）。
    final Uint8List again = (await phone.exportPackage('moe.test.fake'))!;
    expect((await phone.inspect(again)).digest, digest);

    await host.dispose();
    await phone.dispose();
  });
}
