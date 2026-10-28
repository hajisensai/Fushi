/// 字段寄存器内核（native/fushi_fsrs/src/registers.rs）的 Dart 封装：修改记录的合并（支配、排序键与钳位、
/// 「值相同」、删除优先、冲突候选）与笔记 / 卡片标志 / 笔记类型 / 牌组的物化只在 Rust 里写一份，
/// 这里只做打包 / 解包。设计见 docs/specs/2026-10-23-srs-rust-core.md「第二阶段」。
///
/// 一个批量入口（`ffsrs_materialize`），一次 FFI 调用处理一整批实体：修改记录按落库原文
/// （canonical JSON 的 UTF-8 + 服务器时刻）整块交过去，不在 Dart 侧解析；结果里的寄存器只带下标，
/// 某条记录真要用到时才按需解析（[SrsEditItem.edit]）。
///
/// 原生库是硬依赖：加载失败抛 [SrsRegisterKernelUnavailableError]，没有 Dart 回退。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import 'algorithm.dart';
import 'deck.dart';
import 'entities.dart';
import 'ffi/fushi_fsrs_library.dart';
import 'field_edit.dart';
import 'scheduler.dart';
import 'source_ref.dart';

/// 原生字段寄存器内核（fushi_fsrs）不可用：库没随包 / 编出来的库缺 `ffsrs_materialize`。
final class SrsRegisterKernelUnavailableError extends StateError {
  SrsRegisterKernelUnavailableError()
    : super(
        'field register kernel (fushi_fsrs ffsrs_materialize) is not available; '
        'build native/fushi_fsrs (tool/native_libs.ps1) or set FUSHI_FSRS_LIB',
      );
}

/// 「没有」在 i64 列里的哨兵（registers.rs `NONE_I64`）。
const int _none = -0x8000000000000000;

FushiFsrs _library(FushiFsrs? library) =>
    library ??
    FushiFsrs.instance ??
    (throw SrsRegisterKernelUnavailableError());

/// 一个要物化的实体：身份记录的 payload（规范 JSON 原文，落库的 `payload_json`）与它的全部修改记录。
class SrsEntitySource {
  const SrsEntitySource(this.id, this.payloadJson, this.edits);

  /// 由内存里的身份记录构造。
  SrsEntitySource.record(SrsEntityRecord record, this.edits)
    : id = record.id,
      payloadJson = srsCanonicalJson(record.payload);

  final String id;
  final String payloadJson;
  final List<SrsEditItem> edits;
}

/// 一批组的打包（组描述 JSON + 全部项的原文 / 服务器时刻）。
class _Batch {
  final StringBuffer _header = StringBuffer('[');
  final List<Uint8List> _items = <Uint8List>[];
  final List<int?> _servers = <int?>[];
  int _groups = 0;

  /// [descriptor] 是组描述的 JSON 对象原文（registers.rs `Group`）。
  void add(String descriptor, Iterable<SrsEditItem> items) {
    if (_groups++ > 0) _header.write(',');
    _header.write(descriptor);
    for (final SrsEditItem i in items) {
      _items.add(i.json);
      _servers.add(i.serverTime);
    }
  }

  void addValues(Object? a, Object? b) {
    if (_groups++ > 0) _header.write(',');
    _header.write('{"t":"same"}');
    _items
      ..add(utf8.encode(jsonEncode(a)))
      ..add(utf8.encode(jsonEncode(b)));
    _servers
      ..add(null)
      ..add(null);
  }

  /// 一次 FFI 调用；结果与组同序。坏数据（与 Dart 旧实现判坏的同一类）抛 [FormatException]。
  List<Object?> run(FushiFsrs? library) {
    if (_groups == 0) return const <Object?>[];
    final FushiFsrs lib = _library(library);
    _header.write(']');
    final Uint8List header = utf8.encode(_header.toString());
    final int n = _items.length;
    int total = 0;
    for (final Uint8List j in _items) {
      total += j.length;
    }
    final Pointer<Uint8> h = malloc<Uint8>(header.length);
    final Pointer<Uint8> text = malloc<Uint8>(total == 0 ? 1 : total);
    final Pointer<Uint32> offs = malloc<Uint32>(n + 1);
    final Pointer<Int64> servers = malloc<Int64>(n == 0 ? 1 : n);
    final Pointer<Size> outLen = calloc<Size>();
    final Pointer<Pointer<Char>> error = calloc<Pointer<Char>>();
    try {
      h.asTypedListOutOfLine(header.length).setAll(0, header);
      final Uint8List t = text.asTypedListOutOfLine(total == 0 ? 1 : total);
      final Uint32List o = offs.asTypedListOutOfLine(n + 1);
      final Int64List s = servers.asTypedListOutOfLine(n == 0 ? 1 : n);
      int at = 0;
      o[0] = 0;
      for (int i = 0; i < n; i++) {
        final Uint8List j = _items[i];
        t.setRange(at, at + j.length, j);
        at += j.length;
        o[i + 1] = at;
        s[i] = _servers[i] ?? _none;
      }
      final Pointer<Uint8> out = lib.bindings.ffsrs_materialize(
        h,
        header.length,
        text,
        total,
        offs,
        servers,
        n,
        outLen,
        error,
      );
      if (out == nullptr) throw FormatException(_takeError(lib, error));
      final int len = outLen.value;
      try {
        return jsonDecode(utf8.decode(out.asTypedListOutOfLine(len)))
            as List<Object?>;
      } finally {
        lib.bindings.ffsrs_free_bytes(out, len);
      }
    } finally {
      malloc
        ..free(h)
        ..free(text)
        ..free(offs)
        ..free(servers);
      calloc
        ..free(outLen)
        ..free(error);
    }
  }
}

String _takeError(FushiFsrs lib, Pointer<Pointer<Char>> error) {
  final Pointer<Char> p = error.value;
  if (p == nullptr) return 'field register kernel failed';
  try {
    return p.cast<Utf8>().toDartString();
  } finally {
    lib.bindings.ffsrs_free_string(p);
  }
}

List<int> _ints(Object? v) => <int>[
  for (final Object? x in v! as List) x! as int,
];

SrsEntityEdits _edits(Map<String, Object?> r, List<SrsEditItem> items) =>
    SrsEntityEdits(
      _registers(r['r'], items),
      deletedAt: r['d'] as int?,
      concurrentWithDelete: () => <SrsFieldEdit>[
        for (final int i in _ints(r['x'])) items[i].edit,
      ],
    );

Map<String, SrsRegister> _registers(Object? regs, List<SrsEditItem> items) =>
    <String, SrsRegister>{
      for (final List<Object?> x in (regs! as List).cast<List<Object?>>())
        x[0]! as String: SrsRegister.fromKernel(
          x[0]! as String,
          items,
          _ints(x[1]),
          conflicted: x[2] == 1,
          loserIndices: _ints(x[3]),
        ),
    };

String _entityGroup(String t, SrsEntitySource s, [String extra = '']) =>
    '{"t":"$t","n":${s.edits.length},"rec":${s.payloadJson}$extra}';

/// 一批实体各自的寄存器，与输入同序；整批一次 FFI 调用。
List<SrsEntityEdits> srsEntityEditsOf(
  List<List<SrsEditItem>> entities, {
  FushiFsrs? library,
}) {
  final _Batch b = _Batch();
  for (final List<SrsEditItem> e in entities) {
    b.add('{"t":"edits","n":${e.length}}', e);
  }
  final List<Object?> out = b.run(library);
  return <SrsEntityEdits>[
    for (int i = 0; i < entities.length; i++)
      _edits((out[i]! as Map).cast<String, Object?>(), entities[i]),
  ];
}

/// 一批笔记的物化视图，与输入同序；整批一次 FFI 调用。
List<SrsNoteView> srsMaterializeNotes(
  List<SrsEntitySource> notes, {
  FushiFsrs? library,
}) {
  final _Batch b = _Batch();
  for (final SrsEntitySource n in notes) {
    b.add(_entityGroup('note', n), n.edits);
  }
  final List<Object?> out = b.run(library);
  return <SrsNoteView>[
    for (int i = 0; i < notes.length; i++)
      _noteView(notes[i], (out[i]! as Map).cast<String, Object?>()),
  ];
}

SrsNoteView _noteView(SrsEntitySource s, Map<String, Object?> r) {
  final Map<String, Object?> v = (r['v']! as Map).cast<String, Object?>();
  return SrsNoteView(
    id: s.id,
    noteTypeId: v['nt']! as String,
    guid: v['g']! as String,
    createdAt: v['ca']! as int,
    fields: <String, String>{
      for (final List<Object?> f in (v['f']! as List).cast<List<Object?>>())
        f[0]! as String: f[1]! as String,
    },
    tags: <String>[for (final Object? t in v['t']! as List) t! as String],
    source: SrsSourceRef.fromJson(v['s']),
    deckId: v['dk'] as String?,
    deletedAt: v['da'] as int?,
    edits: _edits(r, s.edits),
    hasPendingDecision: v['pd'] == true,
  );
}

/// 内置笔记类型的代码默认值交给内核的形状（registers.rs `note_type_view`）。
String _builtinJson(SrsBuiltinNoteType b) =>
    jsonEncode(srsBuiltinNoteTypeKernelValue(b));

/// [_builtinJson] 的值形态：缓存刷新的配置（native/fushi_fsrs/src/store/caches.rs `CacheConfig`）里也带它。
Map<String, Object?> srsBuiltinNoteTypeKernelValue(SrsBuiltinNoteType b) =>
    <String, Object?>{
      'name': b.name,
      'css': b.css,
      'termFieldId': b.termFieldId,
      'fields': <Object?>[
        for (final SrsFieldDef f in b.fields)
          <String, Object?>{
            'id': f.id,
            ...f.toValue(),
            'description': f.description,
          },
      ],
      'templates': <Object?>[
        for (final SrsTemplateDef t in b.templates)
          <String, Object?>{'id': t.id, ...t.toValue()},
      ],
    };

/// 一批笔记类型的物化视图（[builtin] 是内置类型的代码默认值，没有 = null），与输入同序；整批一次 FFI 调用。
List<SrsNoteTypeView> srsMaterializeNoteTypes(
  List<(SrsEntitySource, SrsBuiltinNoteType?)> types, {
  FushiFsrs? library,
}) {
  final _Batch b = _Batch();
  for (final (SrsEntitySource s, SrsBuiltinNoteType? builtin) in types) {
    b.add(
      _entityGroup(
        'notetype',
        s,
        builtin == null ? '' : ',"b":${_builtinJson(builtin)}',
      ),
      s.edits,
    );
  }
  final List<Object?> out = b.run(library);
  return <SrsNoteTypeView>[
    for (int i = 0; i < types.length; i++)
      _noteTypeView(types[i].$1, (out[i]! as Map).cast<String, Object?>()),
  ];
}

SrsFieldDef _fieldDef(Object? j) {
  final Map<Object?, Object?> m = j! as Map;
  return SrsFieldDef(
    id: m['id']! as String,
    name: m['name']! as String,
    ord: m['ord']! as int,
    ankiNum: m['ankiNum'] as int?,
    description: m['description']! as String,
    deleted: m['deleted'] == true,
  );
}

SrsTemplateDef _templateDef(Object? j) {
  final Map<Object?, Object?> m = j! as Map;
  return SrsTemplateDef(
    id: m['id']! as String,
    name: m['name']! as String,
    ord: m['ord']! as int,
    front: m['front']! as String,
    back: m['back']! as String,
    ankiNum: m['ankiNum'] as int?,
    deleted: m['deleted'] == true,
  );
}

SrsNoteTypeView _noteTypeView(SrsEntitySource s, Map<String, Object?> r) {
  final Map<String, Object?> v = (r['v']! as Map).cast<String, Object?>();
  return SrsNoteTypeView(
    id: s.id,
    ankiNum: v['ak']! as int,
    kind: v['nk']! as String,
    name: v['nm']! as String,
    fields: <SrsFieldDef>[
      for (final Object? f in v['fs']! as List) _fieldDef(f),
    ],
    templates: <SrsTemplateDef>[
      for (final Object? t in v['ts']! as List) _templateDef(t),
    ],
    definedFields: <SrsFieldDef>[
      for (final Object? f in v['df']! as List) _fieldDef(f),
    ],
    definedTemplates: <SrsTemplateDef>[
      for (final Object? t in v['dt']! as List) _templateDef(t),
    ],
    css: v['css']! as String,
    termFieldId: v['tf'] as String?,
    deletedAt: v['da'] as int?,
    builtinKey: v['bk'] as String?,
    edits: _edits(r, s.edits),
  );
}

/// 一批牌组的物化视图，与输入同序；整批一次 FFI 调用。参数组 / 步长 / RWKV 排队设置是值对象，
/// 内核给原值，这里用各自的值对象解析（别处也在用同一份）。
List<SrsDeckView> srsMaterializeDecks(
  List<SrsEntitySource> decks, {
  FushiFsrs? library,
}) {
  final _Batch b = _Batch();
  for (final SrsEntitySource d in decks) {
    b.add(_entityGroup('deck', d), d.edits);
  }
  final List<Object?> out = b.run(library);
  return <SrsDeckView>[
    for (int i = 0; i < decks.length; i++)
      _deckView(decks[i], (out[i]! as Map).cast<String, Object?>()),
  ];
}

List<double> _steps(Object? v, List<double> fallback) => v is List
    ? srsSanitizeSteps(
        v.whereType<num>().map((num x) => x.toDouble()).toList(),
        fallback,
      )
    : fallback;

SrsDeckView _deckView(SrsEntitySource s, Map<String, Object?> r) {
  final Map<String, Object?> v = (r['v']! as Map).cast<String, Object?>();
  return SrsDeckView(
    id: s.id,
    name: v['nm']! as String,
    parentId: v['pa'] as String?,
    ownParams: v['own'] == true,
    newPerDay: v['np']! as int,
    reviewsPerDay: v['rp']! as int,
    learnSteps: _steps(v['ls'], SrsDeckView.defaultLearnSteps),
    relearnSteps: _steps(v['rs'], SrsDeckView.defaultRelearnSteps),
    desiredRetention: (v['ret']! as num).toDouble(),
    algorithmWire: v['alg'] as String? ?? srsDefaultAlgorithm.wire,
    algorithmAuto: v['aa'] == true,
    fsrs6: SrsParamSet.fromValue(v['f6']),
    fsrs7: SrsParamSet.fromValue(v['f7']),
    autoOptimize: v['ao'] == true,
    maxIntervalDays: v['mi']! as int,
    collapsed: v['co'] == true,
    position: (v['po'] as num?)?.toDouble(),
    autoplayAudio: v['ap'] == true,
    replayQuestionAudio: v['rq'] == true,
    rwkvQueue: SrsRwkvQueueSettings.fromValue(v['rw']),
    optimizeBaselineAt: v['ba'] as int?,
    optimizeBaselineCount: v['bn'] as int?,
    deletedAt: v['da'] as int?,
    builtinKey: v['bk'] as String?,
    createdAt: v['ca']! as int,
    edits: _edits(r, s.edits),
  );
}

/// 要算血统与标志的一张卡。
class SrsCardWant {
  const SrsCardWant(
    this.cardId, {
    required this.noteDeckId,
    required this.fallbackDeckId,
  });

  final String cardId;

  /// 笔记的首选牌组：卡片自己（及前身）都没有 deck 记录时用它，再没有用 [fallbackDeckId]。
  final String? noteDeckId;
  final String fallbackDeckId;
}

/// 一张卡的血统与继承后的标志。
class SrsCardLineage {
  const SrsCardLineage(this.lineage, this.flags);

  /// 自己在前，再按广度优先列出全部前身（防环，最多 256 张）。
  final List<String> lineage;

  /// 卡片标志按血统继承：自己有记录的键用自己的，没有的取最近的前身的。
  final SrsCardFlags flags;
}

/// [srsCardLineages] 的结果。
class SrsCardLineages {
  const SrsCardLineages(this.edits, this.wants);

  /// 每张输入卡自己的寄存器。
  final Map<String, SrsEntityEdits> edits;

  /// 与 want 同序。
  final List<SrsCardLineage> wants;
}

/// 一组卡（[cards]：卡 → 它自己的修改记录，须含 [want] 每张卡的全部前身；不在里面的当没有记录）
/// 各自的寄存器，以及 [want] 每张卡的血统与继承后的标志。一次 FFI 调用。
SrsCardLineages srsCardLineages(
  Map<String, List<SrsEditItem>> cards,
  List<SrsCardWant> want, {
  FushiFsrs? library,
}) {
  final List<String> ids = cards.keys.toList();
  final _Batch b = _Batch();
  final List<SrsEditItem> items = <SrsEditItem>[
    for (final String id in ids) ...cards[id]!,
  ];
  b.add(
    jsonEncode(<String, Object?>{
      't': 'cards',
      'cards': <Object?>[
        for (final String id in ids) <Object?>[id, cards[id]!.length],
      ],
      'want': <Object?>[
        for (final SrsCardWant w in want)
          <Object?>[w.cardId, w.noteDeckId, w.fallbackDeckId],
      ],
    }),
    items,
  );
  final Map<String, Object?> out = (b.run(library).single! as Map)
      .cast<String, Object?>();
  final List<Object?> regs = out['r']! as List<Object?>;
  final List<Object?> wants = out['w']! as List<Object?>;
  return SrsCardLineages(
    <String, SrsEntityEdits>{
      for (int i = 0; i < ids.length; i++)
        ids[i]: _edits(
          (regs[i]! as Map).cast<String, Object?>(),
          cards[ids[i]]!,
        ),
    },
    <SrsCardLineage>[
      for (final Object? w in wants)
        _lineage((w! as Map).cast<String, Object?>()),
    ],
  );
}

SrsCardLineage _lineage(Map<String, Object?> w) {
  final Map<String, Object?> f = (w['f']! as Map).cast<String, Object?>();
  return SrsCardLineage(
    <String>[for (final Object? c in w['l']! as List) c! as String],
    SrsCardFlags(
      deckId: f['dk']! as String,
      suspended: f['su'] == true,
      buriedUntilDay: f['bu'] as int?,
      flag: f['fl']! as int,
      newPosition: f['np'] as int?,
    ),
  );
}

/// [srsLandEdits] 的结果。
class SrsLanding {
  const SrsLanding(this.landed, this.dominated);

  /// 每条到达的记录落不落库（与 incoming 同序）。
  final List<bool> landed;

  /// 每条到达的记录支配了哪些、要从库里删掉（下标指向 existing ++ incoming；没落库的是空列表），
  /// 与 incoming 同序。
  final List<List<int>> dominated;
}

/// 落库前的支配裁剪：[existing] 是库里（或内存副本里）已有的记录，[incoming] 依次到达。同 ID 已在
/// 或被同字段键上现存的记录支配 → 不落；落了就删掉同字段键上被它支配的（已有的或先到的）。
/// 一次 FFI 调用；与读路径（寄存器）同一个支配判据。
SrsLanding srsLandEdits(
  List<SrsEditItem> existing,
  List<SrsEditItem> incoming, {
  FushiFsrs? library,
}) {
  if (incoming.isEmpty) return const SrsLanding(<bool>[], <List<int>>[]);
  final _Batch b = _Batch();
  b.add(
    '{"t":"land","n":${existing.length + incoming.length},"e":${existing.length}}',
    <SrsEditItem>[...existing, ...incoming],
  );
  final Map<String, Object?> out = (b.run(library).single! as Map)
      .cast<String, Object?>();
  return SrsLanding(
    <bool>[for (final Object? x in out['l']! as List) x == 1],
    <List<int>>[for (final Object? d in out['d']! as List) _ints(d)],
  );
}

/// 一批值对是否「相同」（修改记录合并的唯一口径：字段文本按释义样式去重的规范形比较，其它值按规范
/// JSON 比较）。一次 FFI 调用。
List<bool> srsSameEditValues(
  List<(Object?, Object?)> pairs, {
  FushiFsrs? library,
}) {
  final _Batch b = _Batch();
  for (final (Object? a, Object? c) in pairs) {
    b.addValues(a, c);
  }
  return <bool>[for (final Object? x in b.run(library)) x == true];
}

/// 值没变且没有冲突的编辑不产生记录（no-op 不递增 seq，避免云盘文件被无意义刷新）。
bool srsEditIsNoop(SrsRegister current, Object? newValue) =>
    srsEditsAreNoop(<(SrsRegister?, Object?)>[(current, newValue)]).single;

/// 批量 [srsEditIsNoop]（没有寄存器 = 不是 no-op）；需要比较值的项整批一次 FFI 调用。
List<bool> srsEditsAreNoop(
  List<(SrsRegister?, Object?)> edits, {
  FushiFsrs? library,
}) {
  final List<int> ask = <int>[
    for (int i = 0; i < edits.length; i++)
      if (edits[i].$1 case final SrsRegister r when !r.isEmpty && !r.conflicted)
        i,
  ];
  final List<bool> out = List<bool>.filled(edits.length, false);
  if (ask.isEmpty) return out;
  final List<bool> same = srsSameEditValues(<(Object?, Object?)>[
    for (final int i in ask) (edits[i].$1!.value, edits[i].$2),
  ], library: library);
  for (int k = 0; k < ask.length; k++) {
    out[ask[k]] = same[k];
  }
  return out;
}
