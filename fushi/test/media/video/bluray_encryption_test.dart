import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/bluray/bluray_encryption.dart';
import 'package:path/path.dart' as p;

/// 一个 BDAV aligned unit：32 个 192 字节源包，每包 4 字节 TP_extra_header + 0x47 起头
/// 的 188 字节 TS 包。[copyPermission] 写进首包 TP_extra_header 的最高两位。
Uint8List _bdavUnit({int copyPermission = 0}) {
  final Uint8List unit = Uint8List(kBlurayAlignedUnitBytes);
  for (int i = 0; i < 32; i++) {
    final int base = i * 192;
    unit[base] = (copyPermission & 0x3) << 6;
    unit[base + 4] = 0x47;
    for (int j = base + 5; j < base + 192; j++) {
      unit[j] = (j * 7) & 0xFF;
    }
  }
  return unit;
}

/// AACS 密文单元：前 16 字节明文，其余打乱（同步字节不再对齐）。
Uint8List _encryptedUnit() {
  final Uint8List unit = _bdavUnit(copyPermission: 3);
  final math.Random rng = math.Random(42);
  for (int i = 16; i < unit.length; i++) {
    int b = rng.nextInt(256);
    if (b == 0x47) b = 0x48;
    unit[i] = b;
  }
  return unit;
}

/// 普通 188 字节封装的 TS（`.ts` 录播）：首字节 0x47、最高两位非零。
Uint8List _plainTsUnit() {
  final Uint8List unit = Uint8List(kBlurayAlignedUnitBytes);
  for (int i = 0; i < unit.length; i++) {
    unit[i] = i % 188 == 0 ? 0x47 : (i * 13) & 0xFF;
  }
  return unit;
}

void main() {
  group('isAacsEncryptedAlignedUnit', () {
    test('密文单元：copy_permission 置位且密文区同步字节被打乱', () {
      expect(isAacsEncryptedAlignedUnit(_encryptedUnit()), isTrue);
    });

    test('未加密 BDAV：copy_permission 为 0', () {
      expect(isAacsEncryptedAlignedUnit(_bdavUnit()), isFalse);
    });

    test('已解密但标志没清：同步字节完整 → 不是密文', () {
      expect(isAacsEncryptedAlignedUnit(_bdavUnit(copyPermission: 3)), isFalse);
    });

    test('普通 188 字节 TS 不被误判（首字节 0x47 的最高两位非零）', () {
      final Uint8List ts = _plainTsUnit();
      expect(ts[0] & 0xC0, isNot(0), reason: '前提：只看标志位就会误判');
      expect(isAacsEncryptedAlignedUnit(ts), isFalse);
    });

    test('偏移 4 碰巧是 0x47 的普通 TS 也不被误判', () {
      final Uint8List ts = _plainTsUnit()..[4] = 0x47;
      expect(isAacsEncryptedAlignedUnit(ts), isFalse);
    });

    test('不足一个单元：不判加密', () {
      expect(isAacsEncryptedAlignedUnit(Uint8List(100)), isFalse);
    });
  });

  group('isAacsEncryptedStreamFile', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('bd_aacs_'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    Future<bool> check(List<Uint8List> units) async {
      final File f = File(p.join(tmp.path, '00001.m2ts'));
      f.writeAsBytesSync(<int>[for (final Uint8List u in units) ...u]);
      return isAacsEncryptedStreamFile(f.path);
    }

    test('开头是密文 → 加密', () async {
      expect(await check(<Uint8List>[_encryptedUnit(), _bdavUnit()]), isTrue);
    });

    test('开头明文、中段密文 → 加密（抽样不止看开头）', () async {
      expect(
        await check(<Uint8List>[
          _bdavUnit(),
          _encryptedUnit(),
          _encryptedUnit(),
        ]),
        isTrue,
      );
    });

    test('全明文 → 不加密', () async {
      expect(await check(<Uint8List>[_bdavUnit(), _bdavUnit()]), isFalse);
    });

    test('文件不存在 / 太短 → 不加密（交给内核报真实错误）', () async {
      expect(
        await isAacsEncryptedStreamFile(p.join(tmp.path, 'missing.m2ts')),
        isFalse,
      );
      expect(await check(<Uint8List>[Uint8List(10)]), isFalse);
    });
  });

  test('isBdavStreamPath', () {
    expect(isBdavStreamPath(r'E:\BDMV\STREAM\00001.M2TS'), isTrue);
    expect(isBdavStreamPath('/cam/0001.mts'), isTrue);
    expect(isBdavStreamPath('/rec/ep01.ts'), isFalse);
    expect(isBdavStreamPath('/v/a.mkv'), isFalse);
  });

  test('播放前解密接线：load() 使用会话，页面按配置错误给出原因', () {
    final String controller = File(
      'lib/src/media/video/video_player_controller.dart',
    ).readAsStringSync();
    final int check = controller.indexOf('aacsSession.playbackSource(');
    final int open = controller.indexOf('await player.open(');
    expect(check, greaterThan(0));
    expect(
      controller,
      isNot(contains('throw BlurayEncryptedStreamException(')),
    );
    expect(check, lessThan(open), reason: '必须在交给 libmpv 之前判');

    final String page = File(
      'lib/src/pages/implementations/video_fushi_page.dart',
    ).readAsStringSync();
    expect(page, contains('error is AacsConfigurationException'));
    expect(page, contains('t.video_bluray_config_no_match'));
  });
}
