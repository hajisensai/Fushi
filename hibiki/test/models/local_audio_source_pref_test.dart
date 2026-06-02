import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/local_audio_source_pref.dart';

void main() {
  test('round trips through json', () {
    const LocalAudioSourcePref p =
        LocalAudioSourcePref(name: 'nhk16', enabled: false);
    final LocalAudioSourcePref restored =
        LocalAudioSourcePref.fromJson(p.toJson());
    expect(restored, p);
  });

  test('defaults enabled to true on malformed json', () {
    final LocalAudioSourcePref p =
        LocalAudioSourcePref.fromJson(const <String, dynamic>{'name': 'forvo'});
    expect(p.name, 'forvo');
    expect(p.enabled, isTrue);
  });

  test('copyWith only changes enabled', () {
    const LocalAudioSourcePref p = LocalAudioSourcePref(name: 'jpod');
    expect(p.copyWith(enabled: false),
        const LocalAudioSourcePref(name: 'jpod', enabled: false));
    expect(p.copyWith().name, 'jpod');
  });
}
