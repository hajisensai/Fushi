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
}
