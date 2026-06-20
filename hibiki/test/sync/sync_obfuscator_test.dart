import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_obfuscator.dart';

/// 把分块的字节流收集回单个 [Uint8List]，便于断言。
Future<Uint8List> _collect(Stream<List<int>> stream) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    builder.add(chunk);
  }
  return builder.toBytes();
}

/// 用任意 [chunkSizes] 把 [data] 切成分块流，模拟真实文件读取的不规则分块。
Stream<List<int>> _chunked(List<int> data, List<int> chunkSizes) async* {
  var offset = 0;
  var i = 0;
  while (offset < data.length) {
    final size =
        chunkSizes.isEmpty ? data.length : chunkSizes[i % chunkSizes.length];
    final end = (offset + size).clamp(0, data.length);
    yield Uint8List.fromList(data.sublist(offset, end));
    offset = end;
    i++;
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
        final data =
            Uint8List.fromList(List<int>.generate(n, (i) => (i * 13) & 0xFF));
        final ob = SyncObfuscator.obfuscateBytes(data);
        expect(SyncObfuscator.deobfuscateBytes(ob), data, reason: 'n=$n');
      }
    });
  });

  group('SyncObfuscator stream round-trip (global offset preserved)', () {
    test('round-trips regardless of obfuscate vs deobfuscate chunk boundaries',
        () async {
      final data = List<int>.generate(50000, (i) => (i * 17 + 3) & 0xFF);
      // 混淆用一组分块边界，反混淆用另一组——验证全局 offset 与分块无关。
      final ob = await _collect(
        SyncObfuscator.obfuscateStream(_chunked(data, [1, 7, 4096, 33, 65535])),
      );
      final back = await _collect(
        SyncObfuscator.deobfuscateStream(_chunked(ob, [3, 5000, 1, 99])),
      );
      expect(back, Uint8List.fromList(data));
    });

    test('stream output equals bytes output for same payload', () async {
      final data =
          Uint8List.fromList(List<int>.generate(1000, (i) => (i * 7) & 0xFF));
      final viaBytes = SyncObfuscator.obfuscateBytes(data);
      final viaStream = await _collect(
        SyncObfuscator.obfuscateStream(Stream<List<int>>.value(data)),
      );
      expect(viaStream, viaBytes);
    });

    test('empty stream still emits magic header only', () async {
      final ob = await _collect(
        SyncObfuscator.obfuscateStream(const Stream<List<int>>.empty()),
      );
      expect(ob.length, SyncObfuscator.magicHeaderLength);
      final back = await _collect(
        SyncObfuscator.deobfuscateStream(Stream<List<int>>.value(ob)),
      );
      expect(back, isEmpty);
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

    test('deobfuscateStream passes through legacy plaintext stream', () async {
      final legacy = List<int>.generate(5000, (i) => (i * 11) & 0xFF);
      final back = await _collect(
        SyncObfuscator.deobfuscateStream(_chunked(legacy, [1, 13, 4096])),
      );
      expect(back, Uint8List.fromList(legacy));
    });

    test('deobfuscateStream handles legacy plaintext shorter than header',
        () async {
      final tiny = [9, 8, 7];
      final back = await _collect(
        SyncObfuscator.deobfuscateStream(Stream<List<int>>.value(tiny)),
      );
      expect(back, Uint8List.fromList(tiny));
    });
  });
}
