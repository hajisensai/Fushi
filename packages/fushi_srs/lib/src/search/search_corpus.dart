/// Anki 搜索的求值：整批卡一次交给 native/fushi_fsrs 的 `search.rs`（Rust `regex` crate，与
/// Anki 桌面版 rslib 同一个正则引擎），返回命中的卡。Dart 侧只剩解析器（search_parser.dart）。
///
/// 语料（字段文本、标签、名字）在第一次搜索时装进原生侧，之后的搜索只传语法树；卡片的数值属性
/// 按查询用到的列惰性上传。逐卡跨 FFI 比 Dart 自己算还慢，所以只有这一个批量入口。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

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

/// 一批卡的搜索语料。卡的顺序就是 [match] 返回下标的口径。
///
/// [SrsSearchSubject.noteKey] 相同的卡共用一份笔记文本（只装一次、笔记级条件只算一次）。
/// 原生句柄随本对象被回收时释放，也可以 [dispose] 提前释放。
final class SrsSearchCorpus implements Finalizable {
  SrsSearchCorpus(this.cards, {FushiFsrs? library}) : _library = library;

  final List<SrsSearchSubject> cards;
  final FushiFsrs? _library;

  Pointer<Void> _handle = nullptr;
  FushiFsrs? _bound;
  final Set<_IntCol> _ints = <_IntCol>{};
  final Set<_FloatCol> _floats = <_FloatCol>{};
  bool _disposed = false;

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
    final Set<_IntCol> ints = <_IntCol>{};
    final Set<_FloatCol> floats = <_FloatCol>{};
    _columnsOf(node, ints, floats);
    for (final _IntCol c in ints.difference(_ints)) {
      _uploadInts(lib, c);
    }
    for (final _FloatCol c in floats.difference(_floats)) {
      _uploadFloats(lib, c);
    }
    final Pointer<Utf8> q = jsonEncode(_nodeJson(node)).toNativeUtf8();
    final Pointer<Uint8> out = calloc<Uint8>(cards.length);
    try {
      final Pointer<Char> resp = lib.bindings.ffsrs_search_corpus_match(
        _handle,
        q.cast(),
        out,
        cards.length,
      );
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
      final Uint8List bits = out.asTypedList(cards.length);
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

  /// 提前释放原生句柄（之后不能再 [match]）。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
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
    final _Layout layout = _Layout.build(cards);
    final Uint8List text = layout.text;
    final Pointer<Uint8> textPtr = malloc<Uint8>(
      text.isEmpty ? 1 : text.length,
    );
    final Pointer<Uint32> layoutPtr = malloc<Uint32>(layout.words.length);
    final Pointer<Pointer<Char>> err = calloc<Pointer<Char>>();
    try {
      textPtr.asTypedList(text.length).setAll(0, text);
      layoutPtr.asTypedList(layout.words.length).setAll(0, layout.words);
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
      lib.bindings.searchCorpusFinalizer.attach(
        this,
        h,
        detach: this,
        // 原生侧另有惰性缓存（拼接字段、去 HTML 后的字段值），粗估成原文的 3 倍。
        externalSize: text.length * 3,
      );
    } finally {
      malloc
        ..free(textPtr)
        ..free(layoutPtr);
      calloc.free(err);
    }
  }

  void _uploadInts(FushiFsrs lib, _IntCol col) {
    final int n = cards.length;
    final Pointer<Int64> p = malloc<Int64>(n);
    try {
      final Int64List v = p.asTypedList(n);
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
      final Float64List v = p.asTypedList(n);
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

/// `search.rs` `Corpus::new` 的布局：全部字符串的 UTF-8 拼接 + u32 数组。
class _Layout {
  _Layout(this.text, this.words);

  final Uint8List text;
  final Uint32List words;

  static _Layout build(List<SrsSearchSubject> cards) {
    final BytesBuilder bytes = BytesBuilder(copy: false);
    final List<int> strOff = <int>[0];
    final Map<String, int> interned = <String, int>{};
    int total = 0;
    int add(String s) {
      final Uint8List b = utf8.encode(s);
      bytes.add(b);
      total += b.length;
      strOff.add(total);
      return strOff.length - 2;
    }

    int intern(String s) => interned[s] ??= add(s);

    final Map<Object, int> noteIndex = <Object, int>{};
    final List<int> noteType = <int>[];
    final List<int> noteFieldOff = <int>[0];
    final List<int> fieldName = <int>[];
    final List<int> fieldValue = <int>[];
    final List<int> noteTagOff = <int>[0];
    final List<int> tag = <int>[];
    final List<int> cardNote = <int>[];
    final List<int> cardDeck = <int>[];
    final List<int> cardTpl = <int>[];
    for (final SrsSearchSubject c in cards) {
      final int note = noteIndex.putIfAbsent(c.noteKey, () {
        noteType.add(intern(c.noteTypeName));
        for (final MapEntry<String, String> e in c.fields.entries) {
          fieldName.add(intern(e.key));
          fieldValue.add(add(e.value));
        }
        noteFieldOff.add(fieldName.length);
        for (final String t in c.tags) {
          tag.add(intern(t));
        }
        noteTagOff.add(tag.length);
        return noteType.length - 1;
      });
      cardNote.add(note);
      cardDeck.add(intern(c.deckName));
      cardTpl.add(intern(c.templateName));
    }
    final int nStr = strOff.length - 1;
    final Uint32List words = Uint32List.fromList(<int>[
      nStr,
      noteType.length,
      fieldName.length,
      tag.length,
      cardNote.length,
      ...strOff,
      ...noteType,
      ...noteFieldOff,
      ...fieldName,
      ...fieldValue,
      ...noteTagOff,
      ...tag,
      ...cardNote,
      ...cardDeck,
      ...cardTpl,
    ]);
    if (total > 0xFFFFFFFF) {
      throw const SrsSearchUnsupported(
        '',
        'search corpus larger than 4 GiB',
        SrsSearchErrorKind.unavailable,
      );
    }
    return _Layout(bytes.takeBytes(), words);
  }
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
    final Uint8List t = text.asTypedList(total);
    final Uint32List o = offs.asTypedList(fields.length + 1);
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
      final Uint8List all = out.asTypedList(len);
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
