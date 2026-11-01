// srsFieldClassSqlFilter（SQLite 侧按字段类别筛修改记录）与 srsFieldClassOf（Dart 侧逐条判）必须恒等：
// [SrsDbStore.syncConflicts] 靠前者在读回之前筛掉笔记字段正文（BUG-3947），两者一旦分叉，冲突记录要么漏项、
// 要么又把整库正文读回来。这里对全部实体种类 × 全部已知字段键（含带参数的前缀键与没见过的键）× 全部类别
// 子集，在真 SQLite 里求值比对。
import 'package:fushi_srs/fushi_srs.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// 已知字段键（[SrsFieldKeys] 的全部常量与带参数键的样例）+ 一个没见过的键 + 带引号的键。
final List<String> _keys = <String>[
  SrsFieldKeys.deleted,
  SrsFieldKeys.noteField('fld1'),
  SrsFieldKeys.noteTags,
  SrsFieldKeys.noteSource,
  SrsFieldKeys.noteDeck,
  SrsFieldKeys.noteType,
  SrsFieldKeys.name,
  SrsFieldKeys.fieldDef('fld1'),
  SrsFieldKeys.fieldDescription('fld1'),
  SrsFieldKeys.templateDef('tmpl1'),
  SrsFieldKeys.css,
  SrsFieldKeys.termField,
  SrsFieldKeys.freqField,
  SrsFieldKeys.suspended,
  SrsFieldKeys.buriedUntilDay,
  SrsFieldKeys.flag,
  SrsFieldKeys.cardDeck,
  SrsFieldKeys.cardNewPosition,
  SrsFieldKeys.cardHistoryFrom('card0'),
  SrsFieldKeys.deckParent,
  SrsFieldKeys.deckParamsMode,
  SrsFieldKeys.deckLimits,
  SrsFieldKeys.deckSteps,
  SrsFieldKeys.deckRetention,
  SrsFieldKeys.deckAlgorithm,
  SrsFieldKeys.deckFsrs6Params,
  SrsFieldKeys.deckFsrs7Params,
  SrsFieldKeys.deckAutoOptimize,
  SrsFieldKeys.deckOptimizeBaseline,
  SrsFieldKeys.deckMaxInterval,
  SrsFieldKeys.deckCollapsed,
  SrsFieldKeys.deckPosition,
  SrsFieldKeys.deckAutoplay,
  SrsFieldKeys.deckReplayQuestion,
  SrsFieldKeys.deckRwkvQueue,
  SrsFieldKeys.deckNewOrder,
  SrsFieldKeys.deckNewPlan,
  SrsFieldKeys.dayRolloverHour,
  SrsFieldKeys.utcOffsetMin,
  'neverSeenKey',
  "it's",
];

/// [SrsFieldClass] 的全部子集（含空集与全集）。
List<Set<SrsFieldClass>> _subsets() {
  const List<SrsFieldClass> all = SrsFieldClass.values;
  return <Set<SrsFieldClass>>[
    for (int mask = 0; mask < 1 << all.length; mask++)
      <SrsFieldClass>{
        for (int i = 0; i < all.length; i++)
          if (mask & (1 << i) != 0) all[i],
      },
  ];
}

void main() {
  test('SQL 筛选与 srsFieldClassOf 对全部种类 × 字段键 × 类别子集逐项相同', () {
    final Database db = sqlite3.openInMemory();
    addTearDown(db.dispose);
    db.execute('CREATE TABLE e (entity_kind TEXT, field_key TEXT)');
    final PreparedStatement insert = db.prepare('INSERT INTO e VALUES (?, ?)');
    for (final SrsEntityKind kind in SrsEntityKind.values) {
      for (final String key in _keys) {
        insert.execute(<Object?>[kind.wire, key]);
      }
    }
    insert.dispose();
    int checked = 0;
    for (final Set<SrsFieldClass> classes in _subsets()) {
      final String filter = srsFieldClassSqlFilter(
        classes,
        kindColumn: 'entity_kind',
        keyColumn: 'field_key',
      );
      final Set<String> got = <String>{
        for (final Row r in db.select(
          'SELECT entity_kind, field_key FROM e WHERE $filter',
        ))
          '${r['entity_kind']}|${r['field_key']}',
      };
      final Set<String> want = <String>{
        for (final SrsEntityKind kind in SrsEntityKind.values)
          for (final String key in _keys)
            if (classes.contains(srsFieldClassOf(kind, key)))
              '${kind.wire}|$key',
      };
      expect(got, want, reason: 'classes=$classes filter=$filter');
      checked += SrsEntityKind.values.length * _keys.length;
    }
    expect(checked, greaterThan(0));
  });

  test('同步冲突要的两类：笔记正文 / 模板 / 删除都不在里面，笔记的牌组与类型在', () {
    final Set<SrsFieldClass> conflicts = <SrsFieldClass>{
      SrsFieldClass.flag,
      SrsFieldClass.setting,
    };
    final Database db = sqlite3.openInMemory();
    addTearDown(db.dispose);
    bool tracked(SrsEntityKind kind, String key) =>
        db.select(
          'SELECT ${srsFieldClassSqlFilter(conflicts, kindColumn: '?1', keyColumn: '?2')} AS x',
          <Object?>[kind.wire, key],
        ).single['x'] ==
        1;
    expect(tracked(SrsEntityKind.note, SrsFieldKeys.noteField('a')), isFalse);
    expect(tracked(SrsEntityKind.note, SrsFieldKeys.deleted), isFalse);
    expect(tracked(SrsEntityKind.note, SrsFieldKeys.noteTags), isFalse);
    expect(tracked(SrsEntityKind.noteType, SrsFieldKeys.css), isFalse);
    expect(tracked(SrsEntityKind.card, SrsFieldKeys.cardNewPosition), isFalse);
    expect(tracked(SrsEntityKind.deck, SrsFieldKeys.deckCollapsed), isFalse);
    expect(tracked(SrsEntityKind.note, SrsFieldKeys.noteDeck), isTrue);
    expect(tracked(SrsEntityKind.note, SrsFieldKeys.noteType), isTrue);
    expect(tracked(SrsEntityKind.card, SrsFieldKeys.suspended), isTrue);
    expect(tracked(SrsEntityKind.deck, SrsFieldKeys.deckLimits), isTrue);
    expect(tracked(SrsEntityKind.profile, 'anything'), isTrue);
  });
}
