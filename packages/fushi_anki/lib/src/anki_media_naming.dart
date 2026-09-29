import 'dart:convert';
import 'dart:isolate';

/// Anki 媒体文件名（`<prefix><sha256>.<ext>`，同名即同内容）与上传编码。
///
/// 纯 Dart（无 Flutter）：app 的各后端与无头服务端的落地后端共用同一套命名，
/// 同一份字节在哪边写进库都是同一个文件名。
const int _uint32Mask = 0xffffffff;

const List<int> _sha256K = <int>[
  0x428a2f98,
  0x71374491,
  0xb5c0fbcf,
  0xe9b5dba5,
  0x3956c25b,
  0x59f111f1,
  0x923f82a4,
  0xab1c5ed5,
  0xd807aa98,
  0x12835b01,
  0x243185be,
  0x550c7dc3,
  0x72be5d74,
  0x80deb1fe,
  0x9bdc06a7,
  0xc19bf174,
  0xe49b69c1,
  0xefbe4786,
  0x0fc19dc6,
  0x240ca1cc,
  0x2de92c6f,
  0x4a7484aa,
  0x5cb0a9dc,
  0x76f988da,
  0x983e5152,
  0xa831c66d,
  0xb00327c8,
  0xbf597fc7,
  0xc6e00bf3,
  0xd5a79147,
  0x06ca6351,
  0x14292967,
  0x27b70a85,
  0x2e1b2138,
  0x4d2c6dfc,
  0x53380d13,
  0x650a7354,
  0x766a0abb,
  0x81c2c92e,
  0x92722c85,
  0xa2bfe8a1,
  0xa81a664b,
  0xc24b8b70,
  0xc76c51a3,
  0xd192e819,
  0xd6990624,
  0xf40e3585,
  0x106aa070,
  0x19a4c116,
  0x1e376c08,
  0x2748774c,
  0x34b0bcb5,
  0x391c0cb3,
  0x4ed8aa4a,
  0x5b9cca4f,
  0x682e6ff3,
  0x748f82ee,
  0x78a5636f,
  0x84c87814,
  0x8cc70208,
  0x90befffa,
  0xa4506ceb,
  0xbef9a3f7,
  0xc67178f2,
];

String fushiAnkiMediaFilenameForBytes({
  required String prefix,
  required List<int> bytes,
  required String sourceName,
  String fallbackExtension = 'bin',
}) {
  final String ext = _mediaExtensionFromSource(
    sourceName,
    fallbackExtension: fallbackExtension,
  );
  return '${_safeMediaPrefix(prefix)}${_sha256Hex(bytes)}.$ext';
}

/// BUG-933：制卡「未响应」根因之一——旧代码在 **UI isolate** 对整段媒体字节同步跑
/// [_sha256Hex]（纯 Dart 逐字节 SHA256，几 MB 音频=数百万次迭代）和 [base64Encode]，
/// 阻塞主线程。这里把「哈希文件名 + base64」一次卸到后台 isolate，同段字节只跨 isolate
/// 拷贝一次。
///
/// 阈值兜底：词典外字（单卡可能数十个、每个仅几 KB）走同步分支——为几 KB 图各起一个
/// isolate 反而挤占资源、拖慢总时长（且不会 jank）；只有封面/音频等大媒体才卸后台。
const int _isolateMediaThresholdBytes = 64 * 1024;

/// AnkiConnect 上传路径：计算 sha256 文件名 + base64 数据。大媒体在后台 isolate 完成，
/// 小媒体同步完成。返回记录 `(filename, base64Data)` 供 `storeMediaFile`。
Future<({String filename, String base64Data})>
    fushiAnkiMediaEncodeForUploadAsync({
  required String prefix,
  required List<int> bytes,
  required String sourceName,
  String fallbackExtension = 'bin',
}) {
  ({String filename, String base64Data}) encode() => (
        filename: fushiAnkiMediaFilenameForBytes(
          prefix: prefix,
          bytes: bytes,
          sourceName: sourceName,
          fallbackExtension: fallbackExtension,
        ),
        base64Data: base64Encode(bytes),
      );
  if (bytes.length < _isolateMediaThresholdBytes) {
    return Future<({String filename, String base64Data})>.value(encode());
  }
  return Isolate.run(encode);
}

/// AnkiDroid 路径：媒体由 platform channel 按文件路径落库（不走 base64），只需 sha256
/// 文件名。大媒体在后台 isolate 完成，小媒体同步完成。
Future<String> fushiAnkiMediaFilenameForBytesAsync({
  required String prefix,
  required List<int> bytes,
  required String sourceName,
  String fallbackExtension = 'bin',
}) {
  String compute() => fushiAnkiMediaFilenameForBytes(
        prefix: prefix,
        bytes: bytes,
        sourceName: sourceName,
        fallbackExtension: fallbackExtension,
      );
  if (bytes.length < _isolateMediaThresholdBytes) {
    return Future<String>.value(compute());
  }
  return Isolate.run(compute);
}

/// [base64Encode] 的按需后台变体（BUG-933）：大媒体卸到 isolate，小媒体同步。用于
/// 文件名已定、只剩 base64 的路径（远端下载音频 / 词典外字上传）。
Future<String> fushiAnkiBase64EncodeAsync(List<int> bytes) {
  if (bytes.length < _isolateMediaThresholdBytes) {
    return Future<String>.value(base64Encode(bytes));
  }
  return Isolate.run(() => base64Encode(bytes));
}

String _safeMediaPrefix(String prefix) {
  final String safe = prefix.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  return safe.isEmpty ? 'fushi_media_' : safe;
}

String _mediaExtensionFromSource(
  String sourceName, {
  required String fallbackExtension,
}) {
  final String fallback = _safeMediaExtension(
    fallbackExtension,
    fallback: 'bin',
  );
  final Uri? uri = Uri.tryParse(sourceName);
  final String path = (uri != null && uri.path.isNotEmpty)
      ? uri.path
      : sourceName.replaceAll('\\', '/');
  final String name = path.split('/').last;
  final int dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return fallback;
  return _safeMediaExtension(name.substring(dot + 1), fallback: fallback);
}

String _safeMediaExtension(String extension, {required String fallback}) {
  final String safe = extension.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9]'),
        '',
      );
  if (safe.isEmpty || safe.length > 12) return fallback;
  return safe;
}

String _sha256Hex(List<int> bytes) {
  final List<int> padded = <int>[
    for (final int byte in bytes) byte & 0xff,
    0x80,
  ];
  while (padded.length % 64 != 56) {
    padded.add(0);
  }
  final int bitLength = bytes.length * 8;
  for (int shift = 56; shift >= 0; shift -= 8) {
    padded.add((bitLength >> shift) & 0xff);
  }

  final List<int> h = <int>[
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ];
  final List<int> w = List<int>.filled(64, 0);

  for (int chunk = 0; chunk < padded.length; chunk += 64) {
    for (int i = 0; i < 16; i++) {
      final int j = chunk + i * 4;
      w[i] = ((padded[j] << 24) |
              (padded[j + 1] << 16) |
              (padded[j + 2] << 8) |
              padded[j + 3]) &
          _uint32Mask;
    }
    for (int i = 16; i < 64; i++) {
      final int s0 =
          _rotr32(w[i - 15], 7) ^ _rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final int s1 =
          _rotr32(w[i - 2], 17) ^ _rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & _uint32Mask;
    }

    int a = h[0];
    int b = h[1];
    int c = h[2];
    int d = h[3];
    int e = h[4];
    int f = h[5];
    int g = h[6];
    int hh = h[7];

    for (int i = 0; i < 64; i++) {
      final int s1 = _rotr32(e, 6) ^ _rotr32(e, 11) ^ _rotr32(e, 25);
      final int ch = (e & f) ^ ((~e) & g);
      final int temp1 = (hh + s1 + ch + _sha256K[i] + w[i]) & _uint32Mask;
      final int s0 = _rotr32(a, 2) ^ _rotr32(a, 13) ^ _rotr32(a, 22);
      final int maj = (a & b) ^ (a & c) ^ (b & c);
      final int temp2 = (s0 + maj) & _uint32Mask;

      hh = g;
      g = f;
      f = e;
      e = (d + temp1) & _uint32Mask;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & _uint32Mask;
    }

    h[0] = (h[0] + a) & _uint32Mask;
    h[1] = (h[1] + b) & _uint32Mask;
    h[2] = (h[2] + c) & _uint32Mask;
    h[3] = (h[3] + d) & _uint32Mask;
    h[4] = (h[4] + e) & _uint32Mask;
    h[5] = (h[5] + f) & _uint32Mask;
    h[6] = (h[6] + g) & _uint32Mask;
    h[7] = (h[7] + hh) & _uint32Mask;
  }

  return h.map((int word) => word.toRadixString(16).padLeft(8, '0')).join();
}

int _rotr32(int value, int shift) =>
    ((value >> shift) | (value << (32 - shift))) & _uint32Mask;
