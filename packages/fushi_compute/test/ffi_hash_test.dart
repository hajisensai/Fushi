// ffc_hash_*（ED2K / SHA-256 / CRC-32）回归测试。
//
// CRC-32 向量由 package:archive 的 getCrc32 对同一确定性输入生成（与 fushi_audio
// epub_builder 删除前的手写 _crc32 逐值一致，见 fushi_engine/benchmark 的对拍）。
//
// 固定向量由删除前的纯 Dart 实现（fushi_engine 的 AnidbEd2kAccumulator + package:crypto
// 的 sha256，2026-10-18）对同一份确定性输入生成，覆盖 ED2K 边界：空输入、MD4 块边界、
// 块大小 -1 / 恰好 / +1、恰好整块倍数（有蓝变体）、跨块非整倍数。
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

const int _chunk = 9728000;

/// byte(i) = (i * 0x9E3779B1 mod 2^32) 的最高字节。
void _fill(Uint8List buf, int start, int length) {
  for (int j = 0; j < length; j++) {
    buf[j] = (((start + j) * 0x9E3779B1) & 0xffffffff) >> 24;
  }
}

/// (长度, ED2K 红, ED2K 蓝, SHA-256)。
const List<(int, String, String?, String)> _vectors =
    <(int, String, String?, String)>[
      (
        0,
        '31d6cfe0d16ae931b73c59d7e0c089c0',
        null,
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      ),
      (
        1,
        '47c61a0fa8738ba77308a8a600f88e4b',
        null,
        '6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d',
      ),
      (
        63,
        'ad38b8cbb1e6e9854f362e1fcec52466',
        null,
        '7be910d529434dd8a31078d25667457b6040c888d64904b25d3ca95f1eae6b16',
      ),
      (
        64,
        'f4f7ca26639a233d5875fcad892f9c44',
        null,
        '51e945469a3948debf6fc154e954fd6623ebbc21da2a3ee5e3ee0264e2cef6f2',
      ),
      (
        65,
        '1562e1b58230dafa89877b3276c48a1f',
        null,
        '3c3e113ec16f54924b2c563c7304d9e10ed4d9b54f266fecfbdc63978a14c9b4',
      ),
      (
        1000,
        '851b231740dc7994060650ccce608b3a',
        null,
        '1fc5d253afbcfa513e578376426755539827de93ebb93944a6966de00daa8c2b',
      ),
      (
        _chunk - 1,
        '516876bfce2c3b6159c2f2de59cbb0dd',
        null,
        '8e9bbaeae82670035f0ccd6bfac29d6e62beec2606cd8873cd8dcfd404681406',
      ),
      (
        _chunk,
        '326504f5b342f4770a96dd5391ebf401',
        'd7e9b3cdd57ffa39fc9758e08aa8abd3',
        'f1b69bef65f613156b3c9deddedc003427fa0b9f170ead2fdecbefd809464046',
      ),
      (
        _chunk + 1,
        'd24d7d71357afe6f25e0a10864fbee63',
        null,
        '20b5c5508abef0cfd3784d2e210388efaa6bf03f1584aa1e501691bb1807da7a',
      ),
      (
        2 * _chunk,
        '716efe76b386670b0d9a84ab6c9e38d3',
        '05dafb36ead3fb3e867a9128de17355a',
        '320375de7e3c62c074580c5aadc089b276cb1de93348b388e50cc41c1b8c33e0',
      ),
      (
        2 * _chunk + 12345,
        '86c34f48796156f064d847f67078d62f',
        null,
        '958c5f51855d86941d431f35b0741c64ed5ed72deb2a15e53237610c77b3bb06',
      ),
      (
        3 * _chunk,
        'dfe82eebb71e69b0de8f6513818be5ce',
        'dcd6b79b3a7646547d1e995cb7dc54b9',
        '9c903476782233ec99e018e9fcb90ab8164c236b98769ba6ea2c22842e8471ae',
      ),
    ];

void main() {
  test('ED2K and SHA-256 match the frozen Dart-era vectors', () {
    for (final (int size, String red, String? blue, String sha) in _vectors) {
      final FfcEd2kHasher ed2k = FfcEd2kHasher.create();
      final FfcSha256Hasher sha256 = FfcSha256Hasher.create();
      try {
        // 写进原生缓冲区再 update（与读文件同一路径）；缓冲区 1 MiB 与块大小不对齐，
        // 所以每个整块边界都落在某次 update 中间。
        for (int offset = 0; offset < size; offset += ed2k.bufferSize) {
          final int n = (size - offset).clamp(0, ed2k.bufferSize);
          _fill(ed2k.buffer, offset, n);
          sha256.buffer.setRange(0, n, ed2k.buffer);
          ed2k.update(n);
          sha256.update(n);
        }
        expect(ed2k.finish(), (red, blue), reason: 'ed2k size=$size');
        expect(sha256.finishHex(), sha, reason: 'sha256 size=$size');
      } finally {
        ed2k.close();
        sha256.close();
      }
    }
  });

  test('update split does not matter (odd slices across a chunk boundary)', () {
    const int size = _chunk + 1;
    final Uint8List data = Uint8List(size);
    _fill(data, 0, size);
    final FfcEd2kHasher ed2k = FfcEd2kHasher.create(bufferSize: 4099);
    addTearDown(ed2k.close);
    ed2k.add(data);
    expect(ed2k.finish(), ('d24d7d71357afe6f25e0a10864fbee63', null));
  });

  test('finalized or closed hashers reject further use', () {
    final FfcEd2kHasher ed2k = FfcEd2kHasher.create();
    expect(ed2k.finish(), ('31d6cfe0d16ae931b73c59d7e0c089c0', null));
    expect(() => ed2k.update(0), throwsStateError);
    expect(ed2k.finish, throwsStateError);
    ed2k.close();
    ed2k.close(); // 幂等
    expect(() => ed2k.update(0), throwsStateError);

    final FfcSha256Hasher sha256 = FfcSha256Hasher.create(bufferSize: 8);
    addTearDown(sha256.close);
    expect(() => sha256.update(9), throwsRangeError);
  });

  test('ffcSha256FileSync hashes a whole file', () async {
    final Directory dir = await Directory.systemTemp.createTemp('ffc-sha-');
    addTearDown(() => dir.delete(recursive: true));
    final File file = File('${dir.path}${Platform.pathSeparator}f.bin');
    final Uint8List data = Uint8List(_chunk + 1);
    _fill(data, 0, data.length);
    await file.writeAsBytes(data);
    expect(
      ffcSha256FileSync(file.path),
      '20b5c5508abef0cfd3784d2e210388efaa6bf03f1584aa1e501691bb1807da7a',
    );
  });

  test('CRC-32 matches the frozen package:archive vectors and chains', () {
    const List<(int, int)> crcVectors = <(int, int)>[
      (0, 0x00000000),
      (1, 0xd202ef8d),
      (63, 0x6b53518c),
      (64, 0x06d28c3e),
      (65, 0x806cdf37),
      (1000, 0x77b6fa33),
      (1048575, 0x5cc0fc87),
      (1048576, 0x158987c5),
      (1048577, 0x5ec41af9),
      (3146505, 0x05cb9764),
    ];
    for (final (int size, int crc) in crcVectors) {
      final Uint8List data = Uint8List(size);
      _fill(data, 0, size);
      expect(ffcCrc32(data), crc, reason: 'size=$size');
      final int half = size ~/ 2;
      expect(
        ffcCrc32(
          Uint8List.sublistView(data, half),
          ffcCrc32(Uint8List.sublistView(data, 0, half)),
        ),
        crc,
        reason: 'chained size=$size',
      );
    }
    // 非 Uint8List 的 List<int> 与 "123456789" 标准值。
    expect(ffcCrc32('123456789'.codeUnits), 0xcbf43926);
  });

  test(
    'ffcSha256Bytes and async ffcSha256File agree with the vectors',
    () async {
      final Uint8List data = Uint8List(_chunk + 1);
      _fill(data, 0, data.length);
      const String expected =
          '20b5c5508abef0cfd3784d2e210388efaa6bf03f1584aa1e501691bb1807da7a';
      expect(ffcSha256Bytes(data), expected);
      expect(
        ffcSha256Bytes(<int>[]),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      final Directory dir = await Directory.systemTemp.createTemp('ffc-sha-');
      addTearDown(() => dir.delete(recursive: true));
      final File file = File('${dir.path}${Platform.pathSeparator}f.bin');
      await file.writeAsBytes(data);
      expect(await ffcSha256File(file.path), expected);
    },
  );

  test('ffcBytesEqual compares across 1 MiB slices', () {
    final Uint8List a = Uint8List(3 * (1 << 20) + 5);
    _fill(a, 0, a.length);
    final Uint8List b = Uint8List.fromList(a);
    expect(ffcBytesEqual(a, b), isTrue);
    expect(ffcBytesEqual(<int>[], <int>[]), isTrue);
    b[b.length - 1] ^= 1;
    expect(ffcBytesEqual(a, b), isFalse);
    expect(ffcBytesEqual(a, Uint8List.sublistView(a, 1)), isFalse);
  });

  test('uuidV5 single and batch agree with RFC 9562 A.4', () {
    final Uint8List dns = Uint8List.fromList(<int>[
      0x6b, 0xa7, 0xb8, 0x10, 0x9d, 0xad, 0x11, 0xd1, //
      0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8,
    ]);
    final List<int> name = 'www.example.com'.codeUnits;
    const String expected = '2ed6657de927568b95e12665a8aea6a2';
    String hex(List<int> b) =>
        b.map((int x) => x.toRadixString(16).padLeft(2, '0')).join();
    expect(hex(ffcUuidV5(dns, name)), expected);
    final Uint8List both = ffcUuidV5Batch(
      Uint8List.fromList(<int>[...dns, ...dns]),
      <List<int>>[name, name],
    );
    expect(hex(both), expected * 2);
    // SHA-256("") 前 7 字节 e3b0c44298fc1c 的低 53 位。
    expect(ffcHash53(<int>[]), 0x00e3b0c44298fc1c & 0x1FFFFFFFFFFFFF);
  });

  test('PoW solve returns the smallest nonce and check agrees', () {
    final List<int> prefix = 'fip1|test-install|'.codeUnits;
    // 与删除前的纯 Dart 求解一致（fushi_engine install_identity_test 冻结了同一组值）。
    expect(ffcPowSolve(prefix, 8), 148);
    expect(ffcPowCheck(prefix, '148'.codeUnits, 8), isTrue);
    expect(ffcPowCheck(prefix, '147'.codeUnits, 8), isFalse);
    expect(ffcPowCheck(prefix, '0'.codeUnits, 0), isTrue);
  });
}
