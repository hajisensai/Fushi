/// 上锁作品的解锁凭据（拍板台 qiqSbvdxrk）：应用内口令 + 系统验证兜底。
///
/// - 口令：只存 PBKDF2-HMAC-SHA256 的盐 + 摘要，放系统安全存储（iOS / macOS 钥匙串、
///   Android Keystore、Windows 凭据管理器、Linux libsecret），**只留在本机**——不进
///   备份、不随互联同步。上锁标记本身会同步，别的设备用它自己的口令 / 系统验证解锁；
/// - 系统验证：生物识别（指纹 / 面容 / Windows Hello）或设备锁屏密码。走原生通道
///   `app.fushi.reader/device_owner_auth`（Android `MainActivity`、iOS / macOS
///   `AppDelegate`、Windows runner `device_owner_auth.cpp`）；Linux 没有统一的系统
///   验证，只能用口令。忘了口令时用系统验证解锁、再重设口令。
///
/// 解锁成功只改 [MediaLockSession]（内存），不写任何持久状态。
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 系统安全存储的最小接口（测试注入内存实现）。
abstract interface class MediaLockSecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// [FlutterSecureStorage] 实现。选项与音乐插件保险库一致：出错不自动清空、只留在
/// 本机（不随 iCloud / 备份迁走）、macOS 用旧式登录钥匙串（侧载包没有描述文件）。
final class FlutterMediaLockSecretStore implements MediaLockSecretStore {
  const FlutterMediaLockSecretStore();

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
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

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// 内存实现（测试用）。
final class MemoryMediaLockSecretStore implements MediaLockSecretStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// 口令最短长度（数字 PIN 也行）。
const int kMediaLockPasscodeMinLength = 4;

/// 应用内解锁口令：PBKDF2-HMAC-SHA256（随机 16 字节盐），摘要在后台 isolate 里算。
final class MediaLockPasscode {
  MediaLockPasscode({
    required MediaLockSecretStore store,
    Random? random,
    this.iterations = defaultIterations,
  }) : _store = store,
       _random = random ?? Random.secure();

  /// 安全存储里的条目名。
  static const String storageKey = 'fushi.media_lock.passcode.v1';

  static const int defaultIterations = 120000;

  final MediaLockSecretStore _store;
  final Random _random;
  final int iterations;

  Future<bool> isSet() async => (await _store.read(storageKey)) != null;

  /// 设置 / 改口令（调用方负责先验证旧口令或系统验证）。
  Future<void> set(String passcode) async {
    if (passcode.length < kMediaLockPasscodeMinLength) {
      throw ArgumentError.value(passcode.length, 'passcode', 'too short');
    }
    final Uint8List salt = Uint8List.fromList(<int>[
      for (int i = 0; i < 16; i++) _random.nextInt(256),
    ]);
    final Uint8List hash = await _derive(passcode, salt, iterations);
    await _store.write(
      storageKey,
      jsonEncode(<String, Object>{
        'v': 1,
        'iter': iterations,
        'salt': base64Encode(salt),
        'hash': base64Encode(hash),
      }),
    );
  }

  /// 口令对不对。没设口令 / 存储里的记录坏了 = false（fail-closed）。
  Future<bool> verify(String passcode) async {
    final String? raw = await _store.read(storageKey);
    if (raw == null) return false;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return false;
    }
    if (decoded is! Map) return false;
    final Object? iter = decoded['iter'];
    final Object? salt = decoded['salt'];
    final Object? hash = decoded['hash'];
    if (iter is! int || iter <= 0 || salt is! String || hash is! String) {
      return false;
    }
    final Uint8List expected;
    final Uint8List saltBytes;
    try {
      expected = base64Decode(hash);
      saltBytes = base64Decode(salt);
    } on FormatException {
      return false;
    }
    final Uint8List actual = await _derive(passcode, saltBytes, iter);
    return _constantTimeEquals(actual, expected);
  }

  Future<void> clear() => _store.delete(storageKey);

  static Future<Uint8List> _derive(
    String passcode,
    Uint8List salt,
    int iterations,
  ) => Isolate.run(
    () => pbkdf2HmacSha256(utf8.encode(passcode), salt, iterations, 32),
  );

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

/// PBKDF2-HMAC-SHA256（RFC 8018）。
Uint8List pbkdf2HmacSha256(
  List<int> password,
  List<int> salt,
  int iterations,
  int length,
) {
  final Hmac hmac = Hmac(sha256, password);
  final BytesBuilder out = BytesBuilder(copy: false);
  int block = 1;
  while (out.length < length) {
    final List<int> first = hmac.convert(<int>[
      ...salt,
      (block >> 24) & 0xff,
      (block >> 16) & 0xff,
      (block >> 8) & 0xff,
      block & 0xff,
    ]).bytes;
    final Uint8List acc = Uint8List.fromList(first);
    List<int> u = first;
    for (int i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (int j = 0; j < acc.length; j++) {
        acc[j] ^= u[j];
      }
    }
    out.add(acc);
    block++;
  }
  return Uint8List.sublistView(out.takeBytes(), 0, length);
}

/// 系统验证的结果。
enum DeviceOwnerAuthResult {
  /// 验证通过。
  success,

  /// 用户取消 / 没通过（不提示错误）。
  failed,

  /// 本机没有可用的系统验证（没设锁屏、平台不支持）。
  unavailable,
}

/// 系统验证（生物识别或设备锁屏密码）。
abstract interface class DeviceOwnerAuth {
  Future<bool> isAvailable();

  /// [reason] 显示在系统验证界面上。
  Future<DeviceOwnerAuthResult> authenticate(String reason);
}

/// 原生通道实现（Android / iOS / macOS / Windows；其余平台通道不存在 = 不可用）。
final class ChannelDeviceOwnerAuth implements DeviceOwnerAuth {
  const ChannelDeviceOwnerAuth();

  static const MethodChannel _channel = MethodChannel(
    'app.fushi.reader/device_owner_auth',
  );

  @override
  Future<bool> isAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<DeviceOwnerAuthResult> authenticate(String reason) async {
    try {
      final String? result = await _channel.invokeMethod<String>(
        'authenticate',
        <String, Object>{'reason': reason},
      );
      return switch (result) {
        'success' => DeviceOwnerAuthResult.success,
        'unavailable' => DeviceOwnerAuthResult.unavailable,
        _ => DeviceOwnerAuthResult.failed,
      };
    } on MissingPluginException {
      return DeviceOwnerAuthResult.unavailable;
    }
  }
}

/// 解锁凭据的装配点（测试替换 [instance]）。
final class MediaLockAuth {
  MediaLockAuth({required this.passcode, required this.device});

  static MediaLockAuth instance = MediaLockAuth(
    passcode: MediaLockPasscode(store: const FlutterMediaLockSecretStore()),
    device: const ChannelDeviceOwnerAuth(),
  );

  final MediaLockPasscode passcode;
  final DeviceOwnerAuth device;

  /// 本机至少有一种解锁方式（设了口令，或系统验证可用）。上锁之前必须满足，
  /// 否则锁上就再也打不开。
  Future<bool> hasAnyMethod() async =>
      await passcode.isSet() || await device.isAvailable();
}
