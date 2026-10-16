import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki_core.dart';

// 「高级制卡」打码覆盖项（`MiningRequestOverrides.mosaic`）的 wire 形态：
//   * 往返不丢、坐标原样；
//   * 向后兼容：旧 payload 没有 `mosaic` 键 → 空列表、覆盖项照旧为空；
//   * 坏项逐个丢弃（不因一项坏掉而丢整组）、退化 / 越界矩形被夹 / 被弃；
//   * 只有打码也算「改过」：attach 会写键。
void main() {
  const MiningMosaicRegion a = MiningMosaicRegion(
    left: 0.1,
    top: 0.2,
    right: 0.3,
    bottom: 0.4,
  );
  const MiningMosaicRegion b = MiningMosaicRegion(
    left: 0.5,
    top: 0.5,
    right: 0.9,
    bottom: 0.95,
  );

  test('往返：两条 wire 线都原样带回打码区域', () {
    const MiningRequestOverrides o = MiningRequestOverrides(
      mosaic: <MiningMosaicRegion>[a, b],
    );
    expect(o.isEmpty, isFalse);
    expect(o.hasMosaic, isTrue);
    final Map<String, String> fields = MiningRequestOverrides.attach(
      <String, String>{'expression': '諦める'},
      o,
    );
    final MiningRequestOverrides back = MiningRequestOverrides.readFrom(
      fields,
    )!;
    expect(back.mosaic, <MiningMosaicRegion>[a, b]);
    // 保类型线（Map 直传）。
    final MiningRequestOverrides fromMap = MiningRequestOverrides.readFrom(
      <String, dynamic>{MiningRequestOverrides.wireKey: o.toJson()},
    )!;
    expect(fromMap.mosaic, <MiningMosaicRegion>[a, b]);
  });

  test('向后兼容：没有 mosaic 键 → 空列表；空打码不写键', () {
    final MiningRequestOverrides old = MiningRequestOverrides.fromJson(
      <String, Object?>{'omitAudio': true},
    );
    expect(old.mosaic, isEmpty);
    expect(old.hasMosaic, isFalse);
    expect(
      const MiningRequestOverrides(
        omitAudio: true,
      ).toJson().containsKey('mosaic'),
      isFalse,
    );
    expect(const MiningRequestOverrides().isEmpty, isTrue);
  });

  test('坏项逐个丢弃：非 Map / 缺字段 / 非数字 / 退化矩形', () {
    final MiningRequestOverrides o = MiningRequestOverrides.fromJson(
      jsonDecode(
            jsonEncode(<String, Object?>{
              'mosaic': <Object?>[
                a.toJson(),
                'junk',
                <String, Object?>{'l': 0.1, 't': 0.1, 'r': 0.2},
                <String, Object?>{'l': 'x', 't': 0.1, 'r': 0.2, 'b': 0.3},
                <String, Object?>{'l': 0.5, 't': 0.1, 'r': 0.5, 'b': 0.9},
                b.toJson(),
              ],
            }),
          )
          as Map<Object?, Object?>,
    );
    expect(o.mosaic, <MiningMosaicRegion>[a, b]);
  });

  test('越界 / 颠倒的矩形夹进 0..1 并摆正', () {
    final MiningMosaicRegion r = MiningMosaicRegion.fromJson(<String, Object?>{
      'l': 1.4,
      't': 0.8,
      'r': -0.2,
      'b': 0.2,
    })!;
    expect(r.left, 0);
    expect(r.right, 1);
    expect(r.top, closeTo(0.2, 1e-12));
    expect(r.bottom, closeTo(0.8, 1e-12));
    expect(MiningMosaicRegion.listFromJson('not a list'), isEmpty);
  });

  test('copyWith 换打码区域，其余不动', () {
    const MiningRequestOverrides o = MiningRequestOverrides(omitAudio: true);
    final MiningRequestOverrides next = o.copyWith(
      mosaic: <MiningMosaicRegion>[a],
    );
    expect(next.omitAudio, isTrue);
    expect(next.mosaic, <MiningMosaicRegion>[a]);
    expect(next.copyWith().mosaic, <MiningMosaicRegion>[a]);
  });
}
