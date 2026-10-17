// 封面本机强比对（cover_compare.dart）的阈值标定。
//
// 样本（cover_samples/）：
//   genuineA.jpg       正版封面 A（= services/leaderboard/test/cover_vectors/cover_portrait.jpg，212×300）；
//   forged.jpg         审查构造的「夹断藏质量」伪造：不夹断的解码器算出 A 的 dHash，完整解码器显示另一张图；
//   inherent_0.15/0.25 审查构造的「老实伪造」：另一张图（A 镜像反色）叠上按 9×8 格凑 A 亮度的偏移，
//                      完整解码后 dHash 距离 ≤ 5，显示仍是另一张图（0.25 是只看 NCC 时最难分的一档）；
//   honestB.jpg        另一张正常封面。
// 同图变体在测试里由 A 现场生成（重编码 / 缩放 / 调色 / 小裁切）。

import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/leaderboard/cover_compare.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

Uint8List _sample(String name) =>
    File('test/leaderboard/cover_samples/$name').readAsBytesSync();

Uint8List _jpg(img.Image im, int quality) =>
    Uint8List.fromList(img.encodeJpg(im, quality: quality));

void main() {
  final Uint8List genuine = _sample('genuineA.jpg');
  final img.Image a = img.decodeImage(genuine)!;

  final Map<String, Uint8List> sameImage = <String, Uint8List>{
    '重编码 q95': _jpg(a, 95),
    '重编码 q80': _jpg(a, 80),
    '重编码 q40': _jpg(a, 40),
    '重编码 q20': _jpg(a, 20),
    '缩到 150 宽 q80': _jpg(img.copyResize(a, width: 150), 80),
    '缩到 106 宽 q70': _jpg(img.copyResize(a, width: 106), 70),
    '缩到 64 宽 q60': _jpg(img.copyResize(a, width: 64), 60),
    '缩小再放大': _jpg(
      img.copyResize(img.copyResize(a, width: 106), width: 212),
      80,
    ),
    '亮度 +8%': _jpg(img.adjustColor(a.clone(), brightness: 1.08), 80),
    '对比度 ×1.2': _jpg(img.adjustColor(a.clone(), contrast: 1.2), 80),
    '灰度': _jpg(img.grayscale(a.clone()), 80),
    '四边各裁 2%': _jpg(
      img.copyCrop(a, x: 4, y: 6, width: a.width - 8, height: a.height - 12),
      80,
    ),
  };
  final Map<String, Uint8List> different = <String, Uint8List>{
    'forged.jpg': _sample('forged.jpg'),
    'inherent_0.15.jpg': _sample('inherent_0.15.jpg'),
    'inherent_0.25.jpg': _sample('inherent_0.25.jpg'),
    'honestB.jpg': _sample('honestB.jpg'),
  };

  test('同一张图的各种压缩 / 尺寸 / 调色变体：判为同一张图，且离阈值有余量', () {
    for (final MapEntry<String, Uint8List> e in sameImage.entries) {
      final CoverSimilarity s = compareCoverBytes(genuine, e.value)!;
      // 标定数据：dart test --reporter expanded 可见。
      print('same  ${e.key}: $s');
      expect(s.sameImage, isTrue, reason: '${e.key}: $s');
      expect(s.ncc, greaterThanOrEqualTo(0.99), reason: e.key);
      expect(s.detailNcc, greaterThanOrEqualTo(0.85), reason: e.key);
    }
  });

  test('审查的伪造样本与不相关封面：判为不符', () {
    for (final MapEntry<String, Uint8List> e in different.entries) {
      final CoverSimilarity s = compareCoverBytes(genuine, e.value)!;
      print('other ${e.key}: $s');
      expect(s.sameImage, isFalse, reason: '${e.key}: $s');
      expect(s.detailNcc, lessThan(0.4), reason: e.key);
    }
    // 夹断藏质量的伪造让 Dart 的 JPEG 解码器直接抛异常：按「候选解不开 = 不符」处理，不崩。
    expect(coverSignature(different['forged.jpg']!), isNull);
  });

  test('只看 NCC 不够：老实伪造的 NCC 已到 0.93，靠细节项拉开', () {
    final CoverSimilarity s = compareCoverBytes(
      genuine,
      different['inherent_0.25.jpg']!,
    )!;
    expect(s.ncc, greaterThan(0.9));
    expect(s.detailNcc, lessThan(kCoverConfirmMinDetailNcc));
  });

  test('本地图解不开返回 null（本机问题，不该据此报不符）；候选解不开算不符', () {
    final Uint8List junk = Uint8List.fromList(<int>[1, 2, 3]);
    expect(compareCoverBytes(junk, genuine), isNull);
    expect(compareCoverBytes(genuine, junk)!.sameImage, isFalse);
  });

  test('纯色封面：两边都平坦时按均值比', () {
    Uint8List flat(int v) => _jpg(
      img.Image(width: 40, height: 60)..clear(img.ColorRgb8(v, v, v)),
      90,
    );
    expect(compareCoverBytes(flat(120), flat(122))!.sameImage, isTrue);
    expect(compareCoverBytes(flat(40), flat(200))!.sameImage, isFalse);
    expect(compareCoverBytes(flat(120), genuine)!.sameImage, isFalse);
  });

  test('后台 isolate 版本与同步版本结果一致', () async {
    final Uint8List v = sameImage['缩到 150 宽 q80']!;
    final CoverSimilarity bg = (await compareCoverBytesInBackground(
      genuine,
      v,
    ))!;
    final CoverSimilarity fg = compareCoverBytes(genuine, v)!;
    expect(bg.ncc, fg.ncc);
    expect(bg.detailNcc, fg.detailNcc);
  });
}
