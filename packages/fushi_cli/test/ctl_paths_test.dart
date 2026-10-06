import 'package:fushi_cli/fushi_cli.dart';
import 'package:test/test.dart';

void main() {
  group('resolveCtlStateDir', () {
    test('FUSHI_CTL_DIR 优先于一切', () {
      expect(
        resolveCtlStateDir(
          environment: <String, String>{
            kCtlDirEnv: '/x/ctl',
            'HOME': '/home/u',
          },
          operatingSystem: 'linux',
          testRoot: '/t',
        ),
        '/x/ctl',
      );
    });

    test('测试根隔离用户真实发现文件', () {
      expect(
        resolveCtlStateDir(
          environment: <String, String>{'HOME': '/home/u'},
          operatingSystem: 'linux',
          testRoot: '/t',
        ),
        '/t/ctl',
      );
    });

    test('测试根按目标平台拼路径（与宿主平台无关）', () {
      expect(
        resolveCtlStateDir(
          environment: const <String, String>{},
          operatingSystem: 'windows',
          testRoot: r'C:\t',
        ),
        r'C:\t\ctl',
      );
    });

    test('Windows 落 LOCALAPPDATA', () {
      expect(
        resolveCtlStateDir(
          environment: <String, String>{
            'LOCALAPPDATA': r'C:\Users\u\AppData\Local',
          },
          operatingSystem: 'windows',
        ),
        r'C:\Users\u\AppData\Local\Fushi\ctl',
      );
    });

    test('macOS 落 Application Support', () {
      expect(
        resolveCtlStateDir(
          environment: <String, String>{'HOME': '/Users/u'},
          operatingSystem: 'macos',
        ),
        '/Users/u/Library/Application Support/Fushi/ctl',
      );
    });

    test('Linux 优先 XDG_STATE_HOME，缺省 ~/.local/state', () {
      expect(
        resolveCtlStateDir(
          environment: <String, String>{
            'XDG_STATE_HOME': '/s',
            'HOME': '/home/u',
          },
          operatingSystem: 'linux',
        ),
        '/s/fushi/ctl',
      );
      expect(
        resolveCtlStateDir(
          environment: <String, String>{'HOME': '/home/u'},
          operatingSystem: 'linux',
        ),
        '/home/u/.local/state/fushi/ctl',
      );
    });

    test('缺系统目录时返回 null', () {
      expect(
        resolveCtlStateDir(
          environment: const <String, String>{},
          operatingSystem: 'windows',
        ),
        isNull,
      );
    });
  });

  group('fushiAppCandidates', () {
    test('显式路径 > FUSHI_APP > CLI 同级 > 默认安装位置', () {
      expect(
        fushiAppCandidates(
          environment: <String, String>{
            kFushiAppEnv: r'D:\env\fushi.exe',
            'LOCALAPPDATA': r'C:\L',
          },
          operatingSystem: 'windows',
          cliExecutable: r'C:\L\Fushi\fushi_cli.exe',
          explicitPath: r'D:\explicit\fushi.exe',
        ),
        <String>[
          r'D:\explicit\fushi.exe',
          r'D:\env\fushi.exe',
          r'C:\L\Fushi\fushi.exe',
        ],
      );
    });

    test('macOS 带 /Applications 下的 app 包', () {
      final List<String> candidates = fushiAppCandidates(
        environment: <String, String>{'HOME': '/Users/u'},
        operatingSystem: 'macos',
        cliExecutable: '/usr/local/bin/fushi_cli',
      );
      expect(candidates, contains('/Applications/fushi.app'));
      expect(candidates, contains('/Users/u/Applications/Fushi.app'));
    });
  });
}
