import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/kavita/kavita_api_registry.dart';
import 'package:fushi/src/media/kavita/kavita_server_config.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/pref_redaction_policy.dart';

KavitaServerConfig _cfg({
  String id = 'a',
  String url = 'https://kavita.example.com',
  String key = 'SECRET-KEY',
  bool http = false,
}) => KavitaServerConfig(
  id: id,
  name: 'Home',
  serverUrl: Uri.parse(url),
  apiKey: key,
  allowInsecureHttp: http,
);

void main() {
  group('KavitaServerConfig', () {
    test('json round-trip keeps fields and stores the key only as base64', () {
      final String json = encodeKavitaServerConfigs(<KavitaServerConfig>[
        _cfg(),
      ]);
      expect(json, isNot(contains('SECRET-KEY')));
      final List<KavitaServerConfig> back = decodeKavitaServerConfigs(json);
      expect(back.single.apiKey, 'SECRET-KEY');
      expect(back.single.id, 'a');
      expect(back.single.enabled, isTrue);
    });

    test('plain http needs explicit opt-in unless loopback', () {
      expect(
        () => _cfg(url: 'http://192.168.0.246:5501'),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        _cfg(url: 'http://192.168.0.246:5501', http: true).isUsable,
        isTrue,
      );
      expect(_cfg(url: 'http://127.0.0.1:5000').isUsable, isTrue);
    });

    test('url with user info and empty id are rejected', () {
      expect(
        () => _cfg(url: 'https://u:p@host.example'),
        throwsA(isA<ArgumentError>()),
      );
      expect(() => _cfg(id: ' '), throwsA(isA<ArgumentError>()));
    });

    test('decode drops malformed and duplicate entries, tolerates garbage', () {
      const String raw =
          '[{"id":"a","url":"https://x.example","apiKeyB64":"S0VZ"},'
          '{"id":"a","url":"https://dup.example"},'
          '{"id":"b","url":""},'
          '{"id":"c","url":"http://10.0.0.5:5000"},'
          '"junk"]';
      final List<KavitaServerConfig> out = decodeKavitaServerConfigs(raw);
      expect(out.map((KavitaServerConfig c) => c.id), <String>['a']);
      expect(out.single.apiKey, 'KEY');
      expect(decodeKavitaServerConfigs('{not json'), isEmpty);
      expect(decodeKavitaServerConfigs(null), isEmpty);
    });

    test('toString never leaks the key', () {
      expect(_cfg().toString(), isNot(contains('SECRET-KEY')));
    });

    test('config without key is not usable', () {
      expect(_cfg(key: '').isUsable, isFalse);
    });
  });

  group('credential registration', () {
    test('kavita_servers is a known credential pref and redacted', () {
      expect(kKnownPreferenceKeys, contains(kKavitaServersPref));
      expect(kCredentialPreferenceKeys, contains(kKavitaServersPref));
      expect(
        PrefRedactionPolicy.sensitiveKeys.contains(kKavitaServersPref),
        isTrue,
      );
      expect(SyncRepository.deviceLocalPrefKeys, contains(kKavitaServersPref));
    });
  });

  group('KavitaApiRegistry', () {
    test('reuses instance, replaces on key change, retainOnly closes', () {
      final KavitaApiRegistry reg = KavitaApiRegistry();
      addTearDown(reg.closeAll);
      final KavitaServerConfig a = _cfg();
      expect(identical(reg.apiFor(a), reg.apiFor(a)), isTrue);
      final first = reg.apiFor(a);
      final second = reg.apiFor(a.copyWith(apiKey: 'NEW'));
      expect(identical(first, second), isFalse);
      expect(reg.length, 1);
      reg.retainOnly(const <KavitaServerConfig>[]);
      expect(reg.length, 0);
    });
  });
}
