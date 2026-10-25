/// 存储位置的端到端加密（docs/specs/2026-10-25-srs-sync-v2-design.md §9）：每个位置一个可选开关，默认关。
///
/// - 集合密钥 = Argon2id(口令, 盐, 参数)（内核 `derive_key`，后台 isolate 跑）。盐与参数写进该位置的 `meta.json`
///   的 `kdf`，外加一个**密钥校验值** `check`（密钥的 SHA-256 截断，不能反推密钥），别的设备输入口令后靠它判断
///   口令对不对，不必先去解一个段。
/// - 段由内核按位置加密（outbox / ingest 收 key）；媒体放 `media-e/`，内容经内核 `seal` / `open`（AAD 绑定文件名）。
///   开加密之前传上去的明文段 / 媒体留在原处，本机按新的上传进度身份（`<位置>#e`）把自己的段全部重传成密文；
///   旧明文由用户「清理此位置」删除（与「取消用途不删文件」同一纪律）。
/// - 开了就不能在这里关：关掉要把全部设备的段重传成明文，等于另起一个位置。
/// - 口令丢失 = 这个位置上的数据解不开，但每台设备本机都有完整日志，换个口令（或换个位置）重新发布即可。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsSync2Result;

/// 位置开了加密但本机没有口令：这一轮不同步该位置（UI 提示输入口令）。
const String kSrsSync2NeedsKey = 'srs location needs passphrase';

/// 本机记的口令与位置上的不符（别的设备改过口令）：这一轮不同步该位置（UI 提示重新输入）。
const String kSrsSync2WrongKey = 'srs location passphrase mismatch';

/// 加密位置上媒体的目录（与明文 `media/` 分开，不会把开加密前的明文文件当密文解）。
const String kSrsSealedMediaFolder = 'media-e';

/// Argon2id 参数与盐（存进 `meta.json` 的 `kdf`）。
class SrsKdf {
  const SrsKdf({
    required this.saltHex,
    this.memoryKib = 64 * 1024,
    this.iterations = 3,
    this.parallelism = 1,
  });

  factory SrsKdf.fromJson(Map<String, Object?> j) => SrsKdf(
    saltHex: j['salt'] as String? ?? '',
    memoryKib: (j['m'] as num?)?.toInt() ?? 64 * 1024,
    iterations: (j['t'] as num?)?.toInt() ?? 3,
    parallelism: (j['p'] as num?)?.toInt() ?? 1,
  );

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

/// 只读的加密握手（只用作媒体、不跑操作同步的位置用；开加密由同步轮次写 `meta.json`）：
/// 位置没开加密 → `(null, null)`；开了 → 本机密钥对得上返回它，否则返回错误码。
Future<({String? keyHex, String? error})> srsCheckLocationKey(
  SrsLocationStore location,
  SrsLocationKey? key,
) async {
  final Uint8List? b = await location.get('meta.json');
  if (b == null) return (keyHex: null, error: null);
  final Object? meta;
  try {
    meta = jsonDecode(utf8.decode(b));
  } on FormatException {
    return (keyHex: null, error: null);
  }
  final Object? kdf = meta is Map ? meta['kdf'] : null;
  if (kdf is! Map) return (keyHex: null, error: null);
  if (key == null) return (keyHex: null, error: kSrsSync2NeedsKey);
  if (kdf['check'] != key.check) {
    return (keyHex: null, error: kSrsSync2WrongKey);
  }
  return (keyHex: key.keyHex, error: null);
}

/// 加密位置上媒体的封装 / 解封（内核 XChaCha20-Poly1305，AAD = 文件名）。
class SrsMediaCipher {
  const SrsMediaCipher(this.host, this.keyHex);

  final SrsSync2Host host;
  final String keyHex;

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
