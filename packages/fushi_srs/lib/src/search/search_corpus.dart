/// Anki 搜索的求值：整批卡一次交给 native/fushi_fsrs 的 `search.rs`（Rust `regex` crate，与
/// Anki 桌面版 rslib 同一个正则引擎），返回命中的卡。Dart 侧只剩解析器（search_parser.dart）。
///
/// 结构（名字、标签、牌组、模板、字段排布）在第一次搜索时装进原生侧；字段值只传查询要的列，
/// 文本量大时可先 [SrsSearchCorpus.prepare]（多 isolate 并行编码）；卡片的数值属性按查询用到的列
/// 惰性上传。逐卡跨 FFI 比 Dart 自己算还慢，所以只有这一个批量入口。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../ffi/fushi_fsrs_bindings.dart'
    show FfsrsChunkNewC, FfsrsChunkNewDart, FfsrsMatchC, FfsrsMatchDart;
import '../ffi/fushi_fsrs_library.dart';
import 'search_node.dart';

/// 原生排程内核（fushi_fsrs）不可用时的原因串。
const String kSrsSearchKernelUnavailable =
    'search kernel (fushi_fsrs) is not available';

/// 与 native/fushi_fsrs/src/search.rs 的 `IntColumn` / `FloatColumn` 同序。
enum _IntCol {
  state,
  noteId,
  cardId,
  addedDay,
  editedDay,
  today,
  flag,
  ordinal,
  interval,
  due,
  reps,
  lapses,
}

enum _FloatCol { stability, difficulty }

/// `search.rs` 的 `DUE_NONE`（没有到期日）。
const int _dueNone = -0x8000000000000000;

/// 字段值的按需来源：求值对象不常驻笔记字段文本时（浏览页的快照只装列表要显示的列），
/// 语料按查询要的列分页向它取，取一页、编码、挂进原生侧，再取下一页——Dart 堆上同时只有一页文本。
///
/// 给了它的语料**只经 [SrsSearchCorpus.prepare] 补传字段值**（取值是异步的）：[SrsSearchCorpus.match]
/// 发现还缺字段值时抛 [StateError]，调用方必须先 `await prepare`。
/// [subject] 所属笔记类型的字段别名：字段名 → 别名（`字段名:值` 按名字或别名命中）。只列有别名的字段；
/// 同一笔记类型的笔记必须给出同一份。用途：内置 Fushi 卡片改过名的字段仍认旧名（Yomitan 的
/// `Expression:…` 查重查询）。
typedef SrsSearchFieldAliases =
    Map<String, String> Function(SrsSearchSubject subject);

abstract interface class SrsSearchFieldLoader {
  /// [subject] 所属笔记的字段名，按笔记类型的字段顺序（同 [SrsSearchSubject.fields] 的键序；不含值）。
  List<String> fieldNames(SrsSearchSubject subject);

  /// 一页笔记的字段原文：`result[i][k]` 是 `notes[i]`（该笔记的代表卡）的 `names[i][k]` 字段；
  /// 没有值的字段给空串。
  Future<List<List<String>>> load(
    List<SrsSearchSubject> notes,
    List<List<String>> names,
  );
}

/// 一批卡的搜索语料。卡的顺序就是 [match] 返回下标的口径。
///
/// [SrsSearchSubject.noteKey] 相同的卡共用一份笔记文本（只装一次、笔记级条件只算一次）。
/// 原生侧先只装结构（名字、标签、牌组、模板、字段排布）；字段值按查询要的才上传
/// （`ffsrs_search_corpus_needs` 说要哪些字段名），只看状态 / 牌组 / 标签的查询完全不传字段文本，
/// `字段名:值` 只传那一列，未限定字段的文本 / `re:` 才传全部。传过的列之后的搜索复用。
/// 原生句柄随本对象被回收时释放，也可以 [dispose] 提前释放。
final class SrsSearchCorpus implements Finalizable {
  SrsSearchCorpus(
    this.cards, {
    FushiFsrs? library,
    SrsSearchFieldLoader? fieldLoader,
    SrsSearchFieldAliases? fieldAliases,
  }) : _library = library,
       _loader = fieldLoader,
       _aliases = fieldAliases;

  final List<SrsSearchSubject> cards;
  final FushiFsrs? _library;

  /// 字段名的别名（`字段名:值` 按名字或别名命中）；null = 都没有别名。
  final SrsSearchFieldAliases? _aliases;

  /// 字段值的按需来源；null = 直接读 [SrsSearchSubject.fields]。
  final SrsSearchFieldLoader? _loader;

  /// 正在经 [_loader] 分页补传字段值的那次 [prepare]（结束时完成并清空）：后来的 [prepare] 等它
  /// 传完再算要补哪些列，同一列不会被两次 [prepare] 各取一遍。
  Future<void>? _loading;

  Pointer<Void> _handle = nullptr;
  FushiFsrs? _bound;
  _Layout? _layout;
  final Set<_IntCol> _ints = <_IntCol>{};
  final Set<_FloatCol> _floats = <_FloatCol>{};
  bool _disposed = false;

  /// 原生侧大约占了多少字节（结构 + 已上传的字段值，去 HTML 等缓存粗估成同量）：报给 GC，
  /// 没 [dispose] 的旧语料才会被及时回收。
  int _nativeBytes = 0;

  /// 正在用原生句柄的后台 isolate 数（[prepare] 的预求值）；期间 [dispose] 推迟释放。
  int _busy = 0;

  /// 正在跑的后台预求值（结束时完成并清空）。原生侧求值期间一直持着语料锁，当前 isolate 上
  /// 写语料（挂字段值 / 数值列）或求值都得等它放锁——[prepare] 先异步等它退场再做这些同步调用。
  Future<void>? _background;

  /// 是否还有后台预求值在用原生句柄（测试用：[prepare] 返回后应为 false）。
  bool get backgroundBusy => _busy > 0;

  /// 每个字段排布的每个槽位是否已上传；[_allUploaded] = 全部字段已按笔记连续上传。
  late List<List<bool>> _slotUploaded;
  bool _allUploaded = false;

  int get length => cards.length;

  /// 命中 [node] 的卡（升序下标）。查询不合法（如正则写错）或原生内核不可用时抛
  /// [SrsSearchUnsupported]，**不退化成空集 / 全集**。[query] 只用于错误信息。
  List<int> match(SrsSearchNode node, {String query = ''}) {
    if (_disposed) throw StateError('SrsSearchCorpus disposed');
    if (node is SrsSearchAll) {
      return List<int>.generate(cards.length, (int i) => i);
    }
    if (cards.isEmpty) return const <int>[];
    final FushiFsrs lib = _lib(query);
    _ensureHandle(lib);
    final Pointer<Utf8> q = jsonEncode(_nodeJson(node)).toNativeUtf8();
    final Pointer<Uint8> out = calloc<Uint8>(cards.length);
    try {
      _ensureValues(
        lib,
        _call(
          lib,
          lib.bindings.ffsrs_search_corpus_needs(_handle, q.cast()),
          query,
        ),
      );
      _ensureColumns(lib, node);
      _call(
        lib,
        lib.bindings.ffsrs_search_corpus_match(
          _handle,
          q.cast(),
          out,
          cards.length,
        ),
        query,
      );
      final Uint8List bits = out.asTypedListOutOfLine(cards.length);
      return <int>[
        for (int i = 0; i < bits.length; i++)
          if (bits[i] != 0) i,
      ];
    } finally {
      calloc
        ..free(q)
        ..free(out);
    }
  }

  /// 读原生侧的 JSON 响应并释放；`{"error"}` 转成 [SrsSearchUnsupported]。
  Object? _call(FushiFsrs lib, Pointer<Char> resp, String query) {
    final String text;
    try {
      text = resp.cast<Utf8>().toDartString();
    } finally {
      lib.bindings.ffsrs_free_string(resp);
    }
    final Map<String, Object?> r = (jsonDecode(text) as Map)
        .cast<String, Object?>();
    if (r.containsKey('error')) {
      final bool syntax = r['kind'] == 'syntax';
      final String at = (r['at'] as String?) ?? '';
      throw SrsSearchUnsupported(
        at.isEmpty ? query : at,
        '${r['error']}',
        syntax ? SrsSearchErrorKind.syntax : SrsSearchErrorKind.unavailable,
      );
    }
    return r['ok'];
  }

  /// 提前释放原生句柄（之后不能再 [match]）。后台预求值还在跑时等它结束再释放。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_busy == 0) _freeHandle();
  }

  void _freeHandle() {
    final Pointer<Void> h = _handle;
    _handle = nullptr;
    final FushiFsrs? lib = _bound;
    if (h != nullptr && lib != null) {
      lib.bindings.searchCorpusFinalizer.detach(this);
      lib.bindings.ffsrs_search_corpus_free(h);
    }
  }

  FushiFsrs _lib(String query) {
    final FushiFsrs? lib = _library ?? FushiFsrs.instance;
    if (lib == null) {
      throw SrsSearchUnsupported(
        query,
        kSrsSearchKernelUnavailable,
        SrsSearchErrorKind.unavailable,
      );
    }
    return lib;
  }

  void _ensureHandle(FushiFsrs lib) {
    if (_handle != nullptr) return;
    final _Layout layout = _Layout.build(cards, _loader, _aliases);
    final Uint8List text = layout.text;
    final Pointer<Uint8> textPtr = malloc<Uint8>(
      text.isEmpty ? 1 : text.length,
    );
    final Pointer<Uint32> layoutPtr = malloc<Uint32>(layout.words.length);
    final Pointer<Pointer<Char>> err = calloc<Pointer<Char>>();
    try {
      textPtr.asTypedListOutOfLine(text.length).setAll(0, text);
      layoutPtr
          .asTypedListOutOfLine(layout.words.length)
          .setAll(0, layout.words);
      final Pointer<Void> h = lib.bindings.ffsrs_search_corpus_new(
        textPtr,
        text.length,
        layoutPtr,
        layout.words.length,
        err,
      );
      if (h == nullptr) {
        String reason = 'corpus rejected';
        if (err.value != nullptr) {
          reason = err.value.cast<Utf8>().toDartString();
          lib.bindings.ffsrs_free_string(err.value);
        }
        throw SrsSearchUnsupported(
          '',
          'search corpus: $reason',
          SrsSearchErrorKind.unavailable,
        );
      }
      _handle = h;
      _bound = lib;
      _layout = layout;
      _slotUploaded = <List<bool>>[
        for (final List<int> names in layout.schemaNames)
          List<bool>.filled(names.length, false),
      ];
      _nativeBytes = text.length + layout.words.length * 4;
      lib.bindings.searchCorpusFinalizer.attach(
        this,
        h,
        detach: this,
        externalSize: _nativeBytes,
      );
    } finally {
      malloc
        ..free(textPtr)
        ..free(layoutPtr);
      calloc.free(err);
    }
  }

  /// 把 [node] 求值的重活预先在后台做掉：字段文本分给多个 isolate 编码并校验（UTF-8 编码是首次
  /// 搜索的大头），量大时再在后台 isolate 上把这条查询求值一遍（去 HTML 等缓存与结果留在原生侧），
  /// 之后同一条查询的 [match] 只是取结果。查询不合法或原生内核不可用时抛 [SrsSearchUnsupported]
  /// （与 [match] 相同）；不调它直接 [match] 也对，只是全部在当前 isolate 上串行做。
  ///
  /// 上一条查询的后台预求值还没算完时又来一条（浏览页边打字边搜）：需求分析不拿语料锁，照常
  /// 同步做；写语料之前、以及返回之前都先异步等后台那次退场——返回后调用方同步 [match] 时不会
  /// 卡在当前 isolate 上等原生锁。
  Future<void> prepare(SrsSearchNode node, {String query = ''}) async {
    if (_disposed || node is SrsSearchAll || cards.isEmpty) return;
    final FushiFsrs lib = _lib(query);
    _ensureHandle(lib);
    final SrsSearchFieldLoader? loader = _loader;
    if (loader != null) {
      await _prepareLoaded(lib, loader, node, query);
      return;
    }
    final Object? needs = _needs(lib, node, query);
    final _UploadPlan? plan = _planFor(needs);
    // 去 HTML、正则扫几百 MB 原文的那部分：大集合才值得开一个 isolate 预先求值。
    final Map<String, Object?> n = (needs! as Map).cast<String, Object?>();
    final bool text =
        n['all'] == true || (n['names']! as List<Object?>).isNotEmpty;
    final bool warm = text && cards.length >= _warmMinCards;
    _Values? values;
    List<int> cuts = const <int>[];
    final List<_Encoded> encoded = <_Encoded>[];
    if (plan != null) {
      values = _collect(_layout!, plan);
      final int parts = values.chars < _parallelEncodeMinChars
          ? 1
          : Platform.numberOfProcessors.clamp(1, _maxEncodeIsolates);
      cuts = parts < 2 ? <int>[0, values.strings.length] : values.cuts(parts);
      final int chunkNew = lib.bindings.ffsrs_search_chunk_new_ptr.address;
      final List<Future<_Encoded>> jobs = <Future<_Encoded>>[
        for (int k = 0; k + 1 < cuts.length; k++)
          parts < 2
              ? Future<_Encoded>.value(
                  _encodeValues(
                    values.strings,
                    values.sep,
                    values.chars,
                    chunkNew,
                  ),
                )
              : _encodeInIsolate(
                  values.strings.sublist(cuts[k], cuts[k + 1]),
                  Uint8List.sublistView(values.sep, cuts[k], cuts[k + 1]),
                  values.charsBetween(cuts[k], cuts[k + 1]),
                  chunkNew,
                ),
      ];
      Object? error;
      StackTrace? stack;
      for (final Future<_Encoded> j in jobs) {
        try {
          encoded.add(await j);
        } catch (e, st) {
          error ??= e;
          stack ??= st;
        }
      }
      if (error != null) {
        _freeChunks(lib, encoded);
        Error.throwWithStackTrace(error, stack!);
      }
    }
    // 下面挂字段值、上传数值列、开后台预求值都要拿原生语料锁：先等别的查询的后台预求值退场。
    // 从这里到 Isolate.run 之间没有 await，别的 prepare 插不进来另起一个后台求值。
    if (!await _settleBackground()) {
      _freeChunks(lib, encoded);
      return;
    }
    if (plan != null) {
      _uploadValues(lib, values!, encoded, cuts);
      _markUploaded(plan);
    }
    if (!warm) return;
    await _warm(lib, node);
  }

  /// 等本语料上正在跑的后台预求值退场（异步等，不占当前 isolate）。返回 false = 等的期间已
  /// [dispose]。
  Future<bool> _settleBackground() async {
    for (Future<void>? b = _background; b != null; b = _background) {
      await b;
    }
    return !_disposed;
  }

  /// [prepare] 的按需取值版：字段值按笔记分页向 [loader] 取、编码、挂进原生侧（每页挂之前先等
  /// 后台预求值退场），Dart 堆上同时只有一页文本；之后照常在后台预求值。
  Future<void> _prepareLoaded(
    FushiFsrs lib,
    SrsSearchFieldLoader loader,
    SrsSearchNode node,
    String query,
  ) async {
    for (Future<void>? l = _loading; l != null; l = _loading) {
      await l;
    }
    if (_disposed) return;
    final Object? needs = _needs(lib, node, query);
    final _UploadPlan? plan = _planFor(needs);
    if (plan != null) {
      final Completer<void> done = Completer<void>();
      _loading = done.future;
      try {
        if (!await _uploadPaged(lib, loader, plan)) return;
        _markUploaded(plan);
      } finally {
        _loading = null;
        done.complete();
      }
    }
    if (!await _settleBackground()) return;
    final Map<String, Object?> n = (needs! as Map).cast<String, Object?>();
    final bool text =
        n['all'] == true || (n['names']! as List<Object?>).isNotEmpty;
    if (text && cards.length >= _warmMinCards) await _warm(lib, node);
  }

  /// 按 [plan] 分页取值、编码、挂进语料。返回 false = 期间已 [dispose]。
  Future<bool> _uploadPaged(
    FushiFsrs lib,
    SrsSearchFieldLoader loader,
    _UploadPlan plan,
  ) async {
    final _Layout layout = _layout!;
    final int chunkNew = lib.bindings.ffsrs_search_chunk_new_ptr.address;
    final int total = layout.notes.length;
    for (int from = 0; from < total; from += _loadPageNotes) {
      final int to = from + _loadPageNotes < total
          ? from + _loadPageNotes
          : total;
      final List<int> page = <int>[];
      final List<SrsSearchSubject> subjects = <SrsSearchSubject>[];
      final List<List<String>> names = <List<String>>[];
      for (int i = from; i < to; i++) {
        final int schema = layout.noteSchema[i];
        final List<bool> wanted = plan.wanted[schema];
        final List<String> all = layout.schemaNameText[schema];
        final List<String> want = <String>[
          for (int k = 0; k < all.length; k++)
            if (wanted[k]) all[k],
        ];
        if (want.isEmpty) continue;
        page.add(i);
        subjects.add(layout.notes[i]);
        names.add(want);
      }
      if (page.isEmpty) continue;
      final List<List<String>> loaded = await loader.load(subjects, names);
      if (_disposed) return false;
      if (loaded.length != page.length) {
        throw StateError(
          'SrsSearchFieldLoader.load returned ${loaded.length} notes '
          'for ${page.length}',
        );
      }
      final _Values values = _collectLoaded(layout, plan, page, loaded);
      final _Encoded encoded = _encodeValues(
        values.strings,
        values.sep,
        values.chars,
        chunkNew,
      );
      // 挂进语料要拿原生锁：先等别的查询的后台预求值退场（从这里到挂完没有 await）。
      if (!await _settleBackground()) {
        _freeChunks(lib, <_Encoded>[encoded]);
        return false;
      }
      _uploadValues(
        lib,
        values,
        <_Encoded>[encoded],
        <int>[0, values.strings.length],
      );
    }
    return true;
  }

  /// 后台 isolate 上把 [node] 求值一遍（去 HTML 等缓存与结果留在原生侧），之后同一条查询的
  /// [match] 只是取结果。
  Future<void> _warm(FushiFsrs lib, SrsSearchNode node) async {
    _ensureColumns(lib, node);
    final int handle = _handle.address;
    final int matchFn = lib.bindings.ffsrs_search_corpus_match_ptr.address;
    final String json = jsonEncode(_nodeJson(node));
    final int count = cards.length;
    final Completer<void> done = Completer<void>();
    _background = done.future;
    _busy++;
    try {
      final int resp = await Isolate.run(
        () => _warmMatch(matchFn, handle, json, count),
      );
      // 出错（如正则不合法）也只是没缓存上：[match] 会再报一次。
      lib.bindings.ffsrs_free_string(Pointer<Char>.fromAddress(resp));
    } finally {
      _busy--;
      if (identical(_background, done.future)) _background = null;
      done.complete();
      if (_disposed && _busy == 0) _freeHandle();
    }
    // 等自己的预求值的期间，后来的查询可能又起了一个：同样等它退场再交还调用方。
    await _settleBackground();
  }

  /// 丢弃编好但没挂进语料的文本块。
  void _freeChunks(FushiFsrs lib, List<_Encoded> encoded) {
    for (final _Encoded e in encoded) {
      lib.bindings.ffsrs_search_chunk_free(Pointer<Void>.fromAddress(e.chunk));
    }
  }

  Object? _needs(FushiFsrs lib, SrsSearchNode node, String query) {
    final Pointer<Utf8> q = jsonEncode(_nodeJson(node)).toNativeUtf8();
    try {
      return _call(
        lib,
        lib.bindings.ffsrs_search_corpus_needs(_handle, q.cast()),
        query,
      );
    } finally {
      calloc.free(q);
    }
  }

  /// 上传 [node] 用到、还没传的数值列。
  void _ensureColumns(FushiFsrs lib, SrsSearchNode node) {
    final Set<_IntCol> ints = <_IntCol>{};
    final Set<_FloatCol> floats = <_FloatCol>{};
    _columnsOf(node, ints, floats);
    for (final _IntCol c in ints.difference(_ints)) {
      _uploadInts(lib, c);
    }
    for (final _FloatCol c in floats.difference(_floats)) {
      _uploadFloats(lib, c);
    }
  }

  /// 按 `ffsrs_search_corpus_needs` 的回答补传还没传的字段值（当前 isolate 上串行编码）。
  void _ensureValues(FushiFsrs lib, Object? needs) {
    final _UploadPlan? plan = _planFor(needs);
    if (plan == null) return;
    if (_loader != null) {
      throw StateError(
        'SrsSearchCorpus: field values come from an SrsSearchFieldLoader; '
        'await prepare() before match()',
      );
    }
    final _Values values = _collect(_layout!, plan);
    _uploadValues(
      lib,
      values,
      <_Encoded>[
        _encodeValues(
          values.strings,
          values.sep,
          values.chars,
          lib.bindings.ffsrs_search_chunk_new_ptr.address,
        ),
      ],
      <int>[0, values.strings.length],
    );
    _markUploaded(plan);
  }

  /// 还要传哪些（字段排布, 槽位）；什么都不用传时返回 null。
  _UploadPlan? _planFor(Object? needs) {
    final Map<String, Object?> n = (needs! as Map).cast<String, Object?>();
    final _Layout layout = _layout!;
    if (_allUploaded) return null;
    if (n['all'] == true) {
      // 全部字段按笔记连续上传、同一笔记的字段之间隔 0x1f：原生侧的 `n.flds` 直接切片，不再拼接。
      return _UploadPlan(<List<bool>>[
        for (final List<int> names in layout.schemaNames)
          List<bool>.filled(names.length, true),
      ], joined: true);
    }
    final Set<int> names = <int>{
      for (final Object? id in n['names']! as List<Object?>) id! as int,
    };
    bool any = false;
    final List<List<bool>> wanted = <List<bool>>[];
    for (int s = 0; s < layout.schemaNames.length; s++) {
      final List<int> slots = layout.schemaNames[s];
      final List<bool> row = List<bool>.filled(slots.length, false);
      for (int k = 0; k < slots.length; k++) {
        if (!_slotUploaded[s][k] && names.contains(slots[k])) {
          row[k] = true;
          any = true;
        }
      }
      wanted.add(row);
    }
    return any ? _UploadPlan(wanted, joined: false) : null;
  }

  void _markUploaded(_UploadPlan plan) {
    if (plan.joined) _allUploaded = true;
    for (int s = 0; s < plan.wanted.length; s++) {
      for (int k = 0; k < plan.wanted[s].length; k++) {
        if (plan.wanted[s][k]) _slotUploaded[s][k] = true;
      }
    }
  }

  /// 按 [plan] 取出要传的字段值（笔记顺序，同一笔记内按槽位顺序）。
  static _Values _collect(_Layout layout, _UploadPlan plan) {
    final List<String> strings = <String>[];
    final List<int> fieldIds = <int>[];
    final List<int> sep = <int>[];
    final List<int> noteStarts = <int>[];
    int chars = 0;
    for (int i = 0; i < layout.notes.length; i++) {
      final int schema = layout.noteSchema[i];
      final List<bool> wanted = plan.wanted[schema];
      final List<String> names = layout.schemaNameText[schema];
      final Map<String, String> fields = layout.notes[i].fields;
      final int base = layout.noteFieldBase[i];
      bool first = true;
      for (int k = 0; k < names.length; k++) {
        if (!wanted[k]) continue;
        if (first) noteStarts.add(strings.length);
        final String v = fields[names[k]]!;
        strings.add(v);
        fieldIds.add(base + k);
        sep.add(plan.joined && !first ? 1 : 0);
        chars += v.length + 1;
        first = false;
      }
    }
    return _Values(
      strings,
      Uint32List.fromList(fieldIds),
      Uint8List.fromList(sep),
      noteStarts,
      chars,
    );
  }

  /// [_collect] 的按需取值版：[page] 是这一页的笔记下标，[loaded] 是它们按 [plan] 取回的字段值。
  static _Values _collectLoaded(
    _Layout layout,
    _UploadPlan plan,
    List<int> page,
    List<List<String>> loaded,
  ) {
    final List<String> strings = <String>[];
    final List<int> fieldIds = <int>[];
    final List<int> sep = <int>[];
    final List<int> noteStarts = <int>[];
    int chars = 0;
    for (int p = 0; p < page.length; p++) {
      final int i = page[p];
      final List<bool> wanted = plan.wanted[layout.noteSchema[i]];
      final List<String> values = loaded[p];
      final int base = layout.noteFieldBase[i];
      int at = 0;
      bool first = true;
      for (int k = 0; k < wanted.length; k++) {
        if (!wanted[k]) continue;
        if (at >= values.length) {
          throw StateError('SrsSearchFieldLoader.load: missing field values');
        }
        if (first) noteStarts.add(strings.length);
        final String v = values[at++];
        strings.add(v);
        fieldIds.add(base + k);
        sep.add(plan.joined && !first ? 1 : 0);
        chars += v.length + 1;
        first = false;
      }
    }
    return _Values(
      strings,
      Uint32List.fromList(fieldIds),
      Uint8List.fromList(sep),
      noteStarts,
      chars,
    );
  }

  /// 把编码好的各段（[cuts] 划分 [values]）挂进语料；文本块的所有权交给原生侧。
  void _uploadValues(
    FushiFsrs lib,
    _Values values,
    List<_Encoded> encoded,
    List<int> cuts,
  ) {
    int k = 0;
    try {
      for (; k < encoded.length; k++) {
        final _Encoded e = encoded[k];
        final int from = cuts[k];
        final int n = cuts[k + 1] - from;
        final Pointer<Uint32> fieldPtr = malloc<Uint32>(n == 0 ? 1 : n);
        final Pointer<Uint32> spanPtr = malloc<Uint32>(n == 0 ? 1 : n * 2);
        try {
          fieldPtr
              .asTypedListOutOfLine(n)
              .setRange(0, n, values.fieldIds, from);
          spanPtr.asTypedListOutOfLine(n * 2).setAll(0, e.spans);
          if (lib.bindings.ffsrs_search_corpus_attach(
                _handle,
                Pointer<Void>.fromAddress(e.chunk),
                fieldPtr,
                n,
                spanPtr,
              ) !=
              0) {
            throw const SrsSearchUnsupported(
              '',
              'ffsrs_search_corpus_attach rejected the field values',
              SrsSearchErrorKind.unavailable,
            );
          }
        } finally {
          malloc
            ..free(fieldPtr)
            ..free(spanPtr);
        }
      }
      // 字段值动辄几百 MB：重新挂一次终结器，把新的量报给 GC。
      int added = 0;
      for (final _Encoded e in encoded) {
        added += e.bytes;
      }
      _nativeBytes += added * 2;
      lib.bindings.searchCorpusFinalizer
        ..detach(this)
        ..attach(this, _handle, detach: this, externalSize: _nativeBytes);
    } finally {
      // attach 无论成败都接管了块；没轮到的块在这里释放。
      for (int j = k + 1; j < encoded.length; j++) {
        lib.bindings.ffsrs_search_chunk_free(
          Pointer<Void>.fromAddress(encoded[j].chunk),
        );
      }
    }
  }

  void _uploadInts(FushiFsrs lib, _IntCol col) {
    final int n = cards.length;
    final Pointer<Int64> p = malloc<Int64>(n);
    try {
      final Int64List v = p.asTypedListOutOfLine(n);
      for (int i = 0; i < n; i++) {
        final SrsSearchSubject s = cards[i];
        v[i] = switch (col) {
          _IntCol.state =>
            (s.isNew ? 1 : 0) |
                (s.isLearn ? 2 : 0) |
                (s.isReview ? 4 : 0) |
                (s.isDue ? 8 : 0) |
                (s.isSuspended ? 16 : 0) |
                (s.isBuried ? 32 : 0),
          _IntCol.noteId => s.noteId,
          _IntCol.cardId => s.cardId,
          _IntCol.addedDay => s.addedDayIndex,
          _IntCol.editedDay => s.editedDayIndex,
          _IntCol.today => s.todayDayIndex,
          _IntCol.flag => s.flag,
          _IntCol.ordinal => s.cardOrdinal,
          _IntCol.interval => s.intervalDays,
          _IntCol.due => s.dueInDays ?? _dueNone,
          _IntCol.reps => s.reps,
          _IntCol.lapses => s.lapses,
        };
      }
      if (lib.bindings.ffsrs_search_corpus_set_ints(_handle, col.index, p, n) !=
          0) {
        throw SrsSearchUnsupported(
          '',
          'ffsrs_search_corpus_set_ints rejected ${col.name}',
          SrsSearchErrorKind.unavailable,
        );
      }
      _ints.add(col);
    } finally {
      malloc.free(p);
    }
  }

  void _uploadFloats(FushiFsrs lib, _FloatCol col) {
    final int n = cards.length;
    final Pointer<Double> p = malloc<Double>(n);
    try {
      final Float64List v = p.asTypedListOutOfLine(n);
      for (int i = 0; i < n; i++) {
        final SrsSearchSubject s = cards[i];
        v[i] =
            (col == _FloatCol.stability ? s.stability : s.difficulty) ??
            double.nan;
      }
      if (lib.bindings.ffsrs_search_corpus_set_floats(
            _handle,
            col.index,
            p,
            n,
          ) !=
          0) {
        throw SrsSearchUnsupported(
          '',
          'ffsrs_search_corpus_set_floats rejected ${col.name}',
          SrsSearchErrorKind.unavailable,
        );
      }
      _floats.add(col);
    } finally {
      malloc.free(p);
    }
  }
}

/// 查询用到的数值列。
void _columnsOf(SrsSearchNode node, Set<_IntCol> ints, Set<_FloatCol> floats) {
  switch (node) {
    case SrsSearchAnd(:final List<SrsSearchNode> children) ||
        SrsSearchOr(:final List<SrsSearchNode> children):
      for (final SrsSearchNode c in children) {
        _columnsOf(c, ints, floats);
      }
    case SrsSearchNot(:final SrsSearchNode child):
      _columnsOf(child, ints, floats);
    case SrsSearchState():
      ints.add(_IntCol.state);
    case SrsSearchNoteIds():
      ints.add(_IntCol.noteId);
    case SrsSearchCardIds():
      ints.add(_IntCol.cardId);
    case SrsSearchAddedInDays():
      ints.addAll(<_IntCol>[_IntCol.addedDay, _IntCol.today]);
    case SrsSearchEditedInDays():
      ints.addAll(<_IntCol>[_IntCol.editedDay, _IntCol.today]);
    case SrsSearchFlag():
      ints.add(_IntCol.flag);
    case SrsSearchCardTemplate(:final int? ordinal):
      if (ordinal != null) ints.add(_IntCol.ordinal);
    case SrsSearchProp(:final SrsSearchProperty property):
      switch (property) {
        case SrsSearchProperty.interval:
          ints.add(_IntCol.interval);
        case SrsSearchProperty.due:
          ints.add(_IntCol.due);
        case SrsSearchProperty.reps:
          ints.add(_IntCol.reps);
        case SrsSearchProperty.lapses:
          ints.add(_IntCol.lapses);
        case SrsSearchProperty.stability:
          floats.add(_FloatCol.stability);
        case SrsSearchProperty.difficulty:
          floats.add(_FloatCol.difficulty);
      }
    case SrsSearchAll() ||
        SrsSearchText() ||
        SrsSearchField() ||
        SrsSearchDeck() ||
        SrsSearchNoteType() ||
        SrsSearchTag() ||
        SrsSearchRegex() ||
        SrsSearchFieldRegex():
      break;
  }
}

/// 语法树 → `search.rs` 的 `Node` JSON。
Map<String, Object?> _nodeJson(SrsSearchNode node) => switch (node) {
  SrsSearchAll() => <String, Object?>{'t': 'all'},
  SrsSearchAnd(:final List<SrsSearchNode> children) => <String, Object?>{
    't': 'and',
    'c': <Object?>[for (final SrsSearchNode c in children) _nodeJson(c)],
  },
  SrsSearchOr(:final List<SrsSearchNode> children) => <String, Object?>{
    't': 'or',
    'c': <Object?>[for (final SrsSearchNode c in children) _nodeJson(c)],
  },
  SrsSearchNot(:final SrsSearchNode child) => <String, Object?>{
    't': 'not',
    'c': _nodeJson(child),
  },
  SrsSearchText(:final String text) => <String, Object?>{
    't': 'text',
    'v': text,
  },
  SrsSearchField(:final String field, :final String text) => <String, Object?>{
    't': 'field',
    'f': field,
    'v': text,
  },
  SrsSearchDeck(:final String deck) => <String, Object?>{
    't': 'deck',
    'v': deck,
  },
  SrsSearchNoteType(:final String name) => <String, Object?>{
    't': 'note',
    'v': name,
  },
  SrsSearchTag(:final String tag) => <String, Object?>{'t': 'tag', 'v': tag},
  SrsSearchState(:final SrsSearchCardState state) => <String, Object?>{
    't': 'state',
    'v': switch (state) {
      SrsSearchCardState.isNew => 'new',
      SrsSearchCardState.learn => 'learn',
      SrsSearchCardState.review => 'review',
      SrsSearchCardState.due => 'due',
      SrsSearchCardState.suspended => 'suspended',
      SrsSearchCardState.buried => 'buried',
    },
  },
  SrsSearchRegex(:final String source, :final String pattern) =>
    <String, Object?>{'t': 're', 'v': pattern, 'at': 're:$source'},
  SrsSearchFieldRegex(
    :final String field,
    :final String source,
    :final String pattern,
  ) =>
    <String, Object?>{
      't': 'fre',
      'f': field,
      'v': pattern,
      'at': '$field:re:$source',
    },
  SrsSearchFlag(:final int flag) => <String, Object?>{'t': 'flag', 'v': flag},
  SrsSearchCardTemplate(:final int? ordinal, :final String? name) =>
    ordinal != null
        ? <String, Object?>{'t': 'cardord', 'v': ordinal}
        : <String, Object?>{'t': 'cardname', 'v': name},
  SrsSearchEditedInDays(:final int days) => <String, Object?>{
    't': 'edited',
    'v': days,
  },
  SrsSearchAddedInDays(:final int days) => <String, Object?>{
    't': 'added',
    'v': days,
  },
  SrsSearchProp(
    :final SrsSearchProperty property,
    :final SrsSearchCompare compare,
    :final num value,
  ) =>
    <String, Object?>{
      't': 'prop',
      'p': switch (property) {
        SrsSearchProperty.interval => 'ivl',
        SrsSearchProperty.due => 'due',
        SrsSearchProperty.reps => 'reps',
        SrsSearchProperty.lapses => 'lapses',
        SrsSearchProperty.stability => 's',
        SrsSearchProperty.difficulty => 'd',
      },
      'op': compare.name,
      'v': value.toDouble(),
      if (value is int) 'iv': value,
    },
  SrsSearchNoteIds(:final Set<int> ids) => <String, Object?>{
    't': 'nid',
    'v': ids.toList(),
  },
  SrsSearchCardIds(:final Set<int> ids) => <String, Object?>{
    't': 'cid',
    'v': ids.toList(),
  },
};

/// 文本少于这么多 UTF-16 码元时不开 isolate（开 isolate 的固定开销约几毫秒，量小时串行更快）。
const int _parallelEncodeMinChars = 4 << 20;

/// 并行编码最多用的 isolate 数。
const int _maxEncodeIsolates = 8;

/// 卡数到这么多才在 [SrsSearchCorpus.prepare] 里开 isolate 预求值文本条件。
const int _warmMinCards = 5000;

/// 经 [SrsSearchFieldLoader] 取字段值时每页的笔记数。
const int _loadPageNotes = 2000;

/// 一次上传选中的（字段排布, 槽位）；[joined] = 全部字段按笔记连续排、同一笔记的字段隔 0x1f。
final class _UploadPlan {
  const _UploadPlan(this.wanted, {required this.joined});

  final List<List<bool>> wanted;
  final bool joined;
}

/// 要上传的字段值（[sep] 为 1 的值前面先写一个 0x1f）。
final class _Values {
  const _Values(
    this.strings,
    this.fieldIds,
    this.sep,
    this.noteStarts,
    this.chars,
  );

  final List<String> strings;
  final Uint32List fieldIds;
  final Uint8List sep;

  /// 每条笔记第一个值的下标（切分只能落在这里，同一笔记的值必须在同一段里才能连续）。
  final List<int> noteStarts;
  final int chars;

  int charsBetween(int from, int to) {
    int n = 0;
    for (int i = from; i < to; i++) {
      n += strings[i].length + 1;
    }
    return n;
  }

  /// 按文本量大致均分成 [parts] 段，切点落在笔记边界；返回含首尾的切点。
  List<int> cuts(int parts) {
    final List<int> out = <int>[0];
    final double per = chars / parts;
    int acc = 0;
    int next = 0;
    for (int i = 0; i < strings.length; i++) {
      if (out.length < parts && acc >= per * out.length) {
        while (next < noteStarts.length && noteStarts[next] < i) {
          next++;
        }
        if (next < noteStarts.length && noteStarts[next] == i && i > out.last) {
          out.add(i);
        }
      }
      acc += strings[i].length + 1;
    }
    out.add(strings.length);
    return out;
  }
}

/// 一段编码结果：原生侧已校验、拷下的文本块（`ffsrs_search_chunk_new` 的句柄地址）与每个值的
/// [start, end)。
final class _Encoded {
  const _Encoded(this.chunk, this.spans, this.bytes);

  final int chunk;
  final Uint32List spans;

  /// 文本块的字节数。
  final int bytes;
}

/// 把 [values] 编成 UTF-8，交给 `ffsrs_search_chunk_new`（[chunkNew] 是它的函数指针地址）校验、
/// 拷成原生侧的文本块。可在任意 isolate 上跑：原生内存与函数指针进程内共享。
_Encoded _encodeValues(
  List<String> values,
  Uint8List sep,
  int estimate,
  int chunkNew,
) {
  final _NativeUtf8Writer w = _NativeUtf8Writer(estimate);
  try {
    final Uint32List spans = Uint32List(values.length * 2);
    for (int i = 0; i < values.length; i++) {
      if (sep[i] != 0) w.writeByte(0x1f);
      spans[2 * i] = w.length;
      w.write(values[i]);
      spans[2 * i + 1] = w.length;
    }
    if (w.length > 0xFFFFFFFF) {
      throw const SrsSearchUnsupported(
        '',
        'search field values larger than 4 GiB',
        SrsSearchErrorKind.unavailable,
      );
    }
    final Pointer<Void> chunk =
        Pointer<NativeFunction<FfsrsChunkNewC>>.fromAddress(
          chunkNew,
        ).asFunction<FfsrsChunkNewDart>()(w.pointer, w.length);
    if (chunk == nullptr) {
      throw const SrsSearchUnsupported(
        '',
        'ffsrs_search_chunk_new rejected the field values',
        SrsSearchErrorKind.unavailable,
      );
    }
    return _Encoded(chunk.address, spans, w.length);
  } finally {
    w.free();
  }
}

/// 在新 isolate 上 [_encodeValues]（顶层函数：闭包只捕获参数，不带上语料对象）。
Future<_Encoded> _encodeInIsolate(
  List<String> values,
  Uint8List sep,
  int estimate,
  int chunkNew,
) => Isolate.run(() => _encodeValues(values, sep, estimate, chunkNew));

/// 后台 isolate 上调一次 `ffsrs_search_corpus_match`（结果缓存在原生侧）；返回响应串的地址，
/// 由调用方释放。
int _warmMatch(int matchFn, int handle, String query, int count) {
  final Pointer<Utf8> q = query.toNativeUtf8();
  final Pointer<Uint8> out = malloc<Uint8>(count);
  try {
    return Pointer<NativeFunction<FfsrsMatchC>>.fromAddress(matchFn)
        .asFunction<FfsrsMatchDart>()(
          Pointer<Void>.fromAddress(handle),
          q.cast(),
          out,
          count,
        )
        .address;
  } finally {
    malloc
      ..free(q)
      ..free(out);
  }
}

/// 布局里「这个字段没有别名」（search.rs `NO_ALIAS`）。
const int _kNoAlias = 0xFFFFFFFF;

/// `search.rs` `Corpus::new` 的布局：名字类字符串（去重）的 UTF-8 拼接 + u32 数组；字段值不在这里
/// （按需由 [SrsSearchCorpus.prepare] / [SrsSearchCorpus.match] 另传）。
class _Layout {
  _Layout._(
    this.text,
    this.words,
    this.notes,
    this.noteSchema,
    this.noteFieldBase,
    this.schemaNames,
    this.schemaNameText,
  );

  final Uint8List text;
  final Uint32List words;

  /// 每条笔记取它的第一张卡作字段来源。
  final List<SrsSearchSubject> notes;
  final Int32List noteSchema;

  /// 第 i 条笔记第一个字段在原生侧的全局字段号。
  final Int32List noteFieldBase;

  /// 字段排布：字段名的字符串 id / 原文。
  final List<List<int>> schemaNames;
  final List<List<String>> schemaNameText;

  static _Layout build(
    List<SrsSearchSubject> cards,
    SrsSearchFieldLoader? loader,
    SrsSearchFieldAliases? aliasesOf,
  ) {
    final BytesBuilder bytes = BytesBuilder(copy: false);
    final List<int> strOff = <int>[0];
    final Map<String, int> interned = <String, int>{};
    int total = 0;
    int intern(String s) => interned[s] ??= () {
      final Uint8List b = utf8.encode(s);
      bytes.add(b);
      total += b.length;
      strOff.add(total);
      return strOff.length - 2;
    }();

    final List<List<int>> schemaNames = <List<int>>[];
    final List<List<String>> schemaNameText = <List<String>>[];
    // 与 schemaNames 对齐：每个槽位的别名字符串 id（[_kNoAlias] = 没有）。
    final List<List<int>> schemaAlias = <List<int>>[];
    final List<Map<String, String>> schemaAliasText = <Map<String, String>>[];
    // 笔记类型名 → 用过的字段排布（同一类型的笔记几乎总是同一份，逐个比字段名即可认出）。
    final Map<String, List<int>> schemasByType = <String, List<int>>{};
    int schemaOf(
      String type,
      Iterable<String> fieldNames,
      Map<String, String> aliases,
    ) {
      final List<int> candidates = schemasByType[type] ??= <int>[];
      final List<String> wanted = fieldNames.toList(growable: false);
      for (final int s in candidates) {
        final List<String> names = schemaNameText[s];
        if (names.length != wanted.length) continue;
        int k = 0;
        bool same = true;
        for (final String name in wanted) {
          if (name != names[k++] || aliases[name] != schemaAliasText[s][name]) {
            same = false;
            break;
          }
        }
        if (same) return s;
      }
      final List<String> names = wanted;
      schemaNameText.add(names);
      schemaNames.add(<int>[for (final String n in names) intern(n)]);
      schemaAliasText.add(aliases);
      schemaAlias.add(<int>[
        for (final String n in names)
          if (aliases[n] case final String a) intern(a) else _kNoAlias,
      ]);
      candidates.add(schemaNames.length - 1);
      return schemaNames.length - 1;
    }

    final Map<Object, int> noteIndex = <Object, int>{};
    final List<SrsSearchSubject> notes = <SrsSearchSubject>[];
    final List<int> noteType = <int>[];
    final List<int> noteSchema = <int>[];
    final List<int> noteFieldBase = <int>[];
    int fieldCount = 0;
    final List<int> noteTagOff = <int>[0];
    final List<int> tag = <int>[];
    final Uint32List cardNote = Uint32List(cards.length);
    final Uint32List cardDeck = Uint32List(cards.length);
    final Uint32List cardTpl = Uint32List(cards.length);
    for (int i = 0; i < cards.length; i++) {
      final SrsSearchSubject c = cards[i];
      final int note = noteIndex.putIfAbsent(c.noteKey, () {
        final String type = c.noteTypeName;
        noteType.add(intern(type));
        final int schema = schemaOf(
          type,
          loader?.fieldNames(c) ?? c.fields.keys,
          aliasesOf?.call(c) ?? const <String, String>{},
        );
        noteSchema.add(schema);
        noteFieldBase.add(fieldCount);
        fieldCount += schemaNames[schema].length;
        for (final String t in c.tags) {
          tag.add(intern(t));
        }
        noteTagOff.add(tag.length);
        notes.add(c);
        return notes.length - 1;
      });
      cardNote[i] = note;
      cardDeck[i] = intern(c.deckName);
      cardTpl[i] = intern(c.templateName);
    }
    final List<int> schemaOff = <int>[0];
    for (final List<int> names in schemaNames) {
      schemaOff.add(schemaOff.last + names.length);
    }
    final int nStr = strOff.length - 1;
    final Uint32List words = Uint32List.fromList(<int>[
      nStr,
      schemaNames.length,
      schemaOff.last,
      notes.length,
      tag.length,
      cards.length,
      ...strOff,
      ...schemaOff,
      for (final List<int> names in schemaNames) ...names,
      for (final List<int> aliases in schemaAlias) ...aliases,
      ...noteType,
      ...noteSchema,
      ...noteTagOff,
      ...tag,
      ...cardNote,
      ...cardDeck,
      ...cardTpl,
    ]);
    if (fieldCount > 0xFFFFFFFF || total > 0xFFFFFFFF) {
      throw const SrsSearchUnsupported(
        '',
        'search corpus too large',
        SrsSearchErrorKind.unavailable,
      );
    }
    return _Layout._(
      bytes.takeBytes(),
      words,
      notes,
      Int32List.fromList(noteSchema),
      Int32List.fromList(noteFieldBase),
      schemaNames,
      schemaNameText,
    );
  }
}

/// 直接写进 native 缓冲区的 UTF-8 编码器（省掉 `utf8.encode` 每串一份的中间数组和之后的整体拷贝）。
/// 语义与 `utf8.encode` 一致：孤立代理写成 U+FFFD。
class _NativeUtf8Writer {
  _NativeUtf8Writer(int estimate)
    : _cap = estimate < 16 ? 16 : estimate,
      _ptr = malloc<Uint8>(estimate < 16 ? 16 : estimate) {
    _buf = _ptr.asTypedListOutOfLine(_cap);
  }

  int _cap;
  Pointer<Uint8> _ptr;
  late Uint8List _buf;
  int length = 0;

  Pointer<Uint8> get pointer => _ptr;

  void _grow(int need) {
    int cap = _cap + (_cap >> 1);
    if (cap < need) cap = need + (need >> 3);
    final Pointer<Uint8> next = malloc<Uint8>(cap);
    final Uint8List nextBuf = next.asTypedListOutOfLine(cap);
    nextBuf.setRange(0, length, _buf);
    malloc.free(_ptr);
    _ptr = next;
    _buf = nextBuf;
    _cap = cap;
  }

  void writeByte(int b) {
    if (length + 1 > _cap) _grow(length + 1);
    _buf[length++] = b;
  }

  void write(String s) {
    final int n = s.length;
    // 最坏每个 UTF-16 码元 3 字节；剩余空间够最坏情况走快路径，不够时逐字检查、按需扩容
    // （估算是按码元数给的，ASCII 为主的文本基本不会扩容）。
    if (length + n * 3 > _cap) {
      _writeChecked(s);
      return;
    }
    length = _encode(s, 0, n, _buf, length);
  }

  void _writeChecked(String s) {
    final int n = s.length;
    int i = 0;
    while (i < n) {
      final int room = (_cap - length) ~/ 3;
      if (room < 3) {
        _grow(length + (n - i) + 8);
        continue;
      }
      // 每段至少留出一个码元的余量，代理对不会被切开。
      int end = i + room - 1;
      if (end > n) end = n;
      if (end < n && _isLead(s.codeUnitAt(end - 1))) end--;
      length = _encode(s, i, end, _buf, length);
      i = end;
    }
  }

  static bool _isLead(int c) => c >= 0xD800 && c < 0xDC00;

  /// 编码 `s[from..to)` 写到 `buf[at..]`，返回新的写入位置（调用方保证空间够 3 × 码元数）。
  static int _encode(String s, int from, int to, Uint8List buf, int at) {
    for (int i = from; i < to; i++) {
      int c = s.codeUnitAt(i);
      if (c < 0x80) {
        buf[at++] = c;
      } else if (c < 0x800) {
        buf[at++] = 0xC0 | (c >> 6);
        buf[at++] = 0x80 | (c & 0x3F);
      } else {
        if (c >= 0xD800 && c < 0xE000) {
          if (c < 0xDC00 && i + 1 < to) {
            final int d = s.codeUnitAt(i + 1);
            if (d >= 0xDC00 && d < 0xE000) {
              final int cp = 0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00);
              buf[at++] = 0xF0 | (cp >> 18);
              buf[at++] = 0x80 | ((cp >> 12) & 0x3F);
              buf[at++] = 0x80 | ((cp >> 6) & 0x3F);
              buf[at++] = 0x80 | (cp & 0x3F);
              i++;
              continue;
            }
          }
          c = 0xFFFD;
        }
        buf[at++] = 0xE0 | (c >> 12);
        buf[at++] = 0x80 | ((c >> 6) & 0x3F);
        buf[at++] = 0x80 | (c & 0x3F);
      }
    }
    return at;
  }

  void free() => malloc.free(_ptr);
}

/// AnkiConnect 查重比较用的首字段规范形（按样式去重规范形 → 去 HTML → trim），批量走
/// `ffsrs_search_dupe_norm_batch`。原生内核不可用时抛 [SrsSearchUnsupported]
/// （[SrsSearchErrorKind.unavailable]）。
List<String> srsDupeNormBatch(List<String> fields, {FushiFsrs? library}) {
  if (fields.isEmpty) return const <String>[];
  final FushiFsrs? lib = library ?? FushiFsrs.instance;
  if (lib == null) {
    throw const SrsSearchUnsupported(
      '',
      kSrsSearchKernelUnavailable,
      SrsSearchErrorKind.unavailable,
    );
  }
  final List<Uint8List> encoded = <Uint8List>[
    for (final String f in fields) utf8.encode(f),
  ];
  int total = 0;
  for (final Uint8List e in encoded) {
    total += e.length;
  }
  final Pointer<Uint8> text = malloc<Uint8>(total == 0 ? 1 : total);
  final Pointer<Uint32> offs = malloc<Uint32>(fields.length + 1);
  final Pointer<Size> outLen = calloc<Size>();
  try {
    final Uint8List t = text.asTypedListOutOfLine(total);
    final Uint32List o = offs.asTypedListOutOfLine(fields.length + 1);
    int at = 0;
    o[0] = 0;
    for (int i = 0; i < encoded.length; i++) {
      t.setAll(at, encoded[i]);
      at += encoded[i].length;
      o[i + 1] = at;
    }
    final Pointer<Uint8> out = lib.bindings.ffsrs_search_dupe_norm_batch(
      text,
      total,
      offs,
      fields.length,
      outLen,
    );
    if (out == nullptr) {
      throw const SrsSearchUnsupported(
        '',
        'ffsrs_search_dupe_norm_batch failed',
        SrsSearchErrorKind.unavailable,
      );
    }
    final int len = outLen.value;
    try {
      final Uint8List all = out.asTypedListOutOfLine(len);
      final int headerBytes = (fields.length + 1) * 4;
      final ByteData header = ByteData.sublistView(all, 0, headerBytes);
      final List<String> result = <String>[];
      for (int i = 0; i < fields.length; i++) {
        final int a = header.getUint32(i * 4, Endian.little);
        final int b = header.getUint32((i + 1) * 4, Endian.little);
        result.add(
          utf8.decode(
            Uint8List.sublistView(all, headerBytes + a, headerBytes + b),
          ),
        );
      }
      return result;
    } finally {
      lib.bindings.ffsrs_free_bytes(out, len);
    }
  } finally {
    malloc
      ..free(text)
      ..free(offs);
    calloc.free(outLen);
  }
}
