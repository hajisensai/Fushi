import 'dart:async';
import 'dart:collection';
import 'dart:convert' show jsonDecode, utf8;
import 'dart:ffi';
import 'dart:io' show Directory;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_core/fushi_core.dart' show fushiDebugPrint;
import 'package:fushi_ffi_view/fushi_ffi_view.dart';
import 'package:meta/meta.dart';

import '../ffi/fushidicts_ffi_bindings.dart';
import '../language/language.dart'
    show buildPopupJsonFromLookup, buildResultFromLookup;
import '../language/transform_description_i18n.dart';
import '../models/dictionary_search_result.dart';
import 'background_borrow.dart';
import 'lookup_scheduler.dart';
import 'ruby_spans.dart';
// 变形表资源的读法按宿主分：Flutter app 走 rootBundle（`dart.library.ui` 分支），
// 纯 Dart 宿主（无头服务端）落到 stub，改用 [FushiDicts.preloadTransformsFrom]
// 自己读文件。本文件因此零 Flutter，可进 fushi_dictionary_core 子 barrel。
import 'transform_asset_loader_stub.dart'
    if (dart.library.ui) 'transform_asset_loader_flutter.dart';
import 'fushidicts_models.dart';

export 'fushidicts_models.dart';
export 'background_borrow.dart' show BackgroundBorrowLedger, borrowNativeHandle;
export 'lookup_scheduler.dart' show LookupJobScheduler;
export 'ruby_spans.dart';

part 'background_lookup.dart';

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
    return utf8.decode(bytes.asTypedListOutOfLine(len), allowMalformed: true);
  }
}

FushiTermResult _convertTerm(FfiTermResult ffi) {
  final glossaries = <FushiGlossaryEntry>[];
  if (ffi.glossaryCount > 0 && ffi.glossaries != nullptr) {
    for (int i = 0; i < ffi.glossaryCount; i++) {
      final g = ffi.glossaries[i];
      glossaries.add(
        FushiGlossaryEntry(
          dictName: _utf8OrEmpty(g.dictName),
          glossary: _utf8OrEmpty(g.glossary),
          definitionTags: _utf8OrEmpty(g.definitionTags),
          termTags: _utf8OrEmpty(g.termTags),
        ),
      );
    }
  }

  final frequencies = <FushiFrequencyEntry>[];
  if (ffi.frequencyCount > 0 && ffi.frequencies != nullptr) {
    for (int i = 0; i < ffi.frequencyCount; i++) {
      final f = ffi.frequencies[i];
      final freqs = <FushiFrequency>[];
      for (int j = 0; j < f.count; j++) {
        freqs.add(
          FushiFrequency(
            value: f.values[j],
            displayValue: _utf8OrEmpty(f.displayValues[j]),
          ),
        );
      }
      frequencies.add(
        FushiFrequencyEntry(
          dictName: _utf8OrEmpty(f.dictName),
          frequencies: freqs,
        ),
      );
    }
  }

  final pitches = <FushiPitchEntry>[];
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
      final patterns = <String>[];
      if (p.patternCount > 0 && p.patterns != nullptr) {
        for (int j = 0; j < p.patternCount; j++) {
          patterns.add(_utf8OrEmpty(p.patterns[j]));
        }
      }
      pitches.add(
        FushiPitchEntry(
          dictName: _utf8OrEmpty(p.dictName),
          pitchPositions: positions,
          patterns: patterns,
          transcriptions: transcriptions,
        ),
      );
    }
  }

  return FushiTermResult(
    expression: _utf8OrEmpty(ffi.expression),
    reading: _utf8OrEmpty(ffi.reading),
    rules: _utf8OrEmpty(ffi.rules),
    glossaries: glossaries,
    frequencies: frequencies,
    pitches: pitches,
  );
}

FushiKanjiResult _convertKanji(FfiKanjiResult ffi) {
  final meanings = <String>[];
  if (ffi.meaningCount > 0 && ffi.meanings != nullptr) {
    for (int i = 0; i < ffi.meaningCount; i++) {
      meanings.add(_utf8OrEmpty(ffi.meanings[i]));
    }
  }
  final stats = <String, String>{};
  if (ffi.statCount > 0 &&
      ffi.statKeys != nullptr &&
      ffi.statValues != nullptr) {
    for (int i = 0; i < ffi.statCount; i++) {
      final String key = _utf8OrEmpty(ffi.statKeys[i]);
      if (key.isEmpty) continue;
      stats[key] = _utf8OrEmpty(ffi.statValues[i]);
    }
  }
  return FushiKanjiResult(
    character: _utf8OrEmpty(ffi.character),
    onyomi: _utf8OrEmpty(ffi.onyomi),
    kunyomi: _utf8OrEmpty(ffi.kunyomi),
    radical: _utf8OrEmpty(ffi.radical),
    strokes: ffi.strokes,
    meanings: meanings,
    stats: stats,
    dictName: _utf8OrEmpty(ffi.dictName),
  );
}

/// [FushiDicts.tokenizeWithReadingsInBackground] 的后台 isolate debugName。
@visibleForTesting
const String kBackgroundTokenizeIsolateName = 'fushi-dict-tokenize';

/// 最近一次后台分词实际跑在哪个 isolate 上（debugName）；只给测试观测用。
@visibleForTesting
String? debugLastBackgroundTokenizeIsolate;

/// 与 fushidicts_ffi.cpp 的 `kLookupFlagChineseSimpToTrad` 同值。
const int _lookupFlagChineseSimpToTrad = 1;

// ── main wrapper class ──────────────────────────────────────────────

class FushiDicts {
  // ── lifecycle ──────────────────────────────────────────────────

  FushiDicts() {
    _bindings ??= FushidictsFfiBindings();
    final Pointer<Void> handle = _bindings!.create();
    // BUG-2110：FFI 闸门把 native 抛出的异常收敛成「返回零值」，于是 create 失败
    // 现在返回 nullptr 而不再 terminate。nullptr 是个**非 null 的 Pointer 对象**，
    // `_handle!` 拦不住它；放行下去每个导出都无条件解引用 handle → SIGSEGV，而
    // ffi_guard 接不住信号。在入口判掉，把不可诊断的段错误换成可诊断的异常。
    if (handle == nullptr) {
      throw StateError(
        'fushidicts_create returned nullptr (native engine unavailable)',
      );
    }
    _handle = handle;
  }
  static FushidictsFfiBindings? _bindings;
  Pointer<Void>? _handle;

  /// 引擎实例代次：每个新实例一个新号。后台查词 isolate 的原始结果缓存按它整体失效
  /// ——词典集合的任何变化都换新实例（见 [_applyTyped] / [loadPendingAsync]）。
  /// 不用句柄地址：旧句柄释放后新句柄可能复用同一地址。
  final int _serial = ++_serialCounter;
  static int _serialCounter = 0;

  // ── singleton ──────────────────────────────────────────────────
  static FushiDicts? _instance;
  static Map<String, String> _stylesCache = {};

  /// 当前引擎里装了几本词典。只服务 [releaseAllMappings] 的空转判断：
  /// 引擎本来就是空的时候没有 mmap view 要释放，重建纯属浪费
  /// （清空全部词典会逐本调一次）。
  static int _loadedDictCount = 0;

  /// 已排期但还没装载的词典集合（null = 引擎与元数据一致，没有待办）。
  ///
  /// 为什么要有这个「待办」而不是每次写元数据就地重建：重建 = 卸掉全部词典的
  /// 文件映射再逐本重新装回来，代价与**当前总词典数**成正比。而写元数据是逐本
  /// 发生的——批量导入 N 本就写 N 次，启动期的类型自愈也是逐本写——于是总代价
  /// 变成 O(N²)：导第 100 本时要把前 99 本卸了再装回去。词典一多，导入越来越慢，
  /// 启动更是直接卡死（用户报告：一次性导入很多词典后 app 打不开）。
  ///
  /// 排期后重建**只发生在真正要用引擎之前**（见 [instance] / [dictionaryStyles]）。
  /// 批量写入期间没人查词，于是 N 次排期塌成 1 次重建，而且不需要任何调用方声明
  /// 「我是批量的」——少写一个声明就退化回 O(N²) 的设计不算修好。
  static _PendingDicts? _pending;

  /// 原生库绝对路径覆盖（null = 平台默认的裸名 / exe 旁 `lib/` 搜索）。纯 Dart 宿主
  /// （无头服务端）按自己的 bundle 布局定位后在**首次用引擎之前**设好；绑定一旦创建
  /// 就缓存，之后再改不会换库。原始 FFI 绑定不对外导出（HBK-AUDIT-098），只开这一个口。
  static String? get nativeLibraryPath =>
      FushidictsFfiBindings.libraryPathOverride;
  static set nativeLibraryPath(String? path) =>
      FushidictsFfiBindings.libraryPathOverride = path;

  /// 联合过滤器的缓存目录（null = 不落盘，每次装载后在内存里现建）。
  ///
  /// 联合过滤器是原生引擎的派生索引：把全部词典的键并进一份分块 Bloom，一次查库读
  /// 一条缓存行就知道「这个键可能在哪几本词典里」，不必逐本探测。它不改查词结果、
  /// 不改词典目录，文件丢了 / 词典集合变了就自动重建，所以放缓存目录即可（**不要**
  /// 放进词典资源目录：那里的子目录会被当成词典盘点）。宿主在首次装载词典前设好；
  /// 之后才设也只是这一轮用内存版。
  static String? unionFilterCacheDirectory;

  /// 装完一套词典后让原生引擎在它自己的后台线程里备好联合过滤器。立刻返回；建好之前
  /// 查词照走各词典自己的过滤器，结果相同。引擎销毁时原生侧会叫停并收回那条线程。
  void _prepareUnionFilter() {
    final Pointer<Void>? handle = _handle;
    if (handle == null) return;
    final Pointer<Utf8> dir = (unionFilterCacheDirectory ?? '').toNativeUtf8(
      allocator: calloc,
    );
    try {
      _bindings!.prepareUnionFilter(handle, dir, 0);
    } finally {
      calloc.free(dir);
    }
  }

  /// 联合过滤器是否已就绪（给测试 / 诊断观测；查词不需要等它）。
  bool get unionFilterReady {
    final Pointer<Void>? handle = _handle;
    return handle != null && _bindings!.unionFilterState(handle) == 2;
  }

  static FushiDicts get instance {
    _applyPendingIfAny();
    assert(_instance != null, 'FushiDicts.initialize() must be called first');
    return _instance!;
  }

  /// 引擎是否可用。有待办时同样算已初始化：待办本身就说明词典集合已知，
  /// 调用方接着就会经 [instance] 触发结算。
  static bool get isInitialized => _instance != null || _pending != null;

  /// 把 zstd 压缩文件 [inPath] 流式解压到 [outPath]（覆盖写）。
  ///
  /// 借本原生库里已经静态链接的 libzstd，不需要任何词典句柄，可在后台 isolate
  /// 里调用。用途：Anki 2.1.50+ 备份里的 `collection.anki21b`。
  ///
  /// 失败抛 [FushiZstdException]；随包原生库还没有这个导出时抛
  /// [UnsupportedError]。
  static void zstdDecompressFile(String inPath, String outPath) {
    final ZstdDecompressFileDart? decompress = lookupZstdDecompressFile();
    if (decompress == null) {
      throw UnsupportedError(
        'fushidicts_zstd_decompress_file is not available in this build',
      );
    }
    final Pointer<Utf8> nativeIn = inPath.toNativeUtf8(allocator: calloc);
    final Pointer<Utf8> nativeOut = outPath.toNativeUtf8(allocator: calloc);
    try {
      final int code = decompress(nativeIn, nativeOut);
      if (code != 0) throw FushiZstdException(code);
    } finally {
      calloc.free(nativeIn);
      calloc.free(nativeOut);
    }
  }

  static List<String>? _cachedTransformJsons;

  /// app 入口用：从 Flutter 资源包读 `assets/transforms/`。纯 Dart 宿主没有资源包，
  /// 调这里只会在日志里留一条「不支持」并保持空变形表——它们应改调
  /// [preloadTransformsFrom]，传自己的读文件函数。
  static Future<void> preloadTransforms() =>
      preloadTransformsFrom(loadBundledTransformAsset);

  /// 用 [loadAsset] 读 `assets/transforms/manifest.json` 与其中列出的每种语言的
  /// `<lang>.json`，缓存起来供之后创建的引擎实例装载（去屈折规则表）。[loadAsset]
  /// 收的是资源键（`assets/transforms/...`），由宿主映射到 rootBundle 或磁盘目录。
  ///
  /// 已在装载中的实例不受影响：变形表只在 [initialize] / [scheduleTyped] 之后
  /// 新建实例时装进去。
  static Future<void> preloadTransformsFrom(
    Future<String> Function(String assetKey) loadAsset,
  ) async {
    final List<String> languages;
    try {
      final manifest = await loadAsset('assets/transforms/manifest.json');
      languages = List<String>.from(jsonDecode(manifest) as List);
    } catch (e) {
      fushiDebugPrint('[FushiDicts.preloadTransforms(manifest)] $e');
      return;
    }
    final jsons = <String>[];
    for (final lang in languages) {
      try {
        final json = await loadAsset('assets/transforms/$lang.json');
        jsons.add(json);
      } catch (e) {
        fushiDebugPrint('[FushiDicts.preloadTransforms($lang)] $e');
      }
    }
    _cachedTransformJsons = jsons;
  }

  /// [preloadTransforms] 用的资源读取后端：Flutter 宿主 `'rootBundle'`，纯 Dart 宿主
  /// `'none'`（条件 import 选中的分支；测试据此钉住两端各自选对了）。
  static String get transformAssetBackend => kTransformAssetBackend;

  /// 已缓存的变形表份数（null = 从未成功预载）。给宿主自检用。
  static int? get loadedTransformCount => _cachedTransformJsons?.length;

  void _loadCachedTransforms() {
    if (_cachedTransformJsons == null) return;
    for (final json in _cachedTransformJsons!) {
      loadTransforms(json);
    }
  }

  /// 旧的扁平装载 API（每条路径同时进 term/freq/pitch 三桶）：立刻生效。
  ///
  /// 与 [initializeTyped] 一样属于「立刻」一族，所以同样要清掉待办并推进代次
  /// ——否则它装完之后，下一次访问 [instance] 会把一份陈旧的待办重放上来，把刚
  /// 装好的集合盖掉。
  static void initialize(List<String> paths) {
    _pending = null;
    _generation++;
    _instance?.dispose();
    final h = FushiDicts();
    h._loadCachedTransforms();
    for (final p in paths) {
      h.addTermDict(p);
      h.addFreqDict(p);
      h.addPitchDict(p);
    }
    h._prepareUnionFilter();
    _instance = h;
    _loadedDictCount = paths.length;
    _rebuildStylesCache();
  }

  /// **立刻**把引擎重建成给定集合（卸掉旧映射 + 逐本装载）。
  ///
  /// 只在「必须马上生效」时用：删词典目录前后（[releaseAllMappings] / BUG-1756，
  /// 文件映射不释放就删不掉文件），以及测试。**写元数据的路径请用 [scheduleTyped]**
  /// ——那条路是逐本触发的，就地重建会把总代价推成 O(N²)。
  ///
  /// [termLanguages]：term 词典路径 → 词头语言（BCP-47，见 [termDictLanguagesOf]）。
  /// 语言是**装载时**交给引擎的属性——标了语言的词典只接受本语言变形表还原出来的
  /// 词形（英语词典不再被阿尔巴尼亚语的规则查到 Our → O）；查词调用本身不带语言，
  /// 所以改了某本词典的语言要重新装载（元数据写入本来就会重排期）。不在表里的词典
  /// 当未标注，行为与此前一致。
  static void initializeTyped({
    List<String> termPaths = const [],
    List<String> freqPaths = const [],
    List<String> pitchPaths = const [],
    List<String> kanjiPaths = const [],
    Map<String, String> termLanguages = const <String, String>{},
  }) {
    _pending = null;
    _applyTyped(termPaths, freqPaths, pitchPaths, kanjiPaths, termLanguages);
  }

  /// 排期一次引擎重建：只记下目标集合，真正装载推迟到下一次要用引擎时
  /// （[instance] / [dictionaryStyles] / [loadPendingNow]）。见 [_pending]。
  ///
  /// 连续排期只保留最后一次——中间那些集合从来没被任何人观察到，装了也是白装。
  ///
  /// [termLanguages] 见 [initializeTyped]。
  static void scheduleTyped({
    List<String> termPaths = const [],
    List<String> freqPaths = const [],
    List<String> pitchPaths = const [],
    List<String> kanjiPaths = const [],
    Map<String, String> termLanguages = const <String, String>{},
  }) {
    _pending = _PendingDicts(
      termPaths: termPaths,
      freqPaths: freqPaths,
      pitchPaths: pitchPaths,
      kanjiPaths: kanjiPaths,
      termLanguages: termLanguages,
    );
    _generation++;
  }

  /// 主动结算待办（如果有）。给「知道自己接下来会用引擎、且希望装载成本落在此处
  /// 而不是落在某次用户查词里」的调用方用，比如启动流程。
  static void loadPendingNow() => _applyPendingIfAny();

  /// 是否还有没结算的待办。测试与启动流程用来断言「引擎已经跟上元数据」。
  static bool get hasPendingDicts => _pending != null;

  /// 测试观察点：当前待办里的 term 路径（无待办时为空）。只读，不触发结算。
  @visibleForTesting
  static List<String> debugPendingTermPathsForTest() =>
      List<String>.unmodifiable(_pending?.termPaths ?? const <String>[]);

  /// 测试收尾：丢掉待办而**不**装载它。用来隔离用例间的静态状态——直接调
  /// [loadPendingNow] 会真的去装载路径，那需要 native 库。
  @visibleForTesting
  static void dropPendingForTest() {
    _pending = null;
    _generation++;
  }

  /// 装载代次。每次排期或立刻装载都 +1，用来判定一次进行中的异步装载是否已经
  /// 被更新的意图取代（见 [loadPendingAsync]）。
  static int _generation = 0;

  /// 在飞的影子实例：[loadPendingAsync] 装载期间它持有**全部**词典的文件映射。
  ///
  /// 必须登记，否则 [releaseAllMappings] 只释放得掉 `_instance` 那一份，shadow
  /// 手里那份还在——Windows 上删词典目录照样撞 ERROR_USER_MAPPED_FILE，
  /// 「释放全部映射」这个不变式直接被证伪（BUG-1756 的形状）。
  static FushiDicts? _inFlightShadow;

  /// **分批让出**地结算待办：每装一本就把控制权交回事件循环一次。
  ///
  /// 为什么启动路径必须走这条而不是 [loadPendingNow]：装载是同步 FFI，一口气装
  /// N 本就是 N 本的时间里主 isolate 完全不动——首帧画不出来，更要命的是**所有
  /// Timer 都不会触发**，于是 `AppModel` 的 12 秒启动 IO 超时和 `main.dart` 的
  /// 20 秒「加载太久」逃生 UI 双双失效：两层看门狗都是 Timer，被同步代码堵住的
  /// 事件循环根本轮不到它们。用户那边看到的就是一直转圈、没有任何逃生口。
  /// 每本之间让出后，装载再慢也只是慢，看门狗照常计时、UI 照常响应。
  ///
  /// 让出必须用 [Future.delayed] 而不是 `await null`：后者只让到 microtask 队列，
  /// Timer 回调排在 event 队列，microtask 让出救不了看门狗。
  ///
  /// 装载在**影子实例**上进行，全部装完才原子替换 [_instance]：让出期间落进来的
  /// 查词看到的是完整的旧集合，而不是装到一半的半成品。若让出期间有人排了新的
  /// 集合（或直接同步装载过），本次结果按代次作废并丢弃——最后一次意图说了算。
  static Future<void> loadPendingAsync() async {
    final _PendingDicts? pending = _pending;
    if (pending == null) return;
    // 映射保持释放的作用域里不装（见 [withMappingsReleased]），待办留到作用域结束。
    if (_mappingHolds > 0) return;
    _pending = null;
    final int generation = _generation;

    final FushiDicts shadow = FushiDicts();
    _inFlightShadow = shadow;
    // 只有真的把 shadow 交给 _instance 之后才算「所有权转移」；在那之前的任何
    // 出口（作废、抛异常、被外部提前销毁）都必须由 finally 把它销毁掉，否则
    // shadow 成孤儿：native handle 永不 destroy，文件映射在进程存活期内永久泄漏
    // （Windows 上对应词典目录永久锁死）。
    bool handedOver = false;
    try {
      shadow._loadCachedTransforms();
      Future<bool> loadAll(
        List<String> paths,
        void Function(String) add,
      ) async {
        for (final String p in paths) {
          // 代次查在 add **之前**：让出期间若有人 releaseAllMappings /
          // disposeInstance，shadow 已被同步销毁（handle 置空），此时再 add 就会
          // 撞 null handle。恢复后第一件事就是查代次，撞不上。
          if (generation != _generation) return false;
          add(p);
          await Future<void>.delayed(Duration.zero);
        }
        return generation == _generation;
      }

      // 让出期间意图变了：丢掉这份成果（连同它持有的文件映射），别把已经过时的
      // 集合盖回引擎上。新意图会由它自己的结算路径装载。
      if (!await loadAll(
        pending.termPaths,
        (String p) => shadow.addTermDict(p, language: pending.termLanguages[p]),
      )) {
        return;
      }
      if (!await loadAll(pending.freqPaths, shadow.addFreqDict)) return;
      if (!await loadAll(pending.pitchPaths, shadow.addPitchDict)) return;
      if (!await loadAll(pending.kanjiPaths, shadow.addKanjiDict)) return;

      shadow._prepareUnionFilter();
      _instance?.dispose();
      _instance = shadow;
      handedOver = true;
      _loadedDictCount =
          pending.termPaths.length +
          pending.freqPaths.length +
          pending.pitchPaths.length +
          pending.kanjiPaths.length;
      _rebuildStylesCache();
    } finally {
      if (!handedOver) shadow.dispose();
      if (identical(_inFlightShadow, shadow)) _inFlightShadow = null;
    }
  }

  static void _applyPendingIfAny() {
    final _PendingDicts? pending = _pending;
    if (pending == null) return;
    if (_mappingHolds > 0) {
      // 映射保持释放的作用域里（[withMappingsReleased]）：待办留到作用域结束。没有
      // 实例时给一个空的，查词退化成空结果，与 [releaseAllMappings] 之后一致。
      if (_instance == null) {
        _applyTyped(
          const <String>[],
          const <String>[],
          const <String>[],
          const <String>[],
        );
      }
      return;
    }
    // 先清待办再装载：装载过程若抛异常，待办不该留在原地被下一次访问重放一遍
    // （同一份坏数据会把每一次查词都变成一次全量重建尝试）。
    _pending = null;
    _applyTyped(
      pending.termPaths,
      pending.freqPaths,
      pending.pitchPaths,
      pending.kanjiPaths,
      pending.termLanguages,
    );
  }

  static void _applyTyped(
    List<String> termPaths,
    List<String> freqPaths,
    List<String> pitchPaths,
    List<String> kanjiPaths, [
    Map<String, String> termLanguages = const <String, String>{},
  ]) {
    // 同步装载同样算一次新意图：进行中的 [loadPendingAsync] 会据此作废自己的成果，
    // 不把过时集合盖回来。
    _generation++;
    _instance?.dispose();
    final h = FushiDicts();
    h._loadCachedTransforms();
    for (final p in termPaths) {
      h.addTermDict(p, language: termLanguages[p]);
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
    h._prepareUnionFilter();
    _instance = h;
    _loadedDictCount =
        termPaths.length +
        freqPaths.length +
        pitchPaths.length +
        kanjiPaths.length;
    _rebuildStylesCache();
  }

  static void rebuild(List<String> paths) {
    initialize(paths);
  }

  static void disposeInstance() {
    _pending = null;
    // 代次必须推：否则在飞的 loadPendingAsync 恢复时代次仍相等，会把 shadow 装回
    // _instance —— 刚被显式销毁的引擎凭空复活（数据根切换 / closeForPopup 可达）。
    _generation++;
    _inFlightShadow?.dispose();
    _inFlightShadow = null;
    _instance?.dispose();
    _instance = null;
    _loadedDictCount = 0;
    // 引擎没了，后台查词 isolate 与它的缓存一起收掉：未开始的请求作废，在飞那一个
    // 等它回信（借着的句柄回信后才归还）再停。下一次查词按需重新拉起。
    unawaited(shutdownBackgroundLookup());
  }

  /// 停掉本 isolate 的后台查词 isolate（未开始的请求以「已作废」结束，在飞那一个
  /// 跑完才停）。下一次 [lookupInBackground] 会重新拉起。
  static Future<void> shutdownBackgroundLookup() =>
      _BackgroundLookupClient.shutdown();

  /// 让后台查词 isolate 丢掉原始引擎结果缓存。正常情况下缓存已按引擎实例代次失效，
  /// 这里给「查词结果缓存整体失效」的调用点（词典元数据变更）一个对称的入口。
  static void clearBackgroundLookupCache() =>
      _BackgroundLookupClient._current?.clearCache();

  /// 释放**全部**已加载词典的文件映射，把引擎重置成空但可用的实例。
  ///
  /// 为什么需要这个：词典加载时，native 侧把每本词典的索引（`key.index`，旧式词典是
  /// `hash.table` + `bloom.filter`）、记录文件（`blobs.bin` / 升级过的 `blobs3.bin`）、
  /// `media.bin` / `media.idx` 全部 `MapViewOfFile` 常驻映射（`fushidicts_src/query.cpp` 的 `add_dict` →
  /// `memory/memory.cpp` 的 `map_rd`）。Windows 上只要那份 view 还活着，
  /// `DeleteFileW` 一律失败（ERROR_USER_MAPPED_FILE 1224），删词典目录必抛
  /// [FileSystemException]。故**删任何词典目录之前必须先调这里**（BUG-1756）。
  ///
  /// 用「重建成空引擎」而不是 [disposeInstance]：`_instance` 始终非 null，释放到
  /// 重新加载之间落进来的查词退化成空结果，而不是撞 `_instance!` 的 null check。
  static void releaseAllMappings() {
    // 待办也要一起清：留着它，删完目录后任何一次查词都会把「含已删词典」的那份
    // 排期重放回引擎，等于映射又长回来了。
    _pending = null;
    // 代次和在飞 shadow 都要在**早退之前**处理：早退路径不经过 initializeTyped，
    // 代次不变意味着在飞的装载会把含已删词典的集合装回引擎（映射长回来），而
    // shadow 手里那份映射不释放，目录本身就还删不掉。两者都是 BUG-1756 的形状。
    _generation++;
    _inFlightShadow?.dispose();
    _inFlightShadow = null;
    if (_instance == null || _loadedDictCount == 0) return;
    initializeTyped();
  }

  /// 后台 isolate 对原生句柄的借用账本（[tokenizeWithReadingsInBackground]）。
  static final BackgroundBorrowLedger _backgroundBorrows =
      BackgroundBorrowLedger();

  /// 此刻在飞的后台借用全部归还后完成。
  ///
  /// 原生句柄的 destroy 只是退役：被后台借着的旧句柄要等最后一个借用归还才销毁、
  /// 解除文件映射。所以「dispose 之后马上搬词典文件」必须先等这里——否则后台分词
  /// 恰好在跑时，Windows 上的映射还活着，搬 / 删照样撞 ERROR_USER_MAPPED_FILE
  /// （BUG-1756）。删 / 覆盖词典文件用 [withMappingsReleased]，它已经等过了。
  static Future<void> whenBackgroundBorrowsSettled() =>
      _backgroundBorrows.settled();

  /// 此刻登记在账本里、尚未归还的后台借用 / 扫描数。只给测试观测次序用。
  @visibleForTesting
  static int get debugBackgroundBorrowsInFlight => _backgroundBorrows.inFlight;

  /// 正在进行的 [withMappingsReleased] 作用域数（可嵌套）。大于 0 时待办不结算。
  static int _mappingHolds = 0;

  /// 在「词典文件映射保持释放」的作用域里跑 [body]：删 / 覆盖词典文件的入口一律用
  /// 这个（BUG-1756）。
  ///
  /// 进入时 [releaseAllMappings]，再等在飞的后台借用归还（被借着的旧句柄此刻才销毁、
  /// 解除映射），然后才跑 [body]。[body] 期间排下的待办（[scheduleTyped]，元数据
  /// 写入逐本触发）只登记、不结算：释放与删除之间隔着好几个 await（等借用、异步
  /// delete、Windows 上的占用重试），这时任何一次查词都会把待办装回引擎，正被删 /
  /// 覆盖的文件又映射上。作用域结束后下一次用引擎时照常结算。[body] 里显式的
  /// [initializeTyped]（删完装回剩余词典）不受影响——那是调用方明确要的装载。
  static Future<T> withMappingsReleased<T>(Future<T> Function() body) async {
    _mappingHolds++;
    try {
      releaseAllMappings();
      await whenBackgroundBorrowsSettled();
      return await body();
    } finally {
      _mappingHolds--;
    }
  }

  static Map<String, String> get dictionaryStyles {
    _applyPendingIfAny();
    return _stylesCache;
  }

  static void _rebuildStylesCache() {
    if (_instance == null) {
      _stylesCache = {};
      return;
    }
    _stylesCache = {
      for (final s in _instance!.getStyles()) s.dictName: s.styles,
    };
  }

  /// 退役本实例的原生句柄。
  ///
  /// 原生 `fushidicts_destroy` 只还掉本实例持有的那个引用：后台 isolate 借着它的
  /// 调用（[tokenizeWithReadingsInBackground]）照常跑完，最后一个借用归还时句柄才
  /// 真正销毁。要确认文件映射已解除，等 [whenBackgroundBorrowsSettled]（删 / 覆盖
  /// 词典文件用 [withMappingsReleased]）。
  void dispose() {
    if (_handle != null) {
      _bindings!.destroy(_handle!);
      _handle = null;
    }
  }

  // ── dict loading ────────────────────────────────────────────────
  /// 本实例按装载顺序装进来的释义词典目录。「我库里的例句」按它算词元归一口径的签名
  /// （词典换了，旧索引里的词典形就过期了）。
  List<String> get termDictionaryPaths =>
      List<String>.unmodifiable(_termDictionaryPaths);
  final List<String> _termDictionaryPaths = <String>[];

  /// 借本实例的原生句柄给后台 isolate 用：[work] 拿到句柄地址与库路径覆盖，在后台里
  /// 调 [corpusTermsBorrowed] 一类静态入口。借用协议同 [tokenizeWithReadingsInBackground]
  /// （[borrowNativeHandle]：在本 isolate 上 retain / release，期间词典重载照常 dispose
  /// 本实例，句柄等借用归还才销毁）。本实例已 dispose 时不跑 [work]、返回 null。
  Future<T?> borrowForBackground<T>(
    Future<T> Function(int address, String? libraryPath) work,
  ) {
    final Pointer<Void>? handle = _handle;
    if (handle == null) return Future<T?>.value();
    final FushidictsFfiBindings bindings = _bindings!;
    final String? libraryPath = FushidictsFfiBindings.libraryPathOverride;
    return borrowNativeHandle<T>(
      ledger: _backgroundBorrows,
      retain: () => bindings.retain(handle) == 1,
      release: () => bindings.release(handle),
      work: () => work(handle.address, libraryPath),
    );
  }

  /// 一批句子的语料词元（原生 `fushidicts_corpus_terms`，一次 FFI 处理整批），返回原生
  /// 线格式的原样字节（`N × {u32 M, M × {u32 start16, u32 len16, str 词典形}}`），交给
  /// native/fushi_corpus 直接解析，Dart 不解码。
  ///
  /// 给**后台 isolate** 用：[address] / [libraryPath] 来自 [borrowForBackground]，调用期间
  /// 借用必须未归还。随包原生库没有这个导出时抛 [UnsupportedError]；原生失败抛
  /// [StateError]。
  static Uint8List corpusTermsBorrowed(
    int address,
    String? libraryPath,
    List<String> sentences,
  ) {
    FushidictsFfiBindings.libraryPathOverride = libraryPath;
    final ({CorpusTermsDart corpusTerms, FreeBytesDart freeBytes})? fns =
        lookupCorpusTerms();
    if (fns == null) {
      throw UnsupportedError(
        'fushidicts_corpus_terms is not available in this build',
      );
    }
    final List<Uint8List> encoded = <Uint8List>[
      for (final String s in sentences) utf8.encode(s),
    ];
    int total = 4;
    for (final Uint8List e in encoded) {
      total += 4 + e.length;
    }
    final Pointer<Uint8> input = calloc<Uint8>(total);
    final Pointer<Pointer<Uint8>> out = calloc<Pointer<Uint8>>();
    final Pointer<Int32> outLen = calloc<Int32>();
    try {
      final Uint8List view = input.asTypedListOutOfLine(total);
      final ByteData data = ByteData.sublistView(view);
      data.setUint32(0, encoded.length, Endian.little);
      int at = 4;
      for (final Uint8List e in encoded) {
        data.setUint32(at, e.length, Endian.little);
        view.setRange(at + 4, at + 4 + e.length, e);
        at += 4 + e.length;
      }
      final int status = fns.corpusTerms(
        Pointer<Void>.fromAddress(address),
        input,
        total,
        defaultScanLength,
        out,
        outLen,
      );
      if (status != 0) {
        throw StateError('fushidicts_corpus_terms failed ($status)');
      }
      try {
        return Uint8List.fromList(out.value.asTypedListOutOfLine(outLen.value));
      } finally {
        fns.freeBytes(out.value);
      }
    } finally {
      calloc.free(input);
      calloc.free(out);
      calloc.free(outLen);
    }
  }

  /// [language]：这本词典词头的语言（BCP-47），null / 空 = 未标注。
  void addTermDict(String path, {String? language}) {
    _termDictionaryPaths.add(path);
    final String tag = language?.trim() ?? '';
    final p = path.toNativeUtf8(allocator: calloc);
    final Pointer<Utf8> l = tag.isEmpty
        ? nullptr
        : tag.toNativeUtf8(allocator: calloc);
    try {
      if (l == nullptr) {
        _bindings!.addTermDict(_handle!, p);
      } else {
        _bindings!.addTermDictWithLanguage(_handle!, p, l);
      }
    } finally {
      calloc.free(p);
      if (l != nullptr) calloc.free(l);
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
  /// Static (handle-free): only reads the dictionary's index and record files on
  /// disk (whichever layout the native side finds), so it can
  /// run during type migration before any query handle exists.
  static int probeDictContent(String dir) {
    _bindings ??= FushidictsFfiBindings();
    final p = dir.toNativeUtf8(allocator: calloc);
    try {
      return _bindings!.probeDictContent(p);
    } finally {
      calloc.free(p);
    }
  }

  /// 给已导入的释义词典补写 `redirect_glossary.flag`（原生 `fushidicts_ensure_redirect_flag`）。
  ///
  /// 为什么要补：装载（`add_term_dict`）只读这份标记、不扫描；缺标记的旧词典查询期
  /// 只能逐条检测纯重定向 glossary。新导入的词典由导入端写好标记，这里只处理存量。
  /// 标记在**下一次装载**时生效，本函数不重载引擎。
  ///
  /// 逐本在后台 isolate 跑（单本整本扫描最多约 1 s，绝不上 UI isolate）。已有有效
  /// 标记的词典由原生侧直接读标记返回（不重扫）。
  ///
  /// 与删 / 覆盖词典串行（Windows 上扫描期间映射着索引与记录文件，删不掉）：
  /// * 每本扫描都登记进后台借用账本，[withMappingsReleased] / [whenBackgroundBorrowsSettled]
  ///   会等在跑的那一本结束；
  /// * 处于 [withMappingsReleased] 作用域内时不再开始新的一本，本轮剩下的标为
  ///   [FushiRedirectFlagReport.deferred]（下次调用再补）；
  /// * 开始前目录已不存在（刚被删）的跳过。
  ///
  /// 随包原生库没有这个导出时抛 [UnsupportedError]。
  static Future<FushiRedirectFlagReport> ensureRedirectFlags(
    List<String> termDictDirs,
  ) async {
    if (lookupEnsureRedirectFlag() == null) {
      throw UnsupportedError(
        'fushidicts_ensure_redirect_flag is not available in this build',
      );
    }
    final String? libraryPath = FushidictsFfiBindings.libraryPathOverride;
    final Map<String, int> results = <String, int>{};
    final List<String> deferred = <String>[];
    for (int i = 0; i < termDictDirs.length; i++) {
      final String dir = termDictDirs[i];
      if (!await Directory(dir).exists()) continue;
      // 作用域检查与登记账本之间不能隔 await：withMappingsReleased 先同步 +1 再等
      // 账本，这里同步看到 0 并立刻登记，它的 settled() 就一定等得到这次扫描。
      if (_mappingHolds > 0) {
        deferred.addAll(termDictDirs.sublist(i));
        break;
      }
      results[dir] = await _backgroundBorrows.track(
        Isolate.run(
          () => _ensureRedirectFlagIn(libraryPath, dir),
          debugName: kRedirectFlagIsolateName,
        ),
      );
    }
    return FushiRedirectFlagReport(results: results, deferred: deferred);
  }

  static int _ensureRedirectFlagIn(String? libraryPath, String dir) {
    FushidictsFfiBindings.libraryPathOverride = libraryPath;
    final EnsureRedirectFlagDart ensure = lookupEnsureRedirectFlag()!;
    final Pointer<Utf8> p = dir.toNativeUtf8(allocator: calloc);
    try {
      return ensure(p);
    } finally {
      calloc.free(p);
    }
  }

  /// 把存量词典原地升级到当前磁盘格式（原生 `fushidicts_upgrade_dictionary`，语义见
  /// `native/fushidicts/fushidicts_include/fushidicts/upgrade.hpp`）。
  ///
  /// 原生侧只创建新文件再改名提交、不碰已有文件，所以引擎正装着这本词典时也能调；
  /// 新格式在**下一次装载**时才生效，本函数不重载引擎。旧文件被映射着（Windows）删不
  /// 掉时留到引擎释放之后的下一次调用（返回 [FushiDictUpgradeOutcome.upToDate] 的
  /// 那一支）再清。文件布局全是原生侧的事，Dart 只看返回码。
  ///
  /// 串行化与 [ensureRedirectFlags] 完全同一套：逐本在后台 isolate 跑（大词典单本可达
  /// 秒级），每本登记进后台借用账本（[withMappingsReleased] 会等在跑的那一本）；处于
  /// 映射释放作用域内时不再开始新的一本，剩下的进 [FushiDictUpgradeReport.deferred]；
  /// 开始前目录已不存在的跳过（不进结果、不回调进度）。
  ///
  /// [onProgress] 每本跑完回调一次：`done` 是这本在 [dictDirs] 里的序号 + 1（跳过的
  /// 目录照样占位，所以 `done / total` 单调、最后一本落在 total），`total` 恒为
  /// `dictDirs.length`。
  ///
  /// 随包原生库没有这个导出时抛 [UnsupportedError]。
  static Future<FushiDictUpgradeReport> upgradeDictionaryFormats(
    List<String> dictDirs, {
    FushiDictUpgradeProgress? onProgress,
  }) {
    if (lookupUpgradeDictionary() == null) {
      throw UnsupportedError(
        'fushidicts_upgrade_dictionary is not available in this build',
      );
    }
    return _runPerDictionary(dictDirs, _upgradeDictionaryIn, onProgress);
  }

  /// 只检查 + 清理（原生 `fushidicts_tidy_dictionary`）：已是新格式的词典顺带清掉遗留
  /// 旧文件、把完成标记换成新名字（[FushiDictUpgradeOutcome.upToDate]）；旧式词典**一个
  /// 字节都不写**，报 [FushiDictUpgradeOutcome.pending]，由宿主征得用户同意后再交给
  /// [upgradeDictionaryFormats]（拍板台 pr3554：升级会整本改写用户词典目录，先提示）。
  ///
  /// 串行化、作用域 deferred、进度回调口径与 [upgradeDictionaryFormats] 完全相同。
  /// 随包原生库没有这个导出时抛 [UnsupportedError]。
  static Future<FushiDictUpgradeReport> tidyDictionaryFormats(
    List<String> dictDirs, {
    FushiDictUpgradeProgress? onProgress,
  }) {
    if (lookupTidyDictionary() == null) {
      throw UnsupportedError(
        'fushidicts_tidy_dictionary is not available in this build',
      );
    }
    return _runPerDictionary(dictDirs, _tidyDictionaryIn, onProgress);
  }

  /// [upgradeDictionaryFormats] / [tidyDictionaryFormats] 的公共循环：逐本在后台 isolate
  /// 跑 [entry]，登记进后台借用账本。
  static Future<FushiDictUpgradeReport> _runPerDictionary(
    List<String> dictDirs,
    int Function(String? libraryPath, String dir) entry,
    FushiDictUpgradeProgress? onProgress,
  ) async {
    final String? libraryPath = FushidictsFfiBindings.libraryPathOverride;
    final Map<String, FushiDictUpgradeOutcome> results =
        <String, FushiDictUpgradeOutcome>{};
    final List<String> deferred = <String>[];
    for (int i = 0; i < dictDirs.length; i++) {
      final String dir = dictDirs[i];
      if (!await Directory(dir).exists()) continue;
      // 同 ensureRedirectFlags：作用域检查与登记账本之间不能隔 await。
      if (_mappingHolds > 0) {
        deferred.addAll(dictDirs.sublist(i));
        break;
      }
      final int code = await _backgroundBorrows.track(
        Isolate.run(
          () => entry(libraryPath, dir),
          debugName: kDictUpgradeIsolateName,
        ),
      );
      final FushiDictUpgradeOutcome outcome = FushiDictUpgradeOutcome.fromCode(
        code,
      );
      results[dir] = outcome;
      onProgress?.call(i + 1, dictDirs.length, dir, outcome);
    }
    return FushiDictUpgradeReport(results: results, deferred: deferred);
  }

  static int _upgradeDictionaryIn(String? libraryPath, String dir) {
    FushidictsFfiBindings.libraryPathOverride = libraryPath;
    final UpgradeDictionaryDart upgrade = lookupUpgradeDictionary()!;
    final Pointer<Utf8> p = dir.toNativeUtf8(allocator: calloc);
    try {
      // allow_meta_rewrite = 1：纯 freq / pitch / ipa 词典顺带预解析记录。
      return upgrade(p, 1);
    } finally {
      calloc.free(p);
    }
  }

  static int _tidyDictionaryIn(String? libraryPath, String dir) {
    FushidictsFfiBindings.libraryPathOverride = libraryPath;
    final TidyDictionaryDart tidy = lookupTidyDictionary()!;
    final Pointer<Utf8> p = dir.toNativeUtf8(allocator: calloc);
    try {
      return tidy(p);
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
  static Future<FushiImportResult> importDictionary(
    String zipPath,
    String outputDir, {
    String breadcrumbDir = '',
  }) async {
    // 宿主指定的原生库绝对路径是 isolate 局部的静态量，新 isolate 里要重新带上，
    // 否则后台导入按裸名 dlopen（无头服务端的 bundle/lib 不在系统搜索路径上）。
    final String? libraryPath = FushidictsFfiBindings.libraryPathOverride;
    return Isolate.run(() {
      FushidictsFfiBindings.libraryPathOverride = libraryPath;
      _bindings ??= FushidictsFfiBindings();
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
          // Error/early-return branches in native fushidicts_import can leave
          // detected_type/title/error NULL; guard every conversion so a failed
          // import reports cleanly instead of crashing on null deref
          // (HBK-AUDIT-032).
          return FushiImportResult(
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
  List<FushiTermResult> query(String expression) =>
      _queryWith(_bindings!.query, expression);

  /// 只要词频的 [query]：同一批 (expression, reading) 词条、同样的 rules 与
  /// frequencies，但 glossaries 与 pitches 恒为空——原生不富化音调、不解压释义。
  ///
  /// 给「拿一个词形去查它的词频」的调用方用（Anki 卡组按词频重排，几千张卡各查一次）。
  /// 释义解压加上把它拷过 FFI 是 [query] 的大头（真实词典集上平均每个词约 370 KB），
  /// 这些调用方一个字也不读；实测单次约 0.33 ms → 0.03 ms。
  List<FushiTermResult> queryFrequencies(String expression) =>
      _queryWith(_bindings!.queryFrequencies, expression);

  List<FushiTermResult> _queryWith(
    FfiQueryResult Function(Pointer<Void> handle, Pointer<Utf8> expression)
    nativeQuery,
    String expression,
  ) {
    final ep = expression.toNativeUtf8(allocator: calloc);
    try {
      final r = nativeQuery(_handle!, ep);
      final rPtr = calloc<FfiQueryResult>();
      rPtr.ref = r;
      try {
        final results = <FushiTermResult>[];
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
  List<FushiKanjiResult> queryKanji(String character) =>
      _queryKanjiWith(_bindings!, _handle!, character);

  /// 同步路径（[queryKanji]）与后台查词共用的一次原生汉字查询。
  static List<FushiKanjiResult> _queryKanjiWith(
    FushidictsFfiBindings bindings,
    Pointer<Void> handle,
    String character,
  ) {
    final cp = character.toNativeUtf8(allocator: calloc);
    try {
      final r = bindings.queryKanji(handle, cp);
      final rPtr = calloc<FfiKanjiResults>();
      rPtr.ref = r;
      try {
        final results = <FushiKanjiResult>[];
        for (int i = 0; i < r.count; i++) {
          results.add(_convertKanji(r.results[i]));
        }
        return results;
      } finally {
        bindings.freeKanjiResults(rPtr);
        calloc.free(rPtr);
      }
    } finally {
      calloc.free(cp);
    }
  }

  static const int defaultMaxResults = 16;
  static const int defaultScanLength = 16;

  // ── lookup (with deinflection) ──────────────────────────────────
  //
  // 排序选项（上游 bc62d2b/86c6e2f）：默认参数下走老导出、行为零变化。
  // [frequencyDictionary]+[frequencyOrder] 指定按某 freq 词典升/降序（在
  // max_results 截断之前生效）；[primaryReading] 让 reading 精确匹配者排最前
  //（Yomitan 内链语义）。当前无设置 UI 消费方，管道先行。
  //
  // [chineseSimpToTrad]：这次查词按中文处理时置 true，引擎在原查询之外额外试另一种
  // 字形的拼写，**双向**：简体 → 繁體（OpenCC STCharacters 全部候选 + 台/港字形）让按
  // 繁體建索引的词典命中简体查询，繁體 → 简体（OpenCC TSCharacters）让按简体建索引的
  // 词典命中繁體查询；一字多候选全展开、由词典认真词，原形结果照常在、同长度时排在
  // 前面。引擎语言无关，由调用方判定（AppModel.lookupChineseSimpToTradFor）；默认
  // false，日语等其它语言的查询一字不变。参数名沿用历史的 SimpToTrad。
  //
  // [excludedDictionaries]：本次查词当作没装这些词典（按词典名精确匹配）。引擎在并入
  // 结果之前就摘掉它们的释义、频率与音调，所以不占 [maxResults] 名额、也不影响排序
  // （见 lookup.hpp 的 LookupOptions::excluded_dictionaries）。服务端常驻全部词典、按
  // 请求的启用集合查词用。默认空集 = 行为逐字不变。
  List<FushiLookupResult> lookup(
    String text, {
    int maxResults = defaultMaxResults,
    int scanLength = defaultScanLength,
    String? frequencyDictionary,
    FushiLookupFrequencyOrder frequencyOrder = FushiLookupFrequencyOrder.auto,
    String? primaryReading,
    bool chineseSimpToTrad = false,
    List<FushiRubySpan> rubySpans = const <FushiRubySpan>[],
    Set<String> excludedDictionaries = const <String>{},
  }) => _lookupWith(
    _bindings!,
    _handle!,
    text,
    maxResults: maxResults,
    scanLength: scanLength,
    frequencyDictionary: frequencyDictionary,
    frequencyOrder: frequencyOrder,
    primaryReading: primaryReading,
    chineseSimpToTrad: chineseSimpToTrad,
    rubySpans: rubySpans,
    excludedDictionaries: excludedDictionaries,
  );

  /// 同步路径（[lookup]）与后台查词共用的一次原生 lookup（同一份封送与转换）。
  static List<FushiLookupResult> _lookupWith(
    FushidictsFfiBindings bindings,
    Pointer<Void> handle,
    String text, {
    int maxResults = defaultMaxResults,
    int scanLength = defaultScanLength,
    String? frequencyDictionary,
    FushiLookupFrequencyOrder frequencyOrder = FushiLookupFrequencyOrder.auto,
    String? primaryReading,
    bool chineseSimpToTrad = false,
    List<FushiRubySpan> rubySpans = const <FushiRubySpan>[],
    Set<String> excludedDictionaries = const <String>{},
  }) {
    final bool useOptions =
        frequencyDictionary != null ||
        frequencyOrder != FushiLookupFrequencyOrder.auto ||
        primaryReading != null;
    // 原文振假名：UTF-16 区间换成引擎用的码点偏移，一次 FFI 整批带过去。
    final ({List<int> bounds, String readings}) ruby =
        rubySpansToCodePointBounds(text, rubySpans);
    final int rubyCount = ruby.bounds.length ~/ 2;
    final tp = text.toNativeUtf8(allocator: calloc);
    final fd = (frequencyDictionary ?? '').toNativeUtf8(allocator: calloc);
    final pr = (primaryReading ?? '').toNativeUtf8(allocator: calloc);
    final Pointer<Utf8> rr = rubyCount == 0
        ? nullptr
        : ruby.readings.toNativeUtf8(allocator: calloc);
    final Pointer<Int32> rb = rubyCount == 0
        ? nullptr
        : calloc<Int32>(ruby.bounds.length);
    if (rubyCount > 0) {
      rb.asTypedListOutOfLine(ruby.bounds.length).setAll(0, ruby.bounds);
    }
    final int flags = chineseSimpToTrad ? _lookupFlagChineseSimpToTrad : 0;
    // 排除词典：一次 FFI 整批带过去（NUL 结尾 UTF-8 串的指针数组）。空串跳过。
    final List<String> excluded = <String>[
      for (final String name in excludedDictionaries)
        if (name.isNotEmpty) name,
    ];
    final Pointer<Pointer<Utf8>> ex = excluded.isEmpty
        ? nullptr
        : calloc<Pointer<Utf8>>(excluded.length);
    for (int i = 0; i < excluded.length; i++) {
      ex[i] = excluded[i].toNativeUtf8(allocator: calloc);
    }
    try {
      final r = excluded.isNotEmpty
          ? bindings.lookupWithExclusions(
              handle,
              tp,
              maxResults,
              scanLength,
              fd,
              frequencyOrder.index,
              pr,
              flags,
              rb,
              rr,
              rubyCount,
              ex,
              excluded.length,
            )
          : rubyCount > 0
          ? bindings.lookupWithRuby(
              handle,
              tp,
              maxResults,
              scanLength,
              fd,
              frequencyOrder.index,
              pr,
              flags,
              rb,
              rr,
              rubyCount,
            )
          : chineseSimpToTrad
          ? bindings.lookupWithFlags(
              handle,
              tp,
              maxResults,
              scanLength,
              fd,
              frequencyOrder.index,
              pr,
              flags,
            )
          : useOptions
          ? bindings.lookupWithOptions(
              handle,
              tp,
              maxResults,
              scanLength,
              fd,
              frequencyOrder.index,
              pr,
            )
          : bindings.lookup(handle, tp, maxResults, scanLength);

      final rPtr = calloc<FfiLookupResults>();
      rPtr.ref = r;
      try {
        final results = <FushiLookupResult>[];
        for (int i = 0; i < r.count; i++) {
          final src = r.results[i];
          final trace = <FushiTransformGroup>[];
          for (int j = 0; j < src.traceCount; j++) {
            trace.add(
              FushiTransformGroup(
                name: _utf8OrEmpty(src.trace[j].name),
                description: _utf8OrEmpty(src.trace[j].description),
              ),
            );
          }
          results.add(
            FushiLookupResult(
              matched: _utf8OrEmpty(src.matched),
              deinflected: _utf8OrEmpty(src.deinflected),
              trace: trace,
              term: _convertTerm(src.term),
              preprocessorSteps: src.preprocessorSteps,
            ),
          );
        }
        return results;
      } finally {
        bindings.freeLookupResults(rPtr);
        calloc.free(rPtr);
      }
    } finally {
      calloc.free(tp);
      calloc.free(fd);
      calloc.free(pr);
      if (rubyCount > 0) {
        calloc.free(rr);
        calloc.free(rb);
      }
      if (excluded.isNotEmpty) {
        for (int i = 0; i < excluded.length; i++) {
          calloc.free(ex[i]);
        }
        calloc.free(ex);
      }
    }
  }

  // ── lookup in the background isolate ────────────────────────────

  /// 在常驻后台 isolate 里跑完整个查词（原生 lookup + 转换 + 结果 / 弹窗 JSON 构建，
  /// 见 `background_lookup.dart`），UI isolate 只收成品。
  ///
  /// 句柄：本 isolate 上同步 retain，借到后台回信（或请求还没发出就被同 lane 的新
  /// 请求取代）才 release；期间词典重载照常 dispose 本实例（[borrowNativeHandle]）。
  /// 本实例已 dispose（借不到引用）时返回 null。
  Future<FushiLookupOutcome?> lookupInBackground(FushiLookupRequest request) {
    final Pointer<Void>? handle = _handle;
    if (handle == null) return Future<FushiLookupOutcome?>.value();
    final FushidictsFfiBindings bindings = _bindings!;
    final _LookupJob job = _LookupJob(
      address: handle.address,
      libraryPath: FushidictsFfiBindings.libraryPathOverride,
      engineSerial: _serial,
      request: request,
    );
    return borrowNativeHandle<FushiLookupOutcome>(
      ledger: _backgroundBorrows,
      retain: () => bindings.retain(handle) == 1,
      release: () => bindings.release(handle),
      work: () => _BackgroundLookupClient.instance.submit(job),
    );
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
      final ptr = _bindings!.lookupPopupJson(
        _handle!,
        tp,
        maxResults,
        scanLength,
        maxTerms,
      );
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

  // ── tokenize（最长匹配分词，一次 FFI 切完整段） ────────────────────
  //
  // 语义见 native tokenize.hpp：与此前 Dart 逐位置 `lookup(maxResults: 1)` 循环逐位
  // 一致——命中切首条结果的 matched 长度，未命中切一个 UTF-16 码元。返回每段的
  // UTF-16 码元数，总和 = [text].length。匹配长度缓存在原生句柄里，随词典集合重建
  // 而失效。

  /// [text] 的分词长度（UTF-16 码元）。原生调用失败时返回 null。
  List<int>? tokenizeLengths(String text) =>
      _tokenize(text, withReadings: false)?.lengths;

  ({List<int> lengths, List<String> readings})? _tokenize(
    String text, {
    required bool withReadings,
  }) => _tokenizeWith(_bindings!, _handle!, text, withReadings: withReadings);

  /// 批量分词 + 每段读音（每段再查一次 `lookup(段, 1)` 的首条读音，未命中为空串），
  /// 切分与 [tokenizeLengths] 逐位相同。原生分词（浏览器扩展整页分词实测约 177 ms）
  /// 跑在一个后台 isolate 里，不占调用方（UI）isolate。
  ///
  /// 句柄生命周期：在本 isolate 上 `fushidicts_retain` 借一个引用、把地址交给后台、
  /// 回来后在本 isolate 上 release（[borrowNativeHandle]）。期间词典重载照常
  /// dispose 本实例——原生 destroy 只是退役，句柄要等这次借用归还才销毁，后台调用
  /// 不会落到已释放的句柄上；查询与 add_*_dict 之间由句柄内的读写锁互斥。
  ///
  /// 返回与 [texts] 等长的列表，某段原生失败为 null（与同步路径同一闸门）；本实例已
  /// dispose（借不到引用）时返回 null。
  Future<List<({List<int> lengths, List<String> readings})?>?>
  tokenizeWithReadingsInBackground(List<String> texts) {
    final Pointer<Void>? handle = _handle;
    if (handle == null) {
      return Future<
        List<({List<int> lengths, List<String> readings})?>?
      >.value();
    }
    final FushidictsFfiBindings bindings = _bindings!;
    return borrowNativeHandle<
      List<({List<int> lengths, List<String> readings})?>
    >(
      ledger: _backgroundBorrows,
      retain: () => bindings.retain(handle) == 1,
      release: () => bindings.release(handle),
      work: () => _runBorrowedTokenize(
        handle.address,
        FushidictsFfiBindings.libraryPathOverride,
        texts,
      ),
    );
  }

  /// 单独成静态函数：交给 `Isolate.run` 的闭包只捕获地址 / 库路径 / 文本这三样
  /// 可发送的值，不把实例（与它的 Pointer）拖过 isolate 边界。
  static Future<List<({List<int> lengths, List<String> readings})?>>
  _runBorrowedTokenize(
    int address,
    String? libraryPath,
    List<String> texts,
  ) async {
    final ({
      List<({List<int> lengths, List<String> readings})?> results,
      String isolateName,
    })
    out = await Isolate.run(
      () => _tokenizeBorrowedBatch(address, libraryPath, texts),
      debugName: kBackgroundTokenizeIsolateName,
    );
    debugLastBackgroundTokenizeIsolate = out.isolateName;
    return out.results;
  }

  /// 后台 isolate 的分词本体：按宿主给的库路径在本 isolate 重建绑定（绑定与
  /// [FushidictsFfiBindings.libraryPathOverride] 都是 isolate 局部的），对借来的
  /// 句柄地址逐段分词。
  static ({
    List<({List<int> lengths, List<String> readings})?> results,
    String isolateName,
  })
  _tokenizeBorrowedBatch(int address, String? libraryPath, List<String> texts) {
    FushidictsFfiBindings.libraryPathOverride = libraryPath;
    final FushidictsFfiBindings bindings = FushidictsFfiBindings();
    final Pointer<Void> handle = Pointer<Void>.fromAddress(address);
    return (
      results: <({List<int> lengths, List<String> readings})?>[
        for (final String text in texts)
          _tokenizeWith(bindings, handle, text, withReadings: true),
      ],
      isolateName: Isolate.current.debugName ?? '',
    );
  }

  /// 同步路径（[tokenizeLengths]）与后台路径共用的一次原生分词（同一份封送与闸门）。
  static ({List<int> lengths, List<String> readings})? _tokenizeWith(
    FushidictsFfiBindings bindings,
    Pointer<Void> handle,
    String text, {
    required bool withReadings,
  }) {
    // 带长传入（HBK-AUDIT-007）：`toNativeUtf8` 产出的是 C 串，原生按 NUL 定界会在
    // 正文里的 U+0000 处截断，切出来的总长对不上原文、整段被下面的闸门判失败。
    // `utf8.encode` 与 `toNativeUtf8` 同口径（孤立代理 → U+FFFD），只是不再靠 NUL。
    final Uint8List bytes = utf8.encode(text);
    // 至少分配 1 字节：空串也传一个有效指针，原生侧 nullptr 只表示非法调用。
    final Pointer<Uint8> tp = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    try {
      tp.asTypedListOutOfLine(bytes.length).setAll(0, bytes);
      final r = bindings.tokenize(
        handle,
        tp,
        bytes.length,
        defaultScanLength,
        withReadings ? 1 : 0,
      );
      final rPtr = calloc<FfiTokenizeResult>();
      rPtr.ref = r;
      try {
        final List<int> lengths = <int>[
          for (int i = 0; i < r.count; i++) r.lengths[i],
        ];
        int total = 0;
        for (final int l in lengths) {
          total += l;
        }
        // 原生闸门吞掉异常后返回 0 段：长度对不上原文就视为失败，交给调用方回落。
        if (total != text.length) return null;
        final List<String> readings = <String>[
          if (withReadings && r.readings != nullptr)
            for (int i = 0; i < r.count; i++) _utf8OrEmpty(r.readings[i]),
        ];
        if (withReadings && readings.length != lengths.length) return null;
        return (lengths: lengths, readings: readings);
      } finally {
        bindings.freeTokenizeResult(rPtr);
        calloc.free(rPtr);
      }
    } finally {
      calloc.free(tp);
    }
  }

  /// [text] 开头的最长匹配长度（UTF-16 码元；0 = 未命中）。
  ///
  /// 引擎只看前 [defaultScanLength] + 1 个码点（见 tokenize.hpp），这里先按码点截好
  /// 再编码——wordFromIndex 一类调用传进来的是整段余文，没必要整段转 UTF-8。
  int matchedLength(String text) {
    final tp = scanWindowOf(text).toNativeUtf8(allocator: calloc);
    try {
      return _bindings!.matchLength(_handle!, tp, defaultScanLength);
    } finally {
      calloc.free(tp);
    }
  }

  /// [text] 的前 [defaultScanLength] + 1 个码点（引擎结果只依赖这一段）。
  @visibleForTesting
  static String scanWindowOf(String text) {
    int units = 0;
    int codePoints = 0;
    while (units < text.length && codePoints <= defaultScanLength) {
      final int unit = text.codeUnitAt(units);
      final bool surrogatePair =
          unit >= 0xD800 &&
          unit <= 0xDBFF &&
          units + 1 < text.length &&
          (text.codeUnitAt(units + 1) & 0xFC00) == 0xDC00;
      units += surrogatePair ? 2 : 1;
      codePoints++;
    }
    return units == text.length ? text : text.substring(0, units);
  }

  // ── styles ──────────────────────────────────────────────────────
  List<FushiDictStyle> getStyles() {
    final r = _bindings!.getStyles(_handle!);
    final rPtr = calloc<FfiDictStyles>();
    rPtr.ref = r;
    try {
      final styles = <FushiDictStyle>[];
      for (int i = 0; i < r.count; i++) {
        styles.add(
          FushiDictStyle(
            dictName: _utf8OrEmpty(r.items[i].dictName),
            styles: _utf8OrEmpty(r.items[i].styles),
          ),
        );
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
          bytes = Uint8List.fromList(r.data.asTypedListOutOfLine(r.size));
        } else if (r.size > 0 && r.data == nullptr) {
          // HBK-AUDIT-100: native kept the real size but data is NULL — this is
          // an allocation failure (malloc returned NULL for a large media
          // file), NOT a genuine miss (which reports size == 0). Surface a
          // diagnostic so OOM is distinguishable from not-found instead of
          // collapsing both into the same silent null. The contract stays
          // `Uint8List?` so the unguarded WebView callers keep degrading to a
          // 404 rather than crashing; the true fix (size=0 / error flag on
          // alloc failure) belongs in fushidicts_ffi.cpp.
          fushiDebugPrint(
            '[fushidicts] getMediaFile: native allocation failed for '
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
    T Function(FushiDicts h) action, {
    List<String> kanjiPaths = const [],
  }) {
    final h = FushiDicts();
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

/// [FushiDicts.ensureRedirectFlags] 的后台 isolate debugName。
const String kRedirectFlagIsolateName = 'fushi-dict-redirect-flag';

/// [FushiDicts.ensureRedirectFlags] 的结果。
class FushiRedirectFlagReport {
  const FushiRedirectFlagReport({
    required this.results,
    required this.deferred,
  });

  /// 目录 → 原生返回值（1 含纯重定向 / 0 不含 / -1 读不了）。
  final Map<String, int> results;

  /// 因进入「映射保持释放」作用域（删 / 覆盖词典）而本轮没做的目录。
  final List<String> deferred;

  /// 读不了的目录（-1）。
  List<String> get unreadable => <String>[
    for (final MapEntry<String, int> e in results.entries)
      if (e.value < 0) e.key,
  ];
}

/// [FushiDicts.upgradeDictionaryFormats] 的后台 isolate debugName。
const String kDictUpgradeIsolateName = 'fushi-dict-format-upgrade';

/// 单本词典原地升级 / 检查的结果（原生 `fushidicts::UpgradeResult` 的五个值）。
enum FushiDictUpgradeOutcome {
  /// -1：读不了 / 写不了；词典原样可用（旧格式照常查词），下次再试。
  failed(-1),

  /// 0：已是最新（顺带清理了遗留的旧文件）。
  upToDate(0),

  /// 1：本次写出了新格式；下一次装载生效。
  upgraded(1),

  /// 2：新格式装不下这本词典，保持旧式、照常可用。
  notApplicable(2),

  /// 3：只检查（[FushiDicts.tidyDictionaryFormats]）时：旧式词典待升级，本次什么都没写。
  pending(3);

  const FushiDictUpgradeOutcome(this.code);

  /// 原生返回码。
  final int code;

  /// 原生返回码 → 枚举；不认识的码按 [failed] 处理（词典照样按旧格式可用）。
  static FushiDictUpgradeOutcome fromCode(int code) {
    for (final FushiDictUpgradeOutcome o in values) {
      if (o.code == code) return o;
    }
    return failed;
  }
}

/// [FushiDicts.upgradeDictionaryFormats] 的逐本进度回调。
typedef FushiDictUpgradeProgress =
    void Function(
      int done,
      int total,
      String dictDir,
      FushiDictUpgradeOutcome outcome,
    );

/// [FushiDicts.upgradeDictionaryFormats] 的结果。
class FushiDictUpgradeReport {
  const FushiDictUpgradeReport({required this.results, required this.deferred});

  /// 目录 → 结果（不存在而跳过的目录不在里面）。
  final Map<String, FushiDictUpgradeOutcome> results;

  /// 因进入「映射保持释放」作用域（删 / 覆盖词典）而本轮没做的目录。
  final List<String> deferred;

  List<String> _where(FushiDictUpgradeOutcome outcome) => <String>[
    for (final MapEntry<String, FushiDictUpgradeOutcome> e in results.entries)
      if (e.value == outcome) e.key,
  ];

  /// 本轮升级过的目录（要重载引擎才用得上新格式）。
  List<String> get upgraded => _where(FushiDictUpgradeOutcome.upgraded);

  /// 已是最新的目录。
  List<String> get upToDate => _where(FushiDictUpgradeOutcome.upToDate);

  /// 升级失败的目录（词典原样可用）。
  List<String> get failed => _where(FushiDictUpgradeOutcome.failed);

  /// 不适用、保持旧式的目录。
  List<String> get notApplicable =>
      _where(FushiDictUpgradeOutcome.notApplicable);

  /// 待升级（只检查时报的）目录。
  List<String> get pending => _where(FushiDictUpgradeOutcome.pending);

  /// 是否有任何一本升级过。
  bool get anyUpgraded =>
      results.values.contains(FushiDictUpgradeOutcome.upgraded);
}

/// [FushiDicts.scheduleTyped] 排下的待装载词典集合（不可变快照）。
///
/// 分四桶而不是一张扁平表：装载时每桶走不同的 native 入口（term/freq/pitch/kanji
/// 各有自己的索引），合成一张表就得在结算时再分一次，白丢已经算好的信息。
class _PendingDicts {
  const _PendingDicts({
    required this.termPaths,
    required this.freqPaths,
    required this.pitchPaths,
    required this.kanjiPaths,
    this.termLanguages = const <String, String>{},
  });

  /// term 词典路径 → 词头语言，见 [FushiDicts.initializeTyped]。
  final Map<String, String> termLanguages;
  final List<String> termPaths;
  final List<String> freqPaths;
  final List<String> pitchPaths;
  final List<String> kanjiPaths;
}
