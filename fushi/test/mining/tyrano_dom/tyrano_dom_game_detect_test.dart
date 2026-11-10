import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fushi/src/mining/tyrano_dom/tyrano_dom_game_detect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 按 asar 格式写一个只有头的包（Pickle：u32 4, u32 头大小, u32 载荷大小, u32 JSON 长度）。
void _writeAsar(String path, Map<String, Object?> files) {
  final List<int> json = utf8.encode(
    jsonEncode(<String, Object?>{'files': files}),
  );
  final int padded = (json.length + 3) & ~3;
  final ByteData head = ByteData(16)
    ..setUint32(0, 4, Endian.little)
    ..setUint32(4, padded + 8, Endian.little)
    ..setUint32(8, padded + 4, Endian.little)
    ..setUint32(12, json.length, Endian.little);
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(<int>[
      ...head.buffer.asUint8List(),
      ...json,
      ...List<int>.filled(padded - json.length, 0),
    ]);
}

void _touch(String path) => File(path)
  ..createSync(recursive: true)
  ..writeAsStringSync('x');

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('tyrano_detect_'));
  tearDown(() => temp.deleteSync(recursive: true));

  String exeIn(String dir, [String name = 'some_game.exe']) {
    final String exe = p.join(dir, name);
    _touch(exe);
    return exe;
  }

  group('Electron 布局', () {
    test('app.asar 顶层有 tyrano/ + ffmpeg.dll → 是', () {
      _touch(p.join(temp.path, 'ffmpeg.dll'));
      _writeAsar(p.join(temp.path, 'resources', 'app.asar'), <String, Object?>{
        'index.html': <String, Object?>{'size': 1, 'offset': '0'},
        'tyrano': <String, Object?>{'files': <String, Object?>{}},
      });
      expect(isTyranoElectronGameDirectory(exeIn(temp.path)), isTrue);
    });

    test('判据不看 exe 名：同一布局换任意 exe 名结果一致', () {
      _touch(p.join(temp.path, 'ffmpeg.dll'));
      _writeAsar(p.join(temp.path, 'resources', 'app.asar'), <String, Object?>{
        'tyrano': <String, Object?>{'files': <String, Object?>{}},
      });
      expect(isTyranoElectronGameDirectory(exeIn(temp.path, 'a.exe')), isTrue);
      expect(
        isTyranoElectronGameDirectory(exeIn(temp.path, 'Game Launcher.exe')),
        isTrue,
      );
    });

    test('非 Tyrano 的 Electron 应用（asar 里无 tyrano/）→ 否', () {
      _touch(p.join(temp.path, 'ffmpeg.dll'));
      _writeAsar(p.join(temp.path, 'resources', 'app.asar'), <String, Object?>{
        'main.js': <String, Object?>{'size': 1, 'offset': '0'},
      });
      expect(isTyranoElectronGameDirectory(exeIn(temp.path)), isFalse);
    });

    test('缺 ffmpeg.dll → 否', () {
      _writeAsar(p.join(temp.path, 'resources', 'app.asar'), <String, Object?>{
        'tyrano': <String, Object?>{'files': <String, Object?>{}},
      });
      expect(isTyranoElectronGameDirectory(exeIn(temp.path)), isFalse);
    });

    test('app.asar 不是合法 asar → 否', () {
      _touch(p.join(temp.path, 'ffmpeg.dll'));
      _touch(p.join(temp.path, 'resources', 'app.asar'));
      expect(isTyranoElectronGameDirectory(exeIn(temp.path)), isFalse);
    });

    test('空目录 → 否', () {
      expect(isTyranoElectronGameDirectory(exeIn(temp.path)), isFalse);
    });
  });

  group('NW.js 布局', () {
    setUp(() {
      _touch(p.join(temp.path, 'ffmpeg.dll'));
      _touch(p.join(temp.path, 'nw.dll'));
    });

    test('exe 同目录散文件：package.json + tyrano/ → 是', () {
      _touch(p.join(temp.path, 'package.json'));
      _touch(p.join(temp.path, 'tyrano', 'tyrano.js'));
      expect(isTyranoElectronGameDirectory(exeIn(temp.path)), isTrue);
    });

    test('package.nw 目录里有 tyrano/ → 是', () {
      _touch(p.join(temp.path, 'package.nw', 'package.json'));
      _touch(p.join(temp.path, 'package.nw', 'tyrano', 'tyrano.js'));
      expect(isTyranoElectronGameDirectory(exeIn(temp.path)), isTrue);
    });

    test('package.nw 是 zip 且含 tyrano/ → 是；不含 → 否', () {
      final Archive withTyrano = Archive()
        ..addFile(ArchiveFile('package.json', 2, utf8.encode('{}')))
        ..addFile(ArchiveFile('tyrano/tyrano.js', 1, utf8.encode('x')));
      final String zipPath = p.join(temp.path, 'package.nw');
      File(zipPath).writeAsBytesSync(ZipEncoder().encode(withTyrano)!);
      expect(isTyranoElectronGameDirectory(exeIn(temp.path)), isTrue);

      final Archive without = Archive()
        ..addFile(ArchiveFile('package.json', 2, utf8.encode('{}')))
        ..addFile(ArchiveFile('js/app.js', 1, utf8.encode('x')));
      File(zipPath).writeAsBytesSync(ZipEncoder().encode(without)!);
      expect(isTyranoElectronGameDirectory(exeIn(temp.path)), isFalse);
    });

    test('有 nw.dll 但没有应用本体 → 否', () {
      expect(isTyranoElectronGameDirectory(exeIn(temp.path)), isFalse);
    });

    test('缺 nw.dll（只有散文件）→ 否', () {
      File(p.join(temp.path, 'nw.dll')).deleteSync();
      _touch(p.join(temp.path, 'package.json'));
      _touch(p.join(temp.path, 'tyrano', 'tyrano.js'));
      expect(isTyranoElectronGameDirectory(exeIn(temp.path)), isFalse);
    });
  });

  test('readAsarTopLevelEntries 读出顶层条目', () {
    final String asar = p.join(temp.path, 'a.asar');
    _writeAsar(asar, <String, Object?>{
      'data': <String, Object?>{'files': <String, Object?>{}},
      'tyrano': <String, Object?>{'files': <String, Object?>{}},
    });
    expect(readAsarTopLevelEntries(asar), <String>{'data', 'tyrano'});
  });
}
