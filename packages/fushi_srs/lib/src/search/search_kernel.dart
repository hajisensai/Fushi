/// Anki 搜索求值的 Dart 侧入口：语法树编成 native/fushi_fsrs `search.rs` 的 `Node` JSON（浏览会话
/// native/fushi_fsrs/src/store/browse.rs 收这一份，浏览页与 AnkiConnect 都在那里求值），以及 AnkiConnect 查重的
/// 首字段规范形批量内核。以前这里还有整批求值的 Dart 包装 `SrsSearchCorpus`（生产已不用，L-5 删掉；它的测试
/// 录成 native/fushi_fsrs/tests/fixtures/search_kernel_vectors.json.zst 由 Rust 对拍）。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../ffi/fushi_fsrs_library.dart';
import 'search_node.dart';

/// 原生排程内核（fushi_fsrs）不可用时的原因串。
const String kSrsSearchKernelUnavailable =
    'search kernel (fushi_fsrs) is not available';

/// 语法树 → `search.rs` 的 `Node` JSON（浏览会话 native/fushi_fsrs/src/store/browse.rs 也收这一份）。
Map<String, Object?> srsSearchNodeJson(SrsSearchNode node) => _nodeJson(node);

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
