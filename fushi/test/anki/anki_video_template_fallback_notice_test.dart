import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/anki_video_template_entry.dart';
import 'package:fushi_engine/foundation/pref_store.dart';

class _MemoryPrefs implements PrefStore {
  final Map<String, dynamic> values = <String, dynamic>{};

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values.containsKey(key) ? values[key] : defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async => values[key] = value;
}

void main() {
  test('每个笔记类型只提示一次', () async {
    final _MemoryPrefs prefs = _MemoryPrefs();
    expect(await claimAnkiVideoTemplateFallbackNotice(prefs, 'Kiku'), isTrue);
    expect(await claimAnkiVideoTemplateFallbackNotice(prefs, 'Kiku'), isFalse);
    expect(await claimAnkiVideoTemplateFallbackNotice(prefs, 'Lapis'), isTrue);
    expect(await claimAnkiVideoTemplateFallbackNotice(prefs, 'Lapis'), isFalse);
  });

  test('损坏的已提示记录当作空，不抛', () async {
    final _MemoryPrefs prefs = _MemoryPrefs()
      ..values[kAnkiVideoTemplateFallbackNoticedKey] = '{not json';
    expect(await claimAnkiVideoTemplateFallbackNotice(prefs, 'Kiku'), isTrue);
    expect(await claimAnkiVideoTemplateFallbackNotice(prefs, 'Kiku'), isFalse);
  });
}
