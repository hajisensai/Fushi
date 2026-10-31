// 冻结的旧版本（协议 1，develop@d407ae22ca）同步代码，只给 2026-10-30 格式断代的测试用：证明旧客户端碰到新格式的
// 位置时停下、一个字节都不改。原样复制，只改了包内互相引用的 import；不要修改、不要在测试之外引用。
// ignore_for_file: type=lint

/// 存储位置的端到端加密（docs/specs/2026-10-25-srs-sync-v2-design.md §9）：每个位置一个可选开关，默认关。
///
/// - 集合密钥 = Argon2id(口令, 盐, 参数)（内核 `derive_key`，后台 isolate 跑）。盐与参数写进该位置的 `meta.json`
///   的 `kdf`，外加一个**密钥校验值** `check`（密钥的 SHA-256 截断，不能反推密钥），别的设备输入口令后靠它判断
///   口令对不对，不必先去解一个段。
/// - 段由内核按位置加密（outbox / ingest 收 key）；媒体放 `media-e/`，内容经内核 `seal` / `open`（AAD 绑定文件名）。
///   开加密之前传上去的明文段 / 媒体留在原处，本机按新的上传进度身份（`<位置>#e`）把自己的段全部重传成密文；
///   旧明文由用户「清理此位置」删除（与「取消用途不删文件」同一纪律）。
/// - 开了就不能在这里关：关掉要把全部设备的段重传成明文，等于另起一个位置。**本机开过加密的位置，`meta.json`
///   上的 `kdf` 不见了（被删 / 被别的版本整份重写）一律报 [kSrsSync2EncryptionMissing] 停下，绝不降级成明文**；
///   `meta.json` 读不到但位置上已经有数据（最终一致的网盘暂时列不到）也不重写它（[kSrsSync2MetaUnavailable]）。
/// - 上传进度按「位置 + 密钥指纹」记（[srsLocationProgressId]）：两台设备同时开加密、后写的 `kdf` 胜出时，先开的那台
///   换上正确口令后密钥指纹变了，进度归零、全部段按新密钥重传；加密媒体同理按指纹分目录（[SrsMediaCipher.folder]）。
/// - KDF 参数来自不可信的 `meta.json`：越界（[kSrsKdfMinMemoryKib] 等）报 [kSrsSync2BadKdf]，不派生。
/// - 口令丢失 = 这个位置上的数据解不开，但每台设备本机都有完整日志，换个口令（或换个位置）重新发布即可。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'srs_location_store.dart';
import 'srs_sync2_round.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsSync2Result;

/// 位置开了加密但本机没有口令：这一轮不同步该位置（UI 提示输入口令）。
const String kSrsSync2NeedsKey = 'srs location needs passphrase';

/// 本机记的口令与位置上的不符（别的设备改过口令）：这一轮不同步该位置（UI 提示重新输入）。
const String kSrsSync2WrongKey = 'srs location passphrase mismatch';

/// 本机开过加密的位置，`meta.json` 上却没有 `kdf`（被删 / 被整份重写）：停下，不降级成明文。
const String kSrsSync2EncryptionMissing =
    'srs location lost its encryption settings';

/// 位置上 `meta.json` 的加密参数越界或格式不对：不派生、不同步。
const String kSrsSync2BadKdf = 'srs location encryption parameters invalid';

/// `meta.json` 此刻读不到 / 解析不了，但位置上已经有数据：不重写它（可能是最终一致的列目录还没看到），下一轮再试。
const String kSrsSync2MetaUnavailable = 'srs location meta.json unavailable';

/// 加密位置上媒体的目录（与明文 `media/` 分开，不会把开加密前的明文文件当密文解）；下一级按密钥指纹分。
const String kSrsSealedMediaFolder = 'media-e';

/// Argon2id 参数上下限（与内核 `KdfParams::MIN_*` / `MAX_*` 同一组）：参数来自不可信的 `meta.json`。
const int kSrsKdfMinMemoryKib = 8 * 1024;
const int kSrsKdfMaxMemoryKib = 256 * 1024;
const int kSrsKdfMinIterations = 1;
const int kSrsKdfMaxIterations = 10;
const int kSrsKdfMinParallelism = 1;
const int kSrsKdfMaxParallelism = 4;
const int kSrsKdfMinSaltBytes = 16;
const int kSrsKdfMaxSaltBytes = 64;

/// 密钥指纹（[srsKeyCheck] 的前 16 位 hex）：进度身份与加密媒体目录按它分。
String srsKeyFingerprint(String keyHex) => srsKeyCheck(keyHex).substring(0, 16);

/// 一个位置的上传进度身份：明文 = 位置本身；加密 = `<位置>#e<密钥指纹>`。换了密钥（另一台设备的 `kdf` 胜出、
/// 重新输入口令）就是另一个身份，进度从零开始，本机的段全部按新密钥重传（同名覆盖）。
String srsLocationProgressId(String locationId, String? keyHex) =>
    keyHex == null ? locationId : '$locationId#e${srsKeyFingerprint(keyHex)}';

/// [srsLocationProgressId] 的逆：进度身份 → 位置（界面把同一个位置的明文 / 加密进度合起来显示）。
String srsLocationOfProgressId(String progressId) {
  final int i = progressId.indexOf('#e');
  return i < 0 ? progressId : progressId.substring(0, i);
}

/// Argon2id 参数与盐（存进 `meta.json` 的 `kdf`）。
class SrsKdf {
  const SrsKdf({
    required this.saltHex,
    this.memoryKib = 64 * 1024,
    this.iterations = 3,
    this.parallelism = 1,
  });

  /// 解析并检查（参数来自不可信的 `meta.json`）：盐不是 [kSrsKdfMinSaltBytes]..[kSrsKdfMaxSaltBytes] 字节的 hex、
  /// 参数越界或类型不对一律抛 [FormatException]。缺的参数取默认值（默认值在界内）。
  factory SrsKdf.fromJson(Map<String, Object?> j) {
    final Object? salt = j['salt'];
    if (salt is! String ||
        salt.length.isOdd ||
        salt.length < 2 * kSrsKdfMinSaltBytes ||
        salt.length > 2 * kSrsKdfMaxSaltBytes ||
        !RegExp(r'^[0-9a-fA-F]+$').hasMatch(salt)) {
      throw const FormatException('srs kdf: bad salt');
    }
    int param(String key, int fallback, int lo, int hi) {
      final Object? v = j[key];
      if (v == null) return fallback;
      if (v is! int || v < lo || v > hi) {
        throw FormatException('srs kdf: $key out of range', v);
      }
      return v;
    }

    return SrsKdf(
      saltHex: salt,
      memoryKib: param(
        'm',
        64 * 1024,
        kSrsKdfMinMemoryKib,
        kSrsKdfMaxMemoryKib,
      ),
      iterations: param('t', 3, kSrsKdfMinIterations, kSrsKdfMaxIterations),
      parallelism: param('p', 1, kSrsKdfMinParallelism, kSrsKdfMaxParallelism),
    );
  }

  /// 新盐（16 字节，系统安全随机源）。
  factory SrsKdf.fresh() {
    final Random r = Random.secure();
    return SrsKdf(
      saltHex: _hex(<int>[for (int i = 0; i < 16; i++) r.nextInt(256)]),
    );
  }

  final String saltHex;
  final int memoryKib;
  final int iterations;
  final int parallelism;

  Map<String, Object?> toJson() => <String, Object?>{
    'alg': 'argon2id',
    'salt': saltHex,
    'm': memoryKib,
    't': iterations,
    'p': parallelism,
  };
}

/// 本机为一个位置记下的密钥（设备本地凭据：不进备份、不出现在日志里）。
class SrsLocationKey {
  const SrsLocationKey({
    required this.keyHex,
    required this.kdf,
    this.pendingEnable = false,
  });

  factory SrsLocationKey.fromJson(Map<String, Object?> j) => SrsLocationKey(
    keyHex: j['key'] as String? ?? '',
    kdf: SrsKdf.fromJson(
      (j['kdf'] as Map?)?.cast<String, Object?>() ?? const <String, Object?>{},
    ),
    pendingEnable: j['pending'] as bool? ?? false,
  );

  final String keyHex;
  final SrsKdf kdf;

  /// 用户刚在本机开了加密、位置上的 `meta.json` 还没写上 `kdf`（下一轮写）。
  final bool pendingEnable;

  /// 密钥校验值（写进 `meta.json`）。
  String get check => srsKeyCheck(keyHex);

  SrsLocationKey enabled() => SrsLocationKey(keyHex: keyHex, kdf: kdf);

  Map<String, Object?> toJson() => <String, Object?>{
    'key': keyHex,
    'kdf': kdf.toJson(),
    if (pendingEnable) 'pending': true,
  };
}

/// 密钥校验值：SHA-256(密钥 ‖ 常量) 的前 16 字节（hex）。
String srsKeyCheck(String keyHex) => sha256
    .convert(<int>[..._unhex(keyHex), ...utf8.encode('fushi-srs-key-check')])
    .toString()
    .substring(0, 32);

/// 用 [passphrase] 派生密钥（[kdf] 为空 = 新开加密，生成新盐）。
Future<SrsLocationKey> srsDeriveLocationKey(
  SrsSync2Host host,
  String passphrase, {
  SrsKdf? kdf,
  bool pendingEnable = false,
}) async {
  final SrsKdf k = kdf ?? SrsKdf.fresh();
  final SrsSync2Result r = await host.sync2Command(<String, Object?>{
    'op': 'derive_key',
    'passphrase': passphrase,
    'salt': k.saltHex,
    'm': k.memoryKib,
    't': k.iterations,
    'p': k.parallelism,
  });
  return SrsLocationKey(
    keyHex: r.map['key']! as String,
    kdf: k,
    pendingEnable: pendingEnable,
  );
}

/// 一个位置的 `meta.json` 握手结论。
class SrsLocationHandshake {
  SrsLocationHandshake();

  /// 这一轮收发用的密钥（null = 明文位置）。
  String? keyHex;

  /// 这个位置这一轮不同步的原因（[kSrsSync2NeedsKey] / [kSrsSync2WrongKey] / [kSrsSync2EncryptionMissing] /
  /// [kSrsSync2BadKdf] / [kSrsSync2MetaUnavailable]）；null = 可以同步。
  String? error;

  /// 位置上的数据来自更新版本（`minReader` 比本机新）。
  bool needsUpgrade = false;

  /// 位置开了加密时它的参数。
  SrsKdf? kdf;

  /// 这一轮把本机的「开加密」写进了 `meta.json`。
  bool encryptionEnabled = false;
}

/// `meta.json` 的握手（设计 §6.1、§9）：同步轮次与只做媒体的位置共用这一份。
///
/// - `meta.json` 不在：位置上还没有任何设备的数据（`devices/`、加密媒体都空）才新建（本机有密钥就连 `kdf` 一起写，
///   开加密不会先留下一份明文 meta）；已经有数据却读不到 meta = 最终一致的列目录还没看到 / 被删了，**不重写**
///   （否则会盖掉一份其实存在的加密 meta），报 [kSrsSync2MetaUnavailable]。
/// - `meta.json` 在但解析不了：同样不重写，报 [kSrsSync2MetaUnavailable]。
/// - 有 `kdf`：参数检查（越界 [kSrsSync2BadKdf]），本机密钥校验值对得上才用。
/// - 没有 `kdf`：本机没开加密 = 明文；本机刚开（[SrsLocationKey.pendingEnable]）= 写上 `kdf`；本机已经开过 =
///   [kSrsSync2EncryptionMissing] 停下，绝不降级成明文。
Future<SrsLocationHandshake> srsLocationHandshake(
  SrsLocationStore location, {
  required SrsLocationKey? key,
  required Object? collection,
  required int nowMs,
  required int protocol,
  required int minReader,
}) async {
  final SrsLocationHandshake h = SrsLocationHandshake();
  Map<String, Object?> withKdf(Map<String, Object?> meta, SrsLocationKey k) =>
      <String, Object?>{
        ...meta,
        'kdf': <String, Object?>{...k.kdf.toJson(), 'check': k.check},
      };
  final Uint8List? bytes = await location.get('meta.json');
  if (bytes == null) {
    final bool hasData =
        (await location.list('devices')).isNotEmpty ||
        (await location.list(kSrsSealedMediaFolder)).isNotEmpty;
    if (hasData) {
      h.error = kSrsSync2MetaUnavailable;
      return h;
    }
    final Map<String, Object?> fresh = <String, Object?>{
      'v': protocol,
      'minReader': minReader,
      'collection': collection,
      'createdAt': nowMs,
    };
    await location.put(
      'meta.json',
      utf8.encode(jsonEncode(key == null ? fresh : withKdf(fresh, key))),
    );
    if (key != null) {
      h.kdf = key.kdf;
      h.keyHex = key.keyHex;
      h.encryptionEnabled = key.pendingEnable;
    }
    return h;
  }
  final Map<String, Object?> meta;
  try {
    final Object? j = jsonDecode(utf8.decode(bytes));
    if (j is! Map) throw const FormatException('meta.json is not an object');
    meta = j.cast<String, Object?>();
  } on FormatException {
    h.error = kSrsSync2MetaUnavailable;
    return h;
  }
  if (((meta['minReader'] as num?)?.toInt() ?? 1) > protocol) {
    h.needsUpgrade = true;
    return h;
  }
  final Object? kdfJson = meta['kdf'];
  if (kdfJson == null) {
    if (key == null) return h;
    if (!key.pendingEnable) {
      h.error = kSrsSync2EncryptionMissing;
      return h;
    }
    await location.put(
      'meta.json',
      utf8.encode(jsonEncode(withKdf(meta, key))),
    );
    h.kdf = key.kdf;
    h.keyHex = key.keyHex;
    h.encryptionEnabled = true;
    return h;
  }
  try {
    if (kdfJson is! Map) throw const FormatException('kdf is not an object');
    h.kdf = SrsKdf.fromJson(kdfJson.cast<String, Object?>());
  } on FormatException {
    h.error = kSrsSync2BadKdf;
    return h;
  }
  if (key == null) {
    h.error = kSrsSync2NeedsKey;
    return h;
  }
  if (kdfJson['check'] != key.check) {
    h.error = kSrsSync2WrongKey;
    return h;
  }
  h.keyHex = key.keyHex;
  return h;
}

/// 加密位置上媒体的封装 / 解封（内核 XChaCha20-Poly1305，AAD = 文件名）。
class SrsMediaCipher {
  const SrsMediaCipher(this.host, this.keyHex);

  final SrsSync2Host host;
  final String keyHex;

  /// 这把密钥的媒体目录（`media-e/<密钥指纹>`）：换了密钥就换目录，旧密钥封的文件不会被当成「已经传过」。
  String get folder => '$kSrsSealedMediaFolder/${srsKeyFingerprint(keyHex)}';

  Future<Uint8List> seal(String name, Uint8List plain) async =>
      (await host.sync2Command(
        <String, Object?>{'op': 'seal', 'key': keyHex, 'name': name},
        blobs: <Uint8List>[plain],
      )).files.single.$2;

  /// 解不开（被篡改 / 口令不对）时返回 null。
  Future<Uint8List?> open(String name, Uint8List sealed) async {
    try {
      return (await host.sync2Command(
        <String, Object?>{'op': 'open', 'key': keyHex, 'name': name},
        blobs: <Uint8List>[sealed],
      )).files.single.$2;
    } on Object {
      return null;
    }
  }
}

String _hex(List<int> b) =>
    b.map((int x) => x.toRadixString(16).padLeft(2, '0')).join();

List<int> _unhex(String h) => <int>[
  for (int i = 0; i + 1 < h.length; i += 2)
    int.parse(h.substring(i, i + 2), radix: 16),
];
