// SyncObfuscator 的 XOR 搬进 native/fushi_compute 后，整块 / 流式 / Range 随机访问三条路径的
// 产物与删除前的 Dart 实现逐字节一致——已同步到云端的文件必须照常解开。向量由旧实现生成：
// packages/fushi_compute/test/crypto/crypto_vectors_v2.json（sync_obfuscator 段）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_obfuscator.dart';

/// 与 packages/fushi_compute/test/crypto/crypto_vector_inputs.dart 的 pseudoRandomBytes 同一算法。
Uint8List _pseudoRandomBytes(int length, int seed) {
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

String _sha(List<int> b) => sha256.convert(b).toString();

Future<Uint8List> _collect(Stream<List<int>> s) async {
  final BytesBuilder b = BytesBuilder(copy: false);
  await for (final List<int> chunk in s) {
    b.add(chunk);
  }
  return b.takeBytes();
}

Stream<List<int>> _chunked(Uint8List data, List<int> sizes) async* {
  int offset = 0;
  int i = 0;
  while (offset < data.length) {
    final int size = sizes[i++ % sizes.length];
    final int end = offset + size > data.length ? data.length : offset + size;
    yield Uint8List.sublistView(data, offset, end);
    offset = end;
  }
}

void main() {
  final Map<String, Object?> v =
      (jsonDecode(
                File(
                  '../packages/fushi_compute/test/crypto/crypto_vectors_v2.json',
                ).readAsStringSync(),
              )
              as Map<String, Object?>)['sync_obfuscator']!
          as Map<String, Object?>;
  final Uint8List data = _pseudoRandomBytes(100003, 901);

  test('input is the frozen one', () {
    expect(_sha(data), v['input_sha256']);
  });

  test('obfuscateBytes / deobfuscateBytes match the old bytes', () {
    final Uint8List obf = SyncObfuscator.obfuscateBytes(data);
    expect(_sha(obf), v['obfuscated_sha256']);
    expect(SyncObfuscator.deobfuscateBytes(obf), data);
  });

  test('obfuscateStream (any chunking) matches the old bytes', () async {
    for (final List<int> sizes in const <List<int>>[
      <int>[1, 7, 8, 31, 33],
      <int>[65536],
      <int>[5, 4096, 3],
    ]) {
      final Uint8List obf = await _collect(
        SyncObfuscator.obfuscateStream(_chunked(data, sizes)),
      );
      expect(_sha(obf), v['obfuscated_sha256'], reason: '$sizes');
      final Uint8List back = await _collect(
        SyncObfuscator.deobfuscateStream(
          _chunked(obf, sizes.reversed.toList()),
        ),
      );
      expect(back, data, reason: '$sizes');
    }
  });

  test('deobfuscateBodyAt matches the old bytes at arbitrary offsets', () {
    final Uint8List obf = SyncObfuscator.obfuscateBytes(data);
    final Map<String, Object?> at =
        v['body_at_offset_1000000_plus']! as Map<String, Object?>;
    for (final MapEntry<String, Object?> e in at.entries) {
      final int off = int.parse(e.key);
      final int len = (data.length - off).clamp(0, 5003);
      expect(
        _sha(
          SyncObfuscator.deobfuscateBodyAt(
            Uint8List.sublistView(obf, 8 + off, 8 + off + len),
            1000000 + off,
          ),
        ),
        e.value,
        reason: 'offset $off',
      );
    }
  });
}
