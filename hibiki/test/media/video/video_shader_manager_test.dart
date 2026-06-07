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

  group('mpvConfigDirCandidates', () {
    test('Windows：MPV_HOME 优先，再 %APPDATA%\\mpv', () {
      final List<String> dirs = mpvConfigDirCandidates(
        env: <String, String>{
          'MPV_HOME': r'C:\custom\mpv',
          'APPDATA': r'C:\Users\me\AppData\Roaming',
        },
        isWindows: true,
        isMacOS: false,
      );
      expect(dirs.first, r'C:\custom\mpv');
      expect(dirs.length, 2);
    });

    test('Windows：无 MPV_HOME 只回 %APPDATA%\\mpv', () {
      final List<String> dirs = mpvConfigDirCandidates(
        env: <String, String>{'APPDATA': r'C:\Users\me\AppData\Roaming'},
        isWindows: true,
        isMacOS: false,
      );
      expect(dirs, <String>[p.join(r'C:\Users\me\AppData\Roaming', 'mpv')]);
    });

    test('Linux：XDG_CONFIG_HOME 设了则用它，不回退 ~/.config', () {
      final List<String> dirs = mpvConfigDirCandidates(
        env: <String, String>{
          'XDG_CONFIG_HOME': '/home/me/.cfg',
          'HOME': '/home/me',
        },
        isWindows: false,
        isMacOS: false,
      );
      expect(dirs, <String>[p.join('/home/me/.cfg', 'mpv')]);
    });

    test('Linux：无 XDG → ~/.config/mpv', () {
      final List<String> dirs = mpvConfigDirCandidates(
        env: <String, String>{'HOME': '/home/me'},
        isWindows: false,
        isMacOS: false,
      );
      expect(dirs, <String>[p.join('/home/me', '.config', 'mpv')]);
    });

    test('macOS：追加 ~/Library/Application Support/mpv', () {
      final List<String> dirs = mpvConfigDirCandidates(
        env: <String, String>{'HOME': '/Users/me'},
        isWindows: false,
        isMacOS: true,
      );
      expect(dirs, <String>[
        p.join('/Users/me', '.config', 'mpv'),
        p.join('/Users/me', 'Library', 'Application Support', 'mpv'),
      ]);
    });

    test('空环境 → 空候选', () {
      expect(
        mpvConfigDirCandidates(
            env: const <String, String>{}, isWindows: false, isMacOS: false),
        isEmpty,
      );
    });
  });

  group('discoverMpvShadersIn', () {
    late Directory cfgDir;
    setUp(() => cfgDir = Directory.systemTemp.createTempSync('mpv_cfg_'));
    tearDown(() => cfgDir.deleteSync(recursive: true));

    test('扫 shaders/ 子目录下 .glsl/.hook，绝对路径按名排序', () {
      final Directory shaders = Directory(p.join(cfgDir.path, 'shaders'))
        ..createSync();
      File(p.join(shaders.path, 'Zoom.glsl')).writeAsStringSync('//');
      File(p.join(shaders.path, 'Anime4K.hook')).writeAsStringSync('//');
      File(p.join(shaders.path, 'notes.txt')).writeAsStringSync('x');
      expect(discoverMpvShadersIn(cfgDir), <String>[
        p.join(shaders.path, 'Anime4K.hook'),
        p.join(shaders.path, 'Zoom.glsl'),
      ]);
    });

    test('无 shaders/ 子目录 → 空', () {
      expect(discoverMpvShadersIn(cfgDir), isEmpty);
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
