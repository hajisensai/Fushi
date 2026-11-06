import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:fushi_music/fushi_music.dart';

/// 系统安全存储的最小接口（测试注入内存实现）。
abstract interface class MusicPluginSecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

/// [FlutterSecureStorage] 实现：iOS / macOS Keychain、Android Keystore、Linux libsecret。
final class FlutterMusicPluginSecretStore implements MusicPluginSecretStore {
  const FlutterMusicPluginSecretStore();

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    // 出错不自动清空：清空 = 数据密钥没了、所有插件掉登录，而且是静默的。宁可让这次凭据操作
    // 报错（插件显示失败原因）。
    aOptions: AndroidOptions(resetOnError: false),
    // 只留在本机：钥匙串不随 iCloud / 备份迁到别的设备（凭据密文同样不随备份走）。
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
    // 旧式登录钥匙串：数据保护钥匙串要 keychain-access-groups entitlement + 描述文件，Developer
    // ID 侧载包没有描述文件（docs/agent/apple-signing.md），开了就会静默写不进去。
    mOptions: MacOsOptions(
      usesDataProtectionKeychain: false,
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

/// 音乐插件凭据保险库的数据密钥（32 字节）：非 Windows 平台存在系统安全存储里，取出后随每次
/// 保险库调用交给 Rust（Rust 不在磁盘上存密钥）。Windows 返回 null：Rust 侧 DPAPI 封装的密钥
/// 文件本来就由操作系统按用户保护，保持原样。
///
/// 首次取时做一次性迁移：旧版把明文密钥落在 `<插件根>/.credentials/key`（`file:` 方案）——
/// 读出 → 写进安全存储 → 读回核对一致 → 才删磁盘上的旧文件。任何一步失败都不删旧文件、抛错
/// （本次凭据操作失败，下次再试），所以迁移幂等、失败不丢凭据。
final class MusicPluginVaultKey {
  MusicPluginVaultKey({
    required this.vaultRoot,
    required MusicPluginSecretStore store,
    bool? osManaged,
    Random? random,
  }) : _store = store,
       _osManaged = osManaged ?? Platform.isWindows,
       _random = random ?? Random.secure();

  /// 安全存储里的条目名。
  static const String storageKey = 'fushi.music_plugins.vault_key.v1';

  final String vaultRoot;
  final MusicPluginSecretStore _store;
  final bool _osManaged;
  final Random _random;
  Future<Uint8List?>? _key;

  /// 取数据密钥（成功后缓存；失败不缓存，下次重试）。
  Future<Uint8List?> call() {
    if (_osManaged) return Future<Uint8List?>.value();
    return _key ??= _load().then<Uint8List?>(
      (Uint8List k) => k,
      onError: (Object e, StackTrace st) {
        _key = null;
        Error.throwWithStackTrace(e, st);
      },
    );
  }

  Future<Uint8List> _load() async {
    final Uint8List? stored = _decode(await _store.read(storageKey));
    final Uint8List? legacy = _decode(
      (await _native(<String, Object?>{'op': 'legacyKey'}))['value'] as String?,
    );
    if (stored != null) {
      // 上次迁移写进去了但没来得及删旧文件：一致就补删；不一致说明旧文件不是它的来源，留着不动。
      if (legacy != null && _same(legacy, stored)) await _dropLegacy(stored);
      return stored;
    }
    if (legacy != null) {
      await _persist(legacy);
      await _dropLegacy(legacy);
      return legacy;
    }
    final Uint8List fresh = Uint8List.fromList(<int>[
      for (int i = 0; i < 32; i++) _random.nextInt(256),
    ]);
    await _persist(fresh);
    // 全新密钥下任何残留密文都解不开：清掉。
    await _native(<String, Object?>{'op': 'resetAll'});
    return fresh;
  }

  /// 写进安全存储并读回核对；对不上抛错（不能拿一把没存住的密钥去加密）。
  Future<void> _persist(Uint8List key) async {
    final String encoded = base64.encode(key);
    await _store.write(storageKey, encoded);
    final Uint8List? back = _decode(await _store.read(storageKey));
    if (back == null || !_same(back, key)) {
      throw StateError('系统安全存储没有存住音乐插件凭据密钥');
    }
  }

  Future<void> _dropLegacy(Uint8List key) => _native(<String, Object?>{
    'op': 'dropLegacyKey',
    'dataKey': base64.encode(key),
  });

  Future<Map<String, Object?>> _native(Map<String, Object?> op) async {
    final Map<String, Object?> r = await MusicPluginNativeAsync.vault(
      vaultRoot,
      op,
    );
    if (r['error'] case final String e) throw StateError(e);
    return r;
  }

  static Uint8List? _decode(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      final Uint8List k = base64.decode(s);
      return k.length == 32 ? k : null;
    } on FormatException {
      return null;
    }
  }

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
