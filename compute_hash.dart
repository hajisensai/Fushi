// Standalone xxh3 hash computation for Isar schema IDs.
// Run: dart compute_hash.dart
import 'dart:convert';
import 'dart:typed_data';

// ---- xxh3 inline (from xxh3-1.0.1) ----

const int kXXHPrime32_1 = 0x9E3779B1;
const int kXXHPrime32_2 = 0x85EBCA77;
const int kXXHPrime32_3 = 0xC2B2AE3D;
const int kXXHPrime64_1 = 0x9E3779B185EBCA87;
const int kXXHPrime64_2 = 0xC2B2AE3D27D4EB4F;
const int kXXHPrime64_3 = 0x165667B19E3779F9;
const int kXXHPrime64_4 = 0x85EBCA77C2B2AE63;
const int kXXHPrime64_5 = 0x27D4EB2F165667C5;
const int kXXH3MidSizeMax = 240;
const int kSecretSizeMin = 136;
const int kSecretConsumeRate = 8;
const int kStripeLength = 64;
const int kAccNB = 8;

final kSecret = Uint8List.fromList([
  0xb8,0xfe,0x6c,0x39,0x23,0xa4,0x4b,0xbe,0x7c,0x01,0x81,0x2c,
  0xf7,0x21,0xad,0x1c,0xde,0xd4,0x6d,0xe9,0x83,0x90,0x97,0xdb,
  0x72,0x40,0xa4,0xa4,0xb7,0xb3,0x67,0x1f,0xcb,0x79,0xe6,0x4e,
  0xcc,0xc0,0xe5,0x78,0x82,0x5a,0xd0,0x7d,0xcc,0xff,0x72,0x21,
  0xb8,0x08,0x46,0x74,0xf7,0x43,0x24,0x8e,0xe0,0x35,0x90,0xe6,
  0x81,0x3a,0x26,0x4c,0x3c,0x28,0x52,0xbb,0x91,0xc3,0x00,0xcb,
  0x88,0xd0,0x65,0x8b,0x1b,0x53,0x2e,0xa3,0x71,0x64,0x48,0x97,
  0xa2,0x0d,0xf9,0x4e,0x38,0x19,0xef,0x46,0xa9,0xde,0xac,0xd8,
  0xa8,0xfa,0x76,0x3f,0xe3,0x9c,0x34,0x3f,0xf9,0xdc,0xbb,0xc7,
  0xc7,0x0b,0x4f,0x1d,0x8a,0x51,0xe0,0x4b,0xcd,0xb4,0x59,0x31,
  0xc8,0x9f,0x7e,0xc9,0xd9,0x78,0x73,0x64,0xea,0xc5,0xac,0x83,
  0x34,0xd3,0xeb,0xc3,0xc5,0x81,0xa0,0xff,0xfa,0x13,0x63,0xeb,
  0x17,0x0d,0xdd,0x51,0xb7,0xf0,0xda,0x49,0xd3,0x16,0x55,0x26,
  0x29,0xd4,0x68,0x9e,0x2b,0x16,0xbe,0x58,0x7d,0x47,0xa1,0xfc,
  0x8f,0xf8,0xb8,0xd1,0x7a,0xd0,0x31,0xce,0x45,0xcb,0x3a,0x8f,
  0x95,0x16,0x04,0x28,0xaf,0xd7,0xfb,0xca,0xbb,0x4b,0x40,0x7e,
]);

int readLE32(Uint8List v, [int off = 0]) =>
    ByteData.sublistView(v).getUint32(off, Endian.little);
int readLE64(Uint8List v, [int off = 0]) =>
    ByteData.sublistView(v).getUint64(off, Endian.little);

int swap32(int x) =>
    ((x << 24) & 0xff000000) | ((x << 8) & 0x00ff0000) |
    ((x >>> 8) & 0x0000ff00) | ((x >>> 24) & 0x000000ff);
int swap64(int x) =>
    ((x << 56) & 0xff00000000000000) | ((x << 40) & 0x00ff000000000000) |
    ((x << 24) & 0x0000ff0000000000) | ((x << 8) & 0x000000ff00000000) |
    ((x >>> 8) & 0x00000000ff000000) | ((x >>> 24) & 0x0000000000ff0000) |
    ((x >>> 40) & 0x000000000000ff00) | ((x >>> 56) & 0x00000000000000ff);

int _mult64to128Lo(int a, int b) {
  int loLo = (a.toUnsigned(32) * b.toUnsigned(32)).toUnsigned(64);
  int hiLo = (a >>> 32) * b.toUnsigned(32);
  int loHi = a.toUnsigned(32) * (b >>> 32);
  int cross = (loLo >>> 32) + hiLo.toUnsigned(32) + loHi;
  return (cross << 32) | loLo.toUnsigned(32);
}
int _mult64to128Hi(int a, int b) {
  int loLo = (a.toUnsigned(32) * b.toUnsigned(32)).toUnsigned(64);
  int hiLo = (a >>> 32) * b.toUnsigned(32);
  int loHi = a.toUnsigned(32) * (b >>> 32);
  int hiHi = (a >>> 32) * (b >>> 32);
  int cross = (loLo >>> 32) + hiLo.toUnsigned(32) + loHi;
  return (hiLo >>> 32) + (cross >>> 32) + hiHi;
}
int mul128Fold64(int a, int b) =>
    _mult64to128Lo(a, b) ^ _mult64to128Hi(a, b);

int _xXH64Avalanche(int h) {
  h ^= h >>> 33; h *= kXXHPrime64_2;
  h ^= h >>> 29; h *= kXXHPrime64_3;
  return h ^ (h >>> 32);
}
int _xXH3Avalanche(int h) {
  h ^= h >>> 37;
  h *= 0x165667919E3779F9;
  return h ^ (h >>> 32);
}
int _xXH3rrmxmx(int h, int length) {
  h ^= ((h << 49) | (h >>> 15)) ^ ((h << 24) | (h >>> 40));
  h *= 0x9FB21C651E98DF25;
  h ^= (h >>> 35) + length;
  h *= 0x9FB21C651E98DF25;
  return h ^ (h >>> 28);
}
int _mix16B(Uint8List input, Uint8List secret, int seed,
    {int iOff = 0, int sOff = 0}) =>
    mul128Fold64(
      readLE64(input, iOff) ^ (readLE64(secret, sOff) + seed),
      readLE64(input, iOff + 8) ^ (readLE64(secret, sOff + 8) - seed),
    );

int xxh3(Uint8List input) {
  final secret = kSecret;
  final int seed = 0;
  final int len = input.length;

  if (len == 0) {
    return _xXH64Avalanche(seed ^ (readLE64(secret, 56) ^ readLE64(secret, 64)));
  } else if (len < 4) {
    int keyed = ((input[0] << 16) | (input[len >>> 1] << 24) |
                 input[len - 1] | (len << 8)) ^
        ((readLE32(secret) ^ readLE32(secret, 4)) + seed);
    return _xXH64Avalanche(keyed);
  } else if (len <= 8) {
    int keyed = (readLE32(input, len - 4) + (readLE32(input) << 32)) ^
        ((readLE64(secret, 8) ^ readLE64(secret, 16)) -
            (seed ^ ((swap32(seed)) << 32)));
    return _xXH3rrmxmx(keyed, len);
  } else if (len <= 16) {
    int lo = readLE64(input) ^ ((readLE64(secret, 24) ^ readLE64(secret, 32)) + seed);
    int hi = readLE64(input, len - 8) ^ ((readLE64(secret, 40) ^ readLE64(secret, 48)) - seed);
    int acc = len + swap64(lo) + hi + mul128Fold64(lo, hi);
    return _xXH3Avalanche(acc);
  } else if (len <= 128) {
    int acc = len * kXXHPrime64_1;
    int sOff = 0;
    for (int i = 0, j = len; j > i; i += 16, j -= 16) {
      acc += _mix16B(input, secret, seed, iOff: i, sOff: sOff);
      acc += _mix16B(input, secret, seed, iOff: j - 16, sOff: sOff + 16);
      sOff += 32;
    }
    return _xXH3Avalanche(acc);
  }
  throw UnimplementedError('len > 128 not needed here');
}

void main() {
  for (final name in ['Audiobook', 'AudioCue', 'SrtBook']) {
    final bytes = Uint8List.fromList(utf8.encode(name));
    final hash = xxh3(bytes);
    print('$name → $hash');
  }
}
