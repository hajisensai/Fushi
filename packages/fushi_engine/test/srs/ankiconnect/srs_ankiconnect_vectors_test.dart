// AnkiConnect 兼容层读动作的输入→输出回归向量（L-5）。
//
// 输入是冻结的库：下面的场景造出的 srs.db 原样（gzip）存成 fixtures/srs_ankiconnect_vectors.db.gz（排程带 fuzz、
// ID 是随机 guid，每次重造的库都不一样，所以冻结库本身）。输出由**旧的 Dart 实现**（`_Resident` 全库镜像：
// `allNoteViews` 物化全部笔记 + 全部卡片缓存行 + Dart 查重倒排 + Dart 侧建的搜索语料，2026-10-30 L-5 之前）在这份
// 库上对一组请求算出，存进 fixtures/srs_ankiconnect_vectors.json；findNotes / findCards / canAddNotes / getTags 搬进
// Rust（浏览会话的常驻语料 `anki_find` / `anki_dupes` / `anki_tags`）、notesInfo / cardsInfo 改为按 id 读之后，
// 新实现必须对同一组请求逐项给出同样的回答。
//
// 场景覆盖：多种笔记类型（Lapis、内置 Fushi 卡片（旧字段名别名）、Basic、Basic 反向两张卡、Cloze 多空）、多层牌组、
// 字段 HTML（加粗、内联 `<style>` 去重后展开回原文）、引号 / 冒号 / 通配符 / 代理对 / 大小写、标签（层级、下划线）、
// 学习 / 复习 / 暂停 / 搁置 / 旗标 / 新卡位置、改字段、删笔记；请求覆盖 Anki 搜索语法（牌组 / 标签 / 状态 / 卡片序号
// 与模板名 / 笔记类型 / 字段 / 通配 / 正则 / 数值属性 / 添加与修改天数 / nid / cid / 布尔组合 / 不支持与非法语法）、
// 查重（集合 / 牌组 / deck-root / 子牌组 / 跨模型 / 空 / 模型或牌组不存在）、notesInfo（按 id / 按查询 / 未知 /
// 已删）、cardsInfo、cardsToNotes、areSuspended、getTags、牌组名。
//
// 重新生成（只在有意改变协议语义时）：SRS_AC_VECTORS_WRITE=1 跑本文件（重造库并重算输出）。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_handler.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../apkg/apkg_test_support.dart';
import '../support/srs_test_storage.dart';
import '../support/srs_raw_sql.dart';

const String kAcVecProfile = '01928c3e-0000-7000-8000-0000000000ad';

final String _fixtures = '${Directory.current.path}/test/srs/fixtures'
    .replaceAll('\\', '/');

/// 请求时的「现在」：东九区 12:00（日界 4 点之后）。
final int _queryNow = DateTime.utc(2026, 10, 15, 3).millisecondsSinceEpoch;

SrsAnkiConnectHandler _handler(SrsDbStore s) => SrsAnkiConnectHandler(
  store: () async => s,
  instanceId: 'vectors',
  profileName: () => 'User 1',
);

Future<Object?> _call(
  SrsAnkiConnectHandler h,
  String action,
  Map<String, Object?> params,
) => h.handle(<String, Object?>{
  'action': action,
  'version': 6,
  'params': params,
});

Future<Object?> _ok(
  SrsAnkiConnectHandler h,
  String action,
  Map<String, Object?> params,
) async {
  final Map<String, Object?> r =
      (await _call(h, action, params))! as Map<String, Object?>;
  if (r['error'] != null) throw StateError('$action: ${r['error']}');
  return r['result'];
}

Map<String, Object?> _lapis(
  String expression, {
  String deck = 'Default',
  String reading = '',
  String sentence = '',
  List<String> tags = const <String>['yomitan'],
}) => <String, Object?>{
  'deckName': deck,
  'modelName': 'Lapis',
  'fields': <String, Object?>{
    'Expression': expression,
    'ExpressionReading': reading,
    'Sentence': sentence,
  },
  'tags': tags,
  'options': <String, Object?>{'allowDuplicate': true},
};

Map<String, Object?> _note(
  String model,
  String deck,
  Map<String, Object?> fields, {
  List<String> tags = const <String>[],
}) => <String, Object?>{
  'deckName': deck,
  'modelName': model,
  'fields': fields,
  'tags': tags,
  'options': <String, Object?>{'allowDuplicate': true},
};

/// 造场景库（只在重新生成时跑）。
Future<SrsDbStore> _build(void Function(int) setNow, int Function() now) async {
  int t = DateTime.utc(2026, 10, 1, 12).millisecondsSinceEpoch;
  setNow(t);
  final SrsDbStore s = await openTestStore(
    profileUid: kAcVecProfile,
    deviceId: 'v',
    localOffsetMin: () => 540,
    now: now,
  );
  await s.editField(
    SrsEntityKind.profile,
    kAcVecProfile,
    // 旧版声明过、从没有写入方的 profile 键：现在不读（时区恒为本机，由打开时的 localOffsetMin 钉住），
    // 留着这条写入让写入序号与生成向量时一致。
    'utcOffsetMin',
    540,
  );
  await s.editField(
    SrsEntityKind.profile,
    kAcVecProfile,
    SrsFieldKeys.dayRolloverHour,
    4,
  );
  for (final String d in <String>[
    'JP::Vocab',
    'JP::Grammar',
    'Other',
    'Root::A::A1',
    'Root::B',
  ]) {
    await s.ensureDeckPath(d);
  }
  await s.createStockNoteType(SrsStockNoteType.basic, 'Basic');
  await s.createStockNoteType(
    SrsStockNoteType.basicReversed,
    'Basic (and reversed card)',
  );
  await s.createStockNoteType(SrsStockNoteType.cloze, 'Cloze');
  final SrsAnkiConnectHandler h = _handler(s);
  final String fushiModel =
      ((await _ok(h, 'modelNames', <String, Object?>{}))! as List<Object?>)
          .cast<String>()
          .firstWhere(
            (String m) =>
                m != 'Lapis' && !m.startsWith('Basic') && m != 'Cloze',
          );
  final List<Map<String, Object?>> notes = <Map<String, Object?>>[
    _lapis('猫', sentence: '<b>猫</b>が寝る。', tags: <String>['yomitan', 'animal']),
    _lapis('<b>犬</b>', deck: 'JP::Vocab', tags: <String>['yomitan', 'Animal']),
    _lapis('食べる', reading: 'たべる', deck: 'JP::Vocab'),
    _lapis(' 鳥 ', deck: 'JP::Grammar', tags: <String>['Mixed::Case']),
    _lapis(
      '<style>.r{color:red}</style><span class="r">赤</span>',
      deck: 'Other',
      tags: <String>['tag_with_underscore'],
    ),
    _lapis('12:30', tags: const <String>[]),
    _lapis('x*y', deck: 'Root::A'),
    _lapis('"引用"', deck: 'Root::A::A1'),
    _lapis('Ärger ÖL', deck: 'Root::B', tags: <String>['umlaut']),
    _lapis('𝒳記号', deck: 'Root::B'),
    _lapis('猫', deck: 'Other', tags: <String>['dup']),
    _note(
      fushiModel,
      'JP',
      <String, Object?>{'Expression': '走る', 'Sentence': '毎朝<i>走る</i>。'},
      tags: <String>['fushi'],
    ),
    _note(fushiModel, 'JP::Vocab', <String, Object?>{'Expression': '泳ぐ'}),
    _note(
      'Basic',
      'Default',
      <String, Object?>{'Front': 'りんご', 'Back': 'apple'},
      tags: <String>['fruit'],
    ),
    _note('Basic', 'JP::Vocab', <String, Object?>{
      'Front': '<div>バナナ</div>',
      'Back': '',
    }),
    _note('Basic', 'Other', <String, Object?>{'Front': '猫', 'Back': 'cat'}),
    _note(
      'Basic (and reversed card)',
      'JP',
      <String, Object?>{'Front': '本', 'Back': 'book'},
      tags: <String>['rev'],
    ),
    _note('Basic (and reversed card)', 'Root::A::A1', <String, Object?>{
      'Front': '水',
      'Back': 'water',
    }),
    _note(
      'Cloze',
      'Root::A::A1',
      <String, Object?>{
        'Text': '{{c1::東京}}は{{c2::日本}}の首都',
        'Back Extra': 'capital',
      },
      tags: <String>['geo'],
    ),
    _note('Cloze', 'Default', <String, Object?>{'Text': '{{c1::一}}{{c3::三}}'}),
  ];
  for (final Map<String, Object?> n in notes) {
    t += 61000;
    setNow(t);
    await _ok(h, 'addNote', <String, Object?>{'note': n});
  }
  // 卡片 id（按 findCards deck:* 的顺序）。
  Future<List<String>> cardIds(String q) async => <String>[
    for (final Object? n
        in (await _ok(h, 'findCards', <String, Object?>{'query': q}))!
            as List<Object?>)
      (await s.cardIdForAnkiNumericId(n! as int))!,
  ];
  Future<List<String>> noteIds(String q) async => <String>[
    for (final Object? n
        in (await _ok(h, 'findNotes', <String, Object?>{'query': q}))!
            as List<Object?>)
      (await s.noteIdForAnkiNumericId(n! as int))!,
  ];
  final List<String> cards = await cardIds('deck:*');
  // 几天的复习：学习中、复习卡、遗忘。
  t += 3600000;
  setNow(t);
  await s.answer(cards[0], 1);
  await s.answer(cards[1], 3);
  await s.answer(cards[1], 3);
  await s.answer(cards[2], 4);
  t += 2 * 86400000;
  setNow(t);
  await s.answer(cards[2], 1);
  await s.answer(cards[3], 3);
  await s.answer(cards[3], 4);
  final SrsDayContext day = await s.dayContext();
  await s.buryUntil(cards[4], day.dayIndexOf(_queryNow) + 1);
  await s.buryUntil(cards[5], day.dayIndexOf(_queryNow) - 1);
  await s.editField(SrsEntityKind.card, cards[6], SrsFieldKeys.suspended, true);
  await s.setFlag(cards[7], 1);
  await s.setFlag(cards[8], 3);
  await s.setNewCardPositions(<String, int>{cards[9]: 5});
  t += 86400000;
  setNow(t);
  final List<String> ns = await noteIds('deck:*');
  final String lapisExpr = (await s.noteTypes())
      .firstWhere((SrsNoteTypeView v) => v.name == 'Lapis')
      .fields
      .first
      .id;
  await s.updateNote(
    ns[2],
    fieldsById: <String, String>{lapisExpr: '食べた'},
    tags: <String>['edited', 'yomitan'],
  );
  await s.deleteNote(ns[5]);
  setNow(_queryNow);
  return s;
}

/// 冻结向量里 `<action> {"query":"deck:*"}` 回答的那批号（旧实现当时给的全部笔记 / 卡片，按它的顺序）。
List<int> _recordedIds(Map<String, Object?> recorded, String action) =>
    ((recorded['$action ${jsonEncode(<String, Object?>{'query': 'deck:*'})}']!
                as Map)['result']!
            as List<Object?>)
        .cast<int>();

/// 冻结向量里按号点名的 `notesInfo` 请求点的号（全部笔记 + 不存在的 42 + 已删笔记）。
List<int> _recordedNotesInfoIds(Map<String, Object?> recorded) {
  const String prefix = 'notesInfo {"notes":';
  final String key = recorded.keys.firstWhere(
    (String k) => k.startsWith(prefix),
  );
  return ((jsonDecode(key.substring('notesInfo '.length)) as Map)['notes']!
          as List<Object?>)
      .cast<int>();
}

/// 迁移前的数字 id → 迁移后的（G9-7：对外给规范 ID 的号 `hash53("anki-id/<规范 ID>")`，带盐的内置实体换了号）。
///
/// 笔记 / 卡片经内核反查（[SrsDbStore.noteIdsForAnkiNumericIds] / [SrsDbStore.cardIdsForAnkiNumericIds]：旧号是
/// 别名类成员的号，`anki_members` 仍认得），再按规范 ID 算新号；反查不到就是迁移丢了实体，直接失败。牌组按全名由
/// 规则独立算规范 ID 的号，笔记类型的号不换（见函数里）。没有对上的号不在表里（原样比）。
Future<Map<int, int>> _renumber(
  SrsDbStore s,
  Map<String, Object?> recorded,
) async {
  final Map<int, int> out = <int, int>{};
  Future<void> resolve(
    List<int> old,
    Future<List<String?>> Function(List<int>) find,
    String what,
  ) async {
    final List<String?> ids = await find(old);
    for (int i = 0; i < old.length; i++) {
      final String? id = ids[i];
      if (id == null) {
        throw StateError('$what ${old[i]} unknown after migrating');
      }
      out[old[i]] = SrsIds.ankiNumericId(id);
    }
  }

  final List<int> noteNums = _recordedNotesInfoIds(
    recorded,
  ).where((int n) => n != 42).toList();
  await resolve(noteNums, s.noteIdsForAnkiNumericIds, 'note');
  await resolve(
    _recordedIds(recorded, 'findCards'),
    s.cardIdsForAnkiNumericIds,
    'card',
  );
  // 牌组 / 笔记类型的新号不从被测的回答里抄（那样 deckNamesAndIds / modelNamesAndIds 自己跟自己比，第五波 K1 nit），
  // 由规则独立算：牌组的号是它规范 ID 的号，规范 ID 按全名（内置默认牌组是常量）向内核的派生规则要；笔记类型的号是
  // 它的 ankiNum（内置笔记类型是固定常量、自建的是存量属性），迁移不换号，所以不进表、原样比。
  final SrsKernelIds kernel = SrsKernelIds(kAcVecProfile);
  final Map<String, Object?> decks =
      ((recorded['deckNamesAndIds {}']! as Map)['result']! as Map)
          .cast<String, Object?>();
  for (final MapEntry<String, Object?> e in decks.entries) {
    final String canon = e.key == 'Default'
        ? kernel.defaultDeck
        : kernel.deck(e.key);
    out[e.value! as int] = SrsIds.ankiNumericId(canon);
  }
  return out;
}

/// [v]（向量 JSON）里的旧号按 [renum] 换成新号：整数值，以及键（请求文本）里的数字串；字段文本等字符串值不动。
Object? _renumbered(Object? v, Map<int, int> renum) {
  String text(String s) => s.replaceAllMapped(
    RegExp(r'\d+'),
    (Match m) => '${renum[int.tryParse(m[0]!)] ?? m[0]}',
  );
  return switch (v) {
    final int n => renum[n] ?? n,
    final Map<Object?, Object?> m => <String, Object?>{
      for (final MapEntry<Object?, Object?> e in m.entries)
        text(e.key! as String): _renumbered(e.value, renum),
    },
    final List<Object?> l => <Object?>[
      for (final Object? x in l) _renumbered(x, renum),
    ],
    _ => v,
  };
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final bool write = Platform.environment['SRS_AC_VECTORS_WRITE'] == '1';
  final File vectors = File('$_fixtures/srs_ankiconnect_vectors.json');
  final File dbFile = File('$_fixtures/srs_ankiconnect_vectors.db.gz');

  test('AnkiConnect 读动作：冻结库上逐项与旧实现相同', () async {
    int t = 0;
    String? deletedNote;
    if (write) {
      final SrsDbStore built = await _build((int v) => t = v, () => t);
      // 删掉的那条笔记的数字 id（冻结库里它已不可见，请求向量里要用）。
      final List<Object?> all =
          (await _ok(_handler(built), 'findNotes', <String, Object?>{
                'query': 'deck:*',
              }))!
              as List<Object?>;
      expect(all, isNotEmpty);
      final Directory tmp = Directory.systemTemp.createTempSync('srs_acvec_');
      final String snap = p.join(tmp.path, 'snap.db');
      built.core.snapshotInto(snap, stripDeviceLocal: false);
      dbFile.writeAsBytesSync(gzip.encode(File(snap).readAsBytesSync()));
      tmp.deleteSync(recursive: true);
    }
    // 冻结库是协议 3 的 srs.db：经换代迁移（用户升级的同一条路）再开新代库，新代的读命令对同一组向量。
    final TestSrs srs = await openMigratedTestSrs(
      gzip.decode(dbFile.readAsBytesSync()),
      prefix: 'srs_acvec_',
    );
    t = _queryNow;
    final SrsDbStore s = await SrsDbStore.open(
      core: srs.core,
      profileUid: kAcVecProfile,
      deviceId: 'v',
      engine: const FakeFsrsEngine(),
      trustedClock: SrsTrustedClock(wallClockMs: () => t, bootClockMs: () => t),
      fallbackRolloverHour: () => 4,
      localOffsetMin: () => 540,
    );
    final SrsAnkiConnectHandler h = _handler(s);
    final Map<String, Object?> recorded = write
        ? <String, Object?>{}
        : (jsonDecode(vectors.readAsStringSync()) as Map)
              .cast<String, Object?>();
    // 旧号 → 新号（G9-7：数字 id 是规范 ID 的号，内置实体换了号；旧号经 `anki_members` 仍能反查）。
    final Map<int, int> renum = write
        ? <int, int>{}
        : await _renumber(s, recorded);
    final Map<String, Object?> produced = <String, Object?>{};
    Future<void> req(String action, Map<String, Object?> params) async {
      produced['$action ${jsonEncode(params)}'] = await _call(
        h,
        action,
        params,
      );
    }

    // 已删笔记的数字 id：库里还留着它的缓存行（deleted_at）。
    deletedNote =
        (await s.core
                .customSelect(
                  'SELECT anki_id FROM notes WHERE deleted_at IS NOT NULL',
                )
                .get())
            .map((SrsRawRow r) => '${r.read<int>('anki_id')}')
            .firstOrNull;
    expect(deletedNote, isNotNull);
    if (!write) {
      // 冻结向量里点名的已删笔记（最后一个号）迁移后就是库里那条已删笔记。
      expect(
        int.parse(deletedNote!),
        renum[_recordedNotesInfoIds(recorded).last],
      );
    }

    // 请求里用到的号按冻结向量里记的那批旧号（换成新号）取，不取「新列表的第 n 个」：顺序本身也在比对之列。
    final List<int> allNotes = write
        ? ((await _ok(h, 'findNotes', <String, Object?>{'query': 'deck:*'}))!
                  as List<Object?>)
              .cast<int>()
        : <int>[
            for (final int n in _recordedIds(recorded, 'findNotes')) renum[n]!,
          ];
    final List<int> allCards = write
        ? ((await _ok(h, 'findCards', <String, Object?>{'query': 'deck:*'}))!
                  as List<Object?>)
              .cast<int>()
        : <int>[
            for (final int n in _recordedIds(recorded, 'findCards')) renum[n]!,
          ];
    final List<String> queries = <String>[
      '',
      'deck:*',
      'deck:Default',
      'deck:JP',
      'deck:JP::*',
      'deck:jp::vocab',
      '"deck:Root::A"',
      'deck:Root -deck:Root::A::A1',
      'deck:Nope',
      'tag:yomitan',
      'tag:animal',
      'tag:mixed::case',
      'tag:Mixed',
      'tag:tag_*',
      'tag:none',
      '-tag:*',
      'is:new',
      'is:learn',
      'is:review',
      'is:due',
      'is:suspended',
      'is:buried',
      '-is:new',
      'card:1',
      'card:2',
      'card:3',
      'card:Card 2',
      'card:Card*',
      'note:Basic',
      'note:Basic*',
      'note:cloze',
      'note:Lapis',
      'Front:*',
      'front:りんご',
      'Front:バナナ',
      'Expression:猫',
      'expression:*鳥*',
      'Expression:赤',
      'Expression:走る',
      'Term:走る',
      'Back:',
      'Back:_*',
      'Sentence:*例*',
      '猫',
      '犬',
      'x*y',
      r'x\*y',
      '12:30',
      '"引用"',
      '引用',
      'Text:*東京*',
      '東京',
      'capital',
      'ärger',
      'öl',
      '𝒳*',
      'flag:1',
      'flag:3',
      'flag:0',
      'prop:ivl>=1',
      'prop:due<=0',
      'prop:due>0',
      'prop:due=-1',
      'prop:reps>0',
      'prop:lapses>0',
      'prop:pos=5',
      'added:1',
      'added:30',
      'edited:1',
      'edited:30',
      '(猫 or 犬) deck:Default',
      '猫 or りんご or 本',
      '-猫 deck:Other',
      'nid:${allNotes.first}',
      'nid:${allNotes[1]},${allNotes.last}',
      'cid:${allCards.first},${allCards[3]}',
      're:^.猫',
      'Expression:re:^食',
      'w:猫',
      'dupe:1,猫',
      '(',
      'deck:"Root::A::A1" card:2',
      'Expression:',
      'expression:"<b>犬</b>"',
      'nc:taberu',
      'prop:s>0',
    ];
    for (final String q in queries) {
      await req('findNotes', <String, Object?>{'query': q});
      await req('findCards', <String, Object?>{'query': q});
    }
    await req('findNotes', <String, Object?>{});
    await req('notesInfo', <String, Object?>{
      'notes': <Object?>[...allNotes, 42, int.parse(deletedNote!)],
    });
    await req('notesInfo', <String, Object?>{'query': 'deck:JP'});
    await req('cardsInfo', <String, Object?>{
      'cards': <Object?>[...allCards, 7],
    });
    await req('cardsToNotes', <String, Object?>{'cards': allCards});
    await req('areSuspended', <String, Object?>{
      'cards': <Object?>[...allCards, 9],
    });
    await req('getTags', <String, Object?>{});
    await req('deckNames', <String, Object?>{});
    await req('deckNamesAndIds', <String, Object?>{});
    await req('modelNamesAndIds', <String, Object?>{});

    Map<String, Object?> cand(
      String expr, {
      String deck = 'Default',
      String model = 'Lapis',
      String field = 'Expression',
      String scope = 'collection',
      String? scopeDeck,
      bool children = false,
      bool allModels = false,
    }) => <String, Object?>{
      'deckName': deck,
      'modelName': model,
      'fields': <String, Object?>{field: expr},
      'options': <String, Object?>{
        'allowDuplicate': false,
        'duplicateScope': scope,
        'duplicateScopeOptions': <String, Object?>{
          'deckName': scopeDeck,
          'checkChildren': children,
          'checkAllModels': allModels,
        },
      },
    };
    final List<Object?> candidates = <Object?>[
      cand('猫'),
      cand('<i>猫</i>'),
      cand('  犬  '),
      cand('犬'),
      cand('食べる'),
      cand('食べた'),
      cand('鳥'),
      cand('赤'),
      cand('<style>.r{color:red}</style><span class="r">赤</span>'),
      cand('12:30'),
      cand('x*y'),
      cand('"引用"'),
      cand('引用'),
      cand('ärger öl'),
      cand('Ärger ÖL'),
      cand('𝒳記号'),
      cand('新しい'),
      cand(''),
      cand('<br>'),
      cand('猫', deck: 'Other', scope: 'deck'),
      cand('猫', deck: 'JP', scope: 'deck'),
      cand('犬', deck: 'JP', scope: 'deck'),
      cand('犬', deck: 'JP', scope: 'deck', children: true),
      cand('犬', deck: 'JP::Grammar', scope: 'deck-root'),
      cand('犬', deck: 'Other', scope: 'deck', scopeDeck: 'JP::Vocab'),
      cand('犬', deck: 'Other', scope: 'deck', scopeDeck: 'Nope'),
      cand('"引用"', deck: 'Root::B', scope: 'deck-root'),
      cand('りんご'),
      cand('りんご', allModels: true),
      cand('りんご', model: 'Basic', field: 'Front'),
      cand('猫', model: 'Basic', field: 'Front'),
      cand('猫', model: 'Basic', field: 'Front', scope: 'deck', deck: 'Other'),
      cand('本', model: 'Basic (and reversed card)', field: 'Front'),
      cand(
        '水',
        model: 'Basic (and reversed card)',
        field: 'Front',
        scope: 'deck',
        deck: 'Root',
        children: true,
      ),
      cand('{{c1::東京}}は{{c2::日本}}の首都', model: 'Cloze', field: 'Text'),
      cand('走る', model: 'Fushi', field: 'Expression'),
      cand('猫', model: 'Nope'),
      cand('猫', deck: 'Nope'),
      'not a note',
    ];
    final String fushiModel = (await s.noteTypes())
        .firstWhere(
          (SrsNoteTypeView v) =>
              v.name != 'Lapis' &&
              !v.name.startsWith('Basic') &&
              v.name != 'Cloze',
        )
        .name;
    for (final Object? c in candidates) {
      if (c is Map && (c['modelName'] == 'Fushi')) c['modelName'] = fushiModel;
    }
    await req('canAddNotesWithErrorDetail', <String, Object?>{
      'notes': candidates,
    });
    await req('canAddNotes', <String, Object?>{'notes': candidates});
    // 一条一条也问一遍（单候选的请求形状）。
    for (int i = 0; i < 6; i++) {
      await req('canAddNotes', <String, Object?>{
        'notes': <Object?>[candidates[i]],
      });
    }
    // 第二遍（常驻状态已热）：回答不变。
    produced['findNotes#2 ${jsonEncode(<String, Object?>{'query': 'deck:*'})}'] =
        await _call(h, 'findNotes', <String, Object?>{'query': 'deck:*'});

    if (write) {
      vectors.writeAsStringSync(
        '${const JsonEncoder.withIndent(' ').convert(produced)}\n',
      );
      return;
    }
    final Map<String, Object?> expected =
        _renumbered(recorded, renum)! as Map<String, Object?>;
    expect(produced.keys.toList(), expected.keys.toList());
    for (final String k in expected.keys) {
      expect(jsonDecode(jsonEncode(produced[k])), expected[k], reason: k);
    }
  });
}
