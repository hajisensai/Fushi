import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_shader_manager.dart';
import 'package:path/path.dart' as p;

void main() {
  group('enabled shaders encode/decode', () {
    test('round-trip', () {
      final List<String> names = <String>['a.glsl', 'b.hook'];
      expect(decodeEnabledShaders(encodeEnabledShaders(names)), names);
    });

    test('容错：null / 空串 / 损坏 JSON → 空列表', () {
      expect(decodeEnabledShaders(null), isEmpty);
      expect(decodeEnabledShaders(''), isEmpty);
      expect(decodeEnabledShaders('{not a list}'), isEmpty);
      expect(decodeEnabledShaders('"a string"'), isEmpty);
    });

    test('过滤非字符串元素', () {
      expect(decodeEnabledShaders('["a.glsl", 3, null, "b.hook"]'),
          <String>['a.glsl', 'b.hook']);
    });
  });

  group('listShaderFilesIn', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('shader_list_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('只返回 .glsl/.hook，按名排序', () {
      File(p.join(dir.path, 'Zoom.glsl')).writeAsStringSync('//');
      File(p.join(dir.path, 'Anime4K.hook')).writeAsStringSync('//');
      File(p.join(dir.path, 'readme.txt')).writeAsStringSync('x');
      File(p.join(dir.path, 'cover.jpg')).writeAsStringSync('x');
      expect(listShaderFilesIn(dir), <String>['Anime4K.hook', 'Zoom.glsl']);
    });

    test('不存在的目录 → 空', () {
      final Directory missing = Directory(p.join(dir.path, 'nope'));
      expect(listShaderFilesIn(missing), isEmpty);
    });
  });

  group('importShaderFileTo', () {
    late Directory src;
    late Directory dst;
    setUp(() {
      src = Directory.systemTemp.createTempSync('shader_src_');
      dst = Directory.systemTemp.createTempSync('shader_dst_');
    });
    tearDown(() {
      src.deleteSync(recursive: true);
      dst.deleteSync(recursive: true);
    });

    test('复制进目标目录并返回 basename', () {
      final File f = File(p.join(src.path, 'MyShader.glsl'))
        ..writeAsStringSync('//shader');
      final String name = importShaderFileTo(dst, f.path);
      expect(name, 'MyShader.glsl');
      final File copied = File(p.join(dst.path, 'MyShader.glsl'));
      expect(copied.existsSync(), isTrue);
      expect(copied.readAsStringSync(), '//shader');
    });
  });

  group('resolveShaderPathsIn', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('shader_resolve_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('只解析存在的文件，保持启用顺序', () {
      File(p.join(dir.path, 'a.glsl')).writeAsStringSync('//');
      File(p.join(dir.path, 'b.hook')).writeAsStringSync('//');
      final List<String> paths = resolveShaderPathsIn(
          dir, <String>['b.hook', 'missing.glsl', 'a.glsl']);
      expect(paths, <String>[
        p.join(dir.path, 'b.hook'),
        p.join(dir.path, 'a.glsl'),
      ]);
    });

    test('全部不存在 → 空', () {
      expect(resolveShaderPathsIn(dir, <String>['x.glsl']), isEmpty);
    });
  });
}
