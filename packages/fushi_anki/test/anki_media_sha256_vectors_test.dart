import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 制卡媒体文件名 `<prefix><sha256>.<ext>` 的回归向量。
///
/// 期望值由删除前的纯 Dart `_sha256Hex`（anki_media_naming.dart）生成，并与
/// package:crypto 逐项核对过。改走 Rust（ffcSha256Bytes）后，同一份字节必须得到同一个
/// 文件名：Anki 库里已有的媒体靠文件名判同内容，名字变了就会重复上传、去重失配。
///
/// 长度覆盖空输入、SHA-256 填充边界（55/56/57、63/64/65、119/120、127/128/129）、
/// 多块，以及 FFI 1 MiB 分段边界（1 MiB − 1 / 1 MiB / 1 MiB + 1）。
void main() {
  Uint8List pattern(int n) =>
      Uint8List.fromList(List<int>.generate(n, (int i) => (i * 31 + 7) & 0xff));

  const List<(int, String)> vectors = <(int, String)>[
    (0, 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'),
    (1, 'ca358758f6d27e6cf45272937977a748fd88391db679ceda7dc7bf1f005ee879'),
    (3, '647674a296197442f518bcca323ec605dd8d098b2d4f22ee1fdcdd2bb753a189'),
    (55, '8aa994584139d128848eeebc4e815639ba5ab6e6e39574195a63ac4f14f7c43b'),
    (56, 'ad574708f75c044c9b85de64cb568ee7711ff4f36448c6242f053ba8f6cc2b63'),
    (57, '5b46e502092be01b1100193e089fdda95638c12e19a1d24f308eb2c3d3ae849d'),
    (63, '280ed3e8ff1df845b2e7dfe6ac6cee817bef20e783cc65abc41b818b4d2fe076'),
    (64, 'c6ab9724ade5b6a7a1edfffb12f3aa9181351355af8fd08c919952ad211339dd'),
    (65, '788367c73c7ddf4c53f65e68cc0d943e6227ab55b0e78ba63ace822b1c6301c0'),
    (119, '3d610547d68216dedf7435a4fb6260353911f6b3fd3f18805ddb8be285d726fe'),
    (120, '1f80156a804cb7862ad113e8200e9d74499723e7c7854d5f48776d3148e09656'),
    (127, '192409cd280e14b743642ad1343fbd3e82d9305de72c078117745a679210cc3d'),
    (128, 'cc548ca2dec1f6fe4f58b2e27aa9c7521607df1130d140b55a4dad0665302356'),
    (129, '81e89a7b2911aaa7795f9e3d4910cb47d6cd2b00d83b8399481527261a1a7519'),
    (1000, '5097e7d587352f5097062ae679f37bda5802d9f875aba14c8cb4d1a188ada179'),
    (65536, 'ef4636928161808e87035fa51983821677527ccd9661991c5d0126a778b2268a'),
    (
      1048575,
      '4ddf525d0f1482ae9ed8ff016e61988dfab2707743585ac310be210689ddb8d6',
    ),
    (
      1048576,
      '06b7bbfb7824aa03382051691630eb26de85102d1b08a81e907ec0744cd8a286',
    ),
    (
      1048577,
      '0d09f3eabb5c78e5d435c41e3b3755f1c4d038657f739d0be0083c24e71235df',
    ),
  ];

  for (final (int length, String sha) in vectors) {
    test('媒体文件名 SHA-256 与旧实现一致：$length 字节', () {
      expect(
        fushiAnkiMediaFilenameForBytes(
          prefix: 'fushi_audio_',
          bytes: pattern(length),
          sourceName: 'clip.mp3',
        ),
        'fushi_audio_$sha.mp3',
      );
    });
  }

  test('后台 isolate 路径（≥64 KiB）与同步路径得到同一个文件名', () async {
    for (final (int length, String sha) in vectors.where(
      ((int, String) v) => v.$1 >= 64 * 1024,
    )) {
      expect(
        await fushiAnkiMediaFilenameForBytesAsync(
          prefix: 'fushi_audio_',
          bytes: pattern(length),
          sourceName: 'clip.mp3',
        ),
        'fushi_audio_$sha.mp3',
      );
    }
  });
}
