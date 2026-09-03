import 'dart:convert' show jsonDecode, utf8;
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../ffi/fushidicts_ffi_bindings.dart';

// ── Dart data classes ───────────────────────────────────────────────

class FushiGlossaryEntry {
  const FushiGlossaryEntry({
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

class FushiFrequency {
  const FushiFrequency({required this.value, required this.displayValue});
  final int value;
  final String displayValue;
}

class FushiFrequencyEntry {
  const FushiFrequencyEntry(
      {required this.dictName, required this.frequencies});
  final String dictName;
  final List<FushiFrequency> frequencies;
}

class FushiPitchEntry {
  const FushiPitchEntry({
    required this.dictName,
    required this.pitchPositions,
    this.patterns = const <String>[],
    this.transcriptions = const <String>[],
  });
  final String dictName;
  final List<int> pitchPositions;

  /// Pattern-style accents（Yomitan pitch 规格里 position 为字符串，如
  /// "heiban"）。数字位仍走 [pitchPositions]，两者分流（79c55c2 二期）。
  final List<String> patterns;

  /// IPA transcriptions for this dict's entry (Yomitan `ipa` meta mode). Empty
  /// for plain pitch-accent dicts. Carried alongside pitchPositions because both
  /// share the native PITCH bucket / query path (TODO-687 block3).
  final List<String> transcriptions;
}

/// lookup 排序模式（上游 bc62d2b）。enum index 即 FFI 的 freq_order 编码：
/// auto=0（既有比较器，零行为变化）/ ascending=1 / descending=2 / disabled=3。
enum FushiLookupFrequencyOrder { auto, ascending, descending, disabled }

class FushiTermResult {
  const FushiTermResult({
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
  final List<FushiGlossaryEntry> glossaries;
  final List<FushiFrequencyEntry> frequencies;
  final List<FushiPitchEntry> pitches;
}

class FushiTransformGroup {
  const FushiTransformGroup({required this.name, required this.description});
  final String name;
  final String description;
}

class FushiLookupResult {
  const FushiLookupResult({
    required this.matched,
    required this.deinflected,
    required this.trace,
    required this.term,
    required this.preprocessorSteps,
  });
  final String matched;
  final String deinflected;
  final List<FushiTransformGroup> trace;
  final FushiTermResult term;
  final int preprocessorSteps;
}

class FushiImportResult {
  const FushiImportResult({
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

class FushiDictStyle {
  const FushiDictStyle({required this.dictName, required this.styles});
  final String dictName;
  final String styles;
}

class FushiKanjiResult {
  const FushiKanjiResult({
    required this.character,
    required this.onyomi,
    required this.kunyomi,
    required this.radical,
    required this.strokes,
    required this.meanings,
    this.stats = const <String, String>{},
    required this.dictName,
  });

  /// Reconstructs a kanji result from a map decoded out of a
  /// [DictionarySearchResult] JSON payload (e.g. when the popup process
  /// receives a serialized search result across the process boundary). Missing
  /// or null fields degrade to empty/zero so a partial payload never throws.
  factory FushiKanjiResult.fromMap(Map<String, dynamic> map) {
    return FushiKanjiResult(
      character: map['character'] as String? ?? '',
      onyomi: map['onyomi'] as String? ?? '',
      kunyomi: map['kunyomi'] as String? ?? '',
      radical: map['radical'] as String? ?? '',
      strokes: (map['strokes'] as num?)?.toInt() ?? 0,
      meanings: List<String>.from(map['meanings'] as List? ?? const <String>[]),
      stats: (map['stats'] as Map?)?.map(
            (Object? k, Object? v) =>
                MapEntry(k.toString(), v?.toString() ?? ''),
          ) ??
          const <String, String>{},
      dictName: map['dictName'] as String? ?? '',
    );
  }

  final String character;
  final String onyomi;
  final String kunyomi;
  final String radical;
  final int strokes;
  final List<String> meanings;

  /// v2 词典的完整 stats 键值对（JLPT/grade 等，radical/strokes 之外）；
  /// v1 存量词典恒为空 map。
  final Map<String, String> stats;
  final String dictName;

  Map<String, dynamic> toMap() => <String, dynamic>{
        'character': character,
        'onyomi': onyomi,
        'kunyomi': kunyomi,
        'radical': radical,
        'strokes': strokes,
        'meanings': meanings,
        'stats': stats,
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

FushiTermResult _convertTerm(FfiTermResult ffi) {
  final glossaries = <FushiGlossaryEntry>[];
  if (ffi.glossaryCount > 0 && ffi.glossaries != nullptr) {
    for (int i = 0; i < ffi.glossaryCount; i++) {
      final g = ffi.glossaries[i];
      glossaries.add(FushiGlossaryEntry(
        dictName: _utf8OrEmpty(g.dictName),
        glossary: _utf8OrEmpty(g.glossary),
        definitionTags: _utf8OrEmpty(g.definitionTags),
        termTags: _utf8OrEmpty(g.termTags),
      ));
    }
  }

  final frequencies = <FushiFrequencyEntry>[];
  if (ffi.frequencyCount > 0 && ffi.frequencies != nullptr) {
    for (int i = 0; i < ffi.frequencyCount; i++) {
      final f = ffi.frequencies[i];
      final freqs = <FushiFrequency>[];
      for (int j = 0; j < f.count; j++) {
        freqs.add(FushiFrequency(
          value: f.values[j],
          displayValue: _utf8OrEmpty(f.displayValues[j]),
        ));
      }
      frequencies.add(FushiFrequencyEntry(
        dictName: _utf8OrEmpty(f.dictName),
        frequencies: freqs,
      ));
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
      pitches.add(FushiPitchEntry(
        dictName: _utf8OrEmpty(p.dictName),
        pitchPositions: positions,
        patterns: patterns,
        transcriptions: transcriptions,
      ));
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

// ── main wrapper class ──────────────────────────────────────────────

class FushiDicts {
  // ── lifecycle ──────────────────────────────────────────────────

  FushiDicts() {
    _bindings ??= FushidictsFfiBindings();
    _handle = _bindings!.create();
  }
  static FushidictsFfiBindings? _bindings;
  Pointer<Void>? _handle;

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

  static FushiDicts get instance {
    _applyPendingIfAny();
    assert(_instance != null, 'FushiDicts.initialize() must be called first');
    return _instance!;
  }

  /// 引擎是否可用。有待办时同样算已初始化：待办本身就说明词典集合已知，
  /// 调用方接着就会经 [instance] 触发结算。
  static bool get isInitialized => _instance != null || _pending != null;

  static List<String>? _cachedTransformJsons;

  static Future<void> preloadTransforms() async {
    final List<String> languages;
    try {
      final manifest =
          await rootBundle.loadString('assets/transforms/manifest.json');
      languages = List<String>.from(jsonDecode(manifest) as List);
    } catch (e) {
      debugPrint('[FushiDicts.preloadTransforms(manifest)] $e');
      return;
    }
    final jsons = <String>[];
    for (final lang in languages) {
      try {
        final json =
            await rootBundle.loadString('assets/transforms/$lang.json');
        jsons.add(json);
      } catch (e) {
        debugPrint('[FushiDicts.preloadTransforms($lang)] $e');
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
    _instance = h;
    _loadedDictCount = paths.length;
    _rebuildStylesCache();
  }

  /// **立刻**把引擎重建成给定集合（卸掉旧映射 + 逐本装载）。
  ///
  /// 只在「必须马上生效」时用：删词典目录前后（[releaseAllMappings] / BUG-1756，
  /// 文件映射不释放就删不掉文件），以及测试。**写元数据的路径请用 [scheduleTyped]**
  /// ——那条路是逐本触发的，就地重建会把总代价推成 O(N²)。
  static void initializeTyped({
    List<String> termPaths = const [],
    List<String> freqPaths = const [],
    List<String> pitchPaths = const [],
    List<String> kanjiPaths = const [],
  }) {
    _pending = null;
    _applyTyped(termPaths, freqPaths, pitchPaths, kanjiPaths);
  }

  /// 排期一次引擎重建：只记下目标集合，真正装载推迟到下一次要用引擎时
  /// （[instance] / [dictionaryStyles] / [loadPendingNow]）。见 [_pending]。
  ///
  /// 连续排期只保留最后一次——中间那些集合从来没被任何人观察到，装了也是白装。
  static void scheduleTyped({
    List<String> termPaths = const [],
    List<String> freqPaths = const [],
    List<String> pitchPaths = const [],
    List<String> kanjiPaths = const [],
  }) {
    _pending = _PendingDicts(
      termPaths: termPaths,
      freqPaths: freqPaths,
      pitchPaths: pitchPaths,
      kanjiPaths: kanjiPaths,
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
    _pending = null;
    final int generation = _generation;

    final FushiDicts shadow = FushiDicts();
    shadow._loadCachedTransforms();
    Future<void> loadAll(
        List<String> paths, void Function(String) add) async {
      for (final String p in paths) {
        add(p);
        await Future<void>.delayed(Duration.zero);
      }
    }

    await loadAll(pending.termPaths, shadow.addTermDict);
    await loadAll(pending.freqPaths, shadow.addFreqDict);
    await loadAll(pending.pitchPaths, shadow.addPitchDict);
    await loadAll(pending.kanjiPaths, shadow.addKanjiDict);

    if (generation != _generation) {
      // 让出期间意图变了：丢掉这份成果（连同它持有的文件映射），别把已经过时的
      // 集合盖回引擎上。新意图会由它自己的结算路径装载。
      shadow.dispose();
      return;
    }

    _instance?.dispose();
    _instance = shadow;
    _loadedDictCount = pending.termPaths.length +
        pending.freqPaths.length +
        pending.pitchPaths.length +
        pending.kanjiPaths.length;
    _rebuildStylesCache();
  }

  static void _applyPendingIfAny() {
    final _PendingDicts? pending = _pending;
    if (pending == null) return;
    // 先清待办再装载：装载过程若抛异常，待办不该留在原地被下一次访问重放一遍
    // （同一份坏数据会把每一次查词都变成一次全量重建尝试）。
    _pending = null;
    _applyTyped(pending.termPaths, pending.freqPaths, pending.pitchPaths,
        pending.kanjiPaths);
  }

  static void _applyTyped(
    List<String> termPaths,
    List<String> freqPaths,
    List<String> pitchPaths,
    List<String> kanjiPaths,
  ) {
    // 同步装载同样算一次新意图：进行中的 [loadPendingAsync] 会据此作废自己的成果，
    // 不把过时集合盖回来。
    _generation++;
    _instance?.dispose();
    final h = FushiDicts();
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
    _loadedDictCount = termPaths.length +
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
    _instance?.dispose();
    _instance = null;
    _loadedDictCount = 0;
  }

  /// 释放**全部**已加载词典的文件映射，把引擎重置成空但可用的实例。
  ///
  /// 为什么需要这个：词典加载时，native 侧把每本词典的 `hash.table` /
  /// `bloom.filter` / `blobs.bin` / `media.bin` / `media.idx` 全部
  /// `MapViewOfFile` 常驻映射（`fushidicts_src/query.cpp` 的 `add_dict` →
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
    if (_instance == null || _loadedDictCount == 0) return;
    initializeTyped();
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
    _bindings ??= FushidictsFfiBindings();
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
  static Future<FushiImportResult> importDictionary(
      String zipPath, String outputDir,
      {String breadcrumbDir = ''}) async {
    return Isolate.run(() {
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
  List<FushiTermResult> query(String expression) {
    final ep = expression.toNativeUtf8(allocator: calloc);
    try {
      final r = _bindings!.query(_handle!, ep);
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
  List<FushiKanjiResult> queryKanji(String character) {
    final cp = character.toNativeUtf8(allocator: calloc);
    try {
      final r = _bindings!.queryKanji(_handle!, cp);
      final rPtr = calloc<FfiKanjiResults>();
      rPtr.ref = r;
      try {
        final results = <FushiKanjiResult>[];
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
  //
  // 排序选项（上游 bc62d2b/86c6e2f）：默认参数下走老导出、行为零变化。
  // [frequencyDictionary]+[frequencyOrder] 指定按某 freq 词典升/降序（在
  // max_results 截断之前生效）；[primaryReading] 让 reading 精确匹配者排最前
  //（Yomitan 内链语义）。当前无设置 UI 消费方，管道先行。
  List<FushiLookupResult> lookup(
    String text, {
    int maxResults = defaultMaxResults,
    int scanLength = defaultScanLength,
    String? frequencyDictionary,
    FushiLookupFrequencyOrder frequencyOrder = FushiLookupFrequencyOrder.auto,
    String? primaryReading,
  }) {
    final bool useOptions = frequencyDictionary != null ||
        frequencyOrder != FushiLookupFrequencyOrder.auto ||
        primaryReading != null;
    final tp = text.toNativeUtf8(allocator: calloc);
    final fd = (frequencyDictionary ?? '').toNativeUtf8(allocator: calloc);
    final pr = (primaryReading ?? '').toNativeUtf8(allocator: calloc);
    try {
      final r = useOptions
          ? _bindings!.lookupWithOptions(_handle!, tp, maxResults, scanLength,
              fd, frequencyOrder.index, pr)
          : _bindings!.lookup(_handle!, tp, maxResults, scanLength);

      final rPtr = calloc<FfiLookupResults>();
      rPtr.ref = r;
      try {
        final results = <FushiLookupResult>[];
        for (int i = 0; i < r.count; i++) {
          final src = r.results[i];
          final trace = <FushiTransformGroup>[];
          for (int j = 0; j < src.traceCount; j++) {
            trace.add(FushiTransformGroup(
              name: _utf8OrEmpty(src.trace[j].name),
              description: _utf8OrEmpty(src.trace[j].description),
            ));
          }
          results.add(FushiLookupResult(
            matched: _utf8OrEmpty(src.matched),
            deinflected: _utf8OrEmpty(src.deinflected),
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
      calloc.free(fd);
      calloc.free(pr);
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
  List<FushiDictStyle> getStyles() {
    final r = _bindings!.getStyles(_handle!);
    final rPtr = calloc<FfiDictStyles>();
    rPtr.ref = r;
    try {
      final styles = <FushiDictStyle>[];
      for (int i = 0; i < r.count; i++) {
        styles.add(FushiDictStyle(
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
          // alloc failure) belongs in fushidicts_ffi.cpp.
          debugPrint(
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
  });

  final List<String> termPaths;
  final List<String> freqPaths;
  final List<String> pitchPaths;
  final List<String> kanjiPaths;
}
