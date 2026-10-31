import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_obfuscator.dart';

/// 在临时目录里写 [data] 到 `in`，跑 [op]（`in` → `out`），返回 `out` 的字节。
Future<Uint8List> _viaFiles(
  List<int> data,
  Future<void> Function(File source, File destination) op,
) async {
  final dir = await Directory.systemTemp.createTemp('sync_obf_test_');
  try {
    final src = File('${dir.path}/in')..writeAsBytesSync(data);
    final dst = File('${dir.path}/out');
    await op(src, dst);
    return dst.readAsBytesSync();
  } finally {
    await dir.delete(recursive: true);
  }
}

void main() {
  group('SyncObfuscator bytes round-trip', () {
    test('empty stays empty round-trips', () {
      final empty = Uint8List(0);
      final ob = SyncObfuscator.obfuscateBytes(empty);
      // 即便空数据，混淆产物也必须带 magic header（供混读判定）。
      expect(ob.length, SyncObfuscator.magicHeaderLength);
      expect(SyncObfuscator.deobfuscateBytes(ob), empty);
    });

    test('small payload round-trips and differs from plaintext', () {
      final data = Uint8List.fromList([0, 1, 2, 250, 251, 255, 7, 42]);
      final ob = SyncObfuscator.obfuscateBytes(data);
      // 混淆后体积 == 原文 + magic header（无填充）。
      expect(ob.length, data.length + SyncObfuscator.magicHeaderLength);
      // 头之后的正文必须与明文不同（确实混淆了）。
      final body = ob.sublist(SyncObfuscator.magicHeaderLength);
      expect(body, isNot(equals(data)));
      expect(SyncObfuscator.deobfuscateBytes(ob), data);
    });

    test('large payload (> keystream period) round-trips', () {
      final data = Uint8List(70000);
      for (var i = 0; i < data.length; i++) {
        data[i] = (i * 31 + 7) & 0xFF;
      }
      final ob = SyncObfuscator.obfuscateBytes(data);
      expect(ob.length, data.length + SyncObfuscator.magicHeaderLength);
      expect(SyncObfuscator.deobfuscateBytes(ob), data);
    });

    test('boundary lengths around 32-byte keystream period round-trip', () {
      for (final n in [1, 31, 32, 33, 63, 64, 65]) {
        final data = Uint8List.fromList(
          List<int>.generate(n, (i) => (i * 13) & 0xFF),
        );
        final ob = SyncObfuscator.obfuscateBytes(data);
        expect(SyncObfuscator.deobfuscateBytes(ob), data, reason: 'n=$n');
      }
    });
  });

  group('SyncObfuscator file round-trip (native, whole file)', () {
    test('multi-chunk file round-trips and equals bytes output', () async {
      // > 1 MiB：跨 Rust 侧读块边界。
      final data = Uint8List.fromList(
        List<int>.generate(3 * 1024 * 1024 + 77, (i) => (i * 17 + 3) & 0xFF),
      );
      final ob = await _viaFiles(data, SyncObfuscator.obfuscateFile);
      expect(ob, SyncObfuscator.obfuscateBytes(data));
      final back = await _viaFiles(ob, SyncObfuscator.deobfuscateFile);
      expect(back, data);
    });

    test('empty file still gets magic header only', () async {
      final ob = await _viaFiles(const <int>[], SyncObfuscator.obfuscateFile);
      expect(ob, SyncObfuscator.magicHeader);
      final back = await _viaFiles(ob, SyncObfuscator.deobfuscateFile);
      expect(back, isEmpty);
    });

    test('destination is truncated, not appended', () async {
      final dir = await Directory.systemTemp.createTemp('sync_obf_test_');
      try {
        final src = File('${dir.path}/in')..writeAsBytesSync([1, 2, 3]);
        final dst = File('${dir.path}/out')
          ..writeAsBytesSync(List<int>.filled(100, 9));
        await SyncObfuscator.obfuscateFile(src, dst);
        expect(dst.lengthSync(), SyncObfuscator.magicHeaderLength + 3);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('missing source throws FileSystemException', () async {
      final dir = await Directory.systemTemp.createTemp('sync_obf_test_');
      try {
        await expectLater(
          SyncObfuscator.deobfuscateFile(
            File('${dir.path}/missing'),
            File('${dir.path}/out'),
          ),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('SyncObfuscator mixed-read backward compat (header detection)', () {
    test('obfuscated bytes have magic header, plaintext does not', () {
      final data = Uint8List.fromList([10, 20, 30, 40, 50, 60, 70, 80, 90]);
      final ob = SyncObfuscator.obfuscateBytes(data);
      expect(SyncObfuscator.hasMagicHeader(ob), isTrue);
      // 旧明文（无魔数）必须被判为未混淆。
      expect(SyncObfuscator.hasMagicHeader(data), isFalse);
    });

    test('deobfuscateBytes passes through legacy plaintext unchanged', () {
      // 旧明文没有魔数：读时按明文原样返回（向后兼容）。
      final legacy = Uint8List.fromList([1, 2, 3, 4, 5]);
      expect(SyncObfuscator.deobfuscateBytes(legacy), legacy);
    });

    test('plaintext shorter than header is passed through', () {
      final tiny = Uint8List.fromList([1, 2, 3]);
      expect(SyncObfuscator.deobfuscateBytes(tiny), tiny);
    });

    test('deobfuscateFile copies legacy plaintext unchanged', () async {
      final legacy = List<int>.generate(5000, (i) => (i * 11) & 0xFF);
      final back = await _viaFiles(legacy, SyncObfuscator.deobfuscateFile);
      expect(back, Uint8List.fromList(legacy));
    });

    test(
      'deobfuscateFile copies legacy plaintext shorter than header',
      () async {
        final tiny = [9, 8, 7];
        final back = await _viaFiles(tiny, SyncObfuscator.deobfuscateFile);
        expect(back, Uint8List.fromList(tiny));
      },
    );
  });

  group('SyncObfuscator random access (deobfuscateBodyAt)', () {
    // 按 64 位字长 XOR 的实现必须与整文件逐字节还原逐字节一致：覆盖全部 32 种
    // 相位、8 字节边界两侧的长度，以及非 Uint8List 的输入（网络分块可能是普通 List）。
    final plain = Uint8List.fromList(
      List<int>.generate(4096 + 77, (i) => (i * 131 + 17) & 0xFF),
    );
    final body = SyncObfuscator.obfuscateBytes(
      plain,
    ).sublist(SyncObfuscator.magicHeaderLength);

    test('any offset / length restores the plaintext slice', () {
      for (var offset = 0; offset < 64; offset++) {
        for (final length in [0, 1, 7, 8, 9, 31, 32, 33, 63, 64, 65, 1000]) {
          final chunk = body.sublist(offset, offset + length);
          expect(
            SyncObfuscator.deobfuscateBodyAt(chunk, offset),
            plain.sublist(offset, offset + length),
            reason: 'offset=$offset length=$length',
          );
          expect(
            SyncObfuscator.deobfuscateBodyAt(List<int>.of(chunk), offset),
            plain.sublist(offset, offset + length),
            reason: 'plain List input, offset=$offset length=$length',
          );
        }
      }
      expect(
        SyncObfuscator.deobfuscateBodyAt(body.sublist(3000), 3000),
        plain.sublist(3000),
      );
    });

    test('does not mutate the input chunk', () {
      final chunk = body.sublist(5, 105);
      final copy = Uint8List.fromList(chunk);
      SyncObfuscator.deobfuscateBodyAt(chunk, 5);
      expect(chunk, copy);
    });
  });
}
