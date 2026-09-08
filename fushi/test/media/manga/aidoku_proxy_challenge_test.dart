import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_network_session.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_proxy_challenge.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi/src/utils/net/app_proxy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final String Function() savedMode = appUserProxyModeReader;
  final String Function() savedProxy = appUserProxyReader;
  final Uri url = Uri.parse('https://source.invalid/chapter');
  late Directory directory;
  late AidokuCookieJar jar;
  late List<MethodCall> calls;
  bool supported = true;
  Object? response;
  void Function()? whileSolving;

  Map<String, Object?> clearance(
    String value, {
    String domain = 'source.invalid',
  }) => AidokuCookie(
    name: 'cf_clearance',
    value: value,
    domain: domain,
    secure: true,
  ).toJson();

  Future<bool?> solve({TargetPlatform platform = TargetPlatform.iOS}) =>
      solveAidokuProxyChallenge(
        url: url,
        userAgent: 'source-specific-agent',
        jar: jar,
        title: 'Verify',
        closeLabel: 'Close',
        platform: platform,
        endpointFactory: () async =>
            Uri.parse('http://fushi:token@127.0.0.1:34567'),
      );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'aidoku-proxy-challenge-',
    );
    jar = AidokuCookieJar(File('${directory.path}/cookies.json'));
    await jar.replaceForHost('source.invalid', <AidokuCookie>[
      AidokuCookie.fromJson(clearance('stale')),
    ]);
    calls = <MethodCall>[];
    supported = true;
    response = <Object?>[clearance('fresh')];
    whileSolving = null;
    appUserProxyModeReader = () => kProxyModeManual;
    appUserProxyReader = () => '127.0.0.1:7890';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FushiChannels.cloudflareProxyBrowser, (
          MethodCall call,
        ) async {
          calls.add(call);
          if (call.method == 'isSupported') return supported;
          whileSolving?.call();
          return response;
        });
  });

  tearDown(() async {
    appUserProxyModeReader = savedMode;
    appUserProxyReader = savedProxy;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FushiChannels.cloudflareProxyBrowser, null);
    await directory.delete(recursive: true);
  });

  test(
    'isolated browser receives relay and UA without downgrading login cookies',
    () async {
      await jar.replaceForHost(url.host, <AidokuCookie>[
        AidokuCookie.fromJson(clearance('stale')),
        const AidokuCookie(
          name: 'login',
          value: 'private',
          domain: 'source.invalid',
        ),
      ]);
      await jar.replaceForHost('unrelated.invalid', <AidokuCookie>[
        AidokuCookie.fromJson(clearance('other', domain: 'unrelated.invalid')),
      ]);
      response = <Object?>[
        clearance('fresh'),
        clearance('foreign', domain: 'evil.invalid'),
      ];
      expect(await solve(), isTrue);
      final Map<Object?, Object?> args =
          calls.last.arguments as Map<Object?, Object?>;
      expect(args['proxyEndpoint'], 'http://fushi:token@127.0.0.1:34567');
      expect(args['userAgent'], 'source-specific-agent');
      expect(args['staleClearance'], <String>['stale']);
      expect((args['cookies'] as List<Object?>), isEmpty);
      expect(jar.clearanceValueFor(url), 'fresh');
      expect(
        jar
            .cookiesFor(url)
            .singleWhere((AidokuCookie cookie) => cookie.name == 'login')
            .value,
        'private',
      );
      expect(jar.cookiesFor(Uri.parse('https://evil.invalid/')), isEmpty);
      expect(
        jar.clearanceValueFor(Uri.parse('https://unrelated.invalid/')),
        'other',
      );
    },
  );

  test(
    'unsupported explicit manual/direct never silently opens system browser',
    () async {
      supported = false;
      for (final String mode in <String>[kProxyModeManual, kProxyModeDirect]) {
        appUserProxyModeReader = () => mode;
        await expectLater(
          solve(),
          throwsA(
            isA<PlatformException>().having(
              (PlatformException error) => error.code,
              'code',
              'CHALLENGE_PROXY_UNSUPPORTED',
            ),
          ),
        );
      }
      expect(
        calls.every((MethodCall call) => call.method == 'isSupported'),
        isTrue,
      );
    },
  );

  test(
    'cancellation and stale clearance do not replace the cookie jar',
    () async {
      response = null;
      expect(await solve(), isFalse);
      response = <Object?>[clearance('stale')];
      expect(await solve(), isFalse);
      expect(jar.clearanceValueFor(url), 'stale');
    },
  );

  test(
    'changed exit while solving rejects a clearance bound to the old exit',
    () async {
      whileSolving = () {
        appUserProxyReader = () => '127.0.0.1:7891';
      };
      expect(await solve(), isFalse);
      expect(jar.clearanceValueFor(url), 'stale');
    },
  );

  test('other platforms retain their own challenge implementation', () async {
    expect(await solve(platform: TargetPlatform.android), isNull);
    expect(calls, isEmpty);
  });
}
