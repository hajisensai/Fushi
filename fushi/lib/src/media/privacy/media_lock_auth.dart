/// 上锁作品的解锁凭据（拍板台 qiqSbvdxrk）：应用内口令 + 系统验证兜底。
///
/// - 口令：只存 PBKDF2-HMAC-SHA256 的盐 + 摘要，放在库里的 `media_lock_credentials`
///   （v171），**随上锁标记一起同步、一起进备份**：锁到了哪台设备，口令摘要就跟到
///   哪台，各设备认同一个口令。只留在本机的话，一台既没设口令、系统验证也不可用的
///   设备上，「新设一个口令」就能打开同步来的锁；
/// - 系统验证：生物识别（指纹 / 面容）或设备锁屏密码。走原生通道
///   `app.fushi.reader/device_owner_auth`（Android `MainActivity`、iOS / macOS
///   `AppDelegate`）；Windows / Linux 暂未接（通道缺失 = 不可用），只能用口令；
/// - 连续输错的冷却状态存系统安全存储（只在本机），重启 app 不清零。
///
/// 规则（[MediaLockAuth.verifyOwnerPlan] / [MediaLockAuth.passcodeChangePlan]）：
/// - 有口令：口令或系统验证都行；
/// - 没口令：系统验证可用就走系统验证；不可用时，本机若还有上锁的作品（只可能是从
///   别的设备同步来、或口令被别的设备删了），**不许**靠新设口令打开——提示去设过
///   口令的设备上重设，口令同步过来后再解锁；
/// - 删口令要先验证；还有上锁作品时，删了以后只能靠系统验证解锁，所以本机系统验证
///   不可用就不许删（先把作品改回公开 / 私密）。
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
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/privacy/media_lock.dart';

/// 系统安全存储的最小接口（测试注入内存实现）。只放本机状态（输错冷却）。
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

/// 口令摘要记录的存取（生产走库，测试可注入内存实现）。
abstract interface class MediaLockCredentialStore {
  /// 当前口令摘要；没设过 / 已删除 = null。
  Future<String?> readVerifier();

  /// 设 / 改（非空）或删除（null）。
  Future<void> writeVerifier(String? verifier);
}

/// 库实现：`media_lock_credentials`（随上锁标记同步 / 备份）。
final class DbMediaLockCredentialStore implements MediaLockCredentialStore {
  const DbMediaLockCredentialStore(this.db);

  final FushiDatabase db;

  @override
  Future<String?> readVerifier() async =>
      (await db.mediaLockCredential())?.verifier;

  @override
  Future<void> writeVerifier(String? verifier) =>
      db.setMediaLockCredential(verifier);
}

/// 内存实现（测试用）。
final class MemoryMediaLockCredentialStore implements MediaLockCredentialStore {
  String? verifier;

  @override
  Future<String?> readVerifier() async => verifier;

  @override
  Future<void> writeVerifier(String? value) async => verifier = value;
}

/// 口令最短长度（数字 PIN 也行）。
const int kMediaLockPasscodeMinLength = 4;

/// 应用内解锁口令：PBKDF2-HMAC-SHA256（随机 16 字节盐），摘要在后台 isolate 里算。
final class MediaLockPasscode {
  MediaLockPasscode({
    required MediaLockCredentialStore store,
    Random? random,
    this.iterations = defaultIterations,
  }) : _store = store,
       _random = random ?? Random.secure();

  static const int defaultIterations = 120000;

  final MediaLockCredentialStore _store;
  final Random _random;
  final int iterations;

  Future<bool> isSet() async => (await _store.readVerifier()) != null;

  /// 设置 / 改口令（调用方负责先按 [MediaLockAuth.passcodeChangePlan] 验证）。
  Future<void> set(String passcode) async {
    if (passcode.length < kMediaLockPasscodeMinLength) {
      throw ArgumentError.value(passcode.length, 'passcode', 'too short');
    }
    final Uint8List salt = Uint8List.fromList(<int>[
      for (int i = 0; i < 16; i++) _random.nextInt(256),
    ]);
    final Uint8List hash = await _derive(passcode, salt, iterations);
    await _store.writeVerifier(
      jsonEncode(<String, Object>{
        'v': 1,
        'iter': iterations,
        'salt': base64Encode(salt),
        'hash': base64Encode(hash),
      }),
    );
  }

  /// 口令对不对。没设口令 / 记录坏了 = false（fail-closed）。
  Future<bool> verify(String passcode) async {
    final String? raw = await _store.readVerifier();
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
    // 轮数有上限：记录随同步 / 备份进来，不能让一条坏记录把验证拖上几分钟。
    if (iter is! int || iter <= 0 || iter > _maxIterations) return false;
    if (salt is! String || hash is! String) return false;
    final Uint8List expected;
    final Uint8List saltBytes;
    try {
      expected = base64Decode(hash);
      saltBytes = base64Decode(salt);
    } on FormatException {
      return false;
    }
    final Uint8List actual = await _derive(passcode, saltBytes, iter);
    return constantTimeEquals(actual, expected);
  }

  static const int _maxIterations = 10000000;

  /// 删除口令（调用方负责先按 [MediaLockAuth.passcodeRemovalPlan] 验证）。
  Future<void> clear() => _store.writeVerifier(null);

  static Future<Uint8List> _derive(
    String passcode,
    Uint8List salt,
    int iterations,
  ) => Isolate.run(
    () => pbkdf2HmacSha256(utf8.encode(passcode), salt, iterations, 32),
  );
}

/// 长度相同的两段字节逐字节异或累计，比较耗时与在哪一位不同无关。
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  int diff = 0;
  for (int i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
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

/// 连续输错口令的冷却（只在本机，存系统安全存储，重启 app 不清零）。
///
/// 每连续错 [failuresPerRound] 次进一轮冷却；第 n 轮冷却 [baseCooldown] × 2^(n-1)，
/// 封顶 [maxCooldown]。口令或系统验证通过一次就全部清零。
final class MediaLockThrottle {
  MediaLockThrottle({
    required MediaLockSecretStore store,
    DateTime Function()? clock,
  }) : _store = store,
       _clock = clock ?? DateTime.now;

  static const String storageKey = 'fushi.media_lock.throttle.v1';
  static const int failuresPerRound = 5;
  static const Duration baseCooldown = Duration(seconds: 30);
  static const Duration maxCooldown = Duration(hours: 1);

  final MediaLockSecretStore _store;
  final DateTime Function() _clock;

  Future<({int failures, int rounds, int untilMs})> _read() async {
    final String? raw = await _store.read(storageKey);
    if (raw == null) return (failures: 0, rounds: 0, untilMs: 0);
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      // 记录坏了按「正在冷却最长一档」处理（fail-closed），下一次成功验证清零。
      return (
        failures: 0,
        rounds: 0,
        untilMs: _clock().add(maxCooldown).millisecondsSinceEpoch,
      );
    }
    int field(String name) =>
        decoded is Map && decoded[name] is int ? decoded[name] as int : 0;
    return (
      failures: field('failures'),
      rounds: field('rounds'),
      untilMs: field('until'),
    );
  }

  /// 正在冷却时返回结束时刻，否则 null。
  Future<DateTime?> coolingUntil() async {
    final int untilMs = (await _read()).untilMs;
    final DateTime until = DateTime.fromMillisecondsSinceEpoch(untilMs);
    return _clock().isBefore(until) ? until : null;
  }

  /// 记一次输错；这一次触发了冷却时返回冷却时长。
  Future<Duration?> recordFailure() async {
    final ({int failures, int rounds, int untilMs}) state = await _read();
    final int failures = state.failures + 1;
    if (failures < failuresPerRound) {
      await _write(failures: failures, rounds: state.rounds, untilMs: 0);
      return null;
    }
    final int rounds = state.rounds + 1;
    final int factor = 1 << min(rounds - 1, 20);
    final Duration cooldown = Duration(
      milliseconds: min(
        baseCooldown.inMilliseconds * factor,
        maxCooldown.inMilliseconds,
      ),
    );
    await _write(
      failures: 0,
      rounds: rounds,
      untilMs: _clock().add(cooldown).millisecondsSinceEpoch,
    );
    return cooldown;
  }

  /// 验证通过：清零。
  Future<void> recordSuccess() => _store.delete(storageKey);

  Future<void> _write({
    required int failures,
    required int rounds,
    required int untilMs,
  }) => _store.write(
    storageKey,
    jsonEncode(<String, int>{
      'failures': failures,
      'rounds': rounds,
      'until': untilMs,
    }),
  );
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

/// 原生通道实现（Android / iOS / macOS；其余平台通道不存在 = 不可用）。
final class ChannelDeviceOwnerAuth implements DeviceOwnerAuth {
  const ChannelDeviceOwnerAuth();

  static const MethodChannel _channel = MethodChannel(
    'app.fushi.reader/device_owner_auth',
  );

  /// 通道缺失 = 本平台没接；通道报错（取不到 KeyguardManager / LAContext 之类）=
  /// 此刻用不了，两种都按「不可用」处理，由调用方改走口令。
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

  /// 通道缺失按不可用；原生侧抛出的 [PlatformException] 原样上抛，由界面把原因
  /// 告诉用户（不当成「用户取消」吞掉）。
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

/// 验证机主时走哪条路（[MediaLockAuth.verifyOwnerPlan]）。
enum MediaLockVerifyPlan {
  /// 弹口令框（系统验证可用时框里多一个「改用系统验证」）。
  passcode,

  /// 没口令，直接走系统验证。
  device,

  /// 没口令、没系统验证、本机也没有上锁的作品：没有要保护的东西，直接放行。
  nothingToProtect,

  /// 没口令、没系统验证，但本机有上锁的作品：不许靠新设口令打开。
  blocked,
}

/// 改 / 设口令前要做的验证（[MediaLockAuth.passcodeChangePlan]）。
enum MediaLockPasscodeChangePlan {
  /// 已有口令：先验证机主（旧口令或系统验证）。
  verifyOwner,

  /// 没口令但本机有上锁的作品：先过系统验证。
  verifyDevice,

  /// 没口令、也没有上锁的作品：直接设。
  free,

  /// 没口令、有上锁的作品、系统验证不可用：不许设（会变成后门）。
  blocked,
}

/// 删除口令前的判定（[MediaLockAuth.passcodeRemovalPlan]）。
enum MediaLockPasscodeRemovalPlan {
  /// 没设口令，无从删除。
  notSet,

  /// 验证机主后可删。
  allowed,

  /// 还有上锁的作品而本机系统验证不可用：删了就再也打不开，不许删。
  blockedByLockedWorks,
}

/// 解锁凭据的装配点。生产按当前库现建（[forDatabase]）；测试替换 [debugOverride]。
final class MediaLockAuth {
  MediaLockAuth({
    required this.passcode,
    required this.device,
    required this.throttle,
    required Future<bool> Function() hasLockedWorks,
  }) : _hasLockedWorks = hasLockedWorks;

  /// 测试注入。
  static MediaLockAuth? debugOverride;

  /// [db] 上的解锁凭据：口令摘要在库里，冷却在系统安全存储里。
  static MediaLockAuth forDatabase(FushiDatabase db) =>
      debugOverride ??
      MediaLockAuth(
        passcode: MediaLockPasscode(store: DbMediaLockCredentialStore(db)),
        device: const ChannelDeviceOwnerAuth(),
        throttle: MediaLockThrottle(store: const FlutterMediaLockSecretStore()),
        hasLockedWorks: () async => !(await MediaLockSnapshot.load(db)).isEmpty,
      );

  final MediaLockPasscode passcode;
  final DeviceOwnerAuth device;
  final MediaLockThrottle throttle;
  final Future<bool> Function() _hasLockedWorks;

  /// 本机此刻是否还有上锁的作品（含上锁合集 / 专辑）。
  Future<bool> hasLockedWorks() => _hasLockedWorks();

  /// 本机至少有一种解锁方式（设了口令，或系统验证可用）。上锁之前必须满足，
  /// 否则锁上就再也打不开。
  Future<bool> hasAnyMethod() async =>
      await passcode.isSet() || await device.isAvailable();

  /// 验证机主走哪条路。
  Future<MediaLockVerifyPlan> verifyOwnerPlan() async {
    if (await passcode.isSet()) return MediaLockVerifyPlan.passcode;
    if (await device.isAvailable()) return MediaLockVerifyPlan.device;
    return await hasLockedWorks()
        ? MediaLockVerifyPlan.blocked
        : MediaLockVerifyPlan.nothingToProtect;
  }

  /// 设 / 改口令前要做的验证。
  Future<MediaLockPasscodeChangePlan> passcodeChangePlan() async {
    if (await passcode.isSet()) return MediaLockPasscodeChangePlan.verifyOwner;
    if (!await hasLockedWorks()) return MediaLockPasscodeChangePlan.free;
    return await device.isAvailable()
        ? MediaLockPasscodeChangePlan.verifyDevice
        : MediaLockPasscodeChangePlan.blocked;
  }

  /// 能不能删口令。
  Future<MediaLockPasscodeRemovalPlan> passcodeRemovalPlan() async {
    if (!await passcode.isSet()) return MediaLockPasscodeRemovalPlan.notSet;
    if (await hasLockedWorks() && !await device.isAvailable()) {
      return MediaLockPasscodeRemovalPlan.blockedByLockedWorks;
    }
    return MediaLockPasscodeRemovalPlan.allowed;
  }
}
