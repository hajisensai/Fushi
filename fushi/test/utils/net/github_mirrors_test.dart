import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/utils/net/github_mirrors.dart';
import 'package:http/http.dart' as http;

void main() {
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
