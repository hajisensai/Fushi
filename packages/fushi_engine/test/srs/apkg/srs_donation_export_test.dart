// 复习历史捐赠包（docs/specs/2026-11-26-srs-review-donation.md）：导出的 apkg 用 sqlite3 打开逐项核对，
// 外加词头 / 读音保留规则与捐赠身份的纯函数单测。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/apkg/srs_donation_export.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'apkg_test_support.dart';

const String kProfile = '01928c3e-0000-7000-8000-000000000001';

const int kVocabNt = 1700000000101;
const int kBasicNt = 1700000000102;

int ms(int y, int m, int d, [int h = 0, int min = 0]) =>
    DateTime.utc(y, m, d, h, min).millisecondsSinceEpoch;

/// 来源 Anki 的 revlog 时刻（ms），导出后应原样作 revlog id。
final int ankiCatRev1 = ms(2026, 9, 1, 10);
final int ankiCatRev2 = ms(2026, 9, 3, 10);
final int ankiSentenceRev = ms(2026, 9, 2, 10);
final int ankiDogRev = ms(2026, 9, 2, 11);

Map<String, Object?> _models() => <String, Object?>{
  '$kVocabNt': <String, Object?>{
    'id': kVocabNt,
    'name': 'My Secret Vocab',
    'type': 0,
    'css': '.secret {}',
    'flds': <Object?>[
      <String, Object?>{'name': 'Expression', 'ord': 0},
      <String, Object?>{'name': 'Reading', 'ord': 1},
      <String, Object?>{'name': 'Meaning', 'ord': 2},
    ],
    'tmpls': <Object?>[
      <String, Object?>{
        'name': 'Recognition',
        'ord': 0,
        'qfmt': '{{Expression}} secret template text',
        'afmt': '{{FrontSide}}<hr id=answer>{{Reading}} {{Meaning}}',
      },
    ],
  },
  '$kBasicNt': <String, Object?>{
    'id': kBasicNt,
    'name': 'Basic',
    'type': 0,
    'css': '',
    'flds': <Object?>[
      <String, Object?>{'name': 'Front', 'ord': 0},
      <String, Object?>{'name': 'Back', 'ord': 1},
    ],
    'tmpls': <Object?>[
      <String, Object?>{
        'name': 'Card 1',
        'ord': 0,
        'qfmt': '{{Front}}',
        'afmt': '{{FrontSide}}<hr id=answer>{{Back}}',
      },
    ],
  },
};

FxCard _reviewedCard(int id, List<FxRevlog> revlog) => FxCard(
  id: id,
  ord: 0,
  did: 1,
  type: 2,
  queue: 2,
  due: 300,
  ivl: 3,
  factor: 2500,
  reps: revlog.length,
  revlog: revlog,
);

Uint8List _ankiApkg() => zipOf(<String, List<int>>{
  'collection.anki21': buildLegacyCollection(
    crtSecs: ms(2026, 1, 1, 4) ~/ 1000,
    conf: <String, Object?>{'rollover': 4, 'localOffset': 0, 'fsrs': true},
    models: _models(),
    decks: <String, Object?>{
      '1': <String, Object?>{'id': 1, 'name': 'Default', 'dyn': 0, 'conf': 1},
    },
    dconf: <String, Object?>{
      '1': <String, Object?>{
        'id': 1,
        'name': 'Default',
        'new': <String, Object?>{
          'delays': <double>[1, 10],
          'perDay': 20,
        },
        'lapse': <String, Object?>{
          'delays': <double>[10],
        },
        'rev': <String, Object?>{'perDay': 200, 'maxIvl': 36500},
      },
    },
    notes: <FxNote>[
      FxNote(
        id: ms(2026, 8, 1),
        guid: 'anki-cat',
        mid: kVocabNt,
        fields: <String>['<b>猫</b>', 'ねこ', 'cat (secret meaning)'],
        tags: <String>['shared_deck_x'],
        cards: <FxCard>[
          _reviewedCard(901, <FxRevlog>[
            FxRevlog(ankiCatRev1, type: 0, ease: 3, ivl: 1, time: 120000),
            FxRevlog(ankiCatRev2, type: 1, ease: 3, ivl: 3, time: 4000),
          ]),
        ],
      ),
      FxNote(
        id: ms(2026, 8, 2),
        guid: 'anki-sentence',
        mid: kVocabNt,
        fields: <String>['私は猫が好きです。', 'わたしはねこがすきです', 'I like cats'],
        cards: <FxCard>[
          _reviewedCard(902, <FxRevlog>[
            FxRevlog(ankiSentenceRev, type: 0, ease: 3, ivl: 1),
          ]),
        ],
      ),
      FxNote(
        id: ms(2026, 8, 3),
        guid: 'anki-dog',
        mid: kBasicNt,
        fields: <String>['犬', 'dog'],
        cards: <FxCard>[
          _reviewedCard(903, <FxRevlog>[
            FxRevlog(ankiDogRev, type: 0, ease: 3, ivl: 1),
          ]),
        ],
      ),
    ],
  ),
  'media': utf8.encode('{}'),
});

/// 打开 apkg 里的集合（sqlite3 直接读）；[body] 结束后关库删临时文件。
T withCollection<T>(File apkg, T Function(Database db, Archive zip) body) {
  final Archive zip = ZipDecoder().decodeBytes(apkg.readAsBytesSync());
  final Directory dir = Directory.systemTemp.createTempSync('don_test_');
  final File db = File('${dir.path}${Platform.pathSeparator}c.anki21')
    ..writeAsBytesSync(zip.findFile('collection.anki21')!.content as List<int>);
  final Database d = sqlite3.open(db.path);
  try {
    return body(d, zip);
  } finally {
    d.close();
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // 句柄晚释放。
    }
  }
}

Map<String, Object?> _json(Database db, String col) =>
    (jsonDecode(db.select('SELECT $col FROM col').single[col] as String) as Map)
        .cast<String, Object?>();

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('srsDonationHeadwordOf / srsDonationWordFieldsOf', () {
    const String nt = 'nt-custom';
    SrsFieldDef f(String id, String name, int ord) =>
        SrsFieldDef(id: id, name: name, ord: ord);

    ({String? headword, String? reading}) word(
      List<SrsFieldDef> fields,
      Map<String, String> values,
    ) => srsDonationHeadwordOf(
      fields: srsDonationWordFieldsOf(
        noteTypeId: nt,
        builtinKey: null,
        fields: fields,
      ),
      valueOf: (String id) => values[id] ?? '',
    );

    test('白名单字段名：去空格、大小写不敏感，每类取第一个命中', () {
      final SrsDonationWordFields w = srsDonationWordFieldsOf(
        noteTypeId: nt,
        builtinKey: null,
        fields: <SrsFieldDef>[
          f('a', 'Front', 0),
          f('b', ' Vocab Kana ', 1),
          f('c', 'VOCAB', 2),
          f('d', '単語', 3),
          f('e', 'Reading', 4),
        ],
      );
      expect(w.headwordFieldId, 'c');
      expect(w.readingFieldId, 'b');
    });

    test('Front / Back 不在白名单：没有词头字段', () {
      final SrsDonationWordFields w = srsDonationWordFieldsOf(
        noteTypeId: nt,
        builtinKey: null,
        fields: <SrsFieldDef>[f('a', 'Front', 0), f('b', 'Back', 1)],
      );
      expect(w.headwordFieldId, isNull);
      expect(w.readingFieldId, isNull);
    });

    test('值校验', () {
      final List<SrsFieldDef> fs = <SrsFieldDef>[
        f('h', 'Expression', 0),
        f('r', 'Reading', 1),
      ];
      ({String? headword, String? reading}) of(String h, [String r = '']) =>
          word(fs, <String, String>{'h': h, 'r': r});
      expect(of('<b>食べる</b> ', 'たべる'), (headword: '食べる', reading: 'たべる'));
      expect(of('カタカナ々〆ヶー'), (headword: 'カタカナ々〆ヶー', reading: null));
      expect(of('𠮷野家', 'よしのや'), (headword: '𠮷野家', reading: 'よしのや'));
      for (final String bad in <String>[
        '漢字[かんじ]',
        '私は猫が好きです。',
        '猫 犬',
        'neko',
        '猫1',
        '（猫）',
        '',
        'あいうえおかきくけこさしすせそた', // 16 字
      ]) {
        expect(of(bad, 'ねこ'), (headword: null, reading: null), reason: bad);
      }
      // 读音单独不通过不影响词头。
      expect(of('猫', 'ネコ'), (headword: '猫', reading: 'ネコ'));
      expect(of('猫', '猫'), (headword: '猫', reading: null));
      expect(of('猫', 'ne ko'), (headword: '猫', reading: null));
    });

    test('内置 Lapis / Fushi 卡片按字段 ID 认', () {
      final SrsBuiltinNoteType lapis = srsBuiltinLapis(kProfile);
      final SrsDonationWordFields lw = srsDonationWordFieldsOf(
        noteTypeId: srsLapisNoteTypeId(kProfile),
        builtinKey: kSrsBuiltinLapisKey,
        fields: lapis.fields,
      );
      expect(lw.headwordFieldId, srsLapisFieldId(kProfile, 'Expression'));
      expect(lw.readingFieldId, srsLapisFieldId(kProfile, 'ExpressionReading'));
      final SrsBuiltinNoteType fc = srsBuiltinFushiCard(kProfile);
      final SrsDonationWordFields fw = srsDonationWordFieldsOf(
        noteTypeId: srsFushiCardNoteTypeId(kProfile),
        builtinKey: kSrsBuiltinFushiCardKey,
        fields: fc.fields,
      );
      expect(
        fw.headwordFieldId,
        srsFushiCardFieldId(kProfile, FushiCardFields.term),
      );
      expect(
        fw.readingFieldId,
        srsFushiCardFieldId(kProfile, FushiCardFields.termReading),
      );
    });
  });

  test('srsDonationIdentity', () {
    final ({String donorId, String donorKey}) id = srsDonationIdentity(
      kProfile,
    );
    expect(
      id.donorId,
      sha256
          .convert(utf8.encode('fushi-srs-donation-id:$kProfile'))
          .toString()
          .substring(0, 32),
    );
    expect(id.donorId, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(id.donorKey, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(
      id.donorKey,
      sha256
          .convert(utf8.encode('fushi-srs-donation-key:$kProfile'))
          .toString(),
    );
    expect(srsDonationIdentity(kProfile), id, reason: '同 profile 恒得同一对');
  });

  group('捐赠包', () {
    late int t;
    late SrsDbStore s;
    late Directory tmp;
    late String lapisReviewed;
    late String lapisFurigana;
    late String lapisNever;
    late String fushiNote;
    late String privateDeck;
    late String subDeck;

    String lapisField(String k) => srsLapisFieldId(kProfile, k);
    String fushiField(String k) => srsFushiCardFieldId(kProfile, k);

    setUp(() async {
      t = ms(2026, 10, 1, 12);
      tmp = Directory.systemTemp.createTempSync('don_export_');
      s = await openTestStore(
        profileUid: kProfile,
        deviceId: 'a',
        now: () => t,
        localOffsetMin: () => 540,
      );
      await importAnkiPackage(
        store: s,
        bytes: _ankiApkg(),
        storeMedia: (String name, Uint8List b) async => name,
        options: const SrsAnkiImportOptions(
          mergeNoteTypes: true,
          updateNotes: SrsImportUpdateCondition.never,
          updateNoteTypes: SrsImportUpdateCondition.never,
          withScheduling: true,
          withDeckConfigs: true,
        ),
        zstdDecompress: (Uint8List b) => null,
      );
      privateDeck = await s.createDeck('Private Stuff');
      subDeck = await s.createDeck('Secret Sub', parentId: privateDeck);
      lapisReviewed = await s.createNote(
        noteTypeId: s.lapisNoteTypeId,
        deckId: subDeck,
        tags: <String>['my_private_tag'],
        fieldsById: <String, String>{
          lapisField('Expression'): '食べる',
          lapisField('ExpressionReading'): 'たべる',
          lapisField('ExpressionFurigana'): '食[た]べる',
          lapisField('MainDefinition'): 'to eat (secret)',
        },
      );
      lapisFurigana = await s.createNote(
        noteTypeId: s.lapisNoteTypeId,
        fieldsById: <String, String>{
          lapisField('Expression'): '漢字[かんじ]',
          lapisField('ExpressionReading'): 'かんじ',
        },
      );
      lapisNever = await s.createNote(
        noteTypeId: s.lapisNoteTypeId,
        fieldsById: <String, String>{lapisField('Expression'): '未習'},
      );
      fushiNote = await s.createNote(
        noteTypeId: s.fushiCardNoteTypeId,
        fieldsById: <String, String>{
          fushiField(FushiCardFields.term): '見る',
          fushiField(FushiCardFields.termReading): 'みる',
        },
      );
      t += 60000;
      final String c1 = (await s.cardsOfNote(lapisReviewed)).single.id;
      await s.answer(c1, 3, durationMs: 90000);
      t += 600000;
      await s.answer(c1, 3, durationMs: 3000);
      t += 60000;
      // 手动改期：普通导出写进 revlog，捐赠包丢弃。
      await s.setDueDay(c1, (await s.dayContext()).dayIndexOf(t) + 5);
      t += 60000;
      await s.answer((await s.cardsOfNote(lapisFurigana)).single.id, 3);
      t += 60000;
      await s.answer((await s.cardsOfNote(fushiNote)).single.id, 4);
      t += 86400000;
    });

    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // 句柄晚释放。
      }
    });

    Future<File> export({
      bool includeWords = true,
      Set<String> excluded = const <String>{},
    }) async {
      final File f = File('${tmp.path}${Platform.pathSeparator}d.apkg');
      if (f.existsSync()) f.deleteSync();
      await exportSrsDonationFile(
        store: s,
        file: f,
        donorId: srsDonationIdentity(kProfile).donorId,
        appVersion: '9.9.9+1',
        includeWords: includeWords,
        excludedNoteIds: excluded,
      );
      return f;
    }

    /// 包里笔记 guid（已哈希）→ 字段值。
    Map<String, List<String>> fieldsByGuid(Database db) =>
        <String, List<String>>{
          for (final Row r in db.select('SELECT guid, flds FROM notes'))
            r['guid'] as String: (r['flds'] as String).split('\x1f'),
        };

    String hashed(String guid) =>
        sha256.convert(utf8.encode(guid)).toString().substring(0, 10);

    Future<String> guidOf(String noteId) async =>
        (await s.notes(<String>[noteId]))[noteId]!.guid;

    test('revlog / 来源 / 元信息 / 脱敏 / 词头', () async {
      final File f = await export();
      final SrsDonationPreview p = await previewSrsDonation(store: s);
      final Map<String, String> guid = <String, String>{
        for (final String n in <String>[
          lapisReviewed,
          lapisFurigana,
          lapisNever,
          fushiNote,
        ])
          n: hashed(await guidOf(n)),
      };
      withCollection(f, (Database db, Archive zip) {
        // zip：集合 + 空媒体清单，不带 fushi-ext。
        expect(zip.files.map((ArchiveFile e) => e.name).toSet(), <String>{
          'collection.anki21',
          'media',
        });
        expect(utf8.decode(zip.findFile('media')!.content as List<int>), '{}');

        // revlog：4 条 Fushi 复习 + 4 条 Anki 导入的复习；手动改期丢弃。
        final List<Row> rev = db
            .select('SELECT id, time, type, ease FROM revlog ORDER BY id')
            .toList();
        expect(rev, hasLength(8));
        expect(p.reviewCount, rev.length);
        expect(rev.every((Row r) => (r['ease'] as int) >= 1), isTrue);
        final Map<int, int> timeOf = <int, int>{
          for (final Row r in rev) r['id'] as int: r['time'] as int,
        };
        expect(timeOf.values, contains(90000), reason: '超过 60 s 的用时不截断');
        // 从 Anki 导入的日志保留原 Anki 时间戳作 revlog id、用时原样。
        expect(
          timeOf.keys,
          containsAll(<int>[
            ankiCatRev1,
            ankiCatRev2,
            ankiSentenceRev,
            ankiDogRev,
          ]),
        );
        expect(timeOf[ankiCatRev1], 120000);

        // 来源表：每条 revlog 一行。
        final Map<int, String> origin = <int, String>{
          for (final Row r in db.select(
            'SELECT id, origin FROM fushi_revlog_origin',
          ))
            r['id'] as int: r['origin'] as String,
        };
        expect(origin.keys.toSet(), timeOf.keys.toSet());
        for (final int id in <int>[
          ankiCatRev1,
          ankiCatRev2,
          ankiSentenceRev,
          ankiDogRev,
        ]) {
          expect(origin[id], SrsLogOrigin.anki);
        }
        expect(
          origin.values.where((String o) => o == SrsLogOrigin.fushi),
          hasLength(4),
        );

        // 元信息。
        final Map<String, String> meta = <String, String>{
          for (final Row r in db.select(
            'SELECT key, value FROM fushi_donation_meta',
          ))
            r['key'] as String: r['value'] as String,
        };
        expect(meta, <String, String>{
          'format': 'fushi-srs-donation',
          'version': '1',
          'donor_id': srsDonationIdentity(kProfile).donorId,
          'exported_at': '$t',
          'app_version': '9.9.9+1',
          'scheduler': 'fushi-fsrs',
          'utc_offset_min': '540',
          'rollover_hour': '4',
        });
        final Map<String, Object?> conf = _json(db, 'conf');
        expect(conf['rollover'], 4);
        expect(conf['localOffset'], -540);

        // 范围：没复习过的笔记不进包。
        final Map<String, List<String>> flds = fieldsByGuid(db);
        expect(flds.keys, isNot(contains(guid[lapisNever])));
        expect(flds, hasLength(6));
        expect(p.noteCount, 6);
        expect(p.cardCount, 6);
        expect(db.select('SELECT COUNT(*) AS n FROM cards').single['n'], 6);

        // 标签清空、guid 哈希。
        expect(
          db
              .select("SELECT COUNT(*) AS n FROM notes WHERE tags != ''")
              .single['n'],
          0,
        );
        expect(
          flds.keys,
          containsAll(<String>[
            guid[lapisReviewed]!,
            guid[lapisFurigana]!,
            guid[fushiNote]!,
            hashed('anki-cat'),
            hashed('anki-sentence'),
            hashed('anki-dog'),
          ]),
        );

        // 名字脱敏。
        final Map<String, Object?> decks = _json(db, 'decks');
        final Set<String> deckNames = <String>{
          for (final Object? d in decks.values) (d! as Map)['name'] as String,
        };
        // 层级不变：子牌组 = 父牌组编号名 + `::` + 自己的编号名（编号按 Anki 数字 id 排序）。
        expect(deckNames, hasLength(3));
        expect(deckNames, contains('Default'));
        final String parent = deckNames.firstWhere(
          (String n) => RegExp(r'^Deck \d+$').hasMatch(n),
        );
        expect(
          deckNames.where(
            (String n) => RegExp(
              '^${RegExp.escape(parent)}'
              r'::Deck \d+$',
            ).hasMatch(n),
          ),
          hasLength(1),
          reason: '$deckNames',
        );
        final Set<String> presetNames = <String>{
          for (final Object? d in _json(db, 'dconf').values)
            (d! as Map)['name'] as String,
        };
        expect(
          presetNames.every((String n) => RegExp(r'^Preset \d+$').hasMatch(n)),
          isTrue,
          reason: '$presetNames',
        );
        final String models =
            db.select('SELECT models FROM col').single['models'] as String;
        for (final String leak in <String>[
          'My Secret Vocab',
          'Basic',
          'Lapis',
          'Meaning',
          '{{Front}}',
          '"Front"',
          'MainDefinition',
          'secret',
          'Recognition',
        ]) {
          expect(models, isNot(contains(leak)), reason: leak);
        }
        for (final Object? m in _json(db, 'models').values) {
          final Map<String, Object?> mm = (m! as Map).cast<String, Object?>();
          expect(mm['name'], matches(RegExp(r'^NoteType \d+$')));
          expect(mm['css'], '');
          for (final Object? fld in mm['flds']! as List<Object?>) {
            expect(
              (fld! as Map)['name'],
              matches(RegExp(r'^(Headword|Reading|Field \d+)$')),
            );
          }
        }

        // 字段值：除词头 / 读音外全空。
        List<String> nonEmpty(String g) =>
            flds[g]!.where((String v) => v.isNotEmpty).toList();
        expect(nonEmpty(guid[lapisReviewed]!), <String>['食べる', 'たべる']);
        expect(nonEmpty(guid[fushiNote]!), <String>['見る', 'みる']);
        expect(nonEmpty(guid[lapisFurigana]!), isEmpty, reason: '漢字[かんじ] 不通过');
        expect(nonEmpty(hashed('anki-cat')), <String>['猫', 'ねこ']);
        expect(nonEmpty(hashed('anki-sentence')), isEmpty, reason: '句子不通过');
        expect(nonEmpty(hashed('anki-dog')), isEmpty, reason: 'Front 不在白名单');
        // sfld / csum 按保留后的首字段重算。
        final Row cat = db.select(
          'SELECT sfld, csum FROM notes WHERE guid = ?',
          <Object?>[hashed('anki-cat')],
        ).single;
        expect(cat['sfld'], '猫');
        expect(
          cat['csum'],
          int.parse(
            sha1.convert(utf8.encode('猫')).toString().substring(0, 8),
            radix: 16,
          ),
        );
      });

      // 预览词表：会保留词头的笔记，按词头排序。
      expect(
        p.words.map((SrsDonationWord w) => (w.headword, w.reading)).toList(),
        <(String, String?)>[('猫', 'ねこ'), ('見る', 'みる'), ('食べる', 'たべる')]..sort(
          ((String, String?) a, (String, String?) b) => a.$1.compareTo(b.$1),
        ),
      );
      expect(
        p.words.map((SrsDonationWord w) => w.noteId),
        containsAll(<String>[lapisReviewed, fushiNote]),
      );
      expect(
        p.firstReviewAt,
        DateTime.fromMillisecondsSinceEpoch(ankiCatRev1, isUtc: true),
      );
    });

    test('excludedNoteIds 与 includeWords=false', () async {
      final String g = hashed(await guidOf(lapisReviewed));
      final String gf = hashed(await guidOf(fushiNote));
      final File f1 = await export(excluded: <String>{lapisReviewed});
      withCollection(f1, (Database db, Archive _) {
        final Map<String, List<String>> flds = fieldsByGuid(db);
        expect(flds[g]!.every((String v) => v.isEmpty), isTrue);
        expect(flds[gf]!.where((String v) => v.isNotEmpty), <String>[
          '見る',
          'みる',
        ]);
        expect(
          db.select('SELECT id FROM revlog'),
          hasLength(8),
          reason: '复习照常进包',
        );
      });
      final File f2 = await export(includeWords: false);
      withCollection(f2, (Database db, Archive _) {
        expect(
          db
              .select('SELECT flds FROM notes')
              .every(
                (Row r) => (r['flds'] as String)
                    .split('\x1f')
                    .every((String v) => v.isEmpty),
              ),
          isTrue,
        );
        expect(
          db.select('SELECT sfld FROM notes').every((Row r) => r['sfld'] == ''),
          isTrue,
        );
        expect(db.select('SELECT id FROM revlog'), hasLength(8));
      });
    });
  });
}
