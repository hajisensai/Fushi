import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/utils/net/github_mirrors.dart';
import 'package:http/http.dart' as http;

void main() {
  group('用户关掉 GitHub 加速镜像（拍板台 0E-r9q489Y）', () {
    tearDown(() => gitHubMirrorsEnabledReader = () => true);

    test('未绑定读取器时默认开，可用前缀就是全量名单', () {
      expect(activeGitHubMirrorPrefixes, kGitHubMirrorPrefixes);
    });

    test('关掉后可用前缀为空，GitHub 直链候选只剩直连', () {
      gitHubMirrorsEnabledReader = () => false;
      expect(activeGitHubMirrorPrefixes, isEmpty);
      final Uri direct = Uri.parse(
        'https://github.com/keiyoushi/extensions/raw/repo/index.pb',
      );
      expect(gitHubMirrorCandidates(direct), <Uri>[direct]);
    });

    test('关掉后仓库文件只走 jsDelivr 与 raw 直连，不出现任何镜像前缀', () {
      gitHubMirrorsEnabledReader = () => false;
      final List<String> urls = gitHubRepoFileUrls(
        'glsl/a.glsl',
        repo: 'bloc97/Anime4K',
        ref: 'master',
      );
      expect(urls, hasLength(kJsDelivrHosts.length + 1));
      expect(
        urls.last,
        'https://raw.githubusercontent.com/bloc97/Anime4K/master/glsl/a.glsl',
      );
      expect(urls.where(isGitHubMirrorUrl), isEmpty);
    });

    test('读取器请求时现读：重新打开立即恢复镜像候选', () {
      bool enabled = false;
      gitHubMirrorsEnabledReader = () => enabled;
      final Uri direct = Uri.parse('https://raw.githubusercontent.com/o/r/m/f');
      expect(gitHubMirrorCandidates(direct), hasLength(1));
      enabled = true;
      expect(
        gitHubMirrorCandidates(direct),
        hasLength(1 + kGitHubMirrorPrefixes.length),
      );
    });

    test('isGitHubMirrorUrl 分档不受开关影响（仍认得出镜像 URL）', () {
      gitHubMirrorsEnabledReader = () => false;
      expect(
        isGitHubMirrorUrl('${kGitHubMirrorPrefixes.first}https://github.com/x'),
        isTrue,
      );
    });
  });

  group('gitHubMirrorCandidates', () {
    const String direct =
        'https://github.com/keiyoushi/extensions/raw/repo/index.pb';

    test(
      'GitHub host → direct first, then one candidate per mirror prefix',
      () {
        final List<Uri> urls = gitHubMirrorCandidates(Uri.parse(direct));
        expect(urls.length, 1 + kGitHubMirrorPrefixes.length);
        expect(urls.first.toString(), direct);
        for (final String prefix in kGitHubMirrorPrefixes) {
          expect(urls.map((Uri u) => u.toString()), contains('$prefix$direct'));
        }
      },
    );

    test('candidates carry no duplicates and direct appears exactly once', () {
      final List<Uri> urls = gitHubMirrorCandidates(Uri.parse(direct));
      expect(urls.toSet().length, urls.length);
      expect(urls.where((Uri u) => u.toString() == direct).length, 1);
    });

    test('non-GitHub host → only itself', () {
      final Uri url = Uri.parse('https://repo.example/index.json');
      expect(gitHubMirrorCandidates(url), <Uri>[url]);
    });

    test('api.github.com is not a download host (mirrors 403 it)', () {
      final Uri url = Uri.parse('https://api.github.com/repos/x/y/releases');
      expect(isGitHubDownloadHost(url), isFalse);
      expect(gitHubMirrorCandidates(url), <Uri>[url]);
    });

    test('host match is exact and case-insensitive', () {
      expect(isGitHubDownloadHost(Uri.parse('https://GitHub.com/x')), isTrue);
      expect(
        isGitHubDownloadHost(Uri.parse('https://RAW.githubusercontent.com/x')),
        isTrue,
      );
      expect(
        isGitHubDownloadHost(
          Uri.parse('https://objects.githubusercontent.com/x'),
        ),
        isTrue,
      );
      expect(
        isGitHubDownloadHost(
          Uri.parse('https://release-assets.githubusercontent.com/x'),
        ),
        isTrue,
      );
      expect(
        isGitHubDownloadHost(Uri.parse('https://codeload.github.com/x')),
        isTrue,
      );
      // 子域 / 伪装域不算：镜像只认这几个精确 host。
      expect(
        isGitHubDownloadHost(Uri.parse('https://evil.github.com.example/x')),
        isFalse,
      );
      expect(
        isGitHubDownloadHost(Uri.parse('https://gist.github.com/x')),
        isFalse,
      );
    });

    test('mirror prefixes end with a slash so they concatenate cleanly', () {
      expect(kGitHubMirrorPrefixes, isNotEmpty);
      expect(
        kGitHubMirrorPrefixes.every((String p) => p.endsWith('/')),
        isTrue,
      );
    });
  });

  group('isTransportFailure', () {
    test('socket / timeout / TLS / http.ClientException → true', () {
      expect(isTransportFailure(const SocketException('timed out')), isTrue);
      expect(isTransportFailure(TimeoutException('slow')), isTrue);
      expect(isTransportFailure(const HandshakeException('tls')), isTrue);
      expect(isTransportFailure(const TlsException('tls')), isTrue);
      expect(
        isTransportFailure(
          http.ClientException('closed', Uri.parse('https://github.com/x')),
        ),
        isTrue,
      );
    });

    test('server-answered / business / parse errors → false', () {
      expect(
        isTransportFailure(
          const MihonRuntimeException('STORE_HTTP_404', 'missing'),
        ),
        isFalse,
      );
      expect(isTransportFailure(const FormatException('bad')), isFalse);
      expect(isTransportFailure(StateError('state')), isFalse);
      expect(isTransportFailure(const HttpException('proto')), isFalse);
    });
  });
}
