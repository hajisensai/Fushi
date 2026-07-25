import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/galgame_helper_installer.dart';
import 'package:path/path.dart' as p;

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

  // ===========================================================================
  // BUG-1103 供应链：这个包里是 **进程注入器 exe + 会被注入进用户游戏进程的 hook DLL**，
  // 被换掉一次就是任意代码执行。所以 ① 拿不到可信摘要必须硬失败（绝不装未校验产物）
  // ② 侧车绝不能和 zip 走同一批第三方镜像（否则一个恶意镜像同时供应两者，校验等于走过场）。
  // ===========================================================================
  group('BUG-1103 侧车来源收紧：只认直连 GitHub', () {
    test('两个架构的侧车候选都只有直连一条，绝不含任何镜像前缀', () {
      for (final String arch in <String>['x86', 'x64']) {
        final List<String> sidecar = galgameHelperSidecarUrls(arch);
        expect(sidecar, <String>[galgameHelperSha256Url(arch)], reason: arch);
        for (final String prefix in kGalgameHelperProxyPrefixes) {
          expect(sidecar.any((String u) => u.startsWith(prefix)), isFalse,
              reason: '$arch 侧车走镜像 $prefix 就等于让镜像自己签自己的注入器');
        }
      }
    });

    test('zip 本体候选照旧含全部镜像（内容已被直连摘要钉死，镜像可用）', () {
      for (final String arch in <String>['x86', 'x64']) {
        final List<String> zipUrls =
            galgameHelperCandidateUrls(galgameHelperDownloadUrl(arch));
        expect(zipUrls.length, 1 + kGalgameHelperProxyPrefixes.length);
        // 侧车候选必须严格少于 zip 候选：这条断言就是「两者不同源」的守卫。
        expect(galgameHelperSidecarUrls(arch).length, lessThan(zipUrls.length));
      }
    });

    test('镜像前缀套出来的侧车 URL 一律判为不可信', () {
      for (final String prefix in kGalgameHelperProxyPrefixes) {
        expect(
          galgameHelperIsTrustedSidecarUrl(
              '$prefix${galgameHelperSha256Url('x64')}'),
          isFalse,
        );
      }
    });

    test('可信判定：只认 https + GitHub 自有域', () {
      expect(galgameHelperIsTrustedSidecarUrl(galgameHelperSha256Url('x86')),
          isTrue);
      expect(
        galgameHelperIsTrustedSidecarUrl(
            'https://objects.githubusercontent.com/x.sha256'),
        isTrue,
      );
      // 明文 http 可被中间人改写
      expect(galgameHelperIsTrustedSidecarUrl('http://github.com/x.sha256'),
          isFalse);
      expect(galgameHelperIsTrustedSidecarUrl('https://evil.com/x.sha256'),
          isFalse);
      // 把可信域塞进子域骗过前缀匹配的经典手法
      expect(
        galgameHelperIsTrustedSidecarUrl(
            'https://github.com.evil.com/x.sha256'),
        isFalse,
      );
      expect(galgameHelperIsTrustedSidecarUrl('not a url at all'), isFalse);
    });

    test('自定义 repo/tag 仍落在 github.com → 侧车可用；主机一旦不可信则候选为空', () {
      expect(
        galgameHelperSidecarUrls('x64', repo: 'foo/bar', tag: 'zzz'),
        <String>[galgameHelperSha256Url('x64', repo: 'foo/bar', tag: 'zzz')],
      );
      // 判定与 URL 构造解耦：不可信主机的侧车 URL 一律产不出候选（→ 安装硬失败）。
      expect(
          galgameHelperIsTrustedSidecarUrl('https://mirror.example/x.sha256'),
          isFalse);
    });
  });

  group('BUG-1103 校验缺失/不符 → 硬失败，绝不安装', () {
    const String sha =
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

    test('侧车取不到（null）→ 抛 verificationFailed，而不是降级为只校验 size', () {
      for (final String arch in <String>['x86', 'x64']) {
        expect(
          () => galgameHelperRequireVerifiedSha(null, arch),
          throwsA(isA<GalgameHelperInstallException>().having(
            (GalgameHelperInstallException e) => e.failure,
            'failure',
            GalgameHelperInstallFailure.verificationFailed,
          )),
          reason: arch,
        );
      }
    });

    test('侧车内容不是合法摘要（镜像错误页 / 空 body）→ 同样硬失败', () {
      for (final String junk in <String>['', '   ', 'Not Found', 'deadbeef']) {
        expect(
          () => galgameHelperRequireVerifiedSha(junk, 'x64'),
          throwsA(isA<GalgameHelperInstallException>()),
          reason: 'junk=$junk',
        );
      }
    });

    test('合法摘要 → 归一化为小写返回', () {
      expect(
        galgameHelperRequireVerifiedSha(' ${sha.toUpperCase()} \n', 'x64'),
        sha,
      );
    });

    test('失败分类：见过 sha 不符 → 校验失败；纯网络不通 → 下载失败', () {
      expect(
        galgameHelperClassifyDownloadFailure(sawIntegrityFailure: true),
        GalgameHelperInstallFailure.verificationFailed,
      );
      expect(
        galgameHelperClassifyDownloadFailure(sawIntegrityFailure: false),
        GalgameHelperInstallFailure.downloadFailed,
      );
      // 两者必须是不同枚举值：调用方要能区分「重试有用」与「产物不可信」。
      expect(GalgameHelperInstallFailure.downloadFailed,
          isNot(GalgameHelperInstallFailure.verificationFailed));
    });
  });

  group('BUG-1103 侧车抓取（真实 HTTP，本地服务器）', () {
    late HttpServer server;
    late String base;
    late List<String> hits;

    setUp(() async {
      hits = <String>[];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((HttpRequest req) async {
        hits.add(req.uri.path);
        switch (req.uri.path) {
          case '/ok.sha256':
            req.response.write(
              'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
              '  voice_hook_x64.zip\n',
            );
          case '/missing.sha256':
            req.response.statusCode = 404;
            req.response.write('Not Found');
          case '/junk.sha256':
            req.response.write('<html>blocked by mirror</html>');
          default:
            req.response.statusCode = 500;
        }
        await req.response.close();
      });
    });

    tearDown(() async => server.close(force: true));

    test('默认可信判定下，非 GitHub 主机的侧车根本不会被请求（镜像不得供应侧车）', () async {
      final HttpClient client = HttpClient();
      final String? sha = await GalgameHelperInstaller().fetchSha256Sidecar(
        client,
        urls: <String>['$base/ok.sha256'], // 本地 = 不可信主机
      );
      client.close(force: true);
      expect(sha, isNull);
      expect(hits, isEmpty, reason: '不可信来源必须在发请求之前就被拒');
      // 拿不到摘要 → 安装路径硬失败，不装。
      expect(() => galgameHelperRequireVerifiedSha(sha, 'x64'),
          throwsA(isA<GalgameHelperInstallException>()));
    });

    test('可信来源 + 正常侧车 → 解析出摘要', () async {
      final HttpClient client = HttpClient();
      final String? sha = await GalgameHelperInstaller().fetchSha256Sidecar(
        client,
        urls: <String>['$base/ok.sha256'],
        isTrusted: (String _) => true,
      );
      client.close(force: true);
      expect(sha,
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(hits, <String>['/ok.sha256']);
    });

    test('侧车 404（历史包没发侧车 / 被墙）→ null → 硬失败，不装未校验注入器', () async {
      final HttpClient client = HttpClient();
      final String? sha = await GalgameHelperInstaller().fetchSha256Sidecar(
        client,
        urls: <String>['$base/missing.sha256'],
        isTrusted: (String _) => true,
      );
      client.close(force: true);
      expect(sha, isNull);
      expect(
        () => galgameHelperRequireVerifiedSha(sha, 'x64'),
        throwsA(isA<GalgameHelperInstallException>().having(
          (GalgameHelperInstallException e) => e.failure,
          'failure',
          GalgameHelperInstallFailure.verificationFailed,
        )),
      );
    });

    test('侧车 body 是镜像的错误页（无合法摘要）→ null，不当成摘要用', () async {
      final HttpClient client = HttpClient();
      final String? sha = await GalgameHelperInstaller().fetchSha256Sidecar(
        client,
        urls: <String>['$base/junk.sha256'],
        isTrusted: (String _) => true,
      );
      client.close(force: true);
      expect(sha, isNull);
    });

    test('总超时兜底：服务器不响应也必须在预算内返回 null（不能永远悬着）', () async {
      final HttpServer silent =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      silent.listen((HttpRequest _) {}); // 收下不回
      final HttpClient client = HttpClient();
      final String? sha = await GalgameHelperInstaller().fetchSha256Sidecar(
        client,
        urls: <String>['http://127.0.0.1:${silent.port}/hang.sha256'],
        isTrusted: (String _) => true,
        timeout: const Duration(milliseconds: 300),
      );
      client.close(force: true);
      await silent.close(force: true);
      expect(sha, isNull);
    });

    test('交互与后台路径都必须有有限的侧车预算', () {
      expect(kGalgameHelperInteractiveShaTimeout.inSeconds,
          greaterThanOrEqualTo(30));
      expect(kGalgameHelperBackgroundShaTimeout.inSeconds,
          greaterThanOrEqualTo(30));
    });
  });

  group('BUG-1103 zip 下载：sha 不符不落地', () {
    late HttpServer server;
    late String base;
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('gal_helper_dl_test_');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((HttpRequest req) async {
        req.response.headers.contentType = ContentType.binary;
        req.response.add(<int>[1, 2, 3, 4, 5, 6, 7, 8]);
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('内容与直连摘要对不上 → verificationFailed，且产物不落地', () async {
      final HttpClient client = HttpClient();
      final File dest = File(p.join(tmp.path, 'voice_hook_x64.zip'));
      final File part = File('${dest.path}.part');
      await expectLater(
        GalgameHelperInstaller().downloadZip(
          client: client,
          candidates: <String>['$base/a.zip', '$base/b.zip'],
          dest: dest,
          part: part,
          expectedSize: null,
          expectedSha256:
              'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
          onProgress: (int _, int? __) {},
        ),
        throwsA(isA<GalgameHelperInstallException>().having(
          (GalgameHelperInstallException e) => e.failure,
          'failure',
          GalgameHelperInstallFailure.verificationFailed,
        )),
      );
      client.close(force: true);
      expect(dest.existsSync(), isFalse, reason: '校验不过的注入器绝不能落到目标路径');
      expect(part.existsSync(), isFalse, reason: '换镜像/失败后不留半截 part');
    });

    test('全都连不上（纯网络）→ downloadFailed，与校验失败区分开', () async {
      final int deadPort = server.port;
      await server.close(force: true);
      final HttpClient client = HttpClient();
      client.connectionTimeout = const Duration(milliseconds: 300);
      final File dest = File(p.join(tmp.path, 'voice_hook_x86.zip'));
      await expectLater(
        GalgameHelperInstaller().downloadZip(
          client: client,
          candidates: <String>['http://127.0.0.1:$deadPort/a.zip'],
          dest: dest,
          part: File('${dest.path}.part'),
          expectedSize: null,
          expectedSha256:
              'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
          onProgress: (int _, int? __) {},
        ),
        throwsA(isA<GalgameHelperInstallException>().having(
          (GalgameHelperInstallException e) => e.failure,
          'failure',
          GalgameHelperInstallFailure.downloadFailed,
        )),
      );
      client.close(force: true);
      expect(dest.existsSync(), isFalse);
    });
  });

  group('BUG-1103 源码守卫：供应链不变式', () {
    late final String src =
        File('lib/src/mining/galgame_helper_installer.dart').readAsStringSync();

    test('侧车绝不走镜像候选列表', () {
      expect(
        src,
        isNot(contains('galgameHelperCandidateUrls(galgameHelperSha256Url')),
        reason: '侧车与 zip 同源镜像 = 恶意镜像可同时供应「篡改包 + 匹配摘要」',
      );
      expect(src, contains('urls: galgameHelperSidecarUrls(arch)'));
    });

    test('先拿到可信摘要才允许下载（顺序不可颠倒）', () {
      final int requireAt = src.indexOf('galgameHelperRequireVerifiedSha(');
      final int downloadAt =
          src.indexOf('final File zip = await _downloadZip(');
      expect(requireAt, greaterThan(0));
      expect(downloadAt, greaterThan(requireAt));
    });

    test('下载入口收的是非空 sha（类型上就不给「不校验」留口子）', () {
      expect(src, contains('required String expectedSha256,'));
      expect(src, isNot(contains('required String? expectedSha256,')));
    });

    test('装机标记不再被 expectedSha != null 条件包住（sha 必然存在）', () {
      expect(src, isNot(contains('if (expectedSha != null)')));
      expect(src, contains('_markerFile(arch).writeAsString(sha'));
    });

    test('供应链关键路径不留零日志的静默 catch', () {
      for (final String needle in <String>[
        "_log('download failed from",
        "_log('download integrity FAILED from",
        "_log('sidecar fetch failed from",
        "_log('sidecar source rejected (untrusted host)",
        "_log('extract: skipped",
      ]) {
        expect(src, contains(needle), reason: '缺日志：$needle');
      }
      expect(src, contains("debugPrint('[gal-helper] "));
    });

    test('交互路径的侧车抓取带总超时', () {
      final int coreAt = src.indexOf('Future<void> _installCore(');
      expect(coreAt, greaterThan(0));
      expect(
        src.substring(coreAt, coreAt + 1400),
        contains('timeout: kGalgameHelperInteractiveShaTimeout'),
      );
    });

    test('校验失败有专属用户可读提示（不与「下载失败」混为一谈）', () {
      expect(src, contains('t.galgame_helper_verification_failed'));
    });

    test('可信主机白名单与 magpie 安装器共用同一份真值（安全清单不得复制）', () {
      final String magpie =
          File('lib/src/mining/magpie_installer.dart').readAsStringSync();
      expect(magpie, contains('kGalgameHelperTrustedSidecarHosts'));
      expect(
        magpie,
        isNot(contains("'objects.githubusercontent.com',")),
        reason: 'magpie 侧不得再有第二份主机清单副本',
      );
    });
  });
}
