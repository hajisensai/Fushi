import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_music/fushi_music.dart';
import 'package:test/test.dart';

import 'plugin_host_test.dart' show buildPlugin, manifest, testVaultKey;

/// 覆盖安装核对签名者：同一签名者（含都未签名）的升级保留登录与存储；签名者对不上（含已装包
/// 校验失败）按新插件处理、清掉旧插件的凭据与存储，别人不能靠同一个 id 继承用户的登录态。
void main() {
  late Directory root;
  late MusicPluginManager m;

  const String js = r'''
module.exports = {
  async search() { return { items: [], hasMore: false, total: 0 }; },
  async album() { return null; },
  async stream(a) { return { url: 'https://m1.cdn.example.com/' + a.id + '.mp3' }; },
  async lyrics() { return null; },
};
''';

  setUp(() {
    root = Directory.systemTemp.createTempSync('fmp-signer-');
    m = MusicPluginManager(
      rootDir: root,
      vaultKey: testVaultKey,
      httpClientFactory: HttpClient.new,
      log: (_, _, _) {},
    );
  });
  tearDown(() async {
    await m.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> install(Uint8List zip) async =>
      m.install(zip, (await m.inspect(zip)).digest);

  /// 直接调保险库时照宿主契约带上数据密钥（Windows 为 null：Rust 侧 DPAPI 封装的磁盘密钥）。
  Future<Map<String, Object?>> vault(Map<String, Object?> op) async {
    final Uint8List? key = await testVaultKey?.call();
    return MusicPluginNativeAsync.vault(root.path, <String, Object?>{
      ...op,
      if (key != null) 'dataKey': base64Encode(key),
    });
  }

  Future<void> seedData(String id) async {
    m.storageFileFor(id)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('{"token":"abc"}');
    final Map<String, Object?> r = await vault(<String, Object?>{
      'op': 'set',
      'plugin': id,
      'key': 'cookie',
      'value': 'MUSIC_U=1',
    });
    expect(r['error'], isNull);
  }

  Future<Object?> cookie(String id) async => (await vault(<String, Object?>{
    'op': 'get',
    'plugin': id,
    'key': 'cookie',
  }))['value'];

  test('同一签名者升级：不算换签名者，登录与存储保留', () async {
    final Uint8List zip = buildPlugin(manifest(), <String, String>{
      'main.js': js,
    });
    await install(zip);
    const String id = 'moe.test.fake';
    await seedData(id);
    expect(await m.signerChanged(await m.inspect(zip)), isFalse);
    await install(zip);
    expect(m.storageFileFor(id).existsSync(), isTrue);
    expect(await cookie(id), 'MUSIC_U=1');
  });

  test('已装包对不上（被改过 / 签名者不同）：按新插件处理，清掉凭据与存储', () async {
    final Uint8List zip = buildPlugin(manifest(), <String, String>{
      'main.js': js,
    });
    await install(zip);
    const String id = 'moe.test.fake';
    await seedData(id);
    // 已装目录被改动：无法核实它的签名者，视同签名者变了。
    File('${root.path}/$id/main.js').writeAsStringSync('// tampered');
    expect(await m.signerChanged(await m.inspect(zip)), isTrue);
    await install(zip);
    expect(m.storageFileFor(id).existsSync(), isFalse);
    expect(await cookie(id), isNull);
  });

  test('只有受信公钥才算已验证；当前没有内置受信公钥', () async {
    expect(kMusicPluginTrustedSigners, isEmpty);
    final MusicPluginPackageInfo info = await m.inspect(
      buildPlugin(manifest(), <String, String>{'main.js': js}),
    );
    expect(info.signer, isNull);
    expect(info.trustedSigner, isFalse);
  });
}
