import 'dart:convert';

import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_handler.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'ankiconnect_harness.dart';

void main() {
  late AcHarness h;

  setUp(() async => h = await AcHarness.create());

  group('元动作（形状对照 AnkiConnect README）', () {
    test('version / requestPermission / getProfiles / fushiIdentify', () async {
      expect(await h.call('version'), <String, Object?>{
        'result': 6,
        'error': null,
      });
      expect(await h.ok('requestPermission'), <String, Object?>{
        'permission': 'granted',
        'requireApikey': false,
        'version': 6,
      });
      expect(await h.ok('getProfiles'), <String>['User 1']);
      expect(await h.ok('getActiveProfile'), 'User 1');
      expect(await h.ok('fushiIdentify'), <String, Object?>{
        'fushi': true,
        'instance': 'inst-123',
      });
    });

    test('version ≤ 4：成功回裸值，错误仍是 {result, error}', () async {
      expect(await h.handler.handle(<String, Object?>{'action': 'version'}), 6);
      expect(
        await h.handler.handle(<String, Object?>{'action': 'nope'}),
        <String, Object?>{'result': null, 'error': 'unsupported action'},
      );
    });

    test('不支持的动作 → unsupported action（Yomitan 据此降级）', () async {
      expect(
        await h.call('deleteDecks', <String, Object?>{}),
        <String, Object?>{'result': null, 'error': kSrsAnkiUnsupportedAction},
      );
    });

    test('apiReflect', () async {
      expect(
        await h.ok('apiReflect', <String, Object?>{
          'scopes': <String>['actions'],
          'actions': <String>['addNote', 'canAddNotesWithErrorDetail', 'x'],
        }),
        <String, Object?>{
          'scopes': <String>['actions'],
          'actions': <String>['addNote', 'canAddNotesWithErrorDetail'],
        },
      );
      expect(
        (await h.call('apiReflect', <String, Object?>{}))['error'],
        'scopes has invalid value',
      );
    });

    test('multi：子请求不带 version 时回裸值（Yomitan findNoteIds 依赖）', () async {
      final Object? r = await h.ok('multi', <String, Object?>{
        'actions': <Object?>[
          <String, Object?>{'action': 'deckNames'},
          <String, Object?>{'action': 'version', 'version': 6},
          <String, Object?>{'action': 'bogus'},
        ],
      });
      expect(r, <Object?>[
        <String>['Default'],
        <String, Object?>{'result': 6, 'error': null},
        <String, Object?>{'result': null, 'error': 'unsupported action'},
      ]);
    });

    test('sync 立即返回 null 并触发回调', () async {
      expect(await h.call('sync'), <String, Object?>{
        'result': null,
        'error': null,
      });
      await Future<void>.delayed(Duration.zero);
      expect(h.syncs, 1);
    });
  });

  group('牌组 / 笔记类型', () {
    test('deckNames / createDeck(父::子) / deckNamesAndIds', () async {
      final Object? id = await h.ok('createDeck', <String, Object?>{
        'deck': '日本語::語彙',
      });
      expect(id, isA<int>());
      expect(await h.ok('deckNames'), <String>['Default', '日本語', '日本語::語彙']);
      final Map<String, Object?> ids = ((await h.ok('deckNamesAndIds'))! as Map)
          .cast<String, Object?>();
      expect(ids['日本語::語彙'], id);
      // 再建一次同名：返回同一个 id，不重复建。
      expect(
        await h.ok('createDeck', <String, Object?>{'deck': '日本語::語彙'}),
        id,
      );
    });

    test('modelNames / modelNamesAndIds / modelFieldNames', () async {
      expect(await h.ok('modelNames'), <String>['Fushi Card', 'Lapis']);
      final Map<String, Object?> m = ((await h.ok('modelNamesAndIds'))! as Map)
          .cast<String, Object?>();
      expect(m['Lapis'], SrsIds.builtinNoteTypeAnkiNum('lapis'));
      final List<Object?> fields =
          (await h.ok('modelFieldNames', <String, Object?>{
                'modelName': 'Lapis',
              }))!
              as List;
      expect(fields.first, 'Expression');
      expect(fields, contains('ExpressionReading'));
      expect(
        (await h.call('modelFieldNames', <String, Object?>{
          'modelName': 'Nope',
        }))['error'],
        'model was not found: Nope',
      );
    });
  });

  group('Fushi 卡片字段改名后的旧名兼容（2026-10-29）', () {
    test(
      'Yomitan 还按旧字段名（Expression / Picture / MiscInfo）加卡 → 落到新名字段',
      () async {
        final int nid =
            (await h.ok('addNote', <String, Object?>{
                  'note': <String, Object?>{
                    ...yomitanNote('食べる', model: 'Fushi Card'),
                    'fields': <String, Object?>{
                      'Expression': '食べる',
                      'expressionreading': 'たべる',
                      'Picture': '<img src="a.webp">',
                      'MiscInfo': '出典',
                    },
                  },
                }))!
                as int;
        final Map<String, Object?> n =
            (((await h.ok('notesInfo', <String, Object?>{
                              'notes': <int>[nid],
                            }))!
                            as List)
                        .first!
                    as Map)
                .cast<String, Object?>();
        final Map<String, Object?> fields = (n['fields']! as Map)
            .cast<String, Object?>();
        String value(String name) =>
            ((fields[name]! as Map)['value'] as String?) ?? '';
        expect(value('Term'), '食べる');
        expect(value('TermReading'), 'たべる');
        expect(value('Media'), '<img src="a.webp">');
        expect(value('Source'), '出典');
      },
    );

    test('findNotes 按旧字段名查（Yomitan 查重 "Expression:…"）仍查到 Fushi 卡片', () async {
      final int fushi =
          (await h.ok('addNote', <String, Object?>{
                'note': <String, Object?>{
                  ...yomitanNote('食べる', model: 'Fushi Card'),
                  'fields': <String, Object?>{
                    'Term': '食べる',
                    'Media': '<img src="m.webp">',
                  },
                },
              }))!
              as int;
      final int lapis =
          (await h.ok('addNote', <String, Object?>{
                'note': yomitanNote('食べる'),
              }))!
              as int;
      Future<List<Object?>> find(String q) async =>
          (await h.ok('findNotes', <String, Object?>{'query': q}))! as List;
      expect(
        await find('"Expression:食べる"'),
        unorderedEquals(<int>[fushi, lapis]),
      );
      expect(await find('"note:Fushi Card" "expression:食べる"'), <int>[fushi]);
      expect(await find('Picture:*m.webp*'), <int>[fushi]);
      // 新名只命中 Fushi 卡片：Lapis 的 Expression 不认 Term。
      expect(await find('"Term:食べる"'), <int>[fushi]);
    });

    test('别名只对 Fushi 卡片生效：Lapis 收到新名 Term 不会写进 Expression', () async {
      final Map<String, Object?> r = await h.call('addNote', <String, Object?>{
        'note': <String, Object?>{
          ...yomitanNote('食べる'),
          'fields': <String, Object?>{'Term': '食べる'},
        },
      });
      expect(r['error'], isNotNull);
    });
  });

  group('加卡与查重（照 Yomitan anki-connect.js 的真实请求形状）', () {
    test('addNote → notesInfo / cardsInfo / findCards 形状', () async {
      final int nid =
          (await h.ok('addNote', <String, Object?>{
                'note': yomitanNote('食べる', reading: 'たべる'),
              }))!
              as int;
      final List<Object?> info =
          (await h.ok('notesInfo', <String, Object?>{
                'notes': <int>[nid, 42],
              }))!
              as List;
      final Map<String, Object?> n = (info[0]! as Map).cast<String, Object?>();
      expect(n['noteId'], nid);
      expect(n['modelName'], 'Lapis');
      expect(n['tags'], <String>['yomitan']);
      expect(n['profile'], 'User 1');
      final Map<String, Object?> fields = (n['fields']! as Map)
          .cast<String, Object?>();
      expect(fields['Expression'], <String, Object?>{
        'value': '食べる',
        'order': 0,
      });
      expect(info[1], <String, Object?>{}, reason: '不存在的 id 回空对象，位置对齐');
      final List<Object?> cards = n['cards']! as List;
      expect(cards, hasLength(1));

      expect(
        await h.ok('findCards', <String, Object?>{'query': 'nid:$nid'}),
        cards,
      );
      final Map<String, Object?> c =
          ((await h.ok('cardsInfo', <String, Object?>{'cards': cards}))!
                      as List)
                  .single!
              as Map<String, Object?>;
      expect(c['cardId'], cards.single);
      expect(c['note'], nid);
      expect(c['deckName'], 'Default');
      expect(c['modelName'], 'Lapis');
      expect(c['queue'], 0);
      expect(c['type'], 0);
      expect(c['question'], contains('食べる'));
      for (final String k in <String>[
        'fields',
        'fieldOrder',
        'answer',
        'ord',
        'css',
        'factor',
        'interval',
        'due',
        'reps',
        'lapses',
        'left',
        'mod',
      ]) {
        expect(c, contains(k));
      }

      // 出处 SourceRef：kind web，经兼容层进来。
      final String? noteId = await h.store.noteIdForAnkiNumericId(nid);
      final SrsNoteView? view = await h.store.note(noteId!);
      expect(view!.source!.kind, SrsSourceKind.web);
      expect(view.source!.data['via'], kSrsAnkiConnectSourceVia);
    });

    test(
      'Yomitan 查重：canAddNotesWithErrorDetail → 重复的再 findNotes 拿 id',
      () async {
        final int nid =
            (await h.ok('addNote', <String, Object?>{
                  'note': yomitanNote('食べる'),
                }))!
                as int;
        final Map<String, Object?> dup = yomitanNote('食べる');
        final Map<String, Object?> fresh = yomitanNote('飲む');
        final List<Object?> detail =
            (await h.ok('canAddNotesWithErrorDetail', <String, Object?>{
                  'notes': <Object?>[
                    yomitanStripped(dup),
                    yomitanStripped(fresh),
                  ],
                }))!
                as List;
        expect(detail[0], <String, Object?>{
          'canAdd': false,
          'error': kSrsAnkiDuplicateError,
        });
        expect(detail[1], <String, Object?>{'canAdd': true});
        expect(
          await h.ok('canAddNotes', <String, Object?>{
            'notes': <Object?>[yomitanStripped(dup), yomitanStripped(fresh)],
          }),
          <bool>[false, true],
        );

        // findNoteIds：单条直接 findNotes；多条先并集再用 nid: 约束（经 multi，不带 version）。
        expect(
          await h.ok('findNotes', <String, Object?>{
            'query': yomitanQuery(dup),
          }),
          <int>[nid],
        );
        final String q1 = yomitanQuery(dup), q2 = yomitanQuery(fresh);
        final List<Object?> union =
            (await h.ok('findNotes', <String, Object?>{
                  'query': '($q1) or ($q2)',
                }))!
                as List;
        expect(union, <int>[nid]);
        final Object? multi = await h.ok('multi', <String, Object?>{
          'actions': <Object?>[
            for (final String q in <String>[q1, q2])
              <String, Object?>{
                'action': 'findNotes',
                'params': <String, Object?>{
                  'query': 'nid:${union.join(',')} ($q)',
                },
              },
          ],
        });
        expect(multi, <Object?>[
          <int>[nid],
          <int>[],
        ]);

        // allowDuplicate=false 的 addNote 报与 AnkiConnect 逐字相同的错误。
        expect(
          (await h.call('addNote', <String, Object?>{
            'note': yomitanNote('食べる', allowDuplicate: false),
          }))['error'],
          kSrsAnkiDuplicateError,
        );
        // allowDuplicate=true（Yomitan 默认）照加。
        expect(
          await h.ok('addNote', <String, Object?>{'note': yomitanNote('食べる')}),
          isA<int>(),
        );
      },
    );

    test('引号 / 冒号 / 通配符 / HTML：查重按「首字段去 HTML 后相等」，搜索按 Anki 语义', () async {
      for (final String e in <String>[
        '12:30',
        'a_b',
        'axb',
        '"引用"',
        '<b>猫</b>',
        'x*y',
      ]) {
        await h.ok('addNote', <String, Object?>{'note': yomitanNote(e)});
      }
      Future<List<Object?>> find(String expr) async =>
          (await h.ok('findNotes', <String, Object?>{
                'query': yomitanQuery(yomitanNote(expr)),
              }))!
              as List;
      Future<Map<String, Object?>> canAdd(String expr) async =>
          (((await h.ok('canAddNotesWithErrorDetail', <String, Object?>{
                            'notes': <Object?>[
                              yomitanStripped(yomitanNote(expr)),
                            ],
                          }))!
                          as List)
                      .single!
                  as Map)
              .cast<String, Object?>();

      // 冒号：值里的冒号原样匹配。
      expect(await find('12:30'), hasLength(1));
      expect((await canAdd('12:30'))['canAdd'], isFalse);
      // 下划线是 Anki 单字通配：搜索命中 a_b 与 axb，查重只认相等。
      expect(await find('a_b'), hasLength(2));
      expect((await canAdd('axb'))['canAdd'], isFalse);
      expect((await canAdd('ayb'))['canAdd'], isTrue);
      // 星号通配。
      expect(await find('x*y'), hasLength(1));
      // 引号：Yomitan 去掉引号后查 `expression:引用`，与 Anki 一样搜不到带引号的原文；
      // 但查重（去 HTML 后相等）照样认出重复——Yomitan 会把它标成「重复但 id 未知」。
      expect(await find('"引用"'), isEmpty);
      expect((await canAdd('"引用"'))['canAdd'], isFalse);
      // HTML：去标签后相等即重复；字段搜索也对去 HTML 的值匹配。
      expect((await canAdd('猫'))['canAdd'], isFalse);
      expect(await find('猫'), hasLength(1));
    });

    test('canAddNotes(WithErrorDetail)：候选首字段整批一次规范化，结果与逐条请求一致', () async {
      final List<List<String>> calls = <List<String>>[];
      final AcHarness hc = await AcHarness.create(
        dupeNormBatch: (List<String> fields) {
          calls.add(List<String>.of(fields));
          return srsDupeNormBatch(fields);
        },
      );
      await hc.ok('createDeck', <String, Object?>{'deck': 'JP::Vocab'});
      await hc.ok('addNote', <String, Object?>{
        'note': yomitanNote('<b>猫</b>', deck: 'JP::Vocab'),
      });
      await hc.ok('addNote', <String, Object?>{'note': yomitanNote('犬')});
      final List<Object?> notes = <Object?>[
        yomitanStripped(yomitanNote('猫')), // 去 HTML 后重复
        yomitanStripped(yomitanNote('  犬 ')), // trim 后重复
        yomitanStripped(yomitanNote('鳥')), // 能加
        yomitanStripped(yomitanNote('')), // 空
        yomitanStripped(yomitanNote('<i></i>')), // 去 HTML 后空
        yomitanStripped(yomitanNote('猫', deck: 'Other')), // 牌组不存在（不进规范化）
        yomitanStripped(
          yomitanNote('猫', deck: 'JP::Vocab', duplicateScope: 'deck'),
        ), // 牌组范围内重复
        yomitanStripped(
          yomitanNote('犬', deck: 'JP::Vocab', duplicateScope: 'deck'),
        ), // 重复的那条在别的牌组 → 能加
        yomitanStripped(yomitanNote('猫', model: 'Nope')), // 模型不存在
        'not a note', // 不是对象
        yomitanStripped(yomitanNote('鳥')), // 同批里再来一条也能加（不和同批互判）
      ];
      // 逐条：每个候选单独一个请求（旧实现的口径：每条各自规范化一次）。
      final List<Object?> single = <Object?>[
        for (final Object? n in notes)
          ((await hc.ok('canAddNotesWithErrorDetail', <String, Object?>{
                    'notes': <Object?>[n],
                  }))!
                  as List)
              .single,
      ];
      expect(single, <Object?>[
        <String, Object?>{'canAdd': false, 'error': kSrsAnkiDuplicateError},
        <String, Object?>{'canAdd': false, 'error': kSrsAnkiDuplicateError},
        <String, Object?>{'canAdd': true},
        <String, Object?>{'canAdd': false, 'error': kSrsAnkiEmptyError},
        <String, Object?>{'canAdd': false, 'error': kSrsAnkiEmptyError},
        <String, Object?>{
          'canAdd': false,
          'error': 'deck was not found: Other',
        },
        <String, Object?>{'canAdd': false, 'error': kSrsAnkiDuplicateError},
        <String, Object?>{'canAdd': true},
        <String, Object?>{
          'canAdd': false,
          'error': 'model was not found: Nope',
        },
        <String, Object?>{'canAdd': false, 'error': 'note must be an object'},
        <String, Object?>{'canAdd': true},
      ]);

      calls.clear();
      final List<Object?> batch =
          (await hc.ok('canAddNotesWithErrorDetail', <String, Object?>{
                'notes': notes,
              }))!
              as List;
      expect(batch, single);
      // 整个请求只跨一次 FFI：解析通过的 8 个候选首字段一批（库内旧笔记的规范形已缓存，不再算）。
      expect(calls, <List<String>>[
        <String>['猫', '  犬 ', '鳥', '', '<i></i>', '猫', '犬', '鳥'],
      ]);

      calls.clear();
      expect(
        await hc.ok('canAddNotes', <String, Object?>{'notes': notes}),
        <bool>[for (final Object? d in single) (d! as Map)['canAdd']! as bool],
      );
      expect(calls, hasLength(1));
    });

    test('查重范围：deck / deck-root / checkChildren / checkAllModels', () async {
      await h.ok('createDeck', <String, Object?>{'deck': 'JP::Vocab'});
      await h.ok('createDeck', <String, Object?>{'deck': 'JP::Grammar'});
      await h.ok('createDeck', <String, Object?>{'deck': 'Other'});
      await h.ok('addNote', <String, Object?>{
        'note': yomitanNote('犬', deck: 'JP::Vocab'),
      });
      Future<bool> canAdd(Map<String, Object?> n) async =>
          ((await h.ok('canAddNotes', <String, Object?>{
                        'notes': <Object?>[yomitanStripped(n)],
                      }))!
                      as List)
                  .single!
              as bool;

      expect(await canAdd(yomitanNote('犬', deck: 'Other')), isFalse);
      expect(
        await canAdd(
          yomitanNote('犬', deck: 'JP::Grammar', duplicateScope: 'deck'),
        ),
        isTrue,
      );
      expect(
        await canAdd(
          yomitanNote('犬', deck: 'JP::Vocab', duplicateScope: 'deck'),
        ),
        isFalse,
      );
      // deck-root：JP 根下的任何子牌组都算。
      expect(
        await canAdd(
          yomitanNote('犬', deck: 'JP::Grammar', duplicateScope: 'deck-root'),
        ),
        isFalse,
      );
      // Yomitan 实际发出的展开形：deck + deckName=根 + checkChildren。
      expect(
        await canAdd(
          yomitanNote(
            '犬',
            deck: 'JP::Grammar',
            duplicateScope: 'deck',
            scopeDeckName: 'JP',
            checkChildren: true,
          ),
        ),
        isFalse,
      );
      expect(
        await canAdd(
          yomitanNote(
            '犬',
            deck: 'JP::Grammar',
            duplicateScope: 'deck',
            scopeDeckName: 'JP',
          ),
        ),
        isTrue,
        reason: '不查子牌组时 JP 本身没有卡',
      );
      expect(
        await canAdd(
          yomitanNote(
            '犬',
            deck: 'Other',
            duplicateScope: 'deck',
            scopeDeckName: 'Missing',
          ),
        ),
        isTrue,
        reason: '范围牌组不存在 → 不可能重复（同 AnkiConnect）',
      );
      expect(
        await canAdd(
          yomitanNote('犬', duplicateScope: 'collection', checkAllModels: true),
        ),
        isFalse,
      );
    });

    test('空首字段 / 模型或牌组不存在 / 选项类型错', () async {
      expect(
        (await h.call('addNote', <String, Object?>{
          'note': yomitanNote(''),
        }))['error'],
        kSrsAnkiEmptyError,
      );
      expect(
        (await h.call('addNote', <String, Object?>{
          'note': yomitanNote('a', deck: 'Nope'),
        }))['error'],
        'deck was not found: Nope',
      );
      expect(
        (await h.call('addNote', <String, Object?>{
          'note': yomitanNote('a', model: 'Basic'),
        }))['error'],
        'model was not found: Basic',
      );
      final Map<String, Object?> bad = yomitanNote('a')
        ..['options'] = <String, Object?>{'allowDuplicate': 'yes'};
      expect(
        (await h.call('addNote', <String, Object?>{'note': bad}))['error'],
        'option parameter "allowDuplicate" must be boolean',
      );
    });

    test('addNotes：失败的位置为 null', () async {
      expect(
        await h.ok('addNotes', <String, Object?>{
          'notes': <Object?>[
            yomitanNote('一'),
            yomitanNote(''),
            yomitanNote('二'),
          ],
        }),
        <Object?>[isA<int>(), null, isA<int>()],
      );
    });
  });

  group('搜索语法', () {
    test('不支持的语法返回明确错误，不静默返回空', () async {
      await h.ok('addNote', <String, Object?>{'note': yomitanNote('猫')});
      for (final String q in <String>[
        'prop:ease>2',
        'rated:1',
        'is:buried-sibling',
      ]) {
        final Map<String, Object?> r = await h.call(
          'findNotes',
          <String, Object?>{'query': q},
        );
        expect(r['result'], isNull, reason: q);
        expect(r['error'], startsWith('unsupported search syntax'), reason: q);
      }
      // 浏览页补上的语法与浏览页同一份求值（原生浏览会话 store/browse.rs）。
      expect(
        await h.ok('findNotes', <String, Object?>{'query': 'prop:ivl=0'}),
        hasLength(1),
      );
      expect(
        await h.ok('findNotes', <String, Object?>{'query': 'flag:1'}),
        isEmpty,
      );
      expect(
        await h.ok('findNotes', <String, Object?>{'query': 'is:buried'}),
        isEmpty,
      );
      final Map<String, Object?> syntax = await h.call(
        'findCards',
        <String, Object?>{'query': '(猫'},
      );
      expect(syntax['result'], isNull);
      expect(syntax['error'], startsWith('invalid search'));
      expect(await h.ok('findNotes', <String, Object?>{}), <int>[]);
      expect(
        await h.ok('findNotes', <String, Object?>{'query': ''}),
        hasLength(1),
      );
    });

    test('deck: / tag: / note: / is:new / is:suspended', () async {
      await h.ok('createDeck', <String, Object?>{'deck': 'A::B'});
      final int n1 =
          (await h.ok('addNote', <String, Object?>{
                'note': yomitanNote('一', deck: 'A::B', tags: <String>['x::y']),
              }))!
              as int;
      await h.ok('addNote', <String, Object?>{'note': yomitanNote('二')});
      expect(
        await h.ok('findNotes', <String, Object?>{'query': 'deck:A'}),
        <int>[n1],
      );
      expect(
        await h.ok('findNotes', <String, Object?>{'query': 'tag:x'}),
        <int>[n1],
      );
      expect(
        await h.ok('findNotes', <String, Object?>{
          'query': 'note:lapis is:new',
        }),
        hasLength(2),
      );
      final List<Object?> cards =
          (await h.ok('findCards', <String, Object?>{'query': 'nid:$n1'}))!
              as List;
      expect(await h.ok('suspend', <String, Object?>{'cards': cards}), isTrue);
      expect(await h.ok('suspend', <String, Object?>{'cards': cards}), isFalse);
      expect(
        await h.ok('areSuspended', <String, Object?>{'cards': cards}),
        <bool>[true],
      );
      expect(
        await h.ok('findCards', <String, Object?>{'query': 'is:suspended'}),
        cards,
      );
      expect(
        await h.ok('unsuspend', <String, Object?>{'cards': cards}),
        isTrue,
      );
      expect(
        await h.ok('suspended', <String, Object?>{'card': cards.single}),
        isFalse,
      );
    });
  });

  group('编辑', () {
    test('updateNoteFields / addTags / removeTags / getTags', () async {
      final int nid =
          (await h.ok('addNote', <String, Object?>{'note': yomitanNote('猫')}))!
              as int;
      await h.ok('updateNoteFields', <String, Object?>{
        'note': <String, Object?>{
          'id': nid,
          'fields': <String, Object?>{'ExpressionReading': 'ねこ'},
        },
      });
      await h.ok('addTags', <String, Object?>{
        'notes': <int>[nid],
        'tags': 'animal  cute',
      });
      await h.ok('removeTags', <String, Object?>{
        'notes': <int>[nid],
        'tags': 'yomitan',
      });
      final Map<String, Object?> n =
          (((await h.ok('notesInfo', <String, Object?>{
                            'notes': <int>[nid],
                          }))!
                          as List)
                      .single!
                  as Map)
              .cast<String, Object?>();
      expect(
        ((n['fields']! as Map)['ExpressionReading'] as Map)['value'],
        'ねこ',
      );
      expect(n['tags'], <String>['animal', 'cute']);
      expect(await h.ok('getTags'), <String>['animal', 'cute']);
      expect(
        (await h.call('updateNoteFields', <String, Object?>{
          'note': <String, Object?>{'id': 1, 'fields': <String, Object?>{}},
        }))['error'],
        'Note was not found: 1',
      );
    });

    test('setSpecificValueOfCard：只认新卡的 due（队列位置），形状照插件', () async {
      // 直接经 store 建笔记：本用例只测位置读写，不依赖查重用的原生搜索内核。
      final String noteId = await h.store.createNote(
        noteTypeId: h.store.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(kAcProfile, 'Expression'): '猫',
        },
      );
      final int card = SrsIds.ankiNumericId(
        (await h.store.cardsOfNote(noteId)).single.id,
      );
      Future<Map<String, Object?>> info() async =>
          (((await h.ok('cardsInfo', <String, Object?>{
                            'cards': <int>[card],
                          }))!
                          as List)
                      .single!
                  as Map)
              .cast<String, Object?>();
      expect((await info())['due'], 0, reason: '没排过的新卡 due 报 0');

      expect(
        await h.ok('setSpecificValueOfCard', <String, Object?>{
          'card': card,
          'keys': <String>['due', 'ivl'],
          'newValues': <Object?>[7, 3],
          'warning_check': true,
        }),
        <Object?>[
          true,
          <Object?>[false, 'Fushi review cannot set "ivl" on a card'],
        ],
      );
      expect((await info())['due'], 7);
      final String? cardId = await h.store.cardIdForAnkiNumericId(card);
      expect((await h.store.cardRow(cardId!))!.newPosition, 7);

      // 长度不一致：裸 false；卡不存在：[[false, 原因]]。
      expect(
        await h.ok('setSpecificValueOfCard', <String, Object?>{
          'card': card,
          'keys': <String>['due'],
          'newValues': <Object?>[],
        }),
        isFalse,
      );
      final List<Object?> missing =
          (await h.ok('setSpecificValueOfCard', <String, Object?>{
                'card': 1,
                'keys': <String>['due'],
                'newValues': <Object?>[1],
              }))!
              as List;
      expect((missing.single! as List).first, isFalse);

      // 空卡（生成门隐藏）按不存在处理。「学过的卡不接受」在 store 层
      // （srs_new_card_position_test）测：本 harness 没装排程内核，答不了题。
      await h.store.updateNote(
        noteId,
        fieldsById: <String, String>{
          srsLapisFieldId(kAcProfile, 'Expression'): '',
        },
      );
      final List<Object?> learned =
          (await h.ok('setSpecificValueOfCard', <String, Object?>{
                'card': card,
                'keys': <String>['due'],
                'newValues': <Object?>[1],
              }))!
              as List;
      expect((learned.single! as List).first, isFalse);
      expect((await h.store.cardRow(cardId))!.newPosition, 7);
    });

    test('guiBrowse / guiEditNote 交给宿主回调', () async {
      final int nid =
          (await h.ok('addNote', <String, Object?>{'note': yomitanNote('猫')}))!
              as int;
      final List<Object?> cards =
          (await h.ok('guiBrowse', <String, Object?>{'query': 'nid:$nid'}))!
              as List;
      expect(cards, hasLength(1));
      expect(h.browsed.single.$1, 'nid:$nid');
      expect(h.browsed.single.$2, hasLength(1));
      await h.ok('guiEditNote', <String, Object?>{'note': nid});
      expect(h.edited.single, await h.store.noteIdForAnkiNumericId(nid));
    });
  });

  group('API key', () {
    test('设了 key：缺 / 错 → 错误；对 → 放行；multi 子请求继承外层 key', () async {
      h.apiKey = 's3cret';
      expect((await h.call('deckNames'))['error'], kSrsAnkiKeyError);
      expect(
        (await h.call('deckNames', null, 'wrong'))['error'],
        kSrsAnkiKeyError,
      );
      expect((await h.call('deckNames', null, 's3cret'))['error'], isNull);
      expect((await h.call('requestPermission'))['result'], <String, Object?>{
        'permission': 'granted',
        'requireApikey': true,
        'version': 6,
      });
      expect((await h.call('fushiIdentify'))['error'], isNull);
      final Map<String, Object?> multi = await h.call(
        'multi',
        <String, Object?>{
          'actions': <Object?>[
            <String, Object?>{'action': 'version'},
            <String, Object?>{'action': 'version', 'key': 'wrong'},
          ],
        },
        's3cret',
      );
      expect(multi['result'], <Object?>[
        6,
        <String, Object?>{'result': null, 'error': kSrsAnkiKeyError},
      ]);
    });
  });

  group('storeMediaFile', () {
    test('data（base64）默认允许，按宿主返回的文件名回', () async {
      expect(
        await h.ok('storeMediaFile', <String, Object?>{
          'filename': '../../evil/a.mp3',
          'data': base64Encode(<int>[9, 8, 7]),
        }),
        'a.mp3',
      );
      expect(h.media['a.mp3'], <int>[9, 8, 7]);
    });

    test('path / url 默认被拒，且不读文件、不发请求', () async {
      final Map<String, Object?> p = await h.call(
        'storeMediaFile',
        <String, Object?>{'filename': 'x.png', 'path': r'C:\Windows\win.ini'},
      );
      expect(p['result'], isNull);
      expect(p['error'], contains('"path" parameter'));
      final Map<String, Object?> u = await h.call(
        'storeMediaFile',
        <String, Object?>{'filename': 'x.png', 'url': 'https://example.com/a'},
      );
      expect(u['error'], contains('"url" parameter'));
      expect(h.fetched, isEmpty);
      expect(h.media, isEmpty);
    });

    test('addNote 的 picture 走同一策略：url 被拒时错误文本写进字段而非下载', () async {
      final Map<String, Object?> note = yomitanNote('猫')
        ..['picture'] = <Object?>[
          <String, Object?>{
            'url': 'http://127.0.0.1/a.png',
            'filename': 'a.png',
            'fields': <String>['Sentence'],
          },
        ]
        ..['audio'] = <String, Object?>{
          'data': base64Encode(<int>[1]),
          'filename': 'a.mp3',
          'fields': <String>['Sentence'],
        };
      final int nid =
          (await h.ok('addNote', <String, Object?>{'note': note}))! as int;
      final Map<String, Object?> n =
          (((await h.ok('notesInfo', <String, Object?>{
                            'notes': <int>[nid],
                          }))!
                          as List)
                      .single!
                  as Map)
              .cast<String, Object?>();
      final String sentence =
          ((n['fields']! as Map)['Sentence'] as Map)['value'] as String;
      expect(sentence, contains('disabled'));
      expect(sentence, contains('[sound:a.mp3]'));
      expect(h.fetched, isEmpty);
    });
  });
}
