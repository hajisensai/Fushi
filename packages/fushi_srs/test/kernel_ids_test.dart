// SrsKernelIds：根上的 ID 与同步目录名经 FFI 向内核要（native/fushi_fsrs/src/gen4_ids/derive.rs）。
// 根上的规则与 golden_ids.json 的逐值比对在 packages/fushi_engine/test/srs/srs_gen4_canonical_ids_golden_test.dart；
// 这里钉住 FFI 入口本身：根上的 ID 答规范值（不带盐、与 profile 无关，G9-7）、批量与逐个同值、改造前 Dart 公式的
// 等价值、落单代理项的处理。
@TestOn('vm')
library;

import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

const String _uid = '019a5e4c-0000-7000-8000-00000000abcd';

void main() {
  final SrsKernelIds ids = SrsKernelIds(_uid);

  test('根上的 ID 答规范规则（不带盐、与 profile 无关），目录名 = uid', () {
    expect(ids.note('g1'), uuidV5(srsNamespace, 'note/g1'));
    expect(ids.noteType(42), uuidV5(srsNamespace, 'notetype/42'));
    expect(
      ids.builtinNoteType('lapis'),
      uuidV5(
        srsNamespace,
        'notetype/${SrsIds.builtinNoteTypeAnkiNum('lapis')}',
      ),
    );
    expect(ids.deck(' A :: B '), uuidV5(srsNamespace, 'deck/A::B'));
    expect(
      ids.deckAlternate('A::B', 3),
      uuidV5(srsNamespace, 'deck-alt/3/A::B'),
    );
    expect(ids.defaultDeck, uuidV5(srsNamespace, 'builtin-deck/default'));
    expect(
      ids.defaultDeck,
      isNot(uuidV5(srsNamespace, '$_uid/builtin-deck/default')),
    );
    expect(ids.locationDir, _uid);
    final SrsKernelIds other = SrsKernelIds(
      '019a5e4c-0000-7000-8000-00000000ef01',
    );
    expect(other.note('g1'), ids.note('g1'));
    expect(other.defaultDeck, ids.defaultDeck);
    expect(other.builtinNoteType('lapis'), ids.builtinNoteType('lapis'));
  });

  test('批量与逐个同值', () {
    const List<String> guids = <String>['a', 'B#c', '雨'];
    expect(ids.notes(guids), <String>[
      for (final String g in guids) ids.note(g),
    ]);
    expect(ids.deckCandidates('X', 2), <String>[
      ids.deck('X'),
      ids.deckAlternate('X', 1),
      ids.deckAlternate('X', 2),
    ]);
    expect(ids.notes(const <String>[]), isEmpty);
  });

  test('「不合并笔记类型」的副本 ankiNum 与改造前 Dart 公式同值', () {
    // 改造前：hash53('notetype-dup/<n>/${srsCanonicalJson({cloze, fields, tmpls})}')。
    int dart(
      int n,
      bool cloze,
      List<SrsDupPart> fields,
      List<SrsDupPart> tmpls,
    ) => hash53(
      'notetype-dup/$n/${srsCanonicalJson(<String, Object?>{
        'cloze': cloze,
        'fields': <Object?>[for (final SrsDupPart f in fields) f.configId ?? 'name:${f.name}'],
        'tmpls': <Object?>[for (final SrsDupPart t in tmpls) t.configId ?? 'name:${t.name}'],
      })}',
    );
    final List<(int, bool, List<SrsDupPart>, List<SrsDupPart>)> cases =
        <(int, bool, List<SrsDupPart>, List<SrsDupPart>)>[
          (
            1725626812943,
            false,
            <SrsDupPart>[
              (configId: 1725626812944, name: 'Front'),
              (configId: null, name: 'Back'),
            ],
            <SrsDupPart>[
              (configId: null, name: 'Card 1'),
              (configId: 1725626812950, name: 'x'),
            ],
          ),
          (
            42,
            true,
            <SrsDupPart>[(configId: null, name: '表面 "q"\\\n\t\u0001\u007f/')],
            <SrsDupPart>[(configId: 7, name: 'c')],
          ),
          (-5, false, <SrsDupPart>[], <SrsDupPart>[]),
        ];
    for (final (int n, bool cloze, List<SrsDupPart> f, List<SrsDupPart> t)
        in cases) {
      expect(
        SrsKernelIds.duplicateNoteTypeAnkiNum(
          sourceAnkiNum: n,
          cloze: cloze,
          fields: f,
          templates: t,
        ),
        dart(n, cloze, f, t),
        reason: '$n',
      );
    }
    // 与内核测试（gen4_ids/derive.rs）里的冻结值同一个。
    expect(
      SrsKernelIds.duplicateNoteTypeAnkiNum(
        sourceAnkiNum: -5,
        cloze: false,
        fields: const <SrsDupPart>[],
        templates: const <SrsDupPart>[],
      ),
      3380722550824366,
    );
  });

  test('旧并入的兜底 ID 与改名写入者哈希与改造前公式同值', () {
    expect(
      SrsKernelIds.mergeFallbacks(_uid, <String>['abc-def', 'x']),
      <String>[
        uuidV5(srsNamespace, 'profile-merge/$_uid/abc-def'),
        uuidV5(srsNamespace, 'profile-merge/$_uid/x'),
      ],
    );
    expect(SrsKernelIds.mergedWriterHashes(_uid, <String>['dev-1']), <String>[
      uuidV5(srsNamespace, 'profile-merge/$_uid/writer/dev-1'),
    ]);
  });

  test('落单的代理项按 U+FFFD 算（与改造前对 utf8.encode 的结果哈希相同）', () {
    const String lone = 'a\uD800b';
    expect(ids.note(lone), ids.note('a�b'));
    expect(ids.note(lone), uuidV5(srsNamespace, 'note/a�b'));
  });

  test('嵌套 List 里的名字含落单代理项：不抛错，按 U+FFFD 算（G5B-2）', () {
    // 以前只清洗顶层字符串，duplicateNoteTypeAnkiNum 的字段 / 模板名在嵌套 List 里，jsonEncode 写出 `\ud800`
    // 转义，内核 serde_json 拒收，整次导入抛错。
    //
    // 与改造前 Dart 公式（hash53('notetype-dup/<n>/${srsCanonicalJson(...)}')）不同值：srsCanonicalJson 把落单
    // 代理项写成六个 ASCII 字符 `\ud800` 再哈希，实测 n=1、字段 'name:a\uD800b'、模板 'name:t' 时旧公式得
    // 8451223386032446，换成 U+FFFD 后得 5460801798626219（下面钉住的值）。内核收到的字符串只能是合法 Unicode，
    // 复现不了旧的转义串；只影响名字里带落单代理项的笔记类型（升级后「不合并」再导入同一个包会另建一份），按
    // U+FFFD 与本文件其余规则一致。
    int dup(String field, String tmpl) => SrsKernelIds.duplicateNoteTypeAnkiNum(
      sourceAnkiNum: 1,
      cloze: false,
      fields: <SrsDupPart>[(configId: null, name: field)],
      templates: <SrsDupPart>[(configId: null, name: tmpl)],
    );
    expect(dup('a\uD800b', 't'), dup('a�b', 't'));
    expect(dup('a\uD800b', 't'), 5460801798626219);
    expect(dup('f', 'x\uDC00'), dup('f', 'x�'));
    expect(
      ids.ask(<List<Object?>>[
        <Object?>[
          'dup_notetype_num',
          1,
          false,
          <Object?>[
            <Object?>[null, 'a\uD800b'],
          ],
          <Object?>[
            <Object?>[null, 't'],
          ],
        ],
      ]).single,
      5460801798626219,
    );
  });

  test('内核拒绝不认识的种类与缺参数', () {
    expect(
      () => ids.ask(<List<Object?>>[
        <Object?>['nope'],
      ]),
      throwsA(anything),
    );
    // 只有目录名要 profile。
    expect(
      () => SrsKernelIds.askFor(null, <List<Object?>>[
        <Object?>['location_dir'],
      ]),
      throwsA(anything),
    );
  });
}
