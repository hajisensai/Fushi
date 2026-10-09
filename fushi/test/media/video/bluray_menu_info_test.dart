import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/bluray/bluray_menu_info.dart';
import 'package:path/path.dart' as p;

Uint8List indexFixture({bool javaTitle = false, bool absentMenu = false}) {
  final Uint8List bytes = Uint8List(144);
  bytes.setRange(0, 8, 'INDX0200'.codeUnits);
  final ByteData data = ByteData.sublistView(bytes);
  data.setUint32(8, 78);
  data.setUint32(40, 34);
  data.setUint32(78, 62);
  for (final int offset in <int>[82, 94, 108, 120, 132]) {
    bytes[offset] = 0x40;
    bytes[offset + 4] = offset < 108 ? 0x40 : 0;
    data.setUint16(offset + 6, offset == 94 && absentMenu ? 0xffff : 1);
  }
  data.setUint16(106, 3);
  if (javaTitle) {
    bytes[132] = 0x80;
    bytes[136] = 0x80;
    bytes.setRange(138, 143, '00001'.codeUnits);
  }
  return bytes;
}

void main() {
  test('HDMV interactive first play/top menu and three movie titles', () {
    final BlurayMenuInfo info = parseBlurayMenuInfo(indexFixture())!;
    expect(info.hasFirstPlay, isTrue);
    expect(info.hasTopMenu, isTrue);
    expect(info.requiresJava, isFalse);
    expect(info.titleCount, 3);
  });

  test('Java title is detected even when first play and top menu are HDMV', () {
    expect(
      parseBlurayMenuInfo(indexFixture(javaTitle: true))!.requiresJava,
      isTrue,
    );
  });

  test('0xffff HDMV object means no top menu', () {
    expect(
      parseBlurayMenuInfo(indexFixture(absentMenu: true))!.hasTopMenu,
      isFalse,
    );
  });

  test('a first-play movie alone is not an interactive menu', () {
    final Uint8List bytes = indexFixture(absentMenu: true);
    bytes[86] = 0; // HDMV movie, rather than an interactive first-play object.
    final BlurayMenuInfo info = parseBlurayMenuInfo(bytes)!;
    expect(info.hasFirstPlay, isTrue);
    expect(info.firstPlayInteractive, isFalse);
    expect(info.hasMenu, isFalse);
    bytes[86] = 0x40;
    expect(parseBlurayMenuInfo(bytes)!.hasMenu, isTrue);
  });

  test('all truncations and out-of-block objects are rejected', () {
    final Uint8List bytes = indexFixture();
    for (int i = 0; i < bytes.length; i++) {
      expect(
        parseBlurayMenuInfo(Uint8List.sublistView(bytes, 0, i)),
        isNull,
        reason: 'truncation at $i',
      );
    }
    ByteData.sublistView(bytes).setUint32(78, 26);
    expect(parseBlurayMenuInfo(bytes), isNull);
  });

  test('bad offset, signature and Java object name fail closed', () {
    final Uint8List offset = indexFixture();
    ByteData.sublistView(offset).setUint32(8, 0xffffffff);
    expect(parseBlurayMenuInfo(offset), isNull);
    final Uint8List signature = indexFixture()..[0] = 0;
    expect(parseBlurayMenuInfo(signature), isNull);
    final Uint8List java = indexFixture(javaTitle: true)..[138] = 0x2f;
    expect(parseBlurayMenuInfo(java), isNull);
  });

  test('invalid primary index falls back to backup', () async {
    final Directory temp = Directory.systemTemp.createTempSync('bd_menu_info_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final Directory backup = Directory(p.join(temp.path, 'BDMV', 'BACKUP'))
      ..createSync(recursive: true);
    File(p.join(temp.path, 'BDMV', 'index.bdmv')).writeAsBytesSync(<int>[0]);
    File(p.join(backup.path, 'index.bdmv')).writeAsBytesSync(indexFixture());
    expect((await readBlurayMenuInfo(temp.path))!.hasTopMenu, isTrue);
  });
}
