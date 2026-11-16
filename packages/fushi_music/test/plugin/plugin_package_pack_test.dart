import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:test/test.dart';

void main() {
  test('已装插件目录原样打回包：相对路径、子目录、字节不变；目录不存在为 null', () async {
    final Directory root = Directory.systemTemp.createTempSync('plugin_pack_');
    addTearDown(() => root.deleteSync(recursive: true));
    final Directory dir = Directory('${root.path}/demo')..createSync();
    File('${dir.path}/manifest.json').writeAsStringSync('{"id":"demo"}');
    File('${dir.path}/files.json').writeAsStringSync('{"files":{}}');
    Directory('${dir.path}/lib').createSync();
    File('${dir.path}/lib/main.js').writeAsBytesSync(<int>[0, 1, 2, 255]);
    // 插件存储与凭据在包目录之外：打包不会碰到。
    Directory('${root.path}/.storage').createSync();
    File('${root.path}/.storage/demo.json').writeAsStringSync('{"secret":1}');

    final Uint8List? zip = await packInstalledPluginDirectory(dir);
    final Archive archive = ZipDecoder().decodeBytes(zip!);
    final Map<String, List<int>> files = <String, List<int>>{
      for (final ArchiveFile f in archive.files)
        if (f.isFile) f.name: f.content as List<int>,
    };
    expect(files.keys, <String>['files.json', 'lib/main.js', 'manifest.json']);
    expect(files['lib/main.js'], <int>[0, 1, 2, 255]);
    expect(utf8.decode(files['manifest.json']!), '{"id":"demo"}');

    expect(
      await packInstalledPluginDirectory(Directory('${root.path}/missing')),
      isNull,
    );
  });
}
