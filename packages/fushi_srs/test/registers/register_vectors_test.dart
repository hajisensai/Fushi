// 字段寄存器与物化搬进 Rust（native/fushi_fsrs/src/registers.rs）之后的回归门：
//
// 固定向量 test/registers/fixtures/register_vectors.json.gz 由**删除前的 Dart 实现**生成
// （test/registers/fixtures/gen_register_vectors.dart.txt，在 34834441d7 上运行）：2400 个用例——
// 笔记 / 笔记类型（含内置默认值）/ 牌组 / profile 的修改记录集（并发、支配、不连续 dot、同 ID 重复与
// 同 ID 异内容、服务器时刻钳位、删除与删除并发、内联样式与引用行、代理对 writerId 的 UTF-16 序、
// int 与 double / -0.0、坏类型）→ 寄存器、删除时刻、与删除并发的修改、物化视图、no-op 判定；
// 卡片血统（成环、缺失前身、historyFrom 值不为 true）→ 血统与继承后的标志（Dart 包装 `srsCardLineages` 已删，
// 这 300 个用例搬到 native/fushi_fsrs/tests/fixtures/card_lineage_vectors.json、由 Rust 测试对拍）；落库支配裁剪；
// Anki 导入判重；卡片历史的钳位标记；坏数据。全部要求与旧实现逐条一致。
//
// 要真实原生库（FUSHI_FSRS_LIB，缺省本仓 prebuilt/）；库加载失败直接判红，不 skip。
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

List<Map<String, Object?>> _vectors() {
  final File f = File('test/registers/fixtures/register_vectors.json.gz');
  final Map<String, Object?> root =
      jsonDecode(utf8.decode(gzip.decode(f.readAsBytesSync())))
          as Map<String, Object?>;
  return (root['vectors']! as List<Object?>).cast<Map<String, Object?>>();
}

Map<String, Object?> _map(Object? v) => (v! as Map).cast<String, Object?>();

/// 向量生成之后牌组视图新加的字段，按它们的缺省补进期望视图（向量的输入里本来就没有这些键，
/// 旧实现的视图里自然也没有）：`rwkvQueue.refreshEvery`（2026-10-23，fb7289744c）、
/// `rwkvQueue.ignoreLimit`（2026-10-30）。
Object? _withLaterDefaults(Object? view) {
  if (view is! Map) return view;
  final Map<String, Object?> v = view.cast<String, Object?>();
  final Object? q = v['rwkvQueue'];
  if (q is! Map) return v;
  const SrsRwkvQueueSettings d = SrsRwkvQueueSettings();
  return <String, Object?>{
    for (final MapEntry<String, Object?> e in v.entries)
      e.key: e.key == 'rwkvQueue'
          ? <String, Object?>{
              ...q.cast<String, Object?>(),
              if (!q.containsKey('refreshEvery'))
                'refreshEvery': d.refreshEvery,
              if (!q.containsKey('ignoreLimit'))
                'ignoreLimit': d.ignoreReviewLimit,
            }
          : e.value,
  };
}

/// 向量生成之后改了的语义：步长写成空列表 = 不用步长（2026-10-30；以前回落默认步长）。
/// 按胜出的 `steps` 修改把期望视图里对应的一项改成空列表。
Object? _withEmptySteps(Object? view, Map<String, Object?> vector) {
  if (view is! Map || vector['kind'] != 'deck') return view;
  final Map<String, Object?> e = _map(vector['expect']);
  String? winner;
  for (final Object? r in e['regs']! as List<Object?>) {
    final List<Object?> reg = r! as List<Object?>;
    final List<Object?> ids = reg[1]! as List<Object?>;
    if (reg[0] == 'steps' && ids.isNotEmpty) winner = ids.first as String?;
  }
  if (winner == null) return view;
  // 同一 id 的重复修改（向量里故意造的 dup）值不一致时，胜出哪份由内核定，这里不改期望。
  final List<Object?> values = <Object?>[
    for (final Object? j in vector['edits']! as List<Object?>)
      if (_map(jsonDecode(j! as String)) case final Map<String, Object?> edit
          when edit['id'] == winner)
        edit['v'],
  ];
  if (values.isEmpty ||
      values.any((Object? x) => jsonEncode(x) != jsonEncode(values.first)) ||
      values.first is! Map) {
    return view;
  }
  final Map<String, Object?> value = _map(values.first);
  bool empty(String k) => value[k] is List && (value[k]! as List).isEmpty;
  return <String, Object?>{
    for (final MapEntry<String, Object?> en
        in view.cast<String, Object?>().entries)
      en.key:
          (en.key == 'learnSteps' && empty('learn')) ||
              (en.key == 'relearnSteps' && empty('relearn'))
          ? <double>[]
          : en.value,
  };
}

List<SrsEditItem> _items(Object? edits, Map<String, Object?> server) {
  return <SrsEditItem>[
    for (final Object? j in edits! as List<Object?>)
      SrsEditItem.stored(
        Uint8List.fromList(utf8.encode(j! as String)),
        server[_idOf(j as String)] as int?,
      ),
  ];
}

String? _idOf(String json) {
  final Object? id = (jsonDecode(json) as Map)['id'];
  return id is String ? id : null;
}

// ------------------------------------------------------------------ 与生成脚本同一份序列化

List<Object?> _regs(SrsEntityEdits edits) => <Object?>[
  for (final String k in edits.keys)
    <Object?>[
      k,
      <String>[for (final SrsFieldEdit e in edits[k]!.live) e.id],
      edits[k]!.conflicted,
      <String>[for (final SrsFieldEdit e in edits[k]!.visibleLosers) e.id],
    ],
];

Map<String, Object?> _noteJson(SrsNoteView n) => <String, Object?>{
  'id': n.id,
  'noteTypeId': n.noteTypeId,
  'guid': n.guid,
  'createdAt': n.createdAt,
  'fields': <Object?>[
    for (final MapEntry<String, String> e in n.fields.entries)
      <String>[e.key, e.value],
  ],
  'tags': n.tags,
  'source': n.source?.toJson(),
  'deckId': n.deckId,
  'deletedAt': n.deletedAt,
  'pending': n.hasPendingDecision,
};

Map<String, Object?> _fieldDefJson(SrsFieldDef f) => <String, Object?>{
  'id': f.id,
  ...f.toValue(),
  'description': f.description,
};

Map<String, Object?> _tmplDefJson(SrsTemplateDef t) => <String, Object?>{
  'id': t.id,
  ...t.toValue(),
};

Map<String, Object?> _noteTypeJson(SrsNoteTypeView t) => <String, Object?>{
  'id': t.id,
  'ankiNum': t.ankiNum,
  'kind': t.kind,
  'name': t.name,
  'fields': <Object?>[for (final SrsFieldDef f in t.fields) _fieldDefJson(f)],
  'templates': <Object?>[
    for (final SrsTemplateDef x in t.templates) _tmplDefJson(x),
  ],
  'css': t.css,
  'termFieldId': t.termFieldId,
  'deletedAt': t.deletedAt,
  'builtinKey': t.builtinKey,
};

Map<String, Object?> _deckJson(SrsDeckView d) => <String, Object?>{
  'id': d.id,
  'name': d.name,
  'parentId': d.parentId,
  'ownParams': d.ownParams,
  'newPerDay': d.newPerDay,
  'reviewsPerDay': d.reviewsPerDay,
  'learnSteps': d.learnSteps,
  'relearnSteps': d.relearnSteps,
  'desiredRetention': d.desiredRetention,
  'algorithmWire': d.algorithmWire,
  'algorithmAuto': d.algorithmAuto,
  'fsrs6': d.fsrs6?.toValue(),
  'fsrs7': d.fsrs7?.toValue(),
  'autoOptimize': d.autoOptimize,
  'maxIntervalDays': d.maxIntervalDays,
  'collapsed': d.collapsed,
  'position': d.position,
  'autoplayAudio': d.autoplayAudio,
  'replayQuestionAudio': d.replayQuestionAudio,
  'rwkvQueue': d.rwkvQueue.toValue(),
  'optimizeBaselineAt': d.optimizeBaselineAt,
  'optimizeBaselineCount': d.optimizeBaselineCount,
  'deletedAt': d.deletedAt,
  'builtinKey': d.builtinKey,
  'createdAt': d.createdAt,
};

SrsBuiltinNoteType _builtinOf(Map<String, Object?> b) => SrsBuiltinNoteType(
  key: b['key']! as String,
  name: b['name']! as String,
  kind: b['kind']! as String,
  fields: <SrsFieldDef>[
    for (final Object? f in b['fields']! as List<Object?>)
      SrsFieldDef(
        id: _map(f)['id']! as String,
        name: _map(f)['name']! as String,
        ord: _map(f)['ord']! as int,
        ankiNum: _map(f)['ankiNum'] as int?,
        description: _map(f)['description']! as String,
        deleted: _map(f)['deleted'] == true,
      ),
  ],
  templates: <SrsTemplateDef>[
    for (final Object? t in b['templates']! as List<Object?>)
      SrsTemplateDef(
        id: _map(t)['id']! as String,
        name: _map(t)['name']! as String,
        ord: _map(t)['ord']! as int,
        front: _map(t)['front']! as String,
        back: _map(t)['back']! as String,
        ankiNum: _map(t)['ankiNum'] as int?,
        deleted: _map(t)['deleted'] == true,
      ),
  ],
  css: b['css']! as String,
  termFieldId: b['termFieldId'] as String?,
);

/// 内核对一个实体用例的结果（序列化成与向量同形状）；坏数据抛 [FormatException]。
Map<String, Object?> _runEntity(Map<String, Object?> v) {
  final Map<String, Object?> server = _map(v['server']);
  final List<SrsEditItem> items = _items(v['edits'], server);
  // 坏数据用例（kind = edits）没有身份记录，只要寄存器。
  final SrsEntitySource src = SrsEntitySource.record(
    v['record'] == null
        ? const SrsEntityRecord(
            id: 'x',
            profileUid: 'p',
            kind: SrsEntityKind.note,
            payload: <String, Object?>{},
          )
        : SrsEntityRecord.fromJson(_map(v['record'])),
    items,
  );
  final (SrsEntityEdits edits, Object? view) = switch (v['kind']) {
    'note' => () {
      final SrsNoteView n = srsMaterializeNotes(<SrsEntitySource>[src]).single;
      return (n.edits, _noteJson(n));
    }(),
    'notetype' => () {
      final Object? b = v['builtin'];
      final SrsNoteTypeView t = srsMaterializeNoteTypes(
        <(SrsEntitySource, SrsBuiltinNoteType?)>[
          (src, b == null ? null : _builtinOf(_map(b))),
        ],
      ).single;
      return (t.edits, _noteTypeJson(t));
    }(),
    'deck' => () {
      final SrsDeckView d = srsMaterializeDecks(<SrsEntitySource>[src]).single;
      return (d.edits, _deckJson(d));
    }(),
    _ => (srsEntityEditsOf(<List<SrsEditItem>>[items]).single, null),
  };
  return <String, Object?>{
    'regs': _regs(edits),
    'deletedAt': edits.deletedAt,
    'concurrent': <String>[
      for (final SrsFieldEdit e in edits.concurrentWithDelete) e.id,
    ],
    'view': view,
    'noop': <Object?>[
      for (final List<Object?> n
          in ((_map(v['expect'])['noop'] as List?) ?? const <Object?>[])
              .cast<List<Object?>>())
        <Object?>[
          n[0],
          n[1],
          srsEditIsNoop(edits[n[0]! as String]!, jsonDecode(n[1]! as String)),
        ],
    ],
  };
}

bool _isError(Map<String, Object?> e) => e['error'] != null;

void main() {
  test('原生库可加载（硬依赖）', () {
    expect(FushiFsrs.instance, isNotNull, reason: 'fushi_fsrs 原生库缺失');
  });

  final List<Map<String, Object?>> vectors = _vectors();
  List<Map<String, Object?>> ofKind(Set<String> kinds) =>
      <Map<String, Object?>>[
        for (final Map<String, Object?> v in vectors)
          if (kinds.contains(v['kind'])) v,
      ];

  test('向量规模哨兵', () {
    expect(vectors, hasLength(2400));
    int conflicted = 0;
    int concurrent = 0;
    int noopTrue = 0;
    int styled = 0;
    for (final Map<String, Object?> v in ofKind(<String>{
      'note',
      'notetype',
      'deck',
      'profile',
    })) {
      final Map<String, Object?> e = _map(v['expect']);
      if (_isError(e)) continue;
      for (final Object? r in e['regs']! as List<Object?>) {
        if ((r! as List)[2] == true) conflicted++;
      }
      if ((e['concurrent']! as List).isNotEmpty) concurrent++;
      for (final Object? n in e['noop']! as List<Object?>) {
        if ((n! as List)[2] == true) noopTrue++;
      }
      if (jsonEncode(v['edits']).contains('_fushi_style_')) styled++;
    }
    expect(conflicted, greaterThan(800));
    expect(concurrent, greaterThan(150));
    expect(noopTrue, greaterThan(500));
    expect(styled, greaterThan(100));
  });

  test('实体：寄存器 / 删除 / 删除并发 / 物化视图 / no-op 与旧实现逐条一致', () {
    int checked = 0;
    for (final Map<String, Object?> v in ofKind(<String>{
      'note',
      'notetype',
      'deck',
      'profile',
      'edits',
    })) {
      final Map<String, Object?> e = _map(v['expect']);
      if (_isError(e)) {
        expect(
          () => _runEntity(v),
          throwsFormatException,
          reason: jsonEncode(v),
        );
        continue;
      }
      final Map<String, Object?> got = _runEntity(v);
      expect(got['regs'], e['regs'], reason: 'regs ${jsonEncode(v)}');
      if (v['kind'] == 'edits') continue;
      expect(got['deletedAt'], e['deletedAt']);
      expect(got['concurrent'], e['concurrent']);
      expect(
        jsonEncode(got['view']),
        jsonEncode(_withEmptySteps(_withLaterDefaults(e['view']), v)),
        reason: jsonEncode(v),
      );
      expect(got['noop'], e['noop'], reason: jsonEncode(v));
      checked++;
    }
    expect(checked, greaterThan(1200));
  });

  test('整批与逐个同结果（一批多个实体一次 FFI）', () {
    final List<Map<String, Object?>> notes = <Map<String, Object?>>[
      for (final Map<String, Object?> v in ofKind(<String>{'note'}))
        if (!_isError(_map(v['expect']))) v,
    ];
    final List<SrsNoteView> batch = srsMaterializeNotes(<SrsEntitySource>[
      for (final Map<String, Object?> v in notes)
        SrsEntitySource.record(
          SrsEntityRecord.fromJson(_map(v['record'])),
          _items(v['edits'], _map(v['server'])),
        ),
    ]);
    for (int i = 0; i < notes.length; i++) {
      final Map<String, Object?> e = _map(notes[i]['expect']);
      expect(jsonEncode(_noteJson(batch[i])), jsonEncode(e['view']));
      expect(_regs(batch[i].edits), e['regs']);
    }
  });

  test('内存里的记录（SrsEntityEdits.build）与落库原文同结果', () {
    for (final Map<String, Object?> v in ofKind(<String>{'note', 'deck'})) {
      final Map<String, Object?> e = _map(v['expect']);
      if (_isError(e)) continue;
      final Map<String, Object?> server = _map(v['server']);
      final SrsEntityEdits built = SrsEntityEdits.build(<SrsFieldEdit>[
        for (final Object? j in v['edits']! as List<Object?>)
          SrsFieldEdit.fromJson(
            (jsonDecode(j! as String) as Map).cast<String, Object?>(),
          ),
      ], serverTimeOf: (String id) => server[id] as int?);
      expect(_regs(built), e['regs']);
      expect(built.deletedAt, e['deletedAt']);
    }
  });

  test('落库支配裁剪与旧实现逐条一致', () {
    int deleted = 0;
    for (final Map<String, Object?> v in ofKind(<String>{'landing'})) {
      final Map<String, Object?> e = _map(v['expect']);
      final List<SrsEditItem> existing = _items(
        v['existing'],
        const <String, Object?>{},
      );
      final List<SrsEditItem> incoming = _items(
        v['incoming'],
        const <String, Object?>{},
      );
      final SrsLanding got = srsLandEdits(existing, incoming);
      expect(got.landed, e['landed'], reason: jsonEncode(v));
      final List<SrsEditItem> all = <SrsEditItem>[...existing, ...incoming];
      expect(<String>[
        for (final List<int> d in got.dominated)
          for (final int i in d) all[i].edit.id,
      ], e['deleted']);
      deleted += (e['deleted']! as List).length;
    }
    expect(deleted, greaterThan(50));
  });

  test('Anki 导入判重与旧 srsImportEquivalent 逐条一致（整批一次 FFI）', () {
    final List<Map<String, Object?>> cases = ofKind(<String>{'import'});
    SrsReviewLog log(Object? j) => SrsReviewLog.fromJson(
      (jsonDecode(j! as String) as Map).cast<String, Object?>(),
    );
    final List<bool> got = srsImportEquivalentAny(
      <(SrsReviewLog, List<SrsReviewLog>)>[
        for (final Map<String, Object?> v in cases)
          (
            log(v['imported']),
            <SrsReviewLog>[
              for (final Object? n in v['natives']! as List<Object?>) log(n),
            ],
          ),
      ],
    );
    expect(got, <bool>[
      for (final Map<String, Object?> v in cases) v['expect']! as bool,
    ]);
    expect(got.where((bool b) => b).length, greaterThan(15));
  });

  test('卡片历史：排序与钳位标记与旧 sortKeyOf 一致', () {
    int clamped = 0;
    for (final Map<String, Object?> v in ofKind(<String>{'clamp'})) {
      final Map<String, Object?> e = _map(v['expect']);
      final Map<String, Object?> server = _map(v['server']);
      final SrsCardHistory h = SrsCardHistory(<SrsReviewLog>[
        for (final Object? j in v['logs']! as List<Object?>)
          SrsReviewLog.fromJson(
            (jsonDecode(j! as String) as Map).cast<String, Object?>(),
          ),
      ], serverTimeOf: (String id) => server[id] as int?);
      expect(<String>[for (final SrsReviewLog l in h.all) l.id], e['all']);
      expect(<String>[
        for (final SrsReviewLog l in h.all)
          if (h.isClamped(l)) l.id,
      ], e['clamped']);
      for (int i = 1; i < h.all.length; i++) {
        expect(h.isAfter(h.all[i], h.all[i - 1]), isTrue);
        expect(h.isAfter(h.all[i - 1], h.all[i]), isFalse);
      }
      clamped += (e['clamped']! as List).length;
    }
    expect(clamped, greaterThan(100));
  });
}
