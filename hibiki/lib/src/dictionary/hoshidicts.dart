import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'hoshidicts_ffi_bindings.dart';

// ── Dart data classes ───────────────────────────────────────────────

class HoshiGlossaryEntry {
  final String dictName;
  final String glossary;
  final String definitionTags;
  final String termTags;

  const HoshiGlossaryEntry({
    required this.dictName,
    required this.glossary,
    required this.definitionTags,
    required this.termTags,
  });
}

class HoshiFrequency {
  final int value;
  final String displayValue;
  const HoshiFrequency({required this.value, required this.displayValue});
}

class HoshiFrequencyEntry {
  final String dictName;
  final List<HoshiFrequency> frequencies;
  const HoshiFrequencyEntry({required this.dictName, required this.frequencies});
}

class HoshiPitchEntry {
  final String dictName;
  final List<int> pitchPositions;
  const HoshiPitchEntry({required this.dictName, required this.pitchPositions});
}

class HoshiTermResult {
  final String expression;
  final String reading;
  final String rules;
  final List<HoshiGlossaryEntry> glossaries;
  final List<HoshiFrequencyEntry> frequencies;
  final List<HoshiPitchEntry> pitches;

  const HoshiTermResult({
    required this.expression,
    required this.reading,
    required this.rules,
    required this.glossaries,
    required this.frequencies,
    required this.pitches,
  });
}

class HoshiTransformGroup {
  final String name;
  final String description;
  const HoshiTransformGroup({required this.name, required this.description});
}

class HoshiLookupResult {
  final String matched;
  final String deinflected;
  final List<HoshiTransformGroup> trace;
  final HoshiTermResult term;
  final int preprocessorSteps;

  const HoshiLookupResult({
    required this.matched,
    required this.deinflected,
    required this.trace,
    required this.term,
    required this.preprocessorSteps,
  });
}

class HoshiImportResult {
  final bool success;
  final String title;
  final int termCount;
  final int metaCount;
  final int tagCount;
  final int mediaCount;
  final String error;

  const HoshiImportResult({
    required this.success,
    required this.title,
    required this.termCount,
    required this.metaCount,
    required this.tagCount,
    required this.mediaCount,
    required this.error,
  });
}

class HoshiDictStyle {
  final String dictName;
  final String styles;
  const HoshiDictStyle({required this.dictName, required this.styles});
}

// ── conversion helpers ──────────────────────────────────────────────

HoshiTermResult _convertTerm(FfiTermResult ffi) {
  final glossaries = <HoshiGlossaryEntry>[];
  for (int i = 0; i < ffi.glossaryCount; i++) {
    final g = ffi.glossaries[i];
    glossaries.add(HoshiGlossaryEntry(
      dictName: g.dictName.toDartString(),
      glossary: g.glossary.toDartString(),
      definitionTags: g.definitionTags.toDartString(),
      termTags: g.termTags.toDartString(),
    ));
  }

  final frequencies = <HoshiFrequencyEntry>[];
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

  final pitches = <HoshiPitchEntry>[];
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
  static HoshidictsFfiBindings? _bindings;
  Pointer<Void>? _handle;

  HoshiDicts() {
    _bindings ??= HoshidictsFfiBindings();
    _handle = _bindings!.create();
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
        final result = HoshiImportResult(
          success: r.success != 0,
          title: r.title.toDartString(),
          termCount: r.termCount,
          metaCount: r.metaCount,
          tagCount: r.tagCount,
          mediaCount: r.mediaCount,
          error: r.error.toDartString(),
        );
        final rPtr = calloc<FfiImportResult>();
        rPtr.ref = r;
        _bindings!.freeImportResult(rPtr);
        calloc.free(rPtr);
        return result;
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
      final results = <HoshiTermResult>[];
      for (int i = 0; i < r.count; i++) {
        results.add(_convertTerm(r.terms[i]));
      }
      final rPtr = calloc<FfiQueryResult>();
      rPtr.ref = r;
      _bindings!.freeQueryResult(rPtr);
      calloc.free(rPtr);
      return results;
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
      final rPtr = calloc<FfiLookupResults>();
      rPtr.ref = r;
      _bindings!.freeLookupResults(rPtr);
      calloc.free(rPtr);
      return results;
    } finally {
      calloc.free(tp);
    }
  }

  // ── styles ──────────────────────────────────────────────────────
  List<HoshiDictStyle> getStyles() {
    final r = _bindings!.getStyles(_handle!);
    final styles = <HoshiDictStyle>[];
    for (int i = 0; i < r.count; i++) {
      styles.add(HoshiDictStyle(
        dictName: r.items[i].dictName.toDartString(),
        styles: r.items[i].styles.toDartString(),
      ));
    }
    final rPtr = calloc<FfiDictStyles>();
    rPtr.ref = r;
    _bindings!.freeStyles(rPtr);
    calloc.free(rPtr);
    return styles;
  }

  // ── media ───────────────────────────────────────────────────────
  Uint8List? getMediaFile(String dictName, String mediaPath) {
    final dn = dictName.toNativeUtf8();
    final mp = mediaPath.toNativeUtf8();
    try {
      final r = _bindings!.getMedia(_handle!, dn, mp);
      if (r.size <= 0 || r.data == nullptr) {
        return null;
      }
      final bytes = Uint8List.fromList(r.data.asTypedList(r.size));
      final rPtr = calloc<FfiMediaFile>();
      rPtr.ref = r;
      _bindings!.freeMedia(rPtr);
      calloc.free(rPtr);
      return bytes;
    } finally {
      calloc.free(dn);
      calloc.free(mp);
    }
  }

  static HoshiDicts withPaths(List<String> paths) {
    final h = HoshiDicts();
    for (final p in paths) {
      h.addTermDict(p);
      h.addFreqDict(p);
      h.addPitchDict(p);
    }
    return h;
  }
}
