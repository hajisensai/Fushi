import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'package:hibiki/src/utils/misc/error_log_service.dart';

import 'package:hibiki/src/dictionary/hoshidicts_ffi_bindings.dart';

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
  const HoshiFrequencyEntry({required this.dictName, required this.frequencies});
  final String dictName;
  final List<HoshiFrequency> frequencies;
}

class HoshiPitchEntry {
  const HoshiPitchEntry({required this.dictName, required this.pitchPositions});
  final String dictName;
  final List<int> pitchPositions;
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
    required this.tagCount,
    required this.mediaCount,
    required this.detectedType,
    required this.error,
  });
  final bool success;
  final String title;
  final int termCount;
  final int metaCount;
  final int tagCount;
  final int mediaCount;
  final String detectedType;
  final String error;
}

class HoshiDictStyle {
  const HoshiDictStyle({required this.dictName, required this.styles});
  final String dictName;
  final String styles;
}

// ── conversion helpers ──────────────────────────────────────────────

HoshiTermResult _convertTerm(FfiTermResult ffi) {
  final glossaries = <HoshiGlossaryEntry>[];
  if (ffi.glossaryCount > 0 && ffi.glossaries != nullptr) {
    for (int i = 0; i < ffi.glossaryCount; i++) {
      final g = ffi.glossaries[i];
      glossaries.add(HoshiGlossaryEntry(
        dictName: g.dictName.toDartString(),
        glossary: g.glossary.toDartString(),
        definitionTags: g.definitionTags.toDartString(),
        termTags: g.termTags.toDartString(),
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
          displayValue: f.displayValues[j].toDartString(),
        ));
      }
      frequencies.add(HoshiFrequencyEntry(
        dictName: f.dictName.toDartString(),
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
      pitches.add(HoshiPitchEntry(
        dictName: p.dictName.toDartString(),
        pitchPositions: positions,
      ));
    }
  }

  return HoshiTermResult(
    expression: ffi.expression.toDartString(),
    reading: ffi.reading.toDartString(),
    rules: ffi.rules.toDartString(),
    glossaries: glossaries,
    frequencies: frequencies,
    pitches: pitches,
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
    const languages = [
      'ar', 'de', 'el', 'en', 'eo', 'es', 'eu', 'fr',
      'ga', 'grc', 'ja', 'ka', 'ko', 'la', 'sga', 'sq', 'tl', 'yi',
    ];
    final jsons = <String>[];
    for (final lang in languages) {
      try {
        final json = await rootBundle.loadString('assets/transforms/$lang.json');
        jsons.add(json);
      } catch (e, stack) {
        ErrorLogService.instance.log('HoshiDicts.preloadTransforms($lang)', e, stack);
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
    final p = path.toNativeUtf8();
    try {
      _bindings!.addTermDict(_handle!, p);
    } finally {
      calloc.free(p);
    }
  }

  void addFreqDict(String path) {
    final p = path.toNativeUtf8();
    try {
      _bindings!.addFreqDict(_handle!, p);
    } finally {
      calloc.free(p);
    }
  }

  void addPitchDict(String path) {
    final p = path.toNativeUtf8();
    try {
      _bindings!.addPitchDict(_handle!, p);
    } finally {
      calloc.free(p);
    }
  }

  void loadTransforms(String json) {
    final p = json.toNativeUtf8();
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
      String zipPath, String outputDir) async {
    return Isolate.run(() {
      _bindings ??= HoshidictsFfiBindings();
      final zp = zipPath.toNativeUtf8();
      final od = outputDir.toNativeUtf8();
      try {
        final r = _bindings!.import_(zp, od);
        final rPtr = calloc<FfiImportResult>();
        rPtr.ref = r;
        try {
          return HoshiImportResult(
            success: r.success != 0,
            title: r.title.toDartString(),
            termCount: r.termCount,
            metaCount: r.metaCount,
            tagCount: r.tagCount,
            mediaCount: r.mediaCount,
            detectedType: r.detectedType.toDartString(),
            error: r.error.toDartString(),
          );
        } finally {
          _bindings!.freeImportResult(rPtr);
          calloc.free(rPtr);
        }
      } finally {
        calloc.free(zp);
        calloc.free(od);
      }
    });
  }

  // ── query ───────────────────────────────────────────────────────
  List<HoshiTermResult> query(String expression) {
    final ep = expression.toNativeUtf8();
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

  // ── lookup (with deinflection) ──────────────────────────────────
  List<HoshiLookupResult> lookup(
    String text, {
    int maxResults = 16,
    int scanLength = 16,
  }) {
    final tp = text.toNativeUtf8();
    try {
      final r = _bindings!.lookup(_handle!, tp, maxResults, scanLength);
      final rPtr = calloc<FfiLookupResults>();
      rPtr.ref = r;
      try {
        final results = <HoshiLookupResult>[];
        for (int i = 0; i < r.count; i++) {
          final src = r.results[i];
          final trace = <HoshiTransformGroup>[];
          for (int j = 0; j < src.traceCount; j++) {
            trace.add(HoshiTransformGroup(
              name: src.trace[j].name.toDartString(),
              description: src.trace[j].description.toDartString(),
            ));
          }
          results.add(HoshiLookupResult(
            matched: src.matched.toDartString(),
            deinflected: src.deinflected.toDartString(),
            trace: trace,
            term: _convertTerm(src.term),
            preprocessorSteps: src.preprocessorSteps,
          ));
        }
        return results;
      } finally {
        _bindings!.freeLookupResults(rPtr);
        calloc.free(rPtr);
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
          dictName: r.items[i].dictName.toDartString(),
          styles: r.items[i].styles.toDartString(),
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
    final dn = dictName.toNativeUtf8();
    final mp = mediaPath.toNativeUtf8();
    try {
      final r = _bindings!.getMedia(_handle!, dn, mp);
      final rPtr = calloc<FfiMediaFile>();
      rPtr.ref = r;
      try {
        Uint8List? bytes;
        if (r.size > 0 && r.data != nullptr) {
          bytes = Uint8List.fromList(r.data.asTypedList(r.size));
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

  static HoshiDicts withPaths(List<String> paths) {
    final h = HoshiDicts();
    h._loadCachedTransforms();
    for (final p in paths) {
      h.addTermDict(p);
      h.addFreqDict(p);
      h.addPitchDict(p);
    }
    return h;
  }
}
