import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fushi_engine/leaderboard/cover_hash.dart';
import 'package:fushi_engine/leaderboard/leaderboard_models.dart';
import 'package:fushi_engine/leaderboard/local_shelf.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

/// 600×840 的「封面」：9×8 色块（相邻块亮度至少差 40），叠一层细噪点与一道斜向渐变，
/// 模拟有结构、有纹理的真实封面。
img.Image _cover(int seed) {
  final Random rnd = Random(seed);
  const int w = 600;
  const int h = 840;
  final List<List<int>> level = <List<int>>[];
  for (int y = 0; y < 8; y++) {
    final List<int> row = <int>[];
    for (int x = 0; x < 9; x++) {
      int v;
      do {
        v = 20 + rnd.nextInt(216);
      } while (x > 0 && (v - row[x - 1]).abs() < 40);
      row.add(v);
    }
    level.add(row);
  }
  final List<int> tint = <int>[
    rnd.nextInt(60),
    rnd.nextInt(60),
    rnd.nextInt(60),
  ];
  final img.Image out = img.Image(width: w, height: h);
  for (final img.Pixel p in out) {
    final int base = level[p.y * 8 ~/ h][p.x * 9 ~/ w];
    final int noise = rnd.nextInt(17) - 8;
    final int grad = (p.x + p.y) * 12 ~/ (w + h);
    int c(int t) => (base + noise + grad - 30 + t).clamp(0, 255);
    p
      ..r = c(tint[0])
      ..g = c(tint[1])
      ..b = c(tint[2]);
  }
  return out;
}

String _hashOfJpeg(img.Image image, {int? width, int quality = 80}) {
  final img.Image scaled = width == null
      ? image
      : img.copyResize(
          image,
          width: width,
          interpolation: img.Interpolation.average,
        );
  return coverDHash(
    Uint8List.fromList(img.encodeJpg(scaled, quality: quality)),
  )!;
}

void main() {
  test('哈希形状：16 位小写 hex；距离对称、自身为 0', () {
    final String h = _hashOfJpeg(_cover(1));
    expect(h, matches(RegExp(r'^[0-9a-f]{16}$')));
    expect(coverHashDistance(h, h), 0);
    expect(coverHashDistance('0000000000000000', 'ffffffffffffffff'), 64);
    expect(coverHashDistance('0000000000000000', '0000000000000007'), 3);
    expect(() => coverHashDistance('00', '00'), throwsFormatException);
  });

  test('同一张图不同 JPEG 质量 / 尺寸：距离远小于阈值', () {
    for (final int seed in <int>[1, 2, 3, 4, 5]) {
      final img.Image cover = _cover(seed);
      final String ref = _hashOfJpeg(cover, quality: 95);
      for (final String other in <String>[
        _hashOfJpeg(cover, quality: 40),
        _hashOfJpeg(cover, width: 300),
        _hashOfJpeg(cover, width: 300, quality: 50),
        _hashOfJpeg(cover, width: 150, quality: 70),
      ]) {
        expect(
          coverHashDistance(ref, other),
          lessThanOrEqualTo(4),
          reason: 'seed $seed: $ref vs $other',
        );
      }
    }
  });

  test('不同的图：距离超过阈值', () {
    final List<String> hashes = <String>[
      for (int seed = 1; seed <= 6; seed++)
        _hashOfJpeg(_cover(seed), width: 300),
    ];
    for (int i = 0; i < hashes.length; i++) {
      for (int j = i + 1; j < hashes.length; j++) {
        expect(
          coverHashDistance(hashes[i], hashes[j]),
          greaterThan(kCoverHashMaxDistance),
          reason: '$i vs $j',
        );
      }
    }
  });

  test('比 9×8 还小的图也有确定的哈希；解不开的字节返回 null', () {
    final img.Image tiny = img.Image(width: 3, height: 2);
    expect(coverDHashOfImage(tiny), hasLength(16));
    expect(coverDHash(Uint8List.fromList(<int>[1, 2, 3])), isNull);
  });

  test('本地封面指纹：随文件内容变化；文件不在 / 没有封面返回 null', () async {
    final Directory dir = await Directory.systemTemp.createTemp('cover_fp');
    addTearDown(() => dir.delete(recursive: true));
    final File f = File('${dir.path}/c.jpg')..writeAsBytesSync(<int>[1, 2, 3]);
    LocalShelfEntry entry(String? path) => LocalShelfEntry(
      localKey: 'book:a',
      localCoverPath: path,
      upload: ShelfEntryUpload(
        kind: LeaderboardKind.book,
        refs: const <String>['t:a|'],
        title: 'a',
        finished: false,
      ),
    );
    final String? a = await localCoverFingerprint(entry(f.path));
    expect(a, startsWith(f.path));
    f.writeAsBytesSync(<int>[1, 2, 3, 4]);
    expect(await localCoverFingerprint(entry(f.path)), isNot(a));
    expect(
      await localCoverFingerprint(entry('${dir.path}/missing.jpg')),
      isNull,
    );
    expect(await localCoverFingerprint(entry(null)), isNull);
  });
}
