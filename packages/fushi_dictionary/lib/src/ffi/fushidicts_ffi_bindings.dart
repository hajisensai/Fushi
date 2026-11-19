import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

DynamicLibrary _openNativeLib() {
  // 宿主显式给了绝对路径（无头服务端按 bundle 布局 `bin/../lib/` 定位）就只认它：
  // 找错库时宁可在这里抛出，也不悄悄退回裸名加载一份别处的旧库。
  final String? override = FushidictsFfiBindings.libraryPathOverride;
  if (override != null && override.isNotEmpty) {
    return DynamicLibrary.open(override);
  }
  if (Platform.isAndroid) return DynamicLibrary.open('libfushidicts_ffi.so');
  if (Platform.isWindows) return DynamicLibrary.open('fushidicts_ffi.dll');
  if (Platform.isMacOS) return DynamicLibrary.open('libfushidicts_ffi.dylib');
  if (Platform.isLinux) return _openLinuxBundled('libfushidicts_ffi.so');
  if (Platform.isIOS) return DynamicLibrary.process();
  throw UnsupportedError(
    'fushidicts: unsupported platform ${Platform.operatingSystem}',
  );
}

/// Linux bundle 把随包 .so 装在 `<exe 目录>/lib/`。runner 的 RUNPATH
/// (`$ORIGIN/lib`) 只作用于 exe 自己的直接依赖，**不**作用于 Dart VM（在
/// libflutter_linux_gtk.so 里）发起的 `dlopen`，所以裸名加载找不到它——
/// pdfium_dart 在 Linux 上同样按这个绝对路径加载。exe 旁没有（flutter test /
/// 纯 Dart 宿主）时退回裸名，交给 LD_LIBRARY_PATH / 系统路径。
DynamicLibrary _openLinuxBundled(String name) {
  final String bundled =
      '${File(Platform.resolvedExecutable).parent.path}/lib/$name';
  if (File(bundled).existsSync()) return DynamicLibrary.open(bundled);
  return DynamicLibrary.open(name);
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
  external Pointer<Pointer<Utf8>> transcriptions;
  @Int32()
  external int transcriptionCount;
  // 79c55c2 二期：pattern 式 accent（"heiban" 等字符串位）；与 native FfiPitch
  // 字段顺序严格镜像。
  external Pointer<Pointer<Utf8>> patterns;
  @Int32()
  external int patternCount;
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

/// `fushidicts_tokenize` 的返回：每段的 UTF-16 码元数（+ 可选的每段读音）。
final class FfiTokenizeResult extends Struct {
  external Pointer<Int32> lengths;
  external Pointer<Pointer<Utf8>> readings;
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
  // v2 词典的完整 stats 键值对（JLPT/grade 等）；与 native FfiKanjiResult 字段
  // 顺序严格镜像（stat_keys/stat_values 平行数组，长度 statCount）。
  external Pointer<Pointer<Utf8>> statKeys;
  external Pointer<Pointer<Utf8>> statValues;
  @Int32()
  external int statCount;
  external Pointer<Utf8> dictName;
}

final class FfiKanjiResults extends Struct {
  external Pointer<FfiKanjiResult> results;
  @Int32()
  external int count;
}

// ── native function typedefs ────────────────────────────────────────

typedef _ImportDart =
    FfiImportResult Function(
      Pointer<Utf8> zipPath,
      Pointer<Utf8> outputDir,
      Pointer<Utf8> breadcrumbDir,
    );

typedef _ProbeDictContentNative = Int32 Function(Pointer<Utf8> dir);
typedef _ProbeDictContentDart = int Function(Pointer<Utf8> dir);

typedef _FreeImportResultDart = void Function(Pointer<FfiImportResult> r);

typedef _CreateDart = Pointer<Void> Function();

typedef _DestroyDart = void Function(Pointer<Void> handle);

typedef _AddDictNative =
    Void Function(Pointer<Void> handle, Pointer<Utf8> path);
typedef _AddDictDart = void Function(Pointer<Void> handle, Pointer<Utf8> path);
typedef _AddTermDictWithLanguageNative =
    Void Function(
      Pointer<Void> handle,
      Pointer<Utf8> path,
      Pointer<Utf8> language,
    );
typedef _AddTermDictWithLanguageDart =
    void Function(
      Pointer<Void> handle,
      Pointer<Utf8> path,
      Pointer<Utf8> language,
    );

typedef _PrepareUnionFilterNative =
    Void Function(Pointer<Void> handle, Pointer<Utf8> cacheDir, Int32 wait);
typedef _PrepareUnionFilterDart =
    void Function(Pointer<Void> handle, Pointer<Utf8> cacheDir, int wait);
typedef _UnionFilterStateDart = int Function(Pointer<Void> handle);

typedef _LoadTransformsDart =
    void Function(Pointer<Void> handle, Pointer<Utf8> json);

typedef _QueryDart =
    FfiQueryResult Function(Pointer<Void> handle, Pointer<Utf8> expression);

typedef _FreeQueryResultDart = void Function(Pointer<FfiQueryResult> r);

typedef _LookupDart =
    FfiLookupResults Function(
      Pointer<Void> handle,
      Pointer<Utf8> text,
      int maxResults,
      int scanLength,
    );

typedef _LookupWithOptionsDart =
    FfiLookupResults Function(
      Pointer<Void> handle,
      Pointer<Utf8> text,
      int maxResults,
      int scanLength,
      Pointer<Utf8> freqDict,
      int freqOrder,
      Pointer<Utf8> primaryReading,
    );

// 带 flags 的 lookup（bit0 = 中文简→繁回落）；老导出签名不动。
typedef _LookupWithFlagsDart =
    FfiLookupResults Function(
      Pointer<Void> handle,
      Pointer<Utf8> text,
      int maxResults,
      int scanLength,
      Pointer<Utf8> freqDict,
      int freqOrder,
      Pointer<Utf8> primaryReading,
      int flags,
    );

// 带原文振假名的 lookup：rubyBounds = 2*rubyCount 个查询串码点偏移（start, end 交替），
// rubyReadings = rubyCount 个 <rt> 读音以 U+001F 连接。
typedef _LookupWithRubyDart =
    FfiLookupResults Function(
      Pointer<Void> handle,
      Pointer<Utf8> text,
      int maxResults,
      int scanLength,
      Pointer<Utf8> freqDict,
      int freqOrder,
      Pointer<Utf8> primaryReading,
      int flags,
      Pointer<Int32> rubyBounds,
      Pointer<Utf8> rubyReadings,
      int rubyCount,
    );

// 带排除词典的 lookup（其余参数同 [_LookupWithRubyDart]，无 ruby 时传 nullptr / 0）：
// excludedNames = excludedCount 个 NUL 结尾 UTF-8 词典名的指针数组。
typedef _LookupWithExclusionsDart =
    FfiLookupResults Function(
      Pointer<Void> handle,
      Pointer<Utf8> text,
      int maxResults,
      int scanLength,
      Pointer<Utf8> freqDict,
      int freqOrder,
      Pointer<Utf8> primaryReading,
      int flags,
      Pointer<Int32> rubyBounds,
      Pointer<Utf8> rubyReadings,
      int rubyCount,
      Pointer<Pointer<Utf8>> excludedNames,
      int excludedCount,
    );

typedef _FreeLookupResultsDart = void Function(Pointer<FfiLookupResults> r);

typedef _GetStylesDart = FfiDictStyles Function(Pointer<Void> handle);

typedef _FreeStylesDart = void Function(Pointer<FfiDictStyles> r);

typedef _GetMediaDart =
    FfiMediaFile Function(
      Pointer<Void> handle,
      Pointer<Utf8> dictName,
      Pointer<Utf8> mediaPath,
    );

typedef _FreeMediaDart = void Function(Pointer<FfiMediaFile> r);

typedef _QueryKanjiDart =
    FfiKanjiResults Function(Pointer<Void> handle, Pointer<Utf8> character);

typedef _FreeKanjiResultsDart = void Function(Pointer<FfiKanjiResults> r);

typedef _LookupPopupJsonDart =
    Pointer<Utf8> Function(
      Pointer<Void> handle,
      Pointer<Utf8> text,
      int maxResults,
      int scanLength,
      int maxTerms,
    );

typedef _FreeStringDart = void Function(Pointer<Utf8> s);

// [text] 是带长 UTF-8 缓冲（[textBytes] 字节，不靠结尾 NUL 定界）：Dart 字符串里
// 合法的 U+0000 是正文的一部分（HBK-AUDIT-007）。
typedef _TokenizeNative =
    FfiTokenizeResult Function(
      Pointer<Void> handle,
      Pointer<Uint8> text,
      Int32 textBytes,
      Int32 scanLength,
      Int32 withReadings,
    );
typedef _TokenizeDart =
    FfiTokenizeResult Function(
      Pointer<Void> handle,
      Pointer<Uint8> text,
      int textBytes,
      int scanLength,
      int withReadings,
    );

typedef _FreeTokenizeResultDart = void Function(Pointer<FfiTokenizeResult> r);

typedef _MatchLengthNative =
    Int32 Function(Pointer<Void> handle, Pointer<Utf8> text, Int32 scanLength);
typedef _MatchLengthDart =
    int Function(Pointer<Void> handle, Pointer<Utf8> text, int scanLength);

typedef _RetainDart = int Function(Pointer<Void> handle);

// ── bindings class ──────────────────────────────────────────────────

class FushidictsFfiBindings {
  /// 原生库的绝对路径覆盖（null = 各平台默认的裸名 / exe 旁 `lib/` 搜索）。
  ///
  /// isolate 局部：后台 isolate（`FushiDicts.importDictionary`）由调用方带过去。
  /// 必须在首次创建绑定（首个 `FushiDicts` 实例 / 导入 / 探测）之前设好——绑定
  /// 一旦创建就缓存，之后改它不会换库。
  static String? libraryPathOverride;

  FushidictsFfiBindings() {
    _lib = _openNativeLib();

    import_ = _lib
        .lookupFunction<
          FfiImportResult Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>),
          _ImportDart
        >('fushidicts_import');
    probeDictContent = _lib
        .lookupFunction<_ProbeDictContentNative, _ProbeDictContentDart>(
          'fushidicts_probe_dict_content',
        );
    freeImportResult = _lib
        .lookupFunction<
          Void Function(Pointer<FfiImportResult>),
          _FreeImportResultDart
        >('fushidicts_free_import_result');
    create = _lib.lookupFunction<Pointer<Void> Function(), _CreateDart>(
      'fushidicts_create',
    );
    destroy = _lib.lookupFunction<Void Function(Pointer<Void>), _DestroyDart>(
      'fushidicts_destroy',
    );
    retain = _lib.lookupFunction<Int32 Function(Pointer<Void>), _RetainDart>(
      'fushidicts_retain',
    );
    release = _lib.lookupFunction<Void Function(Pointer<Void>), _DestroyDart>(
      'fushidicts_release',
    );
    addTermDict = _lib.lookupFunction<_AddDictNative, _AddDictDart>(
      'fushidicts_add_term_dict',
    );
    addTermDictWithLanguage = _lib
        .lookupFunction<
          _AddTermDictWithLanguageNative,
          _AddTermDictWithLanguageDart
        >('fushidicts_add_term_dict_with_language');
    addFreqDict = _lib.lookupFunction<_AddDictNative, _AddDictDart>(
      'fushidicts_add_freq_dict',
    );
    addPitchDict = _lib.lookupFunction<_AddDictNative, _AddDictDart>(
      'fushidicts_add_pitch_dict',
    );
    addKanjiDict = _lib.lookupFunction<_AddDictNative, _AddDictDart>(
      'fushidicts_add_kanji_dict',
    );
    prepareUnionFilter = _lib
        .lookupFunction<_PrepareUnionFilterNative, _PrepareUnionFilterDart>(
          'fushidicts_prepare_union_filter',
        );
    unionFilterState = _lib
        .lookupFunction<Int32 Function(Pointer<Void>), _UnionFilterStateDart>(
          'fushidicts_union_filter_state',
        );
    loadTransforms = _lib
        .lookupFunction<
          Void Function(Pointer<Void>, Pointer<Utf8>),
          _LoadTransformsDart
        >('fushidicts_load_transforms');
    query = _lib
        .lookupFunction<
          FfiQueryResult Function(Pointer<Void>, Pointer<Utf8>),
          _QueryDart
        >('fushidicts_query');
    queryFrequencies = _lib
        .lookupFunction<
          FfiQueryResult Function(Pointer<Void>, Pointer<Utf8>),
          _QueryDart
        >('fushidicts_query_frequencies');
    freeQueryResult = _lib
        .lookupFunction<
          Void Function(Pointer<FfiQueryResult>),
          _FreeQueryResultDart
        >('fushidicts_free_query_result');
    lookup = _lib
        .lookupFunction<
          FfiLookupResults Function(Pointer<Void>, Pointer<Utf8>, Int32, Int32),
          _LookupDart
        >('fushidicts_lookup');
    lookupWithOptions = _lib
        .lookupFunction<
          FfiLookupResults Function(
            Pointer<Void>,
            Pointer<Utf8>,
            Int32,
            Int32,
            Pointer<Utf8>,
            Int32,
            Pointer<Utf8>,
          ),
          _LookupWithOptionsDart
        >('fushidicts_lookup_with_options');
    lookupWithFlags = _lib
        .lookupFunction<
          FfiLookupResults Function(
            Pointer<Void>,
            Pointer<Utf8>,
            Int32,
            Int32,
            Pointer<Utf8>,
            Int32,
            Pointer<Utf8>,
            Int32,
          ),
          _LookupWithFlagsDart
        >('fushidicts_lookup_with_flags');
    lookupWithRuby = _lib
        .lookupFunction<
          FfiLookupResults Function(
            Pointer<Void>,
            Pointer<Utf8>,
            Int32,
            Int32,
            Pointer<Utf8>,
            Int32,
            Pointer<Utf8>,
            Int32,
            Pointer<Int32>,
            Pointer<Utf8>,
            Int32,
          ),
          _LookupWithRubyDart
        >('fushidicts_lookup_with_ruby');
    lookupWithExclusions = _lib
        .lookupFunction<
          FfiLookupResults Function(
            Pointer<Void>,
            Pointer<Utf8>,
            Int32,
            Int32,
            Pointer<Utf8>,
            Int32,
            Pointer<Utf8>,
            Int32,
            Pointer<Int32>,
            Pointer<Utf8>,
            Int32,
            Pointer<Pointer<Utf8>>,
            Int32,
          ),
          _LookupWithExclusionsDart
        >('fushidicts_lookup_with_exclusions');
    freeLookupResults = _lib
        .lookupFunction<
          Void Function(Pointer<FfiLookupResults>),
          _FreeLookupResultsDart
        >('fushidicts_free_lookup_results');
    getStyles = _lib
        .lookupFunction<FfiDictStyles Function(Pointer<Void>), _GetStylesDart>(
          'fushidicts_get_styles',
        );
    freeStyles = _lib
        .lookupFunction<Void Function(Pointer<FfiDictStyles>), _FreeStylesDart>(
          'fushidicts_free_styles',
        );
    getMedia = _lib
        .lookupFunction<
          FfiMediaFile Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>),
          _GetMediaDart
        >('fushidicts_get_media');
    freeMedia = _lib
        .lookupFunction<Void Function(Pointer<FfiMediaFile>), _FreeMediaDart>(
          'fushidicts_free_media',
        );
    queryKanji = _lib
        .lookupFunction<
          FfiKanjiResults Function(Pointer<Void>, Pointer<Utf8>),
          _QueryKanjiDart
        >('fushidicts_query_kanji');
    freeKanjiResults = _lib
        .lookupFunction<
          Void Function(Pointer<FfiKanjiResults>),
          _FreeKanjiResultsDart
        >('fushidicts_free_kanji_results');
    lookupPopupJson = _lib
        .lookupFunction<
          Pointer<Utf8> Function(
            Pointer<Void>,
            Pointer<Utf8>,
            Int32,
            Int32,
            Int32,
          ),
          _LookupPopupJsonDart
        >('fushidicts_lookup_popup_json');
    freeString = _lib
        .lookupFunction<Void Function(Pointer<Utf8>), _FreeStringDart>(
          'fushidicts_free_string',
        );
    tokenize = _lib.lookupFunction<_TokenizeNative, _TokenizeDart>(
      'fushidicts_tokenize',
    );
    freeTokenizeResult = _lib
        .lookupFunction<
          Void Function(Pointer<FfiTokenizeResult>),
          _FreeTokenizeResultDart
        >('fushidicts_free_tokenize_result');
    matchLength = _lib.lookupFunction<_MatchLengthNative, _MatchLengthDart>(
      'fushidicts_match_length',
    );
  }
  late final DynamicLibrary _lib;

  late final _ImportDart import_;
  late final _ProbeDictContentDart probeDictContent;
  late final _FreeImportResultDart freeImportResult;
  late final _CreateDart create;

  /// `fushidicts_destroy` 是**退役**：还掉宿主的引用，在飞借用（[retain]）都还完才销毁。
  late final _DestroyDart destroy;

  /// 借一个句柄引用（1 = 借到，0 = 已退役）。调用方必须自己仍持有一个引用。
  late final _RetainDart retain;

  /// 还一个 [retain] 借来的引用；最后一个归还时销毁句柄（解除文件映射）。
  late final _DestroyDart release;
  late final _AddDictDart addTermDict;

  /// 同 [addTermDict]，另带这本词典词头的语言（BCP-47）。标了语言的词典只接受本语言
  /// 变形表还原出来的词形，见 native `DictionaryQuery::add_term_dict`。
  late final _AddTermDictWithLanguageDart addTermDictWithLanguage;
  late final _AddDictDart addFreqDict;
  late final _AddDictDart addPitchDict;
  late final _AddDictDart addKanjiDict;

  /// 准备联合过滤器（跨词典的键过滤器，纯加速、不改结果）。`cacheDir` 空串 = 只在
  /// 内存里建；`wait` 0 = 立刻返回、引擎在自己的后台线程里建。
  late final _PrepareUnionFilterDart prepareUnionFilter;

  /// 联合过滤器状态：0 没有 / 1 后台构建中 / 2 已就绪。
  late final _UnionFilterStateDart unionFilterState;
  late final _LoadTransformsDart loadTransforms;
  late final _QueryDart query;

  /// 只要词频的 [query]：词条的 glossary / pitch 恒为空（原生不富化音调、不解压释义）。
  /// 结果同样用 [freeQueryResult] 释放。
  late final _QueryDart queryFrequencies;
  late final _FreeQueryResultDart freeQueryResult;
  late final _LookupDart lookup;
  late final _LookupWithOptionsDart lookupWithOptions;
  late final _LookupWithFlagsDart lookupWithFlags;
  late final _LookupWithRubyDart lookupWithRuby;
  late final _LookupWithExclusionsDart lookupWithExclusions;
  late final _FreeLookupResultsDart freeLookupResults;
  late final _GetStylesDart getStyles;
  late final _FreeStylesDart freeStyles;
  late final _GetMediaDart getMedia;
  late final _FreeMediaDart freeMedia;
  late final _QueryKanjiDart queryKanji;
  late final _FreeKanjiResultsDart freeKanjiResults;
  late final _LookupPopupJsonDart lookupPopupJson;
  late final _FreeStringDart freeString;
  late final _TokenizeDart tokenize;
  late final _FreeTokenizeResultDart freeTokenizeResult;
  late final _MatchLengthDart matchLength;
}

// ── 已导入词典的 redirect_glossary.flag 迁移（按需解析） ──────────────

typedef _EnsureRedirectFlagNative = Int32 Function(Pointer<Utf8> dir);
typedef EnsureRedirectFlagDart = int Function(Pointer<Utf8> dir);

/// `fushidicts_ensure_redirect_flag` 的绑定，**用到时才解析**（理由同
/// [lookupZstdDecompressFile]：这是一次性迁移，随包旧库缺这个导出时只让迁移报
/// 「不支持」，不能连累整套查词绑定在构造时抛）。
///
/// 原生语义（`query.cpp` 的 `ensure_redirect_glossary_flag`）：已有与当前 blobs.bin
/// 大小一致的标记文件就直接读它返回；否则整本扫描（单本最多约 1 s）并写回标记。
/// 返回 1 = 含纯重定向 glossary，0 = 不含，-1 = 读不了。不需要查询句柄。
EnsureRedirectFlagDart? lookupEnsureRedirectFlag() {
  try {
    return _openNativeLib()
        .lookupFunction<_EnsureRedirectFlagNative, EnsureRedirectFlagDart>(
          'fushidicts_ensure_redirect_flag',
        );
  } on ArgumentError {
    return null;
  }
}

// ── 存量词典原地升级（按需解析） ───────────────────────────────────

typedef _UpgradeDictionaryNative =
    Int32 Function(Pointer<Utf8> dictDir, Int32 allowMetaRewrite);
typedef UpgradeDictionaryDart =
    int Function(Pointer<Utf8> dictDir, int allowMetaRewrite);

/// `fushidicts_upgrade_dictionary` 的绑定，**用到时才解析**（理由同
/// [lookupEnsureRedirectFlag]：一次性迁移，随包旧库缺这个导出时只让升级报「不支持」，
/// 不能连累整套查词绑定在构造时抛）。
///
/// 原生语义（`fushidicts/upgrade.hpp`）：把旧式索引换成新索引、纯 freq / pitch / ipa
/// 词典（`allowMetaRewrite` 非 0 时）顺带预解析记录。只创建新文件再改名提交，引擎正
/// 装着这本词典时也能调；新索引在下一次装载时生效。返回 0 已是最新（顺带清理遗留
/// 旧文件）/ 1 已升级 / 2 不适用（保持旧式、照常可用）/ -1 失败（词典原样可用）。
/// 不需要查询句柄；大词典单本可达秒级，必须放后台 isolate。
UpgradeDictionaryDart? lookupUpgradeDictionary() {
  try {
    return _openNativeLib()
        .lookupFunction<_UpgradeDictionaryNative, UpgradeDictionaryDart>(
          'fushidicts_upgrade_dictionary',
        );
  } on ArgumentError {
    return null;
  }
}

// ── zstd 文件解压（按需解析） ───────────────────────────────────────

typedef _ZstdDecompressFileNative =
    Int32 Function(Pointer<Utf8> inPath, Pointer<Utf8> outPath);
typedef ZstdDecompressFileDart =
    int Function(Pointer<Utf8> inPath, Pointer<Utf8> outPath);

/// `fushidicts_zstd_decompress_file` 的绑定，**用到时才解析**。
///
/// 不放进 [FushidictsFfiBindings] 的构造函数：那里是急切查找，某个平台上随包
/// 的原生库若还是没有这个导出的旧版本，整套查词绑定会在构造时一起抛。单独解析
/// 让缺符号只影响这一个功能（返回 null，调用方报「本平台不支持」）。
ZstdDecompressFileDart? lookupZstdDecompressFile() {
  try {
    return _openNativeLib()
        .lookupFunction<_ZstdDecompressFileNative, ZstdDecompressFileDart>(
          'fushidicts_zstd_decompress_file',
        );
  } on ArgumentError {
    return null;
  }
}

// ── 语料词元（「我库里的例句」，按需解析） ───────────────────────────────

typedef _CorpusTermsNative =
    Int32 Function(
      Pointer<Void> handle,
      Pointer<Uint8> input,
      Int32 inputLen,
      Int32 scanLength,
      Pointer<Pointer<Uint8>> out,
      Pointer<Int32> outLen,
    );
typedef CorpusTermsDart =
    int Function(
      Pointer<Void> handle,
      Pointer<Uint8> input,
      int inputLen,
      int scanLength,
      Pointer<Pointer<Uint8>> out,
      Pointer<Int32> outLen,
    );
typedef _FreeBytesNative = Void Function(Pointer<Uint8> p);
typedef FreeBytesDart = void Function(Pointer<Uint8> p);

/// `fushidicts_corpus_terms` / `fushidicts_free_bytes` 的绑定，**用到时才解析**（理由同
/// [lookupZstdDecompressFile]：这是「我库里的例句」建索引的喂入路径，随包旧库缺这个导出
/// 时只让建索引报不可用，不连累查词绑定）。线格式见 native/fushidicts/fushidicts_ffi.cpp。
({CorpusTermsDart corpusTerms, FreeBytesDart freeBytes})? lookupCorpusTerms() {
  try {
    final DynamicLibrary lib = _openNativeLib();
    return (
      corpusTerms: lib.lookupFunction<_CorpusTermsNative, CorpusTermsDart>(
        'fushidicts_corpus_terms',
      ),
      freeBytes: lib.lookupFunction<_FreeBytesNative, FreeBytesDart>(
        'fushidicts_free_bytes',
      ),
    );
  } on ArgumentError {
    return null;
  }
}
