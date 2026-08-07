import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_shader_manager.dart';
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
    test('Windows：MPV_HOME 优先，再 %APPDATA% 的 mpv + mpv.net', () {
      final List<String> dirs = mpvConfigDirCandidates(
        env: <String, String>{
          'MPV_HOME': r'C:\custom\mpv',
          'APPDATA': r'C:\Users\me\AppData\Roaming',
        },
        isWindows: true,
        isMacOS: false,
      );
      expect(dirs.first, r'C:\custom\mpv');
      expect(
          dirs,
          containsAll(<String>[
            p.join(r'C:\Users\me\AppData\Roaming', 'mpv'),
            p.join(r'C:\Users\me\AppData\Roaming', 'mpv.net'),
          ]));
    });

    test('Windows：%APPDATA% 与 %LOCALAPPDATA% 变体都覆盖（更正经）', () {
      final List<String> dirs = mpvConfigDirCandidates(
        env: <String, String>{
          'APPDATA': r'C:\Users\me\AppData\Roaming',
          'LOCALAPPDATA': r'C:\Users\me\AppData\Local',
        },
        isWindows: true,
        isMacOS: false,
      );
      expect(dirs, <String>[
        p.join(r'C:\Users\me\AppData\Roaming', 'mpv'),
        p.join(r'C:\Users\me\AppData\Roaming', 'mpv.net'),
        p.join(r'C:\Users\me\AppData\Local', 'mpv'),
      ]);
    });

    test('Linux：XDG 设了仍补 ~/.config/mpv（两处都查，更正经）', () {
      final List<String> dirs = mpvConfigDirCandidates(
        env: <String, String>{
          'XDG_CONFIG_HOME': '/home/me/.cfg',
          'HOME': '/home/me',
        },
        isWindows: false,
        isMacOS: false,
      );
      expect(dirs, <String>[
        p.join('/home/me/.cfg', 'mpv'),
        p.join('/home/me', '.config', 'mpv'),
      ]);
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

  group('mpvPortableConfigCandidates（便携版 PATH 探测）', () {
    test('PATH 每个目录给出 <dir>/portable_config（不给目录本身）', () {
      final List<String> dirs = mpvPortableConfigCandidates(
        env: <String, String>{
          'PATH': <String>[r'C:\mpv', r'C:\Windows\System32'].join(';'),
        },
        pathSeparator: ';',
      );
      expect(dirs, <String>[
        p.join(r'C:\mpv', 'portable_config'),
        p.join(r'C:\Windows\System32', 'portable_config'),
      ]);
      // 关键：绝不包含 PATH 目录本身（否则发现逻辑会去递归扫 System32）。
      expect(dirs.contains(r'C:\Windows\System32'), isFalse);
    });

    test('无 PATH → 空', () {
      expect(
        mpvPortableConfigCandidates(
            env: const <String, String>{}, pathSeparator: ':'),
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

  group('discoverShadersInUserDir（手动指定目录）', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('mpv_userdir_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('用户直接指向 shaders 文件夹：扫该目录本身', () {
      File(p.join(dir.path, 'A.glsl')).writeAsStringSync('//');
      File(p.join(dir.path, 'B.hook')).writeAsStringSync('//');
      File(p.join(dir.path, 'readme.txt')).writeAsStringSync('x');
      expect(discoverShadersInUserDir(dir), <String>[
        p.join(dir.path, 'A.glsl'),
        p.join(dir.path, 'B.hook'),
      ]);
    });

    test('用户指向 mpv 配置目录：扫其 shaders/ 子目录', () {
      final Directory shaders = Directory(p.join(dir.path, 'shaders'))
        ..createSync();
      File(p.join(shaders.path, 'Z.glsl')).writeAsStringSync('//');
      expect(discoverShadersInUserDir(dir), <String>[
        p.join(shaders.path, 'Z.glsl'),
      ]);
    });

    test('目录本身与 shaders/ 都有，按 basename 去重（目录本身优先）', () {
      File(p.join(dir.path, 'Dup.glsl')).writeAsStringSync('//root');
      final Directory shaders = Directory(p.join(dir.path, 'shaders'))
        ..createSync();
      File(p.join(shaders.path, 'Dup.glsl')).writeAsStringSync('//sub');
      File(p.join(shaders.path, 'Only.hook')).writeAsStringSync('//');
      expect(discoverShadersInUserDir(dir), <String>[
        p.join(dir.path, 'Dup.glsl'), // 目录本身先于 shaders/，去重保留它
        p.join(shaders.path, 'Only.hook'),
      ]);
    });

    test('不存在的目录 → 空', () {
      expect(
        discoverShadersInUserDir(Directory(p.join(dir.path, 'nope'))),
        isEmpty,
      );
    });

    test('递归扫嵌套子目录（shaders/<包名>/x.glsl 也找到，更正经）', () {
      final Directory pack = Directory(p.join(dir.path, 'shaders', 'Anime4K'))
        ..createSync(recursive: true);
      File(p.join(pack.path, 'Restore.glsl')).writeAsStringSync('//');
      File(p.join(dir.path, 'Loose.hook')).writeAsStringSync('//');
      final List<String> found = discoverShadersInUserDir(dir);
      expect(
          found,
          containsAll(<String>[
            p.join(dir.path, 'Loose.hook'),
            p.join(pack.path, 'Restore.glsl'),
          ]));
    });
  });

  group('discoverLocalMpvShaders overrideDir 优先', () {
    test('overrideDir 的着色器排在自动候选之前（且按 basename 去重）', () async {
      final Directory override =
          Directory.systemTemp.createTempSync('mpv_override_');
      addTearDown(() => override.deleteSync(recursive: true));
      File(p.join(override.path, 'Custom.glsl')).writeAsStringSync('//');
      // 不构造真实自动候选目录（本机可能装了 mpv），只验证 override 的结果出现且在前。
      final List<String> found =
          await discoverLocalMpvShaders(overrideDir: override.path);
      expect(found, isNotEmpty);
      expect(found.first, p.join(override.path, 'Custom.glsl'),
          reason: '手动指定目录的着色器应优先');
    });

    test('overrideDir 为空串时不抛（走自动候选）', () async {
      final List<String> found = await discoverLocalMpvShaders(overrideDir: '');
      expect(found, isA<List<String>>());
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

  group('buildShaderChangeListCommands（BUG-759 根因守卫）', () {
    test('空启用集 → 只有一条 clr（清空整链）', () {
      expect(buildShaderChangeListCommands(const <String>[]), <List<String>>[
        <String>['change-list', 'glsl-shaders', 'clr', ''],
      ]);
    });

    test('多路径 → clr 打头，再逐个 append，保持勾选顺序', () {
      final List<List<String>> cmds = buildShaderChangeListCommands(<String>[
        '/shaders/Restore.glsl',
        '/shaders/Upscale.glsl',
      ]);
      expect(cmds, <List<String>>[
        <String>['change-list', 'glsl-shaders', 'clr', ''],
        <String>[
          'change-list',
          'glsl-shaders',
          'append',
          '/shaders/Restore.glsl'
        ],
        <String>[
          'change-list',
          'glsl-shaders',
          'append',
          '/shaders/Upscale.glsl'
        ],
      ]);
    });

    test('Windows 盘符路径（含 : 与反斜杠）作为独立参数原样传入，绝不拼分隔符', () {
      const String winPath =
          r'D:\APP\FUSHI_date\support\mpv_shaders\Anime4K_Clamp_Highlights.glsl';
      final List<List<String>> cmds =
          buildShaderChangeListCommands(<String>[winPath]);
      // append 命令的第 4 个参数必须是原始路径（未被任何分隔符切分/转义）。
      expect(cmds.last,
          <String>['change-list', 'glsl-shaders', 'append', winPath]);
      // 关键回归守卫：绝不出现被证伪的 `glsl-shaders-append` property 名（空下发根因）。
      for (final List<String> cmd in cmds) {
        expect(cmd.contains('glsl-shaders-append'), isFalse,
            reason: 'glsl-shaders-append 不是合法 property 名，会被 media_kit '
                '静默吞掉导致着色器空下发（BUG-759）——必须走 change-list 命令');
      }
    });
  });

  group('applyShadersToPlayer 源码守卫（BUG-759）', () {
    test('apply 路径用 native.command，且不再用 glsl-shaders-append property', () {
      final String src = File('lib/src/media/video/video_shader_manager.dart')
          .readAsStringSync();
      // 必须经 command 下发 change-list（正确的运行时改列表机制）。
      expect(src.contains('native.command('), isTrue,
          reason: '着色器必须经 NativePlayer.command 下发 change-list');
      // 绝不再用 setProperty 设 glsl-shaders-append（会 PROPERTY_NOT_FOUND 空下发）。
      expect(src.contains("setProperty('glsl-shaders-append'"), isFalse,
          reason: 'glsl-shaders-append 作为 property 非法，会导致空下发（BUG-759）');
    });
  });
}
