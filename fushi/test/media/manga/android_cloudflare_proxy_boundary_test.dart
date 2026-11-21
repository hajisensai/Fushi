import 'dart:io';

import 'package:test/test.dart';

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

  // BUG-4952：验证 Activity 在 `:network_challenge` 进程里把匿名
  // `object : ResultReceiver` 塞进 Bundle 回发，主进程反序列化时只有 boot
  // classloader，找不到 app 私有类名 → 主线程 BadParcelableException → 一点
  // 「网站验证」主进程就闪退。跨进程的 ResultReceiver 一律先 `.forIpc()`。
  test('ResultReceivers cross process boundaries only as the framework type', () {
    final String helper = File(
      'android/app/src/main/kotlin/app/fushi/reader/mihon/IpcResultReceiver.kt',
    ).readAsStringSync();
    expect(helper, contains('fun ResultReceiver.forIpc(): ResultReceiver'));
    expect(helper, contains('ResultReceiver.CREATOR.createFromParcel(parcel)'));

    final List<File> native = Directory('android/app/src/main')
        .listSync(recursive: true)
        .whereType<File>()
        .where(
          (File file) =>
              file.path.endsWith('.kt') || file.path.endsWith('.java'),
        )
        .toList();
    final RegExp declaration = RegExp(
      r'(?:val|var)\s+(\w+)\s*(?::\s*ResultReceiver\??\s*)?=\s*object\s*:\s*ResultReceiver\(',
    );
    final RegExp putCall = RegExp(
      r'\b(?:putExtra|putParcelable)\(\s*"[^"]*"\s*,\s*(object\b|\w+(?:\.forIpc\(\))?)',
    );
    final List<String> violations = <String>[];
    int wrapped = 0;
    for (final File file in native) {
      final String source = file.readAsStringSync();
      final Set<String> receivers = declaration
          .allMatches(source)
          .map((RegExpMatch m) => m.group(1)!)
          .toSet();
      for (final RegExpMatch call in putCall.allMatches(source)) {
        final String argument = call.group(1)!.trim();
        if (argument.startsWith('object')) {
          violations.add('${file.path}: inline ResultReceiver in $argument');
          continue;
        }
        final String name = RegExp(r'^\w+').stringMatch(argument) ?? '';
        if (!receivers.contains(name)) continue;
        if (argument.startsWith('$name.forIpc()')) {
          wrapped++;
        } else {
          violations.add('${file.path}: $name sent without forIpc()');
        }
      }
    }
    expect(violations, isEmpty);
    // 协调器 → 验证进程的 receiver、验证进程 → 协调器的 control 两处都得命中，
    // 否则说明上面的扫描失效（变成空守卫）。
    expect(wrapped, greaterThanOrEqualTo(2));
  });
}
