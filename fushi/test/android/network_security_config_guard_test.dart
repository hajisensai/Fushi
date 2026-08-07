import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-377 source-scan guard: Android cleartext-HTTP must stay allowed for
/// LAN paired-device sync, while the app's own public endpoints stay https-only.
///
/// Root cause: paired-device book download (and all interconnect sync) on
/// Android talks plaintext HTTP to LAN peers — the candidate URLs are
/// `http://192.168.x.x:port` (mDNS-discovered in lan_discovery_service.dart or
/// hand-typed in interconnect.part.dart). The introduced
/// `network_security_config.xml` set `cleartextTrafficPermitted="false"` on the
/// base-config and only whitelisted `localhost`/`127.0.0.1`, so the Android
/// platform layer rejected every `http://IP` connection (cleartext not
/// permitted). The client probe swallowed the exception as "unreachable" → "No
/// reachable Hibiki server address" → download failed. Desktop has no such gate,
/// hence the symptom was Android-only.
///
/// Fix: base-config allows cleartext (restores API<=27 default; the LAN sync
/// protocol is plaintext-by-design and gated behind the user enabling hosting),
/// but a dedicated domain-config pins the log-upload host to https-only so the
/// one hardcoded public endpoint can never be downgraded.
///
/// A real device's cleartext rejection happens in Android's native HttpEngine
/// (can't run here), so this guards the *config mechanism*: if cleartext gets
/// re-disabled at the base, or the manifest stops referencing the config, the
/// Android paired-device path silently breaks again and this test goes red.
void main() {
  // Tests run with CWD = `hibiki/`.
  final File configFile = File(
    'android/app/src/main/res/xml/network_security_config.xml',
  );
  final File manifestFile = File(
    'android/app/src/main/AndroidManifest.xml',
  );

  test('network_security_config.xml exists and is referenced by the manifest',
      () {
    expect(configFile.existsSync(), isTrue,
        reason: 'BUG-377 fix lives in this file');
    final String manifest = manifestFile.readAsStringSync();
    expect(
      manifest.contains(
        'android:networkSecurityConfig="@xml/network_security_config"',
      ),
      isTrue,
      reason:
          'manifest must point <application> at the network security config '
          'or the cleartext policy never takes effect',
    );
  });

  test(
      'base-config permits cleartext so LAN paired-device sync works on Android',
      () {
    final String xml = configFile.readAsStringSync();
    // Normalize whitespace so attribute-order/spacing changes do not break us.
    final String compact = xml.replaceAll(RegExp(r'\s+'), ' ');
    expect(
      RegExp(r'<base-config[^>]*cleartextTrafficPermitted="true"')
          .hasMatch(compact),
      isTrue,
      reason: 'BUG-377: base-config must allow cleartext, else Android rejects '
          'every http:// LAN peer and paired-device download fails',
    );
    expect(
      RegExp(r'<base-config[^>]*cleartextTrafficPermitted="false"')
          .hasMatch(compact),
      isFalse,
      reason: 'base-config="false" is the exact regression that broke '
          'paired-device download on Android',
    );
  });

  test('app-owned public log-upload endpoint stays https-only (no downgrade)',
      () {
    final String xml = configFile.readAsStringSync();
    final String compact = xml.replaceAll(RegExp(r'\s+'), ' ');
    // There must be a domain-config that forbids cleartext and lists the
    // log-upload host, so the one hardcoded public endpoint can't be downgraded.
    final RegExp httpsOnlyBlock = RegExp(
      r'<domain-config[^>]*cleartextTrafficPermitted="false"[^>]*>.*?logs\.wrds\.xyz.*?</domain-config>',
    );
    expect(
      httpsOnlyBlock.hasMatch(compact),
      isTrue,
      reason: 'BUG-377: keep logs.wrds.xyz pinned https-only via a '
          'cleartext=false domain-config (defense against future downgrade)',
    );
  });
}
