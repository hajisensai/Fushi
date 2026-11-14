// 协议 4 规范 ID 规则表的黄金向量（docs/specs/2026-11-11-srs-generation-break.md §5.2、G3）。
//
// 规则表本身只在内核一处（native/fushi_fsrs/src/gen4_ids/rules.rs）；Dart 不加第二份实现。这里用现有的
// `SrsIds`（packages/fushi_srs/lib/src/ids.dart）与内置笔记类型表（srs_builtin.dart）把同一批输入算一遍，
// 与冻结文件 native/fushi_fsrs/src/gen4_ids/golden_ids.json 逐值比对；内核的测试
// （native/fushi_fsrs/src/gen4_ids/tests.rs）对着同一个文件重算。两边都对得上 = 内核规则表与 `ids.dart` 逐值一致。
//
// - 带盐值：直接调 `SrsIds.*`（存量规则）。
// - 规范值（不带盐）：`uuidV5(srsNamespace, <名字>)`，其中 <名字> 满足「`SrsIds.*` 的带盐值 ==
//   uuidV5(srsNamespace, '<uid>/<名字>')」——即规范名字恰好是存量名字去掉 `<uid>/` 前缀，由本测试逐条断言。
// - 旧并入的兜底 ID / 改名写入者的两条公式在 srs_profile_merge.dart 里是私有的（`_IdMap.fallbackAll`、
//   `_mergedWriterNames`），这里按同一条公式重写；它们在真实库上的验算见内核探针 gen4_ids/probe.rs。
//
// 改了规则或向量后重新生成：`FUSHI_G3_REGEN=1 dart test test/srs/srs_gen4_canonical_ids_golden_test.dart`
// （在 packages/fushi_engine 下）。已经发布出去的 ID 规则不能改；重新生成只该出现在「加向量」时。
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

const String _goldenInRepo = 'native/fushi_fsrs/src/gen4_ids/golden_ids.json';

/// 冻结文件：从 packages/fushi_engine（`dart test` 的工作目录）或仓库根找。
final String _goldenPath = <String>['../../$_goldenInRepo', _goldenInRepo]
    .map((String p) => '${Directory.current.path}/$p'.replaceAll('\\', '/'))
    .firstWhere(
      (String p) => File(p).parent.existsSync(),
      orElse: () => '${Directory.current.path}/../../$_goldenInRepo',
    );

/// 向量里用的两个盐（合成值，不是任何真实 profile）。
const List<String> _uids = <String>[
  '01928c3e-0000-7000-8000-0000000000a1',
  '01928c3e-0000-7000-8000-0000000000b2',
];

const List<String> _guids = <String>[
  'abc',
  'i0.As71JXL',
  'jc@w,U)1uH',
  'nONw]iO[z*',
  r'a/b c$~',
  // Anki 的 base91 字母表里的全部符号。
  r'!#$%&()*+,-./:;<=>?@[]^_`{|}~',
  '\u65e5\u672c\u8a9e',
  // 分解形（不做 NFC）与合成形是两个 guid。
  '\u304b\u3099',
  '\u304c',
  // 非 BMP 字符，以及 U+FFFD（Dart 字符串里的孤立代理项编码成 UTF-8 时就是它，见下面的测试）。
  '\u{1f600}',
  'a\ufffdb',
  '',
];

const List<int> _noteTypeNums = <int>[
  0,
  1,
  1725626812943,
  9007199254740993,
  8443339454048983619,
  -5,
  9223372036854775807,
  -9223372036854775808,
];

const List<int> _defNums = <int>[1, 6037387325910567657, -7, 0];

const List<String> _defNames = <String>[
  'Front',
  '\u8868\u9762',
  'Card 1',
  // 字段 / 模板名不 trim。
  ' a ',
  '\u{1f600}',
  '',
];

const List<int> _clozeOrds = <int>[0, 1, 499, 500, 4294967295];

const List<String> _deckPaths = <String>[
  'Default',
  'A::B',
  ' A :: B ',
  'A::::B',
  '::A::',
  ':::',
  '',
  'A::  ::B',
  '\u65e5\u672c\u8a9e::\u30c7\u30c3\u30ad',
  // Dart 的 trim() 去掉的：U+FEFF、U+3000、U+00A0、制表与换行。
  '\ufeffA::B\u3000',
  '\u00a0A\u00a0::\u2028B\u2029',
  'A\t::\nB\r',
  // 不去掉的：U+180E、U+200B、U+001F（Anki 旧的层级分隔符）。
  '\u180eA',
  '\u200bA',
  '\u001fA\u001f::B',
  'A :: B',
  'a::B',
];

const List<int> _deckAlternates = <int>[1, 2, 8, 17];

const List<int> _revlogIds = <int>[1700000000123, 0, -1];

const List<String> _writers = <String>[
  '01928c3e-0000-7000-8000-00000000d001',
  // v1 的写入者名：<设备公钥>#<代次>。
  'q0J3dGVzdC13cml0ZXIta2V5LW5vdC1hLXJlYWwtb25lMDAw=#1',
  // 旧并入改过名的：旧格式、带最初写入者的新格式、套了两层的。
  'merged-0f4f4039-fc51-5915-adeb-5fc0377a2408',
  'merged-0f4f4039-fc51-5915-adeb-5fc0377a2408~01928c3e-0000-7000-8000-00000000d001',
  'merged-1b1b1b1b-fc51-5915-adeb-5fc0377a2408~merged-0f4f4039-fc51-5915-adeb-5fc0377a2408~q0J3=#1',
  'sync2:tags:7cb0b0f1-fee9-52a0-971a-9bbe263d021d',
  '',
];

const List<int> _seqs = <int>[1, 334270];

const List<String> _hashInputs = <String>[
  '',
  'a',
  'fushi/builtin-notetype/lapis',
  '日本語',
];

const List<String> _oldIds = <String>[
  '7cb0b0f1-fee9-52a0-971a-9bbe263d021d',
  '7CB0B0F1-FEE9-52A0-971A-9BBE263D021D',
  '01a13edc-1141-7e0f-9be4-296e66bec1b4',
  'Deck-Default',
];

Map<String, Object?> _rooted(
  String rule,
  Map<String, Object?> args,
  String name,
  String Function(String uid) salted,
) {
  final Map<String, String> bySalt = <String, String>{
    for (final String uid in _uids) uid: salted(uid),
  };
  for (final String uid in _uids) {
    expect(
      bySalt[uid],
      uuidV5(srsNamespace, '$uid/$name'),
      reason: '$rule $args: canonical name is not the salted name minus uid/',
    );
  }
  return <String, Object?>{
    'rule': rule,
    'args': args,
    'name': name,
    'canonical': uuidV5(srsNamespace, name),
    'salted': bySalt,
  };
}

Map<String, Object?> _derived(
  String rule,
  Map<String, Object?> args,
  String id,
) => <String, Object?>{'rule': rule, 'args': args, 'id': id};

Map<String, Object?> _number(String rule, Map<String, Object?> args, int n) =>
    <String, Object?>{'rule': rule, 'args': args, 'n': n};

/// 用现有 Dart 规则表把全部向量算一遍。
Map<String, Object?> _build() {
  final List<Map<String, Object?>> cases = <Map<String, Object?>>[];

  for (final String g in _guids) {
    cases.add(
      _rooted(
        'note',
        <String, Object?>{'guid': g},
        'note/$g',
        (String uid) => SrsIds.note(uid, g),
      ),
    );
  }
  for (final int n in _noteTypeNums) {
    cases.add(
      _rooted(
        'note_type',
        <String, Object?>{'ankiNum': n},
        'notetype/$n',
        (String uid) => SrsIds.noteType(uid, n),
      ),
    );
  }
  for (final String p in _deckPaths) {
    final String norm = SrsIds.normalizeDeckPath(p);
    cases.add(
      _rooted(
        'deck',
        <String, Object?>{'path': p, 'normalized': norm},
        'deck/$norm',
        (String uid) => SrsIds.deck(uid, p),
      ),
    );
  }
  for (final String p in const <String>['A::B', ' A :: B ', '日本語']) {
    for (final int n in _deckAlternates) {
      cases.add(
        _rooted(
          'deck_alternate',
          <String, Object?>{'path': p, 'n': n},
          'deck-alt/$n/${SrsIds.normalizeDeckPath(p)}',
          (String uid) => SrsIds.deckAlternate(uid, p, n),
        ),
      );
    }
  }
  cases.add(
    _rooted(
      'builtin_default_deck',
      const <String, Object?>{},
      'builtin-deck/default',
      SrsIds.builtinDefaultDeck,
    ),
  );

  // 由父 ID 派生的规则：父取一个带盐的、一个规范的笔记类型 / 笔记。
  final List<String> noteTypes = <String>[
    SrsIds.noteType(_uids[0], 1725626812943),
    uuidV5(srsNamespace, 'notetype/1725626812943'),
  ];
  final List<String> notes = <String>[
    SrsIds.note(_uids[0], 'i0.As71JXL'),
    uuidV5(srsNamespace, 'note/i0.As71JXL'),
  ];
  final List<String> templates = <String>[
    for (final String nt in noteTypes) SrsIds.template(nt, 1),
    SrsIds.templateByName(noteTypes[1], 'Card 1'),
  ];
  for (final String nt in noteTypes) {
    for (final int n in _defNums) {
      cases
        ..add(
          _derived('field', <String, Object?>{
            'noteType': nt,
            'ankiNum': n,
          }, SrsIds.field(nt, n)),
        )
        ..add(
          _derived('template', <String, Object?>{
            'noteType': nt,
            'ankiNum': n,
          }, SrsIds.template(nt, n)),
        );
    }
    for (final String s in _defNames) {
      cases
        ..add(
          _derived('field_by_name', <String, Object?>{
            'noteType': nt,
            'name': s,
          }, SrsIds.fieldByName(nt, s)),
        )
        ..add(
          _derived('template_by_name', <String, Object?>{
            'noteType': nt,
            'name': s,
          }, SrsIds.templateByName(nt, s)),
        );
    }
  }
  final List<String> cards = <String>[];
  for (final String note in notes) {
    for (final String tpl in templates) {
      for (final int ord in _clozeOrds) {
        final String id = SrsIds.card(note, tpl, ord);
        cards.add(id);
        cases.add(
          _derived('card', <String, Object?>{
            'note': note,
            'template': tpl,
            'clozeOrd': ord,
          }, id),
        );
      }
    }
  }
  for (final String card in <String>[cards.first, cards.last]) {
    for (final int id in _revlogIds) {
      cases
        ..add(
          _derived('imported_revlog', <String, Object?>{
            'card': card,
            'ankiRevlogId': id,
          }, SrsIds.importedRevlog(card, id)),
        )
        ..add(
          _derived('import_anchor', <String, Object?>{
            'card': card,
            'anchorMs': id,
          }, SrsIds.importAnchor(card, id)),
        );
    }
    for (final String log in _oldIds) {
      cases.add(
        _derived('remapped_log', <String, Object?>{
          'card': card,
          'originalLogId': log,
        }, SrsIds.remappedLog(card, log)),
      );
    }
  }
  for (final String w in _writers) {
    for (final int seq in _seqs) {
      cases.add(
        _derived('field_edit', <String, Object?>{
          'writer': w,
          'seq': seq,
        }, SrsIds.fieldEdit(w, seq)),
      );
    }
  }
  cases.add(
    _derived(
      'profile_entity',
      const <String, Object?>{},
      uuidV5(srsNamespace, 'profile'),
    ),
  );

  // 旧并入留下的两种痕迹（公式见 srs_profile_merge.dart `_IdMap.fallbackAll` / `_mergedWriterNames`）。
  for (final String uid in _uids) {
    for (final String old in _oldIds) {
      cases.add(
        _derived('merge_fallback', <String, Object?>{
          'targetUid': uid,
          'oldId': old,
        }, uuidV5(srsNamespace, 'profile-merge/$uid/${old.toLowerCase()}')),
      );
    }
    for (final String w in _writers) {
      cases.add(
        _derived('merged_writer_hash', <String, Object?>{
          'targetUid': uid,
          'origin': w,
        }, uuidV5(srsNamespace, 'profile-merge/$uid/writer/$w')),
      );
    }
  }

  for (final String s in _hashInputs) {
    cases.add(_number('hash53', <String, Object?>{'input': s}, hash53(s)));
  }
  for (final String id in <String>[notes.first, cards.first]) {
    cases.add(
      _number('anki_numeric_id', <String, Object?>{
        'uuid': id,
      }, SrsIds.ankiNumericId(id)),
    );
  }

  // 内置笔记类型表（代码里的定义）：每个 key 的 ankiNum、字段种子、模板名，以及派生出的规范 ID 与带盐 ID。
  final List<Map<String, Object?>> builtins = <Map<String, Object?>>[];
  for (final SrsBuiltinNoteTypeSpec spec in kSrsBuiltinNoteTypes) {
    final String key = spec.key;
    final int num = SrsIds.builtinNoteTypeAnkiNum(key);
    final String canonical = uuidV5(srsNamespace, 'notetype/$num');
    final Map<String, SrsBuiltinNoteType> bySalt = <String, SrsBuiltinNoteType>{
      for (final String uid in _uids) uid: srsBuiltinNoteType(uid, spec),
    };
    final SrsBuiltinNoteType first = bySalt[_uids[0]]!;
    builtins.add(<String, Object?>{
      'key': key,
      'ankiNum': num,
      'canonical': canonical,
      'salted': <String, String>{
        for (final String uid in _uids) uid: srsBuiltinNoteTypeId(uid, key),
      },
      'fields': <Map<String, Object?>>[
        for (int i = 0; i < first.fields.length; i++)
          <String, Object?>{
            'name': first.fields[i].name,
            'seed': srsBuiltinFieldSeed(key, first.fields[i].name),
            'ankiNum': first.fields[i].ankiNum,
            'canonical': SrsIds.field(canonical, first.fields[i].ankiNum!),
            'salted': <String, String>{
              for (final String uid in _uids) uid: bySalt[uid]!.fields[i].id,
            },
          },
      ],
      'templates': <Map<String, Object?>>[
        for (int i = 0; i < first.templates.length; i++)
          <String, Object?>{
            'name': first.templates[i].name,
            'ankiNum': first.templates[i].ankiNum,
            'canonical': SrsIds.template(
              canonical,
              first.templates[i].ankiNum!,
            ),
            'salted': <String, String>{
              for (final String uid in _uids) uid: bySalt[uid]!.templates[i].id,
            },
          },
      ],
    });
  }

  return <String, Object?>{
    'about':
        'Frozen ID vectors for the protocol-4 canonical ID rule table. '
        'Generated from packages/fushi_srs/lib/src/ids.dart by '
        'packages/fushi_engine/test/srs/srs_gen4_canonical_ids_golden_test.dart; '
        'checked by that test and by native/fushi_fsrs/src/gen4_ids/tests.rs.',
    'namespace': srsNamespace,
    'salts': _uids,
    'builtinDefaultDeck': uuidV5(srsNamespace, 'builtin-deck/default'),
    'builtins': builtins,
    'cases': cases,
  };
}

/// 稳定的文本形式：缩进一格、非 ASCII 一律写成 `\uXXXX`（文件里不留看不见的字符）。
String _encode(Map<String, Object?> golden) {
  final String raw = const JsonEncoder.withIndent(' ').convert(golden);
  final StringBuffer out = StringBuffer();
  for (final int unit in raw.codeUnits) {
    if (unit > 0x7e) {
      out.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
    } else {
      out.writeCharCode(unit);
    }
  }
  out.write('\n');
  return out.toString();
}

void main() {
  test('golden_ids.json is exactly what ids.dart derives today', () {
    final Map<String, Object?> built = _build();
    final String text = _encode(built);
    final File file = File(_goldenPath);
    if (Platform.environment['FUSHI_G3_REGEN'] == '1') {
      file.writeAsStringSync(text);
    }
    expect(file.existsSync(), isTrue, reason: 'missing $_goldenPath');
    final Map<String, Object?> frozen =
        jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    final Map<String, Object?> fresh = jsonDecode(text) as Map<String, Object?>;

    final List<Object?> frozenCases = frozen['cases']! as List<Object?>;
    final List<Object?> freshCases = fresh['cases']! as List<Object?>;
    expect(frozenCases.length, freshCases.length);
    for (int i = 0; i < freshCases.length; i++) {
      expect(frozenCases[i], freshCases[i], reason: 'case #$i');
    }
    final List<Object?> frozenBuiltins = frozen['builtins']! as List<Object?>;
    final List<Object?> freshBuiltins = fresh['builtins']! as List<Object?>;
    expect(frozenBuiltins.length, freshBuiltins.length);
    for (int i = 0; i < freshBuiltins.length; i++) {
      expect(frozenBuiltins[i], freshBuiltins[i], reason: 'builtin #$i');
    }
    expect(frozen, fresh);
    expect(file.readAsStringSync(), text, reason: 'file text drifted');
  });

  // 批量接口（导入与旧并入走的是这些）与逐个算的逐值相同，所以向量也钉住了批量路径。
  test('batch derivations equal the single ones', () {
    final String uid = _uids[0];
    expect(SrsIds.notes(uid, _guids), <String>[
      for (final String g in _guids) SrsIds.note(uid, g),
    ]);
    final String note = SrsIds.note(uid, 'abc');
    final String tpl = SrsIds.template(SrsIds.noteType(uid, 1), 1);
    final List<(String, String, int)> cardSpecs = <(String, String, int)>[
      for (final int ord in _clozeOrds) (note, tpl, ord),
    ];
    final List<String> cards = SrsIds.cards(cardSpecs);
    expect(cards, <String>[
      for (final int ord in _clozeOrds) SrsIds.card(note, tpl, ord),
    ]);
    expect(
      SrsIds.importedRevlogsOf(<(String, int)>[
        for (final String c in cards)
          for (final int id in _revlogIds) (c, id),
      ]),
      <String>[
        for (final String c in cards)
          for (final int id in _revlogIds) SrsIds.importedRevlog(c, id),
      ],
    );
    expect(SrsIds.importedRevlogs(cards.first, _revlogIds), <String>[
      for (final int id in _revlogIds) SrsIds.importedRevlog(cards.first, id),
    ]);
    expect(
      SrsIds.importAnchorsOf(<(String, int)>[
        for (final int at in _revlogIds) (cards.last, at),
      ]),
      <String>[
        for (final int at in _revlogIds) SrsIds.importAnchor(cards.last, at),
      ],
    );
    expect(SrsIds.ankiNumericIds(cards), <int>[
      for (final String c in cards) SrsIds.ankiNumericId(c),
    ]);
  });

  // 孤立代理项写不进 JSON 也写不进 Rust 的字符串：Dart 把它编码成 UTF-8 时换成 U+FFFD，向量里用 U+FFFD 代表。
  test('a lone surrogate hashes as U+FFFD', () {
    final String lone = 'a${String.fromCharCode(0xd800)}b';
    expect(lone.length, 3);
    expect(SrsIds.note(_uids[0], lone), SrsIds.note(_uids[0], 'a\ufffdb'));
    expect(hash53(lone), hash53('a\ufffdb'));
  });

  test('canonical builtin note types do not depend on the profile uid', () {
    final Map<String, Object?> built = _build();
    for (final Object? b in built['builtins']! as List<Object?>) {
      final Map<String, Object?> m = b! as Map<String, Object?>;
      final Map<String, String> salted = m['salted']! as Map<String, String>;
      expect(salted.values.toSet().length, _uids.length);
      expect(salted.values, isNot(contains(m['canonical'])));
    }
  });
}
