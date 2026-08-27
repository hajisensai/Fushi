import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/aidoku/aidoku_network_session.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

/// BUG-1876：iOS Aidoku runtime 遇到 Cloudflare 挑战时的「解题 → 带 cookie 重试
/// 一次」契约，用假 MethodChannel 驱动，不依赖真 host。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late AidokuCookieJar jar;
  late List<Map<Object?, Object?>> requests;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fushi-aidoku-cf-');
    jar = AidokuCookieJar(File('${root.path}/cookies.json'));
    requests = <Map<Object?, Object?>>[];
    AidokuCloudflareGate.resolver = null;
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FushiChannels.aidokuRuntime, null);
    AidokuCloudflareGate.resolver = null;
    await root.delete(recursive: true);
  });

  void installHost(
    Future<Object?> Function(Map<Object?, Object?> request) handler,
  ) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FushiChannels.aidokuRuntime, (
          MethodCall call,
        ) async {
          final Map<Object?, Object?> request =
              call.arguments as Map<Object?, Object?>;
          requests.add(request);
          return handler(request);
        });
  }

  PlatformException challenge(String url) => PlatformException(
    code: 'CLOUDFLARE_CHALLENGE',
    message: 'Cloudflare challenge blocked this source at $url',
    details: <String, Object?>{
      'code': 'CLOUDFLARE_CHALLENGE',
      'error': 'Cloudflare challenge blocked this source at $url',
      'challengeUrl': url,
    },
  );

  List<Object?> cookiesSent(Map<Object?, Object?> request) =>
      ((request['network'] as Map<Object?, Object?>)['cookies']
          as List<Object?>);

  test(
    'every invoke carries the shared identity and current cookies',
    () async {
      await jar.replaceForHost('mangafire.to', const <AidokuCookie>[
        AidokuCookie(
          name: 'cf_clearance',
          value: 'seed',
          domain: 'mangafire.to',
        ),
      ]);
      installHost(
        (_) async => <String, Object?>{
          'result': <String, Object?>{'entries': <Object?>[]},
        },
      );

      await IosAidokuRuntime(jar: jar).search('/pkg.aix', query: 'x');

      final Map<Object?, Object?> network =
          requests.single['network'] as Map<Object?, Object?>;
      expect(network['userAgent'], kAidokuUserAgent);
      expect(
        (cookiesSent(requests.single).single as Map<Object?, Object?>)['value'],
        'seed',
      );
    },
  );

  test(
    'challenge → resolver solves → retried once with the new cookie',
    () async {
      final List<Uri> resolved = <Uri>[];
      int calls = 0;
      installHost((Map<Object?, Object?> request) async {
        calls++;
        if (calls == 1) {
          throw challenge('https://mangafire.to/filter?keyword=x');
        }
        return <String, Object?>{
          'result': <String, Object?>{'entries': <Object?>[]},
        };
      });
      final IosAidokuRuntime runtime = IosAidokuRuntime(
        jar: jar,
        resolver: (Uri url, String userAgent) async {
          resolved.add(url);
          await jar.replaceForHost(url.host, const <AidokuCookie>[
            AidokuCookie(
              name: 'cf_clearance',
              value: 'solved',
              domain: '.mangafire.to',
            ),
          ]);
          return true;
        },
      );

      await runtime.search('/pkg.aix', query: 'x');

      expect(
        resolved.single.toString(),
        'https://mangafire.to/filter?keyword=x',
      );
      expect(requests.length, 2);
      expect(cookiesSent(requests.first), isEmpty);
      expect(
        (cookiesSent(requests.last).single as Map<Object?, Object?>)['value'],
        'solved',
      );
    },
  );

  test(
    'resolver declines → original challenge error surfaces, no retry',
    () async {
      installHost((_) async => throw challenge('https://mangafire.to/'));
      final IosAidokuRuntime runtime = IosAidokuRuntime(
        jar: jar,
        resolver: (_, __) async => false,
      );

      await expectLater(
        runtime.search('/pkg.aix', query: 'x'),
        throwsA(
          isA<AidokuRuntimeException>()
              .having(
                (AidokuRuntimeException e) => e.code,
                'code',
                kAidokuCloudflareChallengeCode,
              )
              .having(
                (AidokuRuntimeException e) => e.challengeUrl.toString(),
                'challengeUrl',
                'https://mangafire.to/',
              ),
        ),
      );
      expect(requests.length, 1);
    },
  );

  test('a second challenge after solving is final — never loops', () async {
    int solves = 0;
    installHost((_) async => throw challenge('https://mangafire.to/'));
    final IosAidokuRuntime runtime = IosAidokuRuntime(
      jar: jar,
      resolver: (_, __) async {
        solves++;
        return true;
      },
    );

    await expectLater(
      runtime.search('/pkg.aix', query: 'x'),
      throwsA(
        isA<AidokuRuntimeException>().having(
          (AidokuRuntimeException e) => e.code,
          'code',
          kAidokuCloudflareChallengeCode,
        ),
      ),
    );
    expect(solves, 1);
    expect(requests.length, 2);
  });

  test('falls back to the global gate when no resolver is injected', () async {
    int calls = 0;
    installHost((_) async {
      calls++;
      if (calls == 1) throw challenge('https://mangafire.to/');
      return <String, Object?>{
        'result': <String, Object?>{'key': 'm'},
      };
    });
    Uri? gateUrl;
    AidokuCloudflareGate.resolver = (Uri url, String userAgent) async {
      gateUrl = url;
      return true;
    };

    final Map<String, Object?> details = await IosAidokuRuntime(
      jar: jar,
    ).getDetails('/pkg.aix', <String, Object?>{'key': 'm'});

    expect(details['key'], 'm');
    expect(gateUrl?.host, 'mangafire.to');
  });

  test('non-https or missing challengeUrl never opens a resolver', () async {
    int solves = 0;
    installHost(
      (_) async => throw PlatformException(
        code: 'CLOUDFLARE_CHALLENGE',
        message: 'blocked',
        details: <String, Object?>{'challengeUrl': 'http://mangafire.to/'},
      ),
    );
    final IosAidokuRuntime runtime = IosAidokuRuntime(
      jar: jar,
      resolver: (_, __) async {
        solves++;
        return true;
      },
    );

    await expectLater(
      runtime.search('/pkg.aix', query: 'x'),
      throwsA(
        isA<AidokuRuntimeException>().having(
          (AidokuRuntimeException e) => e.challengeUrl,
          'url',
          isNull,
        ),
      ),
    );
    expect(solves, 0);
    expect(requests.length, 1);
  });

  test('suppressed zone (background fan-out) never opens a resolver', () async {
    int solves = 0;
    installHost((_) async => throw challenge('https://mangafire.to/'));
    final IosAidokuRuntime runtime = IosAidokuRuntime(
      jar: jar,
      resolver: (_, __) async {
        solves++;
        return true;
      },
    );

    await expectLater(
      AidokuCloudflareGate.runSuppressed(
        () => runtime.search('/pkg.aix', query: 'x'),
      ),
      throwsA(
        isA<AidokuRuntimeException>().having(
          (AidokuRuntimeException e) => e.code,
          'code',
          kAidokuCloudflareChallengeCode,
        ),
      ),
    );
    expect(solves, 0);
    expect(requests.length, 1);
  });

  test(
    'clearance replaced by a concurrent solve → silent retry, no resolver',
    () async {
      int calls = 0;
      installHost((_) async {
        calls++;
        if (calls == 1) {
          // 模拟并发解题：本次请求已发出（带空 cookie），失败前别的调用把新
          // cf_clearance 写进了 jar。
          await jar.replaceForHost('mangafire.to', const <AidokuCookie>[
            AidokuCookie(
              name: 'cf_clearance',
              value: 'from-other-flight',
              domain: 'mangafire.to',
            ),
          ]);
          throw challenge('https://mangafire.to/');
        }
        return <String, Object?>{
          'result': <String, Object?>{'entries': <Object?>[]},
        };
      });
      int solves = 0;
      final IosAidokuRuntime runtime = IosAidokuRuntime(
        jar: jar,
        resolver: (_, __) async {
          solves++;
          return true;
        },
      );

      await runtime.search('/pkg.aix', query: 'x');

      expect(solves, 0);
      expect(requests.length, 2);
      expect(
        (cookiesSent(requests.last).single as Map<Object?, Object?>)['value'],
        'from-other-flight',
      );
    },
  );

  test('challengeUserAgent from the envelope reaches the resolver', () async {
    final List<String> seen = <String>[];
    int calls = 0;
    installHost((_) async {
      calls++;
      if (calls == 1) {
        throw PlatformException(
          code: 'CLOUDFLARE_CHALLENGE',
          message: 'blocked',
          details: <String, Object?>{
            'challengeUrl': 'https://mangafire.to/',
            'challengeUserAgent': 'SourceCustom/1.0',
          },
        );
      }
      return <String, Object?>{
        'result': <String, Object?>{'entries': <Object?>[]},
      };
    });
    await IosAidokuRuntime(
      jar: jar,
      resolver: (Uri url, String userAgent) async {
        seen.add(userAgent);
        return true;
      },
    ).search('/pkg.aix', query: 'x');

    expect(seen, <String>['SourceCustom/1.0']);
  });

  test(
    'envelope without challengeUserAgent falls back to the shared identity',
    () async {
      final List<String> seen = <String>[];
      int calls = 0;
      installHost((_) async {
        calls++;
        if (calls == 1) throw challenge('https://mangafire.to/');
        return <String, Object?>{
          'result': <String, Object?>{'entries': <Object?>[]},
        };
      });
      await IosAidokuRuntime(
        jar: jar,
        resolver: (Uri url, String userAgent) async {
          seen.add(userAgent);
          return true;
        },
      ).search('/pkg.aix', query: 'x');

      expect(seen, <String>[kAidokuUserAgent]);
    },
  );
}
