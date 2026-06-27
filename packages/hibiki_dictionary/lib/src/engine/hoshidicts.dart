import 'dart:convert' show jsonDecode, utf8;
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../ffi/hoshidicts_ffi_bindings.dart';

// ── Dart data classes ───────────────────────────────────────────────

class HoshiGlossaryEntry {
  const HoshiGlossaryEntry({
    required this.dictName,
    required this.glossary,
    required this.definitionTags,
    required this.termTags,
  });
  final String dictName;
  final String glossary;
  final String definitionTags;
  final String termTags;
}

class HoshiFrequency {
  const HoshiFrequency({required this.value, required this.displayValue});
  final int value;
  final String displayValue;
}

class HoshiFrequencyEntry {
  const HoshiFrequencyEntry(
      {required this.dictName, required this.frequencies});
  final String dictName;
  final List<HoshiFrequency> frequencies;
}

class HoshiPitchEntry {
  const HoshiPitchEntry({
    required this.dictName,
    required this.pitchPositions,
    this.transcriptions = const <String>[],
  });
  final String dictName;
  final List<int> pitchPositions;

  /// IPA transcriptions for this dict's entry (Yomitan `ipa` meta mode). Empty
  /// for plain pitch-accent dicts. Carried alongside pitchPositions because both
  /// share the native PITCH bucket / query path (TODO-687 block3).
  final List<String> transcriptions;
}

class HoshiTermResult {
  const HoshiTermResult({
    required this.expression,
    required this.reading,
    required this.rules,
    required this.glossaries,
    required this.frequencies,
    required this.pitches,
  });
  final String expression;
  final String reading;
  final String rules;
  final List<HoshiGlossaryEntry> glossaries;
  final List<HoshiFrequencyEntry> frequencies;
  final List<HoshiPitchEntry> pitches;
}

class HoshiTransformGroup {
  const HoshiTransformGroup({required this.name, required this.description});
  final String name;
  final String description;
}

class HoshiLookupResult {
  const HoshiLookupResult({
    required this.matched,
    required this.deinflected,
    required this.trace,
    required this.term,
    required this.preprocessorSteps,
  });
  final String matched;
  final String deinflected;
  final List<HoshiTransformGroup> trace;
  final HoshiTermResult term;
  final int preprocessorSteps;
}

class HoshiImportResult {
  const HoshiImportResult({
    required this.success,
    required this.title,
    required this.termCount,
    required this.metaCount,
    required this.freqCount,
    required this.pitchCount,
    required this.mediaCount,
    required this.kanjiCount,
    required this.detectedType,
    required this.error,
  });
  final bool success;
  final String title;
  final int termCount;
  final int metaCount;
  final int freqCount;
  final int pitchCount;
  final int mediaCount;
  final int kanjiCount;
  final String detectedType;
  final String error;
}

class HoshiDictStyle {
  const HoshiDictStyle({required this.dictName, required this.styles});
  final String dictName;
  final String styles;
}

class HoshiKanjiResult {
  const HoshiKanjiResult({
    required this.character,
    required this.onyomi,
    required this.kunyomi,
    required this.radical,
    required this.strokes,
    required this.meanings,
    required this.dictName,
  });

  /// Reconstructs a kanji result from a map decoded out of a
  /// [DictionarySearchResult] JSON payload (e.g. when the popup process
  /// receives a serialized search result across the process boundary). Missing
  /// or null fields degrade to empty/zero so a partial payload never throws.
  factory HoshiKanjiResult.fromMap(Map<String, dynamic> map) {
    return HoshiKanjiResult(
      character: map['character'] as String? ?? '',
      onyomi: map['onyomi'] as String? ?? '',
      kunyomi: map['kunyomi'] as String? ?? '',
      radical: map['radical'] as String? ?? '',
      strokes: (map['strokes'] as num?)?.toInt() ?? 0,
      meanings: List<String>.from(map['meanings'] as List? ?? const <String>[]),
      dictName: map['dictName'] as String? ?? '',
    );
  }

  final String character;
  final String onyomi;
  final String kunyomi;
  final String radical;
  final int strokes;
  final List<String> meanings;
  final String dictName;

  Map<String, dynamic> toMap() => <String, dynamic>{
        'character': character,
        'onyomi': onyomi,
        'kunyomi': kunyomi,
        'radical': radical,
        'strokes': strokes,
        'meanings': meanings,
        'dictName': dictName,
      };
}

// ── conversion helpers ──────────────────────────────────────────────

/// Converts a possibly-null native UTF-8 pointer to a Dart string, treating
/// nullptr as '' so a native OOM/error path that left a string field NULL
/// cannot crash the Dart side with a null dereference (HBK-AUDIT-032/097).
String _utf8OrEmpty(Pointer<Utf8> p) {
  if (p == nullptr) return '';
  try {
    return p.toDartString();
  } on FormatException {
    // 词典数据含非法 UTF-8 字节（非标准编码导入的词典）：容错解码替换非法字节，
    // 而非让 FormatException 崩掉整个词典初始化 / 查词（getStyles 等触点）。
    // toDartString 内部是严格 utf8.decode，不支持容错；故手动读到首个 NUL 的
    // 字节后用 allowMalformed 解码。
    final Pointer<Uint8> bytes = p.cast<Uint8>();
    int len = 0;
    while (bytes[len] != 0) {
      len++;
    }
    return utf8.decode(bytes.asTypedList(len), allowMalformed: true);
  }
}

HoshiTermResult _convertTerm(FfiTermResult ffi) {
  final glossaries = <HoshiGlossaryEntry>[];
  if (ffi.glossaryCount > 0 && ffi.glossaries != nullptr) {
    for (int i = 0; i < ffi.glossaryCount; i++) {
      final g = ffi.glossaries[i];
      glossaries.add(HoshiGlossaryEntry(
        dictName: _utf8OrEmpty(g.dictName),
        glossary: _utf8OrEmpty(g.glossary),
        definitionTags: _utf8OrEmpty(g.definitionTags),
        termTags: _utf8OrEmpty(g.termTags),
      ));
    }
  }

  final frequencies = <HoshiFrequencyEntry>[];
  if (ffi.frequencyCount > 0 && ffi.frequencies != nullptr) {
    for (int i = 0; i < ffi.frequencyCount; i++) {
      final f = ffi.frequencies[i];
      final freqs = <HoshiFrequency>[];
      for (int j = 0; j < f.count; j++) {
        freqs.add(HoshiFrequency(
          value: f.values[j],
          displayValue: _utf8OrEmpty(f.displayValues[j]),
        ));
      }
      frequencies.add(HoshiFrequencyEntry(
        dictName: _utf8OrEmpty(f.dictName),
        frequencies: freqs,
      ));
    }
  }

  final pitches = <HoshiPitchEntry>[];
  if (ffi.pitchCount > 0 && ffi.pitches != nullptr) {
    for (int i = 0; i < ffi.pitchCount; i++) {
      final p = ffi.pitches[i];
      final positions = <int>[];
      for (int j = 0; j < p.count; j++) {
        positions.add(p.positions[j]);
      }
      final transcriptions = <String>[];
      if (p.transcriptionCount > 0 && p.transcriptions != nullptr) {
        for (int j = 0; j < p.transcriptionCount; j++) {
          transcriptions.add(_utf8OrEmpty(p.transcriptions[j]));
        }
      }
      pitches.add(HoshiPitchEntry(
        dictName: _utf8OrEmpty(p.dictName),
        pitchPositions: positions,
        transcriptions: transcriptions,
      ));
    }
  }

  return HoshiTermResult(
    expression: _utf8OrEmpty(ffi.expression),
    reading: _utf8OrEmpty(ffi.reading),
    rules: _utf8OrEmpty(ffi.rules),
    glossaries: glossaries,
    frequencies: frequencies,
    pitches: pitches,
  );
}

HoshiKanjiResult _convertKanji(FfiKanjiResult ffi) {
  final meanings = <String>[];
  if (ffi.meaningCount > 0 && ffi.meanings != nullptr) {
    for (int i = 0; i < ffi.meaningCount; i++) {
      meanings.add(_utf8OrEmpty(ffi.meanings[i]));
    }
  }
  return HoshiKanjiResult(
    character: _utf8OrEmpty(ffi.character),
    onyomi: _utf8OrEmpty(ffi.onyomi),
    kunyomi: _utf8OrEmpty(ffi.kunyomi),
    radical: _utf8OrEmpty(ffi.radical),
    strokes: ffi.strokes,
    meanings: meanings,
    dictName: _utf8OrEmpty(ffi.dictName),
  );
}

// ── main wrapper class ──────────────────────────────────────────────

class HoshiDicts {
  // ── lifecycle ──────────────────────────────────────────────────

  HoshiDicts() {
    _bindings ??= HoshidictsFfiBindings();
    _handle = _bindings!.create();
  }
  static HoshidictsFfiBindings? _bindings;
  Pointer<Void>? _handle;

  // ── singleton ──────────────────────────────────────────────────
  static HoshiDicts? _instance;
  static Map<String, String> _stylesCache = {};

  static HoshiDicts get instance {
    assert(_instance != null, 'HoshiDicts.initialize() must be called first');
    return _instance!;
  }

  static bool get isInitialized => _instance != null;

  static List<String>? _cachedTransformJsons;

  static Future<void> preloadTransforms() async {
    final List<String> languages;
    try {
      final manifest =
          await rootBundle.loadString('assets/transforms/manifest.json');
      languages = List<String>.from(jsonDecode(manifest) as List);
    } catch (e) {
      debugPrint('[HoshiDicts.preloadTransforms(manifest)] $e');
      return;
    }
    final jsons = <String>[];
    for (final lang in languages) {
      try {
        final json =
            await rootBundle.loadString('assets/transforms/$lang.json');
        jsons.add(json);
      } catch (e) {
        debugPrint('[HoshiDicts.preloadTransforms($lang)] $e');
      }
    }
    _cachedTransformJsons = jsons;
  }

  void _loadCachedTransforms() {
    if (_cachedTransformJsons == null) return;
    for (final json in _cachedTransformJsons!) {
      loadTransforms(json);
    }
  }

  static void initialize(List<String> paths) {
    _instance?.dispose();
    final h = HoshiDicts();
    h._loadCachedTransforms();
    for (final p in paths) {
      h.addTermDict(p);
      h.addFreqDict(p);
      h.addPitchDict(p);
    }
    _instance = h;
    _rebuildStylesCache();
  }

  static void initializeTyped({
    List<String> termPaths = const [],
    List<String> freqPaths = const [],
    List<String> pitchPaths = const [],
    List<String> kanjiPaths = const [],
  }) {
    _instance?.dispose();
    final h = HoshiDicts();
    h._loadCachedTransforms();
    for (final p in termPaths) {
      h.addTermDict(p);
    }
    for (final p in freqPaths) {
      h.addFreqDict(p);
    }
    for (final p in pitchPaths) {
      h.addPitchDict(p);
    }
    for (final p in kanjiPaths) {
      h.addKanjiDict(p);
    }
    _instance = h;
    _rebuildStylesCache();
  }

  static void rebuild(List<String> paths) {
    initialize(paths);
  }

  static void disposeInstance() {
    _instance?.dispose();
    _instance = null;
  }

  static Map<String, String> get dictionaryStyles => _stylesCache;

  static void _rebuildStylesCache() {
    if (_instance == null) {
      _stylesCache = {};
      return;
    }
    _stylesCache = {
      for (final s in _instance!.getStyles()) s.dictName: s.styles,
    };
  }

  void dispose() {
    if (_handle != null) {
      _bindings!.destroy(_handle!);
      _handle = null;
    }
  }

  // ── dict loading ────────────────────────────────────────────────
  void addTermDict(String path) {
    final p = path.toNativeUtf8(allocator: calloc);
    try {
      _bindings!.addTermDict(_handle!, p);
    } finally {
      calloc.free(p);
    }
  }

  void addFreqDict(String path) {
    final p = path.toNativeUtf8(allocator: calloc);
    try {
      _bindings!.addFreqDict(_handle!, p);
    } finally {
      calloc.free(p);
    }
  }

  void addPitchDict(String path) {
    final p = path.toNativeUtf8(allocator: calloc);
    try {
      _bindings!.addPitchDict(_handle!, p);
    } finally {
      calloc.free(p);
    }
  }

  void addKanjiDict(String path) {
    final p = path.toNativeUtf8(allocator: calloc);
    try {
      _bindings!.addKanjiDict(_handle!, p);
    } finally {
      calloc.free(p);
    }
  }

  /// Probe a written dictionary directory's on-disk content (single source of
  /// truth, independent of its declared classification). Returns a bitmask:
  /// bit0 (0x1) = has term records, bit1 (0x2) = has kanji records, 0 on
  /// failure. Used to route mixed dictionaries into both buckets and to
  /// self-heal already-imported dictionaries that detect_type mislabeled.
  ///
  /// Static (handle-free): only reads blobs.bin/hash.table on disk, so it can
  /// run during type migration before any query handle exists.
  static int probeDictContent(String dir) {
    _bindings ??= HoshidictsFfiBindings();
    final p = dir.toNativeUtf8(allocator: calloc);
    try {
      return _bindings!.probeDictContent(p);
    } finally {
      calloc.free(p);
    }
  }

  void loadTransforms(String json) {
    final p = json.toNativeUtf8(allocator: calloc);
    try {
      _bindings!.loadTransforms(_handle!, p);
    } finally {
      calloc.free(p);
    }
  }

  // ── import (static, no handle needed) ───────────────────────────
  // The C++ side spawns a pthread with 32 MB stack to handle deep
  // recursion in zip/JSON parsing, so this can safely run in any isolate.
  static Future<HoshiImportResult> importDictionary(
      String zipPath, String outputDir,
      {String breadcrumbDir = ''}) async {
    return Isolate.run(() {
      _bindings ??= HoshidictsFfiBindings();
      final zp = zipPath.toNativeUtf8(allocator: calloc);
      final od = outputDir.toNativeUtf8(allocator: calloc);
      // TODO-892: native writes a synchronous '.import_step' crash breadcrumb
      // into this fixed directory; empty string disables it.
      final bc = breadcrumbDir.toNativeUtf8(allocator: calloc);
      try {
        final r = _bindings!.import_(zp, od, bc);
        final rPtr = calloc<FfiImportResult>();
        rPtr.ref = r;
        try {
          // Error/early-return branches in native hoshidicts_import can leave
          // detected_type/title/error NULL; guard every conversion so a failed
          // import reports cleanly instead of crashing on null deref
          // (HBK-AUDIT-032).
          return HoshiImportResult(
            success: r.success != 0,
            title: _utf8OrEmpty(r.title),
            termCount: r.termCount,
            metaCount: r.metaCount,
            freqCount: r.freqCount,
            pitchCount: r.pitchCount,
            mediaCount: r.mediaCount,
            kanjiCount: r.kanjiCount,
            detectedType: _utf8OrEmpty(r.detectedType),
            error: _utf8OrEmpty(r.error),
          );
        } finally {
          _bindings!.freeImportResult(rPtr);
          calloc.free(rPtr);
        }
      } finally {
        calloc.free(zp);
        calloc.free(od);
        calloc.free(bc);
      }
    });
  }

  // ── query ───────────────────────────────────────────────────────
  List<HoshiTermResult> query(String expression) {
    final ep = expression.toNativeUtf8(allocator: calloc);
    try {
      final r = _bindings!.query(_handle!, ep);
      final rPtr = calloc<FfiQueryResult>();
      rPtr.ref = r;
      try {
        final results = <HoshiTermResult>[];
        for (int i = 0; i < r.count; i++) {
          results.add(_convertTerm(r.terms[i]));
        }
        return results;
      } finally {
        _bindings!.freeQueryResult(rPtr);
        calloc.free(rPtr);
      }
    } finally {
      calloc.free(ep);
    }
  }

  // ── kanji query ─────────────────────────────────────────────────
  List<HoshiKanjiResult> queryKanji(String character) {
    final cp = character.toNativeUtf8(allocator: calloc);
    try {
      final r = _bindings!.queryKanji(_handle!, cp);
      final rPtr = calloc<FfiKanjiResults>();
      rPtr.ref = r;
      try {
        final results = <HoshiKanjiResult>[];
        for (int i = 0; i < r.count; i++) {
          results.add(_convertKanji(r.results[i]));
        }
        return results;
      } finally {
        _bindings!.freeKanjiResults(rPtr);
        calloc.free(rPtr);
      }
    } finally {
      calloc.free(cp);
    }
  }

  static const int defaultMaxResults = 16;
  static const int defaultScanLength = 16;

  // ── lookup (with deinflection) ──────────────────────────────────
  List<HoshiLookupResult> lookup(
    String text, {
    int maxResults = defaultMaxResults,
    int scanLength = defaultScanLength,
  }) {
    final tp = text.toNativeUtf8(allocator: calloc);
    try {
      final swNative = Stopwatch()..start();
      final r = _bindings!.lookup(_handle!, tp, maxResults, scanLength);
      swNative.stop();
      debugPrint(
          '[dict-perf]     native call: ${swNative.elapsedMicroseconds}µs count=${r.count}');

      final rPtr = calloc<FfiLookupResults>();
      rPtr.ref = r;
      try {
        final swConvert = Stopwatch()..start();
        final results = <HoshiLookupResult>[];
        for (int i = 0; i < r.count; i++) {
          final src = r.results[i];
          final trace = <HoshiTransformGroup>[];
          for (int j = 0; j < src.traceCount; j++) {
            trace.add(HoshiTransformGroup(
              name: _utf8OrEmpty(src.trace[j].name),
              description: _utf8OrEmpty(src.trace[j].description),
            ));
          }
          results.add(HoshiLookupResult(
            matched: _utf8OrEmpty(src.matched),
            deinflected: _utf8OrEmpty(src.deinflected),
            trace: trace,
            term: _convertTerm(src.term),
            preprocessorSteps: src.preprocessorSteps,
          ));
        }
        swConvert.stop();
        debugPrint(
            '[dict-perf]     ffi→dart convert: ${swConvert.elapsedMicroseconds}µs');
        return results;
      } finally {
        _bindings!.freeLookupResults(rPtr);
        calloc.free(rPtr);
      }
    } finally {
      calloc.free(tp);
    }
  }

  // ── popup JSON (single source of truth — same C++ as JNI) ───────
  String lookupPopupJson(
    String text, {
    int maxResults = defaultMaxResults,
    int scanLength = defaultScanLength,
    int maxTerms = 100,
  }) {
    final tp = text.toNativeUtf8(allocator: calloc);
    try {
      final ptr = _bindings!
          .lookupPopupJson(_handle!, tp, maxResults, scanLength, maxTerms);
      if (ptr == nullptr) return '[]';
      try {
        // 容错解码：词典 popupJson 数据可能含非法 UTF-8 字节（非标准编码导入的
        // 词典），严格 toDartString 会抛 FormatException 让整个查词失败。
        return _utf8OrEmpty(ptr);
      } finally {
        _bindings!.freeString(ptr);
      }
    } finally {
      calloc.free(tp);
    }
  }

  // ── styles ──────────────────────────────────────────────────────
  List<HoshiDictStyle> getStyles() {
    final r = _bindings!.getStyles(_handle!);
    final rPtr = calloc<FfiDictStyles>();
    rPtr.ref = r;
    try {
      final styles = <HoshiDictStyle>[];
      for (int i = 0; i < r.count; i++) {
        styles.add(HoshiDictStyle(
          dictName: _utf8OrEmpty(r.items[i].dictName),
          styles: _utf8OrEmpty(r.items[i].styles),
        ));
      }
      return styles;
    } finally {
      _bindings!.freeStyles(rPtr);
      calloc.free(rPtr);
    }
  }

  // ── media ───────────────────────────────────────────────────────
  Uint8List? getMediaFile(String dictName, String mediaPath) {
    final dn = dictName.toNativeUtf8(allocator: calloc);
    final mp = mediaPath.toNativeUtf8(allocator: calloc);
    try {
      final r = _bindings!.getMedia(_handle!, dn, mp);
      final rPtr = calloc<FfiMediaFile>();
      rPtr.ref = r;
      try {
        Uint8List? bytes;
        if (r.size > 0 && r.data != nullptr) {
          bytes = Uint8List.fromList(r.data.asTypedList(r.size));
        } else if (r.size > 0 && r.data == nullptr) {
          // HBK-AUDIT-100: native kept the real size but data is NULL — this is
          // an allocation failure (malloc returned NULL for a large media
          // file), NOT a genuine miss (which reports size == 0). Surface a
          // diagnostic so OOM is distinguishable from not-found instead of
          // collapsing both into the same silent null. The contract stays
          // `Uint8List?` so the unguarded WebView callers keep degrading to a
          // 404 rather than crashing; the true fix (size=0 / error flag on
          // alloc failure) belongs in hoshidicts_ffi.cpp.
          debugPrint(
            '[hoshidicts] getMediaFile: native allocation failed for '
            '"$dictName/$mediaPath" (size=${r.size}, data=null); reporting '
            'as not-found.',
          );
        }
        return bytes;
      } finally {
        _bindings!.freeMedia(rPtr);
        calloc.free(rPtr);
      }
    } finally {
      calloc.free(dn);
      calloc.free(mp);
    }
  }

  static T withPaths<T>(
    List<String> paths,
    T Function(HoshiDicts h) action, {
    List<String> kanjiPaths = const [],
  }) {
    final h = HoshiDicts();
    h._loadCachedTransforms();
    for (final p in paths) {
      h.addTermDict(p);
      h.addFreqDict(p);
      h.addPitchDict(p);
    }
    for (final p in kanjiPaths) {
      h.addKanjiDict(p);
    }
    try {
      return action(h);
    } finally {
      h.dispose();
    }
  }
}
