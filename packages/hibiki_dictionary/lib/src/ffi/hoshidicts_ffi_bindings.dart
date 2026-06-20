import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

DynamicLibrary _openNativeLib() {
  if (Platform.isAndroid) return DynamicLibrary.open('libhoshidicts_ffi.so');
  if (Platform.isWindows) return DynamicLibrary.open('hoshidicts_ffi.dll');
  if (Platform.isMacOS) return DynamicLibrary.open('libhoshidicts_ffi.dylib');
  if (Platform.isLinux) return DynamicLibrary.open('libhoshidicts_ffi.so');
  if (Platform.isIOS) return DynamicLibrary.process();
  throw UnsupportedError(
      'hoshidicts: unsupported platform ${Platform.operatingSystem}');
}

// ── C struct mirrors ────────────────────────────────────────────────

final class FfiGlossary extends Struct {
  external Pointer<Utf8> dictName;
  external Pointer<Utf8> glossary;
  external Pointer<Utf8> definitionTags;
  external Pointer<Utf8> termTags;
}

final class FfiFrequency extends Struct {
  external Pointer<Utf8> dictName;
  external Pointer<Int32> values;
  external Pointer<Pointer<Utf8>> displayValues;
  @Int32()
  external int count;
}

final class FfiPitch extends Struct {
  external Pointer<Utf8> dictName;
  external Pointer<Int32> positions;
  @Int32()
  external int count;
}

final class FfiTermResult extends Struct {
  external Pointer<Utf8> expression;
  external Pointer<Utf8> reading;
  external Pointer<Utf8> rules;
  external Pointer<FfiGlossary> glossaries;
  @Int32()
  external int glossaryCount;
  external Pointer<FfiFrequency> frequencies;
  @Int32()
  external int frequencyCount;
  external Pointer<FfiPitch> pitches;
  @Int32()
  external int pitchCount;
}

final class FfiQueryResult extends Struct {
  external Pointer<FfiTermResult> terms;
  @Int32()
  external int count;
}

final class FfiTransformGroup extends Struct {
  external Pointer<Utf8> name;
  external Pointer<Utf8> description;
}

final class FfiLookupResult extends Struct {
  external Pointer<Utf8> matched;
  external Pointer<Utf8> deinflected;
  external Pointer<FfiTransformGroup> trace;
  @Int32()
  external int traceCount;
  external FfiTermResult term;
  @Int32()
  external int preprocessorSteps;
}

final class FfiLookupResults extends Struct {
  external Pointer<FfiLookupResult> results;
  @Int32()
  external int count;
}

final class FfiImportResult extends Struct {
  @Int32()
  external int success;
  external Pointer<Utf8> title;
  @Int32()
  external int termCount;
  @Int32()
  external int metaCount;
  @Int32()
  external int freqCount;
  @Int32()
  external int pitchCount;
  @Int32()
  external int mediaCount;
  @Int32()
  external int kanjiCount;
  external Pointer<Utf8> detectedType;
  external Pointer<Utf8> error;
}

final class FfiDictStyle extends Struct {
  external Pointer<Utf8> dictName;
  external Pointer<Utf8> styles;
}

final class FfiDictStyles extends Struct {
  external Pointer<FfiDictStyle> items;
  @Int32()
  external int count;
}

final class FfiMediaFile extends Struct {
  external Pointer<Uint8> data;
  @Int32()
  external int size;
}

final class FfiKanjiResult extends Struct {
  external Pointer<Utf8> character;
  external Pointer<Utf8> onyomi;
  external Pointer<Utf8> kunyomi;
  external Pointer<Utf8> radical;
  @Int32()
  external int strokes;
  external Pointer<Pointer<Utf8>> meanings;
  @Int32()
  external int meaningCount;
  external Pointer<Utf8> dictName;
}

final class FfiKanjiResults extends Struct {
  external Pointer<FfiKanjiResult> results;
  @Int32()
  external int count;
}

// ── native function typedefs ────────────────────────────────────────

typedef _ImportDart = FfiImportResult Function(
    Pointer<Utf8> zipPath, Pointer<Utf8> outputDir);

typedef _ProbeDictContentNative = Int32 Function(Pointer<Utf8> dir);
typedef _ProbeDictContentDart = int Function(Pointer<Utf8> dir);

typedef _FreeImportResultDart = void Function(Pointer<FfiImportResult> r);

typedef _CreateDart = Pointer<Void> Function();

typedef _DestroyDart = void Function(Pointer<Void> handle);

typedef _AddDictNative = Void Function(
    Pointer<Void> handle, Pointer<Utf8> path);
typedef _AddDictDart = void Function(Pointer<Void> handle, Pointer<Utf8> path);

typedef _LoadTransformsDart = void Function(
    Pointer<Void> handle, Pointer<Utf8> json);

typedef _QueryDart = FfiQueryResult Function(
    Pointer<Void> handle, Pointer<Utf8> expression);

typedef _FreeQueryResultDart = void Function(Pointer<FfiQueryResult> r);

typedef _LookupDart = FfiLookupResults Function(
    Pointer<Void> handle, Pointer<Utf8> text, int maxResults, int scanLength);

typedef _FreeLookupResultsDart = void Function(Pointer<FfiLookupResults> r);

typedef _GetStylesDart = FfiDictStyles Function(Pointer<Void> handle);

typedef _FreeStylesDart = void Function(Pointer<FfiDictStyles> r);

typedef _GetMediaDart = FfiMediaFile Function(
    Pointer<Void> handle, Pointer<Utf8> dictName, Pointer<Utf8> mediaPath);

typedef _FreeMediaDart = void Function(Pointer<FfiMediaFile> r);

typedef _QueryKanjiDart = FfiKanjiResults Function(
    Pointer<Void> handle, Pointer<Utf8> character);

typedef _FreeKanjiResultsDart = void Function(Pointer<FfiKanjiResults> r);

typedef _LookupPopupJsonDart = Pointer<Utf8> Function(Pointer<Void> handle,
    Pointer<Utf8> text, int maxResults, int scanLength, int maxTerms);

typedef _FreeStringDart = void Function(Pointer<Utf8> s);

// ── bindings class ──────────────────────────────────────────────────

class HoshidictsFfiBindings {
  HoshidictsFfiBindings() {
    _lib = _openNativeLib();

    import_ = _lib.lookupFunction<
        FfiImportResult Function(Pointer<Utf8>, Pointer<Utf8>),
        _ImportDart>('hoshidicts_import');
    probeDictContent =
        _lib.lookupFunction<_ProbeDictContentNative, _ProbeDictContentDart>(
            'hoshidicts_probe_dict_content');
    freeImportResult = _lib.lookupFunction<
        Void Function(Pointer<FfiImportResult>),
        _FreeImportResultDart>('hoshidicts_free_import_result');
    create = _lib.lookupFunction<Pointer<Void> Function(), _CreateDart>(
        'hoshidicts_create');
    destroy = _lib.lookupFunction<Void Function(Pointer<Void>), _DestroyDart>(
        'hoshidicts_destroy');
    addTermDict = _lib.lookupFunction<_AddDictNative, _AddDictDart>(
        'hoshidicts_add_term_dict');
    addFreqDict = _lib.lookupFunction<_AddDictNative, _AddDictDart>(
        'hoshidicts_add_freq_dict');
    addPitchDict = _lib.lookupFunction<_AddDictNative, _AddDictDart>(
        'hoshidicts_add_pitch_dict');
    addKanjiDict = _lib.lookupFunction<_AddDictNative, _AddDictDart>(
        'hoshidicts_add_kanji_dict');
    loadTransforms = _lib.lookupFunction<
        Void Function(Pointer<Void>, Pointer<Utf8>),
        _LoadTransformsDart>('hoshidicts_load_transforms');
    query = _lib.lookupFunction<
        FfiQueryResult Function(Pointer<Void>, Pointer<Utf8>),
        _QueryDart>('hoshidicts_query');
    freeQueryResult = _lib.lookupFunction<
        Void Function(Pointer<FfiQueryResult>),
        _FreeQueryResultDart>('hoshidicts_free_query_result');
    lookup = _lib.lookupFunction<
        FfiLookupResults Function(Pointer<Void>, Pointer<Utf8>, Int32, Int32),
        _LookupDart>('hoshidicts_lookup');
    freeLookupResults = _lib.lookupFunction<
        Void Function(Pointer<FfiLookupResults>),
        _FreeLookupResultsDart>('hoshidicts_free_lookup_results');
    getStyles = _lib.lookupFunction<FfiDictStyles Function(Pointer<Void>),
        _GetStylesDart>('hoshidicts_get_styles');
    freeStyles = _lib.lookupFunction<Void Function(Pointer<FfiDictStyles>),
        _FreeStylesDart>('hoshidicts_free_styles');
    getMedia = _lib.lookupFunction<
        FfiMediaFile Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>),
        _GetMediaDart>('hoshidicts_get_media');
    freeMedia = _lib.lookupFunction<Void Function(Pointer<FfiMediaFile>),
        _FreeMediaDart>('hoshidicts_free_media');
    queryKanji = _lib.lookupFunction<
        FfiKanjiResults Function(Pointer<Void>, Pointer<Utf8>),
        _QueryKanjiDart>('hoshidicts_query_kanji');
    freeKanjiResults = _lib.lookupFunction<
        Void Function(Pointer<FfiKanjiResults>),
        _FreeKanjiResultsDart>('hoshidicts_free_kanji_results');
    lookupPopupJson = _lib.lookupFunction<
        Pointer<Utf8> Function(
            Pointer<Void>, Pointer<Utf8>, Int32, Int32, Int32),
        _LookupPopupJsonDart>('hoshidicts_lookup_popup_json');
    freeString =
        _lib.lookupFunction<Void Function(Pointer<Utf8>), _FreeStringDart>(
            'hoshidicts_free_string');
  }
  late final DynamicLibrary _lib;

  late final _ImportDart import_;
  late final _ProbeDictContentDart probeDictContent;
  late final _FreeImportResultDart freeImportResult;
  late final _CreateDart create;
  late final _DestroyDart destroy;
  late final _AddDictDart addTermDict;
  late final _AddDictDart addFreqDict;
  late final _AddDictDart addPitchDict;
  late final _AddDictDart addKanjiDict;
  late final _LoadTransformsDart loadTransforms;
  late final _QueryDart query;
  late final _FreeQueryResultDart freeQueryResult;
  late final _LookupDart lookup;
  late final _FreeLookupResultsDart freeLookupResults;
  late final _GetStylesDart getStyles;
  late final _FreeStylesDart freeStyles;
  late final _GetMediaDart getMedia;
  late final _FreeMediaDart freeMedia;
  late final _QueryKanjiDart queryKanji;
  late final _FreeKanjiResultsDart freeKanjiResults;
  late final _LookupPopupJsonDart lookupPopupJson;
  late final _FreeStringDart freeString;
}
