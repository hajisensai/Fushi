// TODO-094b S3 source-scan guard for the kanji dictionary FFI binding chain.
//
// The kanji query has to cross four layers that each name the *same* C symbols.
// The classic FFI breakage is a silent name/typedef mismatch between the C
// `extern "C"` export and the Dart `lookupFunction(...)` string: it compiles on
// both sides but throws `Invalid argument(s): Failed to lookup symbol` only at
// runtime on a real device. flutter_test cannot link the native lib, so the
// strongest *landable* guard is a source-scan that asserts every layer still
// declares the kanji exports symmetrically. A verified end-to-end FFI round-trip
// also exists (host: load hoshidicts_ffi.dll -> add_kanji_dict -> query_kanji).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String relativeToHibiki) {
    final File f = File(relativeToHibiki);
    expect(f.existsSync(), isTrue,
        reason: 'expected file at ${f.absolute.path}');
    return f.readAsStringSync();
  }

  test('native FFI exports the kanji C symbols', () {
    final String ffi = read('../native/hoshidicts/hoshidicts_ffi.cpp');
    for (final String sym in <String>[
      'hoshidicts_add_kanji_dict',
      'hoshidicts_query_kanji',
      'hoshidicts_free_kanji_results',
    ]) {
      expect(ffi.contains(sym), isTrue,
          reason: 'hoshidicts_ffi.cpp must export $sym (TODO-094b S3)');
    }
    // The FFI result struct must carry every KanjiResult field.
    expect(ffi.contains('struct FfiKanjiResult'), isTrue);
    for (final String field in <String>[
      'character',
      'onyomi',
      'kunyomi',
      'radical',
      'strokes',
      'meanings',
      'meaning_count',
      'dict_name',
    ]) {
      expect(ffi.contains(field), isTrue,
          reason: 'FfiKanjiResult must include $field');
    }
  });

  test('Dart bindings look up the kanji C symbols by their exact names', () {
    final String bindings = read(
        '../packages/hibiki_dictionary/lib/src/ffi/hoshidicts_ffi_bindings.dart');
    // The lookupFunction string MUST match the C export name byte-for-byte.
    for (final String sym in <String>[
      'hoshidicts_add_kanji_dict',
      'hoshidicts_query_kanji',
      'hoshidicts_free_kanji_results',
    ]) {
      expect(bindings.contains("'$sym'"), isTrue,
          reason: 'bindings must lookupFunction $sym');
    }
    expect(bindings.contains('class FfiKanjiResult extends Struct'), isTrue);
    expect(bindings.contains('class FfiKanjiResults extends Struct'), isTrue);
  });

  test('engine exposes addKanjiDict / queryKanji and converts every field', () {
    final String engine =
        read('../packages/hibiki_dictionary/lib/src/engine/hoshidicts.dart');
    expect(engine.contains('void addKanjiDict(String path)'), isTrue);
    expect(engine.contains('List<HoshiKanjiResult> queryKanji('), isTrue);
    expect(engine.contains('class HoshiKanjiResult'), isTrue);
    expect(engine.contains('HoshiKanjiResult _convertKanji('), isTrue);
    // initializeTyped must accept the kanji bucket so S4 can route kanji dicts.
    expect(engine.contains('List<String> kanjiPaths'), isTrue);
  });

  test('Android JNI mirrors the kanji bindings symmetrically', () {
    final String jni = read('../native/hoshidicts/hoshidicts_jni.cpp');
    expect(jni.contains('nativeAddKanjiDict'), isTrue);
    expect(jni.contains('nativeQueryKanjiJson'), isTrue);
    final String bridge = read(
        '../hibiki/android/app/src/main/java/app/hibiki/reader/HoshiBridge.kt');
    expect(bridge.contains('nativeAddKanjiDict'), isTrue);
    expect(bridge.contains('nativeQueryKanjiJson'), isTrue);
    expect(bridge.contains('fun queryKanjiJson('), isTrue);
  });
}
