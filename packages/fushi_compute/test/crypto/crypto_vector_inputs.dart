// 加密域固定向量的**输入**构造（确定性，不入库大文件）。
//
// 期望输出（crypto_vectors.json）是删掉 pointycastle 解密实现之前，用原 Dart 实现
// （AacsContentDecoder.decryptUnit / decryptHlsSegment）对这些输入跑出来的：每个结果的
// SHA-256 与异常形态。密文用 fushi_compute 的 AES-CBC 加密方向现造（仓库已不依赖
// pointycastle）；密文本身的 SHA-256 也冻结在向量里（当时由 pointycastle 加密得到），
// 所以加密方向同样被钉死。
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';

const int kAacsUnit = 6144;

final Uint8List _aacsIv = Uint8List.fromList(const <int>[
  0x0b, 0xa0, 0xf8, 0xdd, 0xfe, 0xa6, 0x1f, 0xb3, //
  0xd8, 0xdf, 0x9f, 0x56, 0x6a, 0x05, 0x0f, 0x78,
]);

/// 确定性字节流（xorshift32）。
Uint8List pseudoRandomBytes(int length, int seed) {
  final Uint8List out = Uint8List(length);
  int x = seed == 0 ? 0x9e3779b9 : seed & 0xffffffff;
  for (int i = 0; i < length; i++) {
    x ^= (x << 13) & 0xffffffff;
    x ^= x >> 17;
    x ^= (x << 5) & 0xffffffff;
    out[i] = x & 0xff;
  }
  return out;
}

Uint8List key16(int seed) => pseudoRandomBytes(16, seed);

/// 一个合法 TS 对齐单元的明文：每个源包首字节带 copy-permission 位、偏移 4 是 0x47。
Uint8List plainAacsUnit(int seed, {bool encryptedFlag = true}) {
  final Uint8List unit = pseudoRandomBytes(kAacsUnit, seed);
  for (int offset = 0; offset < kAacsUnit; offset += 192) {
    unit[offset] = encryptedFlag
        ? (0xc0 | (unit[offset] & 0x3f))
        : (unit[offset] & 0x3f);
    unit[offset + 4] = 0x47;
  }
  return unit;
}

/// 用 [unitKey] 按 AACS 1 aligned-unit 格式加密 [plain]。
Uint8List encryptAacsUnit(Uint8List unitKey, Uint8List plain) {
  final FushiComputeCrypto crypto = FushiComputeCrypto.instance;
  // AES-ECB 单块 = 零 IV 的 CBC 单块。
  final Uint8List contentKey = crypto.aesCbcEncryptNoPadding(
    plain.sublist(0, 16),
    unitKey,
    Uint8List(16),
  );
  for (int i = 0; i < 16; i++) {
    contentKey[i] ^= plain[i];
  }
  return Uint8List.fromList(plain)..setAll(
    16,
    crypto.aesCbcEncryptNoPadding(plain.sublist(16), contentKey, _aacsIv),
  );
}

/// AACS 向量用的 unit key（解码器按此顺序拿到 k0 / k1 / k2；k3 不在盘里）。
List<Uint8List> aacsKeys() => <Uint8List>[
  key16(11),
  key16(22),
  key16(33),
  key16(44),
];

/// 一条混合流：轮换 key、明文单元、坏单元交替出现，覆盖「从上次命中的 key 开始试」
/// 与「失败不改 last key」。返回拼好的 40 个单元。
Uint8List aacsMixedStream() {
  final List<Uint8List> keys = aacsKeys();
  // 每个单元的形态：0..2 = 用 k0..k2 加密；3 = 用盘外 k3 加密（无 key 可解）；
  // 4 = 合法明文单元；5 = 坏同步字节的明文单元；6 = k1 加密后破坏一个同步字节所在块。
  const List<int> pattern = <int>[
    1, 1, 0, 0, 2, 4, 2, 1, 3, 1, 0, 5, 0, 6, 2, 2, 4, 4, 1, 0, //
    3, 3, 2, 1, 0, 6, 1, 1, 5, 2, 0, 4, 1, 2, 0, 3, 2, 2, 1, 0,
  ];
  final Uint8List out = Uint8List(pattern.length * kAacsUnit);
  for (int i = 0; i < pattern.length; i++) {
    final int kind = pattern[i];
    final Uint8List unit;
    if (kind <= 3) {
      unit = encryptAacsUnit(keys[kind], plainAacsUnit(1000 + i));
    } else if (kind == 4) {
      unit = plainAacsUnit(1000 + i, encryptedFlag: false);
    } else if (kind == 5) {
      unit = plainAacsUnit(1000 + i, encryptedFlag: false)
        ..[192 * 7 + 4] = 0x46;
    } else {
      unit = encryptAacsUnit(keys[1], plainAacsUnit(1000 + i));
      // 破坏第 2 个源包同步字节所在密文块之前的一块：CBC 下该同步字节必错。
      unit[192 + 4 - 16] ^= 0x01;
    }
    out.setAll(i * kAacsUnit, unit);
  }
  return out;
}

/// 用 PKCS7 加密一段 HLS 分片。
Uint8List encryptHlsSegment(Uint8List plain, Uint8List key, Uint8List iv) {
  final int pad = 16 - plain.length % 16;
  final Uint8List padded = Uint8List(plain.length + pad)
    ..setAll(0, plain)
    ..fillRange(plain.length, plain.length + pad, pad);
  return encryptCbcRaw(padded, key, iv);
}

/// 不加填充地 CBC 加密（造坏填充用；[plain] 长度须为 16 的倍数）。
Uint8List encryptCbcRaw(Uint8List plain, Uint8List key, Uint8List iv) =>
    FushiComputeCrypto.instance.aesCbcEncryptNoPadding(plain, key, iv);

/// 一个 HLS 向量：输入 + 参数。
final class HlsVectorInput {
  HlsVectorInput(this.name, this.data, this.key, this.iv);
  final String name;
  final Uint8List data;
  final Uint8List key;
  final Uint8List iv;
}

List<HlsVectorInput> hlsVectorInputs() {
  final Uint8List k16 = pseudoRandomBytes(16, 501);
  final Uint8List k24 = pseudoRandomBytes(24, 502);
  final Uint8List k32 = pseudoRandomBytes(32, 503);
  final Uint8List iv = pseudoRandomBytes(16, 504);
  Uint8List badPad(List<int> tail) {
    final Uint8List plain = pseudoRandomBytes(64, 505);
    plain.setAll(64 - tail.length, tail);
    return encryptCbcRaw(plain, k16, iv);
  }

  return <HlsVectorInput>[
    for (final int length in const <int>[
      1,
      15,
      16,
      17,
      31,
      32,
      1000,
      4096,
      65543,
      1 << 21,
    ])
      HlsVectorInput(
        'pkcs7_len_$length',
        encryptHlsSegment(pseudoRandomBytes(length, 600 + length), k16, iv),
        k16,
        iv,
      ),
    HlsVectorInput(
      'aes192',
      encryptHlsSegment(pseudoRandomBytes(5000, 701), k24, iv),
      k24,
      iv,
    ),
    HlsVectorInput(
      'aes256',
      encryptHlsSegment(pseudoRandomBytes(5000, 702), k32, iv),
      k32,
      iv,
    ),
    HlsVectorInput('bad_pad_zero', badPad(const <int>[0]), k16, iv),
    HlsVectorInput('bad_pad_17', badPad(const <int>[17]), k16, iv),
    HlsVectorInput('bad_pad_mixed', badPad(const <int>[3, 2, 3]), k16, iv),
    HlsVectorInput('pad_full_block', badPad(List<int>.filled(16, 16)), k16, iv),
    HlsVectorInput(
      'wrong_key',
      encryptHlsSegment(
        pseudoRandomBytes(3000, 703),
        pseudoRandomBytes(16, 9),
        iv,
      ),
      k16,
      iv,
    ),
    HlsVectorInput('unaligned_33', pseudoRandomBytes(33, 704), k16, iv),
    HlsVectorInput('empty_input', Uint8List(0), k16, iv),
    HlsVectorInput(
      'key_15',
      pseudoRandomBytes(32, 705),
      pseudoRandomBytes(15, 1),
      iv,
    ),
    HlsVectorInput(
      'iv_15',
      pseudoRandomBytes(32, 706),
      k16,
      pseudoRandomBytes(15, 2),
    ),
  ];
}
