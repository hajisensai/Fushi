import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/plugin/music_plugin_vault_key.dart';
import 'package:fushi_music/fushi_music.dart';

/// 保险库数据密钥进系统安全存储：旧版明文密钥文件一次性迁移（幂等、任何一步失败都不删旧文件）、
/// 全新密钥清掉解不开的残留密文、Windows 交给原生库（DPAPI）。
class _Store implements MusicPluginSecretStore {
  final Map<String, String> data = <String, String>{};
  bool failWrite = false;
  bool dropWrites = false;

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw StateError('keychain locked');
    if (!dropWrites) data[key] = value;
  }
}

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('fmp-vkey-'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File keyFile() => File('${root.path}/.credentials/key');

  Future<Map<String, Object?>> vault(Map<String, Object?> op) =>
      MusicPluginNativeAsync.vault(root.path, op);

  /// 造一个旧版现场：明文密钥文件 + 用它加密的一条凭据。
  Future<Uint8List> seedLegacy() async {
    final Uint8List legacy = Uint8List.fromList(
      List<int>.generate(32, (int i) => i + 1),
    );
    expect(
      (await vault(<String, Object?>{
        'op': 'set',
        'plugin': 'moe.a',
        'key': 'cookie',
        'value': 'MUSIC_U=1',
        'dataKey': base64.encode(legacy),
      }))['error'],
      isNull,
    );
    keyFile().writeAsBytesSync(<int>[...utf8.encode('file:'), ...legacy]);
    return legacy;
  }

  Future<Object?> cookie(Uint8List key) async => (await vault(<String, Object?>{
    'op': 'get',
    'plugin': 'moe.a',
    'key': 'cookie',
    'dataKey': base64.encode(key),
  }))['value'];

  MusicPluginVaultKey make(_Store store) =>
      MusicPluginVaultKey(vaultRoot: root.path, store: store, osManaged: false);

  test('旧明文密钥迁进安全存储后删除，凭据照常解开；再取幂等', () async {
    final Uint8List legacy = await seedLegacy();
    final _Store store = _Store();
    final Uint8List? k = await make(store).call();
    expect(k, legacy);
    expect(store.data[MusicPluginVaultKey.storageKey], base64.encode(legacy));
    expect(keyFile().existsSync(), isFalse);
    expect(await cookie(k!), 'MUSIC_U=1');
    expect(await make(store).call(), legacy);
  });

  test('安全存储写失败 / 没存住：抛错且不删旧密钥文件，修好后再取成功', () async {
    final Uint8List legacy = await seedLegacy();
    final _Store store = _Store()..failWrite = true;
    final MusicPluginVaultKey key = make(store);
    await expectLater(key.call(), throwsA(isA<StateError>()));
    expect(keyFile().existsSync(), isTrue);

    store
      ..failWrite = false
      ..dropWrites = true;
    await expectLater(key.call(), throwsA(isA<StateError>()));
    expect(keyFile().existsSync(), isTrue);

    store.dropWrites = false;
    expect(await key.call(), legacy, reason: '失败不缓存，下次重试');
    expect(keyFile().existsSync(), isFalse);
    expect(await cookie(legacy), 'MUSIC_U=1');
  });

  test('上次迁移写进安全存储但没删旧文件：这次补删', () async {
    final Uint8List legacy = await seedLegacy();
    final _Store store = _Store()
      ..data[MusicPluginVaultKey.storageKey] = base64.encode(legacy);
    expect(await make(store).call(), legacy);
    expect(keyFile().existsSync(), isFalse);
  });

  test('两边都没有：生成新密钥存进安全存储，清掉解不开的残留密文', () async {
    await seedLegacy();
    keyFile().deleteSync();
    final _Store store = _Store();
    final Uint8List? k = await make(store).call();
    expect(k, hasLength(32));
    expect(store.data[MusicPluginVaultKey.storageKey], base64.encode(k!));
    expect(File('${root.path}/.credentials/moe.a.json').existsSync(), isFalse);
  });

  test('Windows：交给原生库（DPAPI），不碰安全存储', () async {
    final _Store store = _Store();
    final MusicPluginVaultKey key = MusicPluginVaultKey(
      vaultRoot: root.path,
      store: store,
      osManaged: true,
    );
    expect(await key.call(), isNull);
    expect(store.data, isEmpty);
  });
}
