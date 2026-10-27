part of 'fushidicts.dart';

// ── 后台查词（常驻 isolate） ──────────────────────────────────────────
//
// 查词热路径「原生 lookup → 逐条把 FFI 结构转成 Dart 对象 → buildResultFromLookup →
// buildPopupJsonFromLookup（→ 查词历史 toJson）」整段搬到一个常驻后台 isolate：
// UI isolate 只发一条请求、收一份成品（DictionarySearchResult / popupJson 字符串）。
// 跨 isolate 的消息由**发送方**拷贝（SendPort.send 的线性拷贝发生在 send 调用里），
// 所以成品拷贝成本落在后台，UI 侧收到就是现成对象。
//
// 句柄安全沿用 [tokenizeWithReadingsInBackground] 的借用协议（[borrowNativeHandle]）：
// 每个请求在 UI isolate 上同步 retain，引用一直借到**后台真正回信**（或请求还没发出就
// 被取代）才 release。词典重载照常 dispose 旧实例——原生 destroy 只是退役，被借着的
// 句柄要等最后一次借用归还才销毁；[withMappingsReleased] 经账本等这些借用归还后才删 /
// 覆盖文件（BUG-1756）。

/// 后台查词 isolate 的 debugName。
@visibleForTesting
const String kBackgroundLookupIsolateName = 'fushi-dict-lookup';

/// 最近一次后台查词实际跑在哪个 isolate 上（debugName）；只给测试观测用。
@visibleForTesting
String? debugLastBackgroundLookupIsolate;

/// 后台查词 isolate 里原始引擎结果缓存的默认字节上限。
const int kDefaultLookupFfiCacheMaxBytes = 32 << 20;

/// 原始引擎结果（[FushiLookupResult] 列表）缓存键的单一真相。格式：
/// `<window.length>:<window>/<maxResults>`，window = [FushiDicts.scanWindowOf]。
///
/// 🔴 **键必须带 [maxResults]**：引擎按该上限 `partial_sort` + `resize` 截断，不同上限
/// 拿到的是不同长度的结果集；load-more 以更大上限重查同一个词，键里不含上限就会命中
/// 上一轮的短结果集，`allLoaded` 随即为 true —— load-more 永久失灵（BUG-1307）。
///
/// 用扫描窗口而不是整串作键：引擎结果只依赖前 [FushiDicts.defaultScanLength] + 1 个
/// 码点（`lookup.cpp` 的 scan_window + `word_scan.cpp` 的 scan_candidates 只看窗口与
/// 窗口后第一个码点，与 [FushiDicts.matchedLength] 同一份契约）。阅读器传进来的是
/// 「光标到句尾」的整段余文，整串作键时同一位置的不同余文互相命中不了。
///
/// [chineseSimpToTrad] 为 true（查词语言为中文，引擎会额外试繁體变体）时键尾追加
/// `/zh`：同一个词在中文 / 非中文语境下结果集不同，不能共用缓存。默认 false 时键与
/// 此前逐字相同。
String buildFfiLookupCacheKey({
  required String term,
  required int maxResults,
  bool chineseSimpToTrad = false,
}) {
  final String window = FushiDicts.scanWindowOf(term);
  return '${window.length}:$window/$maxResults${chineseSimpToTrad ? '/zh' : ''}';
}

/// 粗估一次 FFI lookup 结果列表的常驻字节数（UTF-16 每字符 2 字节 + 每对象固定
/// 开销，宁可高估），只服务缓存的字节封顶。
int estimateFushiLookupResultsBytes(List<FushiLookupResult> results) {
  const int objectOverhead = 64;
  int chars = 0;
  int overhead = objectOverhead;
  for (final FushiLookupResult result in results) {
    overhead += objectOverhead;
    chars += result.matched.length + result.deinflected.length;
    for (final FushiTransformGroup group in result.trace) {
      overhead += objectOverhead;
      chars += group.name.length + group.description.length;
    }
    final FushiTermResult term = result.term;
    chars += term.expression.length + term.reading.length + term.rules.length;
    for (final FushiGlossaryEntry glossary in term.glossaries) {
      overhead += objectOverhead;
      chars +=
          glossary.dictName.length +
          glossary.glossary.length +
          glossary.definitionTags.length +
          glossary.termTags.length;
    }
    for (final FushiFrequencyEntry freq in term.frequencies) {
      overhead += objectOverhead;
      chars += freq.dictName.length;
      for (final FushiFrequency f in freq.frequencies) {
        overhead += objectOverhead;
        chars += f.displayValue.length;
      }
    }
    for (final FushiPitchEntry pitch in term.pitches) {
      overhead += objectOverhead + pitch.pitchPositions.length * 8;
      chars += pitch.dictName.length;
      for (final String transcription in pitch.transcriptions) {
        chars += transcription.length;
      }
    }
  }
  return chars * 2 + overhead;
}

/// 一次后台查词的输入。全部字段都能跨 isolate 发送。
class FushiLookupRequest {
  const FushiLookupRequest({
    required this.text,
    required this.maxResults,
    this.includeKanji = false,
    this.popupOnly = false,
    this.hiddenDictionaries = const <String>{},
    this.dictionaryOrder = const <String>[],
    this.ffiCacheMaxBytes = kDefaultLookupFfiCacheMaxBytes,
    this.supersedeLane,
    this.chineseSimpToTrad = false,
  });

  /// 已清洗的查询串（交给引擎的就是它，结果的 searchTerm 也是它）。
  final String text;

  /// 引擎结果上限 == 本次消费的词头预算（BUG-1307）。
  final int maxResults;

  /// 顺带查汉字桶（调用方已判定 [text] 是单个汉字）。
  final bool includeKanji;

  /// 只要 popupJson + bestLength（浏览器扩展 / 远端 popupOnly 快路径），不物化
  /// DictionaryEntry（BUG-1525）。
  final bool popupOnly;

  /// 被用户关掉的词典名（结果构建期的源头过滤）。
  final Set<String> hiddenDictionaries;

  /// 词典管理页的 term 词典顺序。
  final List<String> dictionaryOrder;

  /// 后台原始结果缓存的字节上限（低内存模式由调用方收紧）。
  final int ffiCacheMaxBytes;

  /// 非 null 时：同 lane 里还没开始执行的旧请求被本请求取代（见 [LookupJobScheduler]）。
  /// 只给自带代次检查、拿到被取代的空结果也无害的调用方用。
  final String? supersedeLane;

  /// 查询语言为中文：引擎额外试简体 → 繁體拼写（原形结果照常在），原始结果缓存键带 `/zh`。
  final bool chineseSimpToTrad;
}

/// 后台查词的产出。
class FushiLookupOutcome {
  const FushiLookupOutcome({
    this.result,
    this.popupJson,
    this.bestLength = 0,
    this.superseded = false,
    this.ffiCacheHit = false,
    this.ffiCacheMicros = 0,
    this.ffiLookupMicros = 0,
    this.buildMicros = 0,
  });

  /// 被同 lane 的更新请求取代、或后台关停时还没开始执行：没有任何结果，调用方不得
  /// 把它当成「查不到」写进缓存。
  const FushiLookupOutcome.dropped()
    : result = null,
      popupJson = null,
      bestLength = 0,
      superseded = true,
      ffiCacheHit = false,
      ffiCacheMicros = 0,
      ffiLookupMicros = 0,
      buildMicros = 0;

  /// 完整模式：词条结果（entries 非空，已带 popupJson 与汉字结果），或没有词条命中
  /// 但汉字桶命中时的纯汉字结果；都没有为 null。
  final DictionarySearchResult? result;

  /// popupOnly 模式：引擎有结果时的 popupJson；引擎无结果为 null。
  final String? popupJson;

  /// popupOnly 模式：全部引擎结果里最长的 matched（UTF-16），与旧同步路径同口径
  /// （不排除隐藏词典）。
  final int bestLength;

  final bool superseded;

  /// 诊断：原始引擎结果是否命中后台缓存，以及各段耗时（后台 isolate 内测得）。
  final bool ffiCacheHit;
  final int ffiCacheMicros;
  final int ffiLookupMicros;
  final int buildMicros;
}

/// 后台 isolate 里跑的那一整段（也是同步对照路径：测试拿同一个函数在当前 isolate
/// 跑，和后台结果逐字段比对）。
FushiLookupOutcome _computeLookupOutcome({
  required FushidictsFfiBindings bindings,
  required Pointer<Void> handle,
  required FushiLookupRequest request,
  required FushiLookupFfiCache? cache,
}) {
  final Stopwatch watch = Stopwatch()..start();
  final String cacheKey = buildFfiLookupCacheKey(
    term: request.text,
    maxResults: request.maxResults,
    chineseSimpToTrad: request.chineseSimpToTrad,
  );
  List<FushiLookupResult>? ffiResults = cache?.get(cacheKey);
  final int ffiCacheMicros = watch.elapsedMicroseconds;
  final bool ffiCacheHit = ffiResults != null;
  int ffiLookupMicros = 0;
  if (ffiResults == null) {
    // 🔴 引擎上限 == 本次真正要消费的词头预算（BUG-1307）。`lookup.cpp` 在
    // `partial_sort` + `resize(max_results)` **之后**才对存活的每条结果做
    // `materialize()`（逐 glossary zstd 解压，每条落在 blobs.bin 的随机偏移上）。
    // 输出逐字不变，三条理由（改这里前必须逐条复核）：
    // 1. `partial_sort` 的比较器没动，top-N 的集合与顺序不变；
    // 2. `query.cpp` 的 `query_raw` 里 `glossaries.push_back` 无条件执行，每个返回的
    //    term 至少带一条 glossary —— N 个结果必然凑够 N 个词头，构建期的
    //    maximumTerms 预算先于结果数耗尽；
    // 3. `bestLength` 取 `matched` 的最大 UTF-16 长度，而所有 `matched` 都是同一个
    //    查询串的前缀（`scan_candidates` 只产出前缀），最长者必在 `partial_sort` 后
    //    排首位、永远落在 top-N 内。
    final int lookupStart = watch.elapsedMicroseconds;
    ffiResults = FushiDicts._lookupWith(
      bindings,
      handle,
      request.text,
      maxResults: request.maxResults,
      chineseSimpToTrad: request.chineseSimpToTrad,
    );
    ffiLookupMicros = watch.elapsedMicroseconds - lookupStart;
    if (ffiResults.isNotEmpty) {
      cache?.put(cacheKey, ffiResults, maxBytes: request.ffiCacheMaxBytes);
    }
  }

  final int buildStart = watch.elapsedMicroseconds;
  if (request.popupOnly) {
    if (ffiResults.isEmpty) {
      return FushiLookupOutcome(
        ffiCacheHit: ffiCacheHit,
        ffiCacheMicros: ffiCacheMicros,
        ffiLookupMicros: ffiLookupMicros,
      );
    }
    int bestLength = 0;
    for (final FushiLookupResult result in ffiResults) {
      if (result.matched.length > bestLength) {
        bestLength = result.matched.length;
      }
    }
    final String popupJson = buildPopupJsonFromLookup(
      results: ffiResults,
      maximumTerms: request.maxResults,
      hiddenDictionaries: request.hiddenDictionaries,
      dictionaryOrder: request.dictionaryOrder,
    );
    return FushiLookupOutcome(
      popupJson: popupJson,
      bestLength: bestLength,
      ffiCacheHit: ffiCacheHit,
      ffiCacheMicros: ffiCacheMicros,
      ffiLookupMicros: ffiLookupMicros,
      buildMicros: watch.elapsedMicroseconds - buildStart,
    );
  }

  // 汉字桶与 term 索引正交：单个汉字既可能是词头也可能是汉字条目，两边各查各的，
  // 汉字结果挂到词条结果上；没有词条命中时单独成一个纯汉字结果（TODO-094 S4）。
  final List<FushiKanjiResult> kanjiResults = request.includeKanji
      ? FushiDicts._queryKanjiWith(bindings, handle, request.text)
      : const <FushiKanjiResult>[];

  DictionarySearchResult? result;
  if (ffiResults.isNotEmpty) {
    final DictionarySearchResult terms = buildResultFromLookup(
      searchTerm: request.text,
      results: ffiResults,
      maximumTerms: request.maxResults,
      dictionaryOrder: request.dictionaryOrder,
      hiddenDictionaries: request.hiddenDictionaries,
    );
    // 词条全被隐藏词典过滤掉时这份结果会被丢弃（下面落到纯汉字 / 无结果），
    // 不必再生成 popupJson。
    if (terms.entries.isNotEmpty) {
      // popupJson 由同一批 ffiResults 生成（与 C++ build_popup_json 逐字段对齐），
      // 不再让引擎把同一个词的完整查询管线从零再跑一遍。
      terms.popupJson = buildPopupJsonFromLookup(
        results: ffiResults,
        maximumTerms: request.maxResults,
        hiddenDictionaries: request.hiddenDictionaries,
        dictionaryOrder: request.dictionaryOrder,
      );
      result = terms.withKanjiResults(kanjiResults);
    }
  }
  if (result == null && kanjiResults.isNotEmpty) {
    result = DictionarySearchResult(
      searchTerm: request.text,
      kanjiResults: kanjiResults,
    );
  }
  return FushiLookupOutcome(
    result: result,
    ffiCacheHit: ffiCacheHit,
    ffiCacheMicros: ffiCacheMicros,
    ffiLookupMicros: ffiLookupMicros,
    buildMicros: watch.elapsedMicroseconds - buildStart,
  );
}

/// 后台 isolate 里的原始引擎结果 LRU（按字节封顶）。
///
/// 按引擎实例代次（[FushiDicts] 的 `_serial`）整体失效：词典集合的任何变化（增删、
/// 重排、开关、覆盖导入、释放映射）都会换一个新实例，旧实例的结果一条都不能再用。
/// 隐藏 / 顺序 / 译文只作用在结果构建期，不进这份缓存。
///
/// 只在后台查词 isolate 里实例化；公开只为了单测它的淘汰与失效规则。
@visibleForTesting
class FushiLookupFfiCache {
  static const int _maxEntries = 2000;

  int _engineSerial = -1;
  int _bytes = 0;

  /// 当前缓存的条数。
  int get length => _entries.length;

  /// 当前记账的估算字节数。
  int get bytes => _bytes;
  final LinkedHashMap<String, ({List<FushiLookupResult> results, int bytes})>
  _entries =
      LinkedHashMap<String, ({List<FushiLookupResult> results, int bytes})>();

  void bindEngine(int serial) {
    if (serial == _engineSerial) return;
    _engineSerial = serial;
    clear();
  }

  void clear() {
    _entries.clear();
    _bytes = 0;
  }

  List<FushiLookupResult>? get(String key) {
    final ({List<FushiLookupResult> results, int bytes})? hit = _entries.remove(
      key,
    );
    if (hit == null) return null;
    _entries[key] = hit; // 移到最新
    return hit.results;
  }

  void put(
    String key,
    List<FushiLookupResult> results, {
    required int maxBytes,
  }) {
    final int size = estimateFushiLookupResultsBytes(results);
    final ({List<FushiLookupResult> results, int bytes})? old = _entries.remove(
      key,
    );
    if (old != null) _bytes -= old.bytes;
    if (size > maxBytes) return; // 单条就超预算：不缓存，也不挤掉别人
    _entries[key] = (results: results, bytes: size);
    _bytes += size;
    while (_bytes > maxBytes || _entries.length > _maxEntries) {
      final String oldest = _entries.keys.first;
      _bytes -= _entries.remove(oldest)!.bytes;
    }
  }
}

// ── UI isolate 一侧：常驻 isolate 的客户端 ─────────────────────────────

/// 一个排队中的后台查词任务（UI isolate 内部对象，不跨 isolate）。
class _LookupJob {
  _LookupJob({
    required this.address,
    required this.libraryPath,
    required this.engineSerial,
    required this.request,
  });

  final int address;
  final String? libraryPath;
  final int engineSerial;
  final FushiLookupRequest request;
}

/// 发往后台 isolate 的消息。
sealed class _WorkerMessage {
  const _WorkerMessage();
}

class _WorkerCatalog extends _WorkerMessage {
  const _WorkerCatalog(this.localeTag, this.translations);
  final String? localeTag;
  final Map<String, String> translations;
}

class _WorkerClearCache extends _WorkerMessage {
  const _WorkerClearCache();
}

class _WorkerStop extends _WorkerMessage {
  const _WorkerStop();
}

class _WorkerLookup extends _WorkerMessage {
  const _WorkerLookup({
    required this.id,
    required this.address,
    required this.libraryPath,
    required this.engineSerial,
    required this.request,
  });
  final int id;
  final int address;
  final String? libraryPath;
  final int engineSerial;
  final FushiLookupRequest request;
}

/// 后台 isolate 的回信。
class _WorkerReply {
  const _WorkerReply({
    required this.id,
    this.outcome,
    this.error,
    this.stack,
    required this.isolateName,
  });
  final int id;
  final FushiLookupOutcome? outcome;
  final String? error;
  final String? stack;
  final String isolateName;
}

/// 后台 isolate 抛回来的错误（原样带着后台的错误文本与栈）。
class FushiBackgroundLookupException implements Exception {
  const FushiBackgroundLookupException(this.message, [this.remoteStack]);
  final String message;
  final String? remoteStack;

  @override
  String toString() => 'FushiBackgroundLookupException: $message';
}

/// 常驻后台查词 isolate 的 UI 侧客户端（每个 isolate 一个，惰性启动）。
///
/// 生命周期：
/// * 第一次查词时 `Isolate.spawn`，之后常驻复用（不是每次 `Isolate.run`：每次起
///   isolate 要付 spawn 成本，而且后台缓存留不住）。
/// * 回信端口只在有任务时 `keepIsolateAlive`，空闲时不拖住宿主 isolate 退出。
/// * [shutdown]（[FushiDicts.disposeInstance] 调）：丢掉未开始的任务，等在飞那一个
///   回信（原生调用不可中断，回信前绝不能 release 借来的句柄）后再停掉 isolate。
/// * 后台 isolate 意外退出（未捕获错误）：在飞任务以错误结束（原生调用已随 isolate
///   结束而结束，此时归还借用是安全的），下一次查词重新拉起。
/// * 热重启 / 进程退出：VM 连同后台 isolate 一起收掉，无需额外清理。
class _BackgroundLookupClient {
  _BackgroundLookupClient() {
    _scheduler = LookupJobScheduler<_LookupJob, FushiLookupOutcome>(
      run: _send,
      onDropped: (_LookupJob job) => const FushiLookupOutcome.dropped(),
      laneOf: (_LookupJob job) => job.request.supersedeLane,
    );
  }

  static _BackgroundLookupClient? _current;

  static _BackgroundLookupClient get instance =>
      _current ??= _BackgroundLookupClient();

  late final LookupJobScheduler<_LookupJob, FushiLookupOutcome> _scheduler;

  RawReceivePort? _port;
  SendPort? _worker;
  Isolate? _isolate;
  Completer<SendPort>? _starting;
  int _nextId = 0;
  int _sentCatalogRevision = -1;
  bool _closed = false;
  final Map<int, Completer<FushiLookupOutcome>> _waiting =
      <int, Completer<FushiLookupOutcome>>{};

  Future<FushiLookupOutcome> submit(_LookupJob job) => _scheduler.submit(job);

  /// 让后台丢掉原始结果缓存（未启动时无事可做）。
  void clearCache() => _worker?.send(const _WorkerClearCache());

  static Future<void> shutdown() {
    final _BackgroundLookupClient? client = _current;
    _current = null;
    return client?._shutdown() ?? Future<void>.value();
  }

  Future<void> _shutdown() async {
    await _scheduler.drain();
    _closed = true;
    _worker?.send(const _WorkerStop());
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _teardown();
  }

  void _teardown() {
    _port?.close();
    _port = null;
    _worker = null;
    _isolate = null;
    _starting = null;
  }

  Future<FushiLookupOutcome> _send(_LookupJob job) async {
    if (_closed) return const FushiLookupOutcome.dropped();
    final SendPort worker = _worker ?? await _start();
    final int revision = TransformDescriptionCatalog.revision;
    if (revision != _sentCatalogRevision) {
      // 弹窗 JSON 的变形标签在后台按界面语言翻译（BUG-2038 只在显示路径翻）：
      // 后台 isolate 的静态译文表要先跟上。同一端口的消息按序到达，先于下面的请求。
      worker.send(
        _WorkerCatalog(
          TransformDescriptionCatalog.localeTag,
          TransformDescriptionCatalog.translations,
        ),
      );
      _sentCatalogRevision = revision;
    }
    final int id = _nextId++;
    final Completer<FushiLookupOutcome> reply = Completer<FushiLookupOutcome>();
    _waiting[id] = reply;
    _port?.keepIsolateAlive = true;
    worker.send(
      _WorkerLookup(
        id: id,
        address: job.address,
        libraryPath: job.libraryPath,
        engineSerial: job.engineSerial,
        request: job.request,
      ),
    );
    return reply.future;
  }

  Future<SendPort> _start() {
    final Completer<SendPort>? starting = _starting;
    if (starting != null) return starting.future;
    final Completer<SendPort> started = _starting = Completer<SendPort>();
    final RawReceivePort port = _port = RawReceivePort(_onMessage);
    port.keepIsolateAlive = true;
    Isolate.spawn<SendPort>(
      _backgroundLookupMain,
      port.sendPort,
      debugName: kBackgroundLookupIsolateName,
      onExit: port.sendPort,
      onError: port.sendPort,
      errorsAreFatal: true,
    ).then(
      (Isolate isolate) {
        if (identical(_port, port)) _isolate = isolate;
      },
      onError: (Object error, StackTrace stack) {
        if (!identical(_port, port)) return;
        _teardown();
        if (!started.isCompleted) started.completeError(error, stack);
      },
    );
    return started.future;
  }

  void _onMessage(Object? message) {
    if (message is SendPort) {
      _worker = message;
      final Completer<SendPort>? starting = _starting;
      if (starting != null && !starting.isCompleted) starting.complete(message);
      _updateKeepAlive();
      return;
    }
    if (message is _WorkerReply) {
      final Completer<FushiLookupOutcome>? reply = _waiting.remove(message.id);
      _updateKeepAlive();
      if (reply == null) return;
      debugLastBackgroundLookupIsolate = message.isolateName;
      final FushiLookupOutcome? outcome = message.outcome;
      if (outcome != null) {
        reply.complete(outcome);
      } else {
        reply.completeError(
          FushiBackgroundLookupException(
            message.error ?? 'unknown error',
            message.stack,
          ),
        );
      }
      return;
    }
    // onError（[错误文本, 栈]）或 onExit（null）：后台 isolate 没了。errorsAreFatal，
    // 两种情况它都已经不在执行任何原生调用，在飞任务以错误结束（借用随之归还）。
    final String reason = message is List && message.isNotEmpty
        ? '${message.first}'
        : 'background lookup isolate exited';
    final List<Completer<FushiLookupOutcome>> orphans = _waiting.values.toList(
      growable: false,
    );
    _waiting.clear();
    final Completer<SendPort>? starting = _starting;
    _teardown();
    if (starting != null && !starting.isCompleted) {
      starting.completeError(FushiBackgroundLookupException(reason));
    }
    for (final Completer<FushiLookupOutcome> orphan in orphans) {
      orphan.completeError(FushiBackgroundLookupException(reason));
    }
  }

  void _updateKeepAlive() {
    _port?.keepIsolateAlive = _waiting.isNotEmpty;
  }
}

/// 后台 isolate 入口。
void _backgroundLookupMain(SendPort host) {
  final RawReceivePort inbox = RawReceivePort();
  final FushiLookupFfiCache cache = FushiLookupFfiCache();
  final Map<String, FushidictsFfiBindings> bindingsByPath =
      <String, FushidictsFfiBindings>{};
  final String isolateName = Isolate.current.debugName ?? '';

  inbox.handler = (Object? message) {
    switch (message) {
      case _WorkerCatalog(:final String? localeTag, :final translations):
        if (localeTag == null) {
          TransformDescriptionCatalog.clear();
        } else {
          TransformDescriptionCatalog.apply(
            localeTag: localeTag,
            translations: translations,
          );
        }
      case _WorkerClearCache():
        cache.clear();
      case _WorkerStop():
        inbox.close();
      case final _WorkerLookup job:
        _WorkerReply reply;
        try {
          // 绑定与库路径覆盖都是 isolate 局部的：按宿主给的库路径在本 isolate 建
          // 一次绑定后复用。
          final FushidictsFfiBindings bindings = bindingsByPath.putIfAbsent(
            job.libraryPath ?? '',
            () {
              FushidictsFfiBindings.libraryPathOverride = job.libraryPath;
              return FushidictsFfiBindings();
            },
          );
          cache.bindEngine(job.engineSerial);
          reply = _WorkerReply(
            id: job.id,
            outcome: _computeLookupOutcome(
              bindings: bindings,
              handle: Pointer<Void>.fromAddress(job.address),
              request: job.request,
              cache: cache,
            ),
            isolateName: isolateName,
          );
        } catch (error, stack) {
          reply = _WorkerReply(
            id: job.id,
            error: '$error',
            stack: '$stack',
            isolateName: isolateName,
          );
        }
        host.send(reply);
      default:
        break;
    }
  };
  host.send(inbox.sendPort);
}
