import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:fushi/src/media/manga/cookie/manga_cookie_jar.dart';
import 'package:fushi/src/media/manga/mihon/desktop_mihon_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cloudflare_challenge.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cloudflare_gate.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cookie_jar.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';

/// 桌面 Mihon 的 Cloudflare 解题链路：sidecar 报 `errorKind: cloudflare` →
/// 结构化挑战异常 → `ChallengeMihonRuntime.solveCloudflare` 经装配的 resolver
/// 弹页 → 新 cookie 落回运行时自己的 jar。
void main() {
  http.Response envelope(Map<String, Object?> body, {int status = 403}) =>
      http.Response(jsonEncode(body), status);

  group('decodeErrorResponse', () {
    test('cloudflare 信封解成带 URL 与 UA 的结构化挑战异常', () {
      final MihonRuntimeException error =
          DesktopMihonRuntime.decodeErrorResponse(
            envelope(<String, Object?>{
              'error':
                  'CLOUDFLARE_CHALLENGE_REQUIRED: Open website verification',
              'errorType':
                  'eu.kanade.tachiyomi.network.interceptor'
                  '.CloudflareChallengeRequiredException',
              'errorKind': 'cloudflare',
              'challengeUrl': 'https://hachiraw.invalid/manga/?page=2',
              'userAgent': 'Mozilla/5.0 fixture',
              'stackTrace': 'trace',
            }),
          );
      expect(error, isA<MihonCloudflareChallengeException>());
      final MihonCloudflareChallengeException challenge =
          error as MihonCloudflareChallengeException;
      expect(
        challenge.url,
        Uri.parse('https://hachiraw.invalid/manga/?page=2'),
      );
      expect(challenge.userAgent, 'Mozilla/5.0 fixture');
      expect(challenge.code, 'CLOUDFLARE_CHALLENGE_REQUIRED');
    });

    test('空 UA 落成 null，让解题页用自己的默认值而不是空串', () {
      final MihonRuntimeException error =
          DesktopMihonRuntime.decodeErrorResponse(
            envelope(<String, Object?>{
              'errorKind': 'cloudflare',
              'challengeUrl': 'https://hachiraw.invalid/',
              'userAgent': '',
            }),
          );
      expect((error as MihonCloudflareChallengeException).userAgent, isNull);
    });

    test('缺少可用 URL 的 cloudflare 信封退回普通桥错误，不伪造挑战', () {
      for (final Object? url in <Object?>[null, '', 'not a url', 'ftp://x/']) {
        final MihonRuntimeException error =
            DesktopMihonRuntime.decodeErrorResponse(
              envelope(<String, Object?>{
                'errorKind': 'cloudflare',
                'challengeUrl': url,
                'error': 'boom',
              }),
            );
        expect(error, isNot(isA<MihonCloudflareChallengeException>()));
        expect(error.code, 'BRIDGE_HTTP_403');
      }
    });

    test('sourceHttp 与 bridge 信封不受影响', () {
      expect(
        DesktopMihonRuntime.decodeErrorResponse(
          envelope(<String, Object?>{
            'errorKind': 'sourceHttp',
            'sourceStatusCode': 403,
          }),
        ).code,
        'SOURCE_HTTP_403',
      );
      expect(
        DesktopMihonRuntime.decodeErrorResponse(
          envelope(<String, Object?>{
            'errorKind': 'bridge',
            'error': 'x',
          }, status: 500),
        ).code,
        'BRIDGE_HTTP_500',
      );
    });
  });

  group('DesktopMihonRuntime.solveCloudflare', () {
    late Directory directory;
    late MihonCookieJar jar;
    late DesktopMihonRuntime runtime;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('mihon-cf-');
      jar = MihonCookieJar(File('${directory.path}/cookies.json'));
      runtime = DesktopMihonRuntime(
        dataDirectory: directory,
        resourceDirectory: directory,
        cookieJar: jar,
      );
    });

    tearDown(() async {
      MihonCloudflareGate.resolver = null;
      await runtime.dispose();
      directory.deleteSync(recursive: true);
    });

    test('桌面运行时对外声明能解题，UI 的验证按钮据此显示', () {
      expect(runtime, isA<ChallengeMihonRuntime>());
    });

    test('没装 resolver 时明确报 CHALLENGE_UNAVAILABLE，不静默当作解完', () async {
      await expectLater(
        runtime.solveCloudflare(Uri.parse('https://hachiraw.invalid/')),
        throwsA(
          isA<MihonRuntimeException>().having(
            (MihonRuntimeException e) => e.code,
            'code',
            'CHALLENGE_UNAVAILABLE',
          ),
        ),
      );
    });

    test('resolver 收到被拦 URL、UA 和运行时自己的 jar；用户关页算取消', () async {
      final List<Object?> seen = <Object?>[];
      MihonCloudflareGate.resolver =
          (Uri url, String userAgent, MangaCookieJar target) async {
            seen.addAll(<Object?>[url, userAgent, target]);
            return false;
          };
      await expectLater(
        runtime.solveCloudflare(
          Uri.parse('https://hachiraw.invalid/manga/'),
          userAgent: 'Mozilla/5.0 fixture',
        ),
        throwsA(
          isA<MihonRuntimeException>().having(
            (MihonRuntimeException e) => e.code,
            'code',
            'CHALLENGE_CANCELLED',
          ),
        ),
      );
      expect(seen, <Object?>[
        Uri.parse('https://hachiraw.invalid/manga/'),
        'Mozilla/5.0 fixture',
        // 必须是同一个实例：解题页写进别的 jar，下一次注入 sidecar 的仍是旧 cookie。
        same(jar),
      ]);
    });

    test('resolver 解成功则正常返回', () async {
      MihonCloudflareGate.resolver =
          (Uri url, String userAgent, MangaCookieJar target) async => true;
      await runtime.solveCloudflare(Uri.parse('https://hachiraw.invalid/'));
    });
  });

  group('installMihonCloudflareResolver 的按 host 单飞', () {
    tearDown(() => MihonCloudflareGate.resolver = null);

    final Uri challengeUrl = Uri.parse('https://hachiraw.invalid/manga/');

    Widget stubPage(Uri url, String userAgent, MangaCookieJar jar) =>
        const Scaffold(body: Center(child: Text('stub-challenge')));

    testWidgets('navigator 未就绪的同步早退不会把这个 host 永久毒死', (
      WidgetTester tester,
    ) async {
      final GlobalKey<NavigatorState> navigatorKey =
          GlobalKey<NavigatorState>();
      final MihonCookieJar jar = MihonCookieJar(
        File('${Directory.systemTemp.path}/unused-cookies.json'),
      );
      int pushes = 0;
      installMihonCloudflareResolver(
        navigatorKey,
        pageBuilder: (Uri url, String userAgent, MangaCookieJar target) {
          pushes++;
          return stubPage(url, userAgent, target);
        },
      );
      final MihonCloudflareResolver resolve = MihonCloudflareGate.resolver!;

      expect(await resolve(challengeUrl, 'ua', jar), isFalse);
      expect(pushes, 0);

      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigatorKey, home: const SizedBox.shrink()),
      );
      final Future<bool> solving = resolve(challengeUrl, 'ua', jar);
      await tester.pumpAndSettle();
      expect(pushes, 1);
      expect(find.text('stub-challenge'), findsOneWidget);

      navigatorKey.currentState!.pop(true);
      await tester.pumpAndSettle();
      expect(await solving, isTrue);
    });

    testWidgets('同站并发共享一次解题，解完后 map 释放', (WidgetTester tester) async {
      final GlobalKey<NavigatorState> navigatorKey =
          GlobalKey<NavigatorState>();
      final MihonCookieJar jar = MihonCookieJar(
        File('${Directory.systemTemp.path}/unused-cookies.json'),
      );
      int pushes = 0;
      installMihonCloudflareResolver(
        navigatorKey,
        pageBuilder: (Uri url, String userAgent, MangaCookieJar target) {
          pushes++;
          return stubPage(url, userAgent, target);
        },
      );
      final MihonCloudflareResolver resolve = MihonCloudflareGate.resolver!;
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigatorKey, home: const SizedBox.shrink()),
      );

      final Future<bool> first = resolve(challengeUrl, 'ua', jar);
      final Future<bool> second = resolve(challengeUrl, 'ua', jar);
      await tester.pumpAndSettle();
      expect(pushes, 1);

      navigatorKey.currentState!.pop(true);
      await tester.pumpAndSettle();
      expect(await first, isTrue);
      expect(await second, isTrue);

      final Future<bool> third = resolve(challengeUrl, 'ua', jar);
      await tester.pumpAndSettle();
      expect(pushes, 2);
      navigatorKey.currentState!.pop(false);
      await tester.pumpAndSettle();
      expect(await third, isFalse);
    });
  });
}
