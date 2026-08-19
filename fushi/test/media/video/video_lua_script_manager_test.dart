import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_lua_script_manager.dart';
import 'package:path/path.dart' as p;

void main() {
  group('listLuaScriptFilesIn', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('lua_scripts_test_');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('只收顶层 .lua（扩展名不分大小写），按路径排序', () {
      File(p.join(dir.path, 'b_second.lua')).writeAsStringSync('-- b');
      File(p.join(dir.path, 'a_first.LUA')).writeAsStringSync('-- a');
      File(p.join(dir.path, 'readme.txt')).writeAsStringSync('not a script');
      File(p.join(dir.path, 'osc.lua.bak')).writeAsStringSync('not a script');
      // 子目录不递归：脚本自己的模块/资源不当独立脚本装载。
      final Directory sub = Directory(p.join(dir.path, 'modules'))
        ..createSync();
      File(p.join(sub.path, 'dep.lua')).writeAsStringSync('-- dep');

      final List<String> out = listLuaScriptFilesIn(dir);

      expect(out, <String>[
        p.join(dir.path, 'a_first.LUA'),
        p.join(dir.path, 'b_second.lua'),
      ]);
    });

    test('目录不存在返回空列表', () {
      final Directory missing = Directory(p.join(dir.path, 'nope'));
      expect(listLuaScriptFilesIn(missing), isEmpty);
    });

    test('空目录返回空列表', () {
      expect(listLuaScriptFilesIn(dir), isEmpty);
    });
  });

  group('buildLoadScriptCommands', () {
    test('每个路径一条 load-script 命令，保持输入顺序', () {
      final List<List<String>> cmds = buildLoadScriptCommands(
        <String>[r'C:\a\x.lua', r'C:\a\y.lua'],
      );
      expect(cmds, <List<String>>[
        <String>['load-script', r'C:\a\x.lua'],
        <String>['load-script', r'C:\a\y.lua'],
      ]);
    });

    test('空输入产生空命令序列（调用方零下发）', () {
      expect(buildLoadScriptCommands(const <String>[]), isEmpty);
    });
  });

  group('importLuaScriptFileTo', () {
    late Directory src;
    late Directory dst;

    setUp(() {
      src = Directory.systemTemp.createTempSync('lua_import_src_');
      dst = Directory.systemTemp.createTempSync('lua_import_dst_');
    });

    tearDown(() {
      for (final Directory d in <Directory>[src, dst]) {
        if (d.existsSync()) d.deleteSync(recursive: true);
      }
    });

    test('复制进目标目录并返回文件名；重名覆盖', () {
      final File source = File(p.join(src.path, 'auto_profile.lua'))
        ..writeAsStringSync('-- v1');
      expect(importLuaScriptFileTo(dst, source.path), 'auto_profile.lua');
      expect(
        File(p.join(dst.path, 'auto_profile.lua')).readAsStringSync(),
        '-- v1',
      );

      source.writeAsStringSync('-- v2');
      importLuaScriptFileTo(dst, source.path);
      expect(
        File(p.join(dst.path, 'auto_profile.lua')).readAsStringSync(),
        '-- v2',
      );
    });

    test('目标目录不存在时创建', () {
      final Directory nested = Directory(p.join(dst.path, 'nested'));
      final File source = File(p.join(src.path, 's.lua'))
        ..writeAsStringSync('-- s');
      importLuaScriptFileTo(nested, source.path);
      expect(File(p.join(nested.path, 's.lua')).existsSync(), isTrue);
    });
  });
}
