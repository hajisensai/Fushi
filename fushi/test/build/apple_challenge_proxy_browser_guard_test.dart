import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String source = File(
    'apple/FushiChallengeBrowser.swift',
  ).readAsStringSync();

  test('Apple challenge proxy is isolated before the WKWebView is created', () {
    expect(source, contains('WKWebsiteDataStore.nonPersistent()'));
    expect(source, isNot(contains('WKWebsiteDataStore.default()')));
    expect(
      source.indexOf('dataStore.proxyConfigurations = [proxy]'),
      lessThan(source.indexOf('webView = WKWebView(')),
    );
    expect(source, contains('configuration.websiteDataStore = dataStore'));
    expect(source, contains('proxy.allowFailover = false'));
    expect(source, contains('proxy.applyCredential('));
    expect(source, contains('#available(iOS 17.0, macOS 14.0, *)'));
    expect(source, contains('PROXY_BROWSER_UNSUPPORTED'));
  });

  test(
    'proxy credentials cannot be supplied to a website or a different endpoint',
    () {
      expect(source, contains('proxy.host == "127.0.0.1"'));
      expect(source, contains('guard space.isProxy()'));
      expect(source, contains('space.host == "127.0.0.1"'));
      expect(source, contains('space.port == Int(input.proxyPort)'));
      expect(source, contains('NSURLAuthenticationMethodHTTPBasic'));
      expect(source, contains('challenge.previousFailureCount == 0'));
      expect(source, isNot(contains('URLCredential(trust:')));
      expect(source, isNot(contains('error.localizedDescription')));
    },
  );

  test(
    'only fresh challenge-domain cookies finish and lifecycle paths complete once',
    () {
      expect(
        source,
        contains('ChallengeInput.matches(host: host, domain: cookie.domain)'),
      );
      expect(
        source,
        contains('!self.input.staleClearance.contains(cookie.value)'),
      );
      expect(source, contains('guard !finished else { return }'));
      expect(source, contains('httpCookieStore.remove(self)'));
      expect(source, contains('PROXY_BROWSER_BUSY'));
      expect(source, contains('presentationControllerDidDismiss'));
      expect(source, contains('windowShouldClose'));
      expect(source, contains('webViewWebContentProcessDidTerminate'));
      for (final String field in <String>[
        'name',
        'value',
        'domain',
        'path',
        'secure',
        'expiresAt',
      ]) {
        expect(source, contains('"$field":'));
      }
    },
  );

  for (final String platform in <String>['ios', 'macos']) {
    test('$platform registers and compiles the shared native browser', () {
      final String delegate = File(
        '$platform/Runner/AppDelegate.swift',
      ).readAsStringSync();
      final String project = File(
        '$platform/Runner.xcodeproj/project.pbxproj',
      ).readAsStringSync();
      expect(
        delegate,
        contains('private var challengeBrowser: FushiChallengeBrowser?'),
      );
      expect(delegate, contains('challengeBrowser = FushiChallengeBrowser('));
      expect(
        project,
        contains('path = ../../apple/FushiChallengeBrowser.swift;'),
      );
      expect(
        project,
        contains(
          'FA171A002B000001001C0F01 /* FushiChallengeBrowser.swift in Sources */,',
        ),
      );
      expect(
        source,
        contains('name: "app.fushi.reader/cloudflare_proxy_browser"'),
      );
    });
  }
}
