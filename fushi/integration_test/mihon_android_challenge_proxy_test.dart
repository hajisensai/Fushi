import 'dart:io' hide Cookie;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:fushi/src/media/manga/mihon/android_mihon_runtime.dart';
import 'package:fushi/src/utils/net/app_proxy.dart';

/// A deterministic browser/relay/cookie fixture, not a live Cloudflare bypass test.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'explicit challenge browser proxies resources without changing reader WebView',
    (WidgetTester tester) async {
      if (!Platform.isAndroid) return;
      final String Function() oldMode = appUserProxyModeReader;
      final String Function() oldProxy = appUserProxyReader;
      final HttpServer upstream = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final HttpServer reader = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final List<Uri> proxied = <Uri>[];
      final List<String?> agents = <String?>[];
      int readerRequests = 0;
      int? readerAtChallenge;
      final String clearance =
          'fixture-${DateTime.now().microsecondsSinceEpoch}';
      upstream.listen((HttpRequest request) async {
        proxied.add(request.uri);
        agents.add(request.headers.value(HttpHeaders.userAgentHeader));
        request.response.headers.set('Access-Control-Allow-Origin', '*');
        if (request.uri.host == 'example.net') {
          request.response.write('fixture asset');
        } else {
          readerAtChallenge ??= readerRequests;
          request.response.headers.contentType = ContentType.html;
          request.response.write(
            '''<!doctype html><html><body>Browser proxy fixture<script>
fetch('http://example.net/verification-resource').then(r => r.text()).then(() => {
  setTimeout(() => { document.cookie = 'cf_clearance=$clearance; Path=/'; }, 3000);
});
</script></body></html>''',
          );
        }
        await request.response.close();
      });
      reader.listen((HttpRequest request) async {
        readerRequests++;
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<html><body>Reader stays direct<script>setInterval(() => fetch("/ping"), 250);</script></body></html>',
        );
        await request.response.close();
      });
      appUserProxyModeReader = () => kProxyModeManual;
      appUserProxyReader = () => '127.0.0.1:${upstream.port}';
      final AndroidMihonRuntime runtime = AndroidMihonRuntime();
      Object? failure;
      bool completed = false;
      final FocusNode verifyFocus = FocusNode();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: <Widget>[
                  TextButton(
                    focusNode: verifyFocus,
                    onPressed: () async {
                      try {
                        await runtime.solveCloudflare(
                          Uri.parse('http://example.com/challenge-fixture'),
                          userAgent: 'Hibiki challenge fixture/1',
                        );
                      } on Object catch (error) {
                        failure = error;
                      } finally {
                        completed = true;
                      }
                    },
                    child: const Text('Verify source'),
                  ),
                  Expanded(
                    child: InAppWebView(
                      initialUrlRequest: URLRequest(
                        url: WebUri('http://127.0.0.1:${reader.port}/reader'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        for (int attempt = 0; attempt < 100 && readerRequests == 0; attempt++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(readerRequests, greaterThan(0));
        for (int step = 0; step < 10 && !verifyFocus.hasFocus; step++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
        }
        expect(verifyFocus.hasFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        for (int attempt = 0; attempt < 1200 && !completed; attempt++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          completed,
          isTrue,
          reason:
              'Native challenge must return success, cancellation, or timeout',
        );
        expect(failure, isNull);
        expect(proxied.any((Uri uri) => uri.host == 'example.com'), isTrue);
        expect(proxied.any((Uri uri) => uri.host == 'example.net'), isTrue);
        expect(agents, everyElement('Hibiki challenge fixture/1'));
        expect(readerAtChallenge, isNotNull);
        expect(
          readerRequests,
          greaterThan(readerAtChallenge!),
          reason:
              'Main-process reader keeps making direct requests during remote verification',
        );
        final List<Cookie> cookies = await CookieManager.instance().getCookies(
          url: WebUri('http://example.com/challenge-fixture'),
        );
        expect(
          cookies.any(
            (Cookie cookie) =>
                cookie.name == 'cf_clearance' && cookie.value == clearance,
          ),
          isTrue,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        verifyFocus.dispose();
        await runtime.dispose();
        await upstream.close(force: true);
        await reader.close(force: true);
        appUserProxyModeReader = oldMode;
        appUserProxyReader = oldProxy;
      }
    },
  );
}
