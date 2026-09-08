import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'verification does not turn primary login cookies into JavaScript cookies',
    () {
      final String coordinator = File(
        'android/app/src/main/kotlin/app/fushi/reader/mihon/CloudflareChallengeCoordinator.kt',
      ).readAsStringSync();
      final String activity = File(
        'android/app/src/main/kotlin/app/fushi/reader/mihon/CloudflareChallengeActivity.kt',
      ).readAsStringSync();
      expect(coordinator, isNot(contains('"initialCookies"')));
      expect(activity, isNot(contains('"initialCookies"')));
      expect(coordinator, contains('.filter { it.name == "cf_clearance" }'));
      expect(coordinator, contains('.path("/").httpOnly()'));
      expect(coordinator, contains('activeSession.compareAndSet(false, true)'));
      final String timeout = coordinator.substring(
        coordinator.indexOf('if (!completed.await(100'),
        coordinator.indexOf('failure?.let'),
      );
      expect(timeout, isNot(contains('activeSession.set(false)')));
    },
  );
  test('Cloudflare browser proxy changes stay inside a non-exported process', () {
    final String manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final String registration = RegExp(
      r'<activity\s[^>]*android:name="\.mihon\.CloudflareChallengeActivity"[^>]*/>',
      dotAll: true,
    ).firstMatch(manifest)!.group(0)!;
    expect(registration, contains('android:exported="false"'));
    expect(registration, contains('android:process=":network_challenge"'));
    final List<File> native = Directory('android/app/src/main')
        .listSync(recursive: true)
        .whereType<File>()
        .where(
          (File file) =>
              file.path.endsWith('.kt') || file.path.endsWith('.java'),
        )
        .toList();
    final List<File> overrides = native
        .where(
          (File file) => file.readAsStringSync().contains('setProxyOverride('),
        )
        .toList();
    expect(overrides, hasLength(1));
    expect(overrides.single.path, endsWith('CloudflareChallengeActivity.kt'));
  });

  test(
    'extension requests report challenges without opening hidden browsers',
    () {
      final String source = File(
        'android/app/src/main/kotlin/eu/kanade/tachiyomi/network/interceptor/CloudflareInterceptor.kt',
      ).readAsStringSync();
      expect(source, contains('throw CloudflareChallengeRequiredException'));
      expect(source, isNot(contains('WebView(')));
      expect(source, isNot(contains('startActivity(')));
      expect(source, contains('cf-mitigated'));
    },
  );
}
