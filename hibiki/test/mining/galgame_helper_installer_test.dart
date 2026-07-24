import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/galgame_helper_installer.dart';

void main() {
  group('galgameHelperArch', () {
    test('32 位游戏选 x86，否则 x64', () {
      expect(galgameHelperArch(is32Bit: true), 'x86');
      expect(galgameHelperArch(is32Bit: false), 'x64');
    });
  });

  group('zip / URL 构造', () {
    test('zip 名与 CI 打包命名一致', () {
      expect(galgameHelperZipName('x64'), 'voice_hook_x64.zip');
      expect(galgameHelperZipName('x86'), 'voice_hook_x86.zip');
    });

    test('下载 URL 按固定 tag 拼接（非 run 号）', () {
      final String url = galgameHelperDownloadUrl('x64');
      expect(url, contains('/releases/download/'));
      expect(url, contains('/$kGalgameHelperReleaseTag/'));
      expect(url, endsWith('/voice_hook_x64.zip'));
      expect(url, isNot(contains('run')));
    });

    test('固定 tag 值稳定', () {
      expect(kGalgameHelperReleaseTag, 'voice-hook-helper');
    });

    test('helper 默认走独立仓库 hibiki-hook（非主 app 仓库）', () {
      expect(kGalgameHelperRepo, 'hajisensai/hibiki-hook');
      expect(galgameHelperDownloadUrl('x64'),
          startsWith('https://github.com/hajisensai/hibiki-hook/'));
      expect(galgameHelperSha256Url('x86'),
          startsWith('https://github.com/hajisensai/hibiki-hook/'));
    });

    test('sha256 侧车 URL = zip URL + .sha256', () {
      expect(
        galgameHelperSha256Url('x86'),
        '${galgameHelperDownloadUrl('x86')}.sha256',
      );
    });

    test('自定义 repo/tag 可注入', () {
      final String url =
          galgameHelperDownloadUrl('x64', repo: 'foo/bar', tag: 'zzz');
      expect(url,
          'https://github.com/foo/bar/releases/download/zzz/voice_hook_x64.zip');
    });
  });

  group('galgameHelperCandidateUrls', () {
    test('直连恒首位，随后每个镜像前缀套一份，无重复', () {
      const String direct = 'https://github.com/o/r/releases/download/t/a.zip';
      final List<String> urls = galgameHelperCandidateUrls(direct);
      expect(urls.first, direct);
      expect(urls.length, 1 + kGalgameHelperProxyPrefixes.length);
      for (int i = 0; i < kGalgameHelperProxyPrefixes.length; i++) {
        expect(urls[i + 1], '${kGalgameHelperProxyPrefixes[i]}$direct');
      }
      expect(urls.toSet().length, urls.length); // 无重复
    });
  });

  group('parseSha256Sidecar', () {
    const String hash =
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

    test('纯摘要', () {
      expect(parseSha256Sidecar(hash), hash);
    });

    test('大写归一化为小写', () {
      expect(parseSha256Sidecar(hash.toUpperCase()), hash);
    });

    test('<hash>  <filename> 形式取第一个 64-hex', () {
      expect(parseSha256Sidecar('$hash  voice_hook_x64.zip\n'), hash);
    });

    test('前后空白/换行容错', () {
      expect(parseSha256Sidecar('  \n$hash\n  '), hash);
    });

    test('无合法摘要返回 null', () {
      expect(parseSha256Sidecar('not-a-hash'), isNull);
      expect(parseSha256Sidecar('deadbeef'), isNull); // 非 64 位
    });
  });

  group('sha256Matches', () {
    test('去空白、大小写无关相等', () {
      expect(sha256Matches('ABCdef', ' abcdef '), isTrue);
      expect(sha256Matches('abc', 'abd'), isFalse);
    });
  });

  group('formatDownloadSize', () {
    test('MB / KB / 非正数', () {
      expect(formatDownloadSize(12 * 1024 * 1024), '12.0 MB');
      expect(formatDownloadSize(512 * 1024), '512 KB');
      expect(formatDownloadSize(0), '');
      expect(formatDownloadSize(-1), '');
    });
  });

  group('自动更新（版本标记 + 更新判据）', () {
    const String shaA =
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
    const String shaB =
        'da39a3ee5e6b4b0d3255bfef95601890afd80709da39a3ee5e6b4b0d32551234';

    test('标记文件名稳定', () {
      expect(galgameHelperMarkerName(), 'installed.sha256');
    });

    test('本地与远端 sha 不同 → 需要更新', () {
      expect(galgameHelperNeedsUpdate(shaA, shaB), isTrue);
    });

    test('本地与远端 sha 相同（大小写/空白无关）→ 不更新', () {
      expect(galgameHelperNeedsUpdate(shaA, shaA), isFalse);
      expect(
          galgameHelperNeedsUpdate(shaA, ' ${shaA.toUpperCase()} '), isFalse);
    });

    test('无本地标记（手动放置/旧装）→ 不自动更新（保守）', () {
      expect(galgameHelperNeedsUpdate(null, shaB), isFalse);
    });

    test('远端取不到（离线）→ 不更新（不阻塞启动）', () {
      expect(galgameHelperNeedsUpdate(shaA, null), isFalse);
      expect(galgameHelperNeedsUpdate(null, null), isFalse);
    });
  });

  group('helper release manifest', () {
    test('x86 requires locale runtime and license', () {
      expect(
        galgameHelperRequiredFiles('x86'),
        containsAll(<String>[
          'hibiki_voice_injector.exe',
          'hibiki_voice_hook.dll',
          'LunaHook32.dll',
          'LunaHost32.dll',
          'LoaderDll.dll',
          'LocaleEmulator.dll',
          'LocaleEmulator-LGPL-3.0.txt',
        ]),
      );
    });

    test('x64 uses its own Luna binaries and does not require x86 locale DLLs',
        () {
      final List<String> required = galgameHelperRequiredFiles('x64');
      expect(
          required,
          containsAll(<String>[
            'hibiki_voice_injector.exe',
            'hibiki_voice_hook.dll',
            'LunaHook64.dll',
            'LunaHost64.dll',
          ]));
      expect(required, isNot(contains('LoaderDll.dll')));
      expect(required, isNot(contains('LocaleEmulator.dll')));
    });

    test('missing-file detection is case-insensitive and complete', () {
      final List<String> present =
          List<String>.from(galgameHelperRequiredFiles('x86'))
            ..remove('LocaleEmulator.dll')
            ..remove('LocaleEmulator-LGPL-3.0.txt')
            ..add('localeemulator-lgpl-3.0.TXT');
      expect(
        galgameHelperMissingFiles('x86', present),
        <String>['LocaleEmulator.dll'],
      );
    });

    test('unknown architecture is rejected', () {
      expect(
        () => galgameHelperRequiredFiles('arm64'),
        throwsArgumentError,
      );
    });
  });

  test('incomplete existing installs are repaired before launch', () {
    final String source = File(
      'lib/src/mining/galgame_helper_installer.dart',
    ).readAsStringSync();
    expect(source, contains('if (_hasExistingInstall(arch))'));
    expect(source, contains('expectedSize: null'));
    expect(source, contains('missingFromPackage'));
    expect(
      source.indexOf('missingFromPackage'),
      lessThan(source.indexOf('_markerFile(arch).writeAsString')),
    );
  });
}
