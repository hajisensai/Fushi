import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

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
  external int tagCount;
  @Int32()
  external int mediaCount;
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

// ── native function typedefs ────────────────────────────────────────

typedef _ImportNative = FfiImportResult Function(
    Pointer<Utf8> zipPath, Pointer<Utf8> outputDir);
typedef _ImportDart = FfiImportResult Function(
    Pointer<Utf8> zipPath, Pointer<Utf8> outputDir);

typedef _FreeImportResultNative = Void Function(Pointer<FfiImportResult> r);
typedef _FreeImportResultDart = void Function(Pointer<FfiImportResult> r);

typedef _CreateNative = Pointer<Void> Function();
typedef _CreateDart = Pointer<Void> Function();

typedef _DestroyNative = Void Function(Pointer<Void> handle);
typedef _DestroyDart = void Function(Pointer<Void> handle);

typedef _AddDictNative = Void Function(
    Pointer<Void> handle, Pointer<Utf8> path);
typedef _AddDictDart = void Function(
    Pointer<Void> handle, Pointer<Utf8> path);

typedef _LoadTransformsNative = Void Function(
    Pointer<Void> handle, Pointer<Utf8> json);
typedef _LoadTransformsDart = void Function(
    Pointer<Void> handle, Pointer<Utf8> json);

typedef _QueryNative = FfiQueryResult Function(
    Pointer<Void> handle, Pointer<Utf8> expression);
typedef _QueryDart = FfiQueryResult Function(
    Pointer<Void> handle, Pointer<Utf8> expression);

typedef _FreeQueryResultNative = Void Function(Pointer<FfiQueryResult> r);
typedef _FreeQueryResultDart = void Function(Pointer<FfiQueryResult> r);

typedef _LookupNative = FfiLookupResults Function(
    Pointer<Void> handle, Pointer<Utf8> text, Int32 maxResults, Int32 scanLength);
typedef _LookupDart = FfiLookupResults Function(
    Pointer<Void> handle, Pointer<Utf8> text, int maxResults, int scanLength);

typedef _FreeLookupResultsNative = Void Function(Pointer<FfiLookupResults> r);
typedef _FreeLookupResultsDart = void Function(Pointer<FfiLookupResults> r);

typedef _GetStylesNative = FfiDictStyles Function(Pointer<Void> handle);
typedef _GetStylesDart = FfiDictStyles Function(Pointer<Void> handle);

typedef _FreeStylesNative = Void Function(Pointer<FfiDictStyles> r);
typedef _FreeStylesDart = void Function(Pointer<FfiDictStyles> r);

typedef _GetMediaNative = FfiMediaFile Function(
    Pointer<Void> handle, Pointer<Utf8> dictName, Pointer<Utf8> mediaPath);
typedef _GetMediaDart = FfiMediaFile Function(
    Pointer<Void> handle, Pointer<Utf8> dictName, Pointer<Utf8> mediaPath);

typedef _FreeMediaNative = Void Function(Pointer<FfiMediaFile> r);
typedef _FreeMediaDart = void Function(Pointer<FfiMediaFile> r);

// ── bindings class ──────────────────────────────────────────────────

class HoshidictsFfiBindings {
  late final DynamicLibrary _lib;

  late final _ImportDart import_;
  late final _FreeImportResultDart freeImportResult;
  late final _CreateDart create;
  late final _DestroyDart destroy;
  late final _AddDictDart addTermDict;
  late final _AddDictDart addFreqDict;
  late final _AddDictDart addPitchDict;
  late final _LoadTransformsDart loadTransforms;
  late final _QueryDart query;
  late final _FreeQueryResultDart freeQueryResult;
  late final _LookupDart lookup;
  late final _FreeLookupResultsDart freeLookupResults;
  late final _GetStylesDart getStyles;
  late final _FreeStylesDart freeStyles;
  late final _GetMediaDart getMedia;
  late final _FreeMediaDart freeMedia;

  HoshidictsFfiBindings() {
    _lib = Platform.isAndroid
        ? DynamicLibrary.open('libhoshidicts_ffi.so')
        : throw UnsupportedError('hoshidicts only supports Android');

    import_ = _lib
        .lookupFunction<_ImportNative, _ImportDart>('hoshidicts_import');
    freeImportResult = _lib.lookupFunction<_FreeImportResultNative,
        _FreeImportResultDart>('hoshidicts_free_import_result');
    create =
        _lib.lookupFunction<_CreateNative, _CreateDart>('hoshidicts_create');
    destroy =
        _lib.lookupFunction<_DestroyNative, _DestroyDart>('hoshidicts_destroy');
    addTermDict = _lib.lookupFunction<_AddDictNative, _AddDictDart>(
        'hoshidicts_add_term_dict');
    addFreqDict = _lib.lookupFunction<_AddDictNative, _AddDictDart>(
        'hoshidicts_add_freq_dict');
    addPitchDict = _lib.lookupFunction<_AddDictNative, _AddDictDart>(
        'hoshidicts_add_pitch_dict');
    loadTransforms = _lib.lookupFunction<_LoadTransformsNative,
        _LoadTransformsDart>('hoshidicts_load_transforms');
    query =
        _lib.lookupFunction<_QueryNative, _QueryDart>('hoshidicts_query');
    freeQueryResult = _lib.lookupFunction<_FreeQueryResultNative,
        _FreeQueryResultDart>('hoshidicts_free_query_result');
    lookup =
        _lib.lookupFunction<_LookupNative, _LookupDart>('hoshidicts_lookup');
    freeLookupResults = _lib.lookupFunction<_FreeLookupResultsNative,
        _FreeLookupResultsDart>('hoshidicts_free_lookup_results');
    getStyles = _lib
        .lookupFunction<_GetStylesNative, _GetStylesDart>('hoshidicts_get_styles');
    freeStyles = _lib
        .lookupFunction<_FreeStylesNative, _FreeStylesDart>('hoshidicts_free_styles');
    getMedia = _lib
        .lookupFunction<_GetMediaNative, _GetMediaDart>('hoshidicts_get_media');
    freeMedia = _lib
        .lookupFunction<_FreeMediaNative, _FreeMediaDart>('hoshidicts_free_media');
  }
}
