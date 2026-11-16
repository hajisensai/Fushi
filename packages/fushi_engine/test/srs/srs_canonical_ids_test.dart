// 持久化 SRS 实体 ID 的归一（G9-6，lib/srs/srs_canonical_ids.dart）：纯逻辑，内核的 `canonical_ids` 用假的查表代替。
//
// 每类持久化位置（单值 ID：制卡牌组 / 笔记类型；两层键：字段映射）各验三件事：带盐成员 ID → 规范 ID 并落盘、
// 并入后（别名类变了）再跑一次重归一、归一不到（实体已不存在）保留原值不写。统一入口按内核上限分批。
import 'package:fushi_engine/srs/srs_canonical_ids.dart';
import 'package:fushi_engine/srs/srs_mining_target.dart';
import 'package:test/test.dart';

/// 假的 `canonical_ids`：按 [aliases] 归一，表里没有的原样（与内核同口径），记下每批请求。
final class _FakeKernel {
  _FakeKernel([Map<String, String>? aliases])
    : aliases = aliases ?? <String, String>{};

  final Map<String, String> aliases;
  final List<List<String>> batches = <List<String>>[];

  Future<List<String>> lookup(List<String> ids) async {
    if (ids.length > kSrsCanonicalIdsBatchMax) {
      throw StateError('canonical_ids: at most $kSrsCanonicalIdsBatchMax');
    }
    batches.add(List<String>.of(ids));
    return <String>[for (final String id in ids) aliases[id] ?? id];
  }
}

/// 内存里的三条制卡偏好（同 PreferencesRepository 的 `srs_mining_*`），记下写了几次。
final class _Prefs {
  _Prefs({
    this.deckId = '',
    this.noteTypeId = '',
    Map<String, Map<String, String>>? mappings,
  }) : mappings = mappings ?? <String, Map<String, String>>{};

  String deckId;
  String noteTypeId;
  Map<String, Map<String, String>> mappings;
  final List<String> writes = <String>[];

  List<SrsPersistedIdSite> get sites => srsMiningDestinationIdSites(
    read: () => SrsMiningDestination(
      deckId: deckId,
      noteTypeId: noteTypeId,
      fieldMappingsByType: mappings,
    ),
    writeDeckId: (String id) async {
      writes.add('deck');
      deckId = id;
    },
    writeNoteTypeId: (String id) async {
      writes.add('noteType');
      noteTypeId = id;
    },
    writeFieldMappings: (Map<String, Map<String, String>> m) async {
      writes.add('mappings');
      mappings = m;
    },
  );
}

// 合成的 ID：`m*` 是按别的盐算出的成员，`c*` 是规范 ID。
const String _deckMember = 'm-deck-0000';
const String _deckCanon = 'c-deck-0000';
const String _typeMember = 'm-type-0000';
const String _typeCanon = 'c-type-0000';
const String _fieldMember = 'm-field-0001';
const String _fieldCanon = 'c-field-0001';

void main() {
  group('单值 ID 位置（srs_mining_deck_id / srs_mining_note_type_id）', () {
    test('带盐成员 ID 换成规范 ID 并落盘', () async {
      final _Prefs prefs = _Prefs(deckId: _deckMember, noteTypeId: _typeMember);
      final _FakeKernel k = _FakeKernel(<String, String>{
        _deckMember: _deckCanon,
        _typeMember: _typeCanon,
      });
      final List<String> written = await srsNormalizePersistedIds(
        prefs.sites,
        k.lookup,
      );
      expect(prefs.deckId, _deckCanon);
      expect(prefs.noteTypeId, _typeCanon);
      expect(written, <String>[
        'srs_mining_deck_id',
        'srs_mining_note_type_id',
      ]);
      expect(k.batches, hasLength(1), reason: '全部位置合成一批问一次');
    });

    test('并入之后再跑一次：重归一并落盘；已是规范 ID 的不重写', () async {
      final _Prefs prefs = _Prefs(deckId: _deckMember);
      final _FakeKernel k = _FakeKernel();
      // 并入之前：别名类里没有它，原样、不写。
      expect(await srsNormalizePersistedIds(prefs.sites, k.lookup), isEmpty);
      expect(prefs.deckId, _deckMember);
      expect(prefs.writes, isEmpty);
      // bindingChanged：别名类变了，同一个入口再跑一次。
      k.aliases[_deckMember] = _deckCanon;
      expect(await srsNormalizePersistedIds(prefs.sites, k.lookup), <String>[
        'srs_mining_deck_id',
      ]);
      expect(prefs.deckId, _deckCanon);
      // 第三次：已是规范 ID，不写。
      prefs.writes.clear();
      expect(await srsNormalizePersistedIds(prefs.sites, k.lookup), isEmpty);
      expect(prefs.writes, isEmpty);
    });

    test('归一不到（实体已不存在）保留原值、不写，空串（没选过）不问', () async {
      final _Prefs prefs = _Prefs(deckId: 'gone-deck');
      final _FakeKernel k = _FakeKernel(<String, String>{
        _typeMember: _typeCanon,
      });
      expect(await srsNormalizePersistedIds(prefs.sites, k.lookup), isEmpty);
      expect(prefs.deckId, 'gone-deck');
      expect(prefs.noteTypeId, '');
      expect(prefs.writes, isEmpty);
      expect(k.batches.single, <String>['gone-deck']);
    });

    test('问完内核时副本已换掉（shouldStop）：不落盘', () async {
      final _Prefs prefs = _Prefs(deckId: _deckMember);
      final _FakeKernel k = _FakeKernel(<String, String>{
        _deckMember: _deckCanon,
      });
      expect(
        await srsNormalizePersistedIds(
          prefs.sites,
          k.lookup,
          shouldStop: () => true,
        ),
        isEmpty,
      );
      expect(prefs.deckId, _deckMember);
    });

    test('改写时现读当前值：问内核期间用户改了设置，不拿旧值覆盖', () async {
      final _Prefs prefs = _Prefs(deckId: _deckMember);
      final _FakeKernel k = _FakeKernel(<String, String>{
        _deckMember: _deckCanon,
      });
      Future<List<String>> racing(List<String> ids) async {
        final List<String> out = await k.lookup(ids);
        prefs.deckId = 'user-picked-new';
        return out;
      }

      await srsNormalizePersistedIds(prefs.sites, racing);
      expect(prefs.deckId, 'user-picked-new');
    });
  });

  group('两层键位置（srs_mining_field_mappings）', () {
    test('笔记类型键与字段键都换成规范 ID', () async {
      final _Prefs prefs = _Prefs(
        mappings: <String, Map<String, String>>{
          _typeMember: <String, String>{_fieldMember: '{expression}'},
        },
      );
      final _FakeKernel k = _FakeKernel(<String, String>{
        _typeMember: _typeCanon,
        _fieldMember: _fieldCanon,
      });
      expect(await srsNormalizePersistedIds(prefs.sites, k.lookup), <String>[
        'srs_mining_field_mappings',
      ]);
      expect(prefs.mappings, <String, Map<String, String>>{
        _typeCanon: <String, String>{_fieldCanon: '{expression}'},
      });
    });

    test('并入后成员键撞到同一个规范键：规范键原有的优先，别的只补缺，不丢字段', () async {
      final _Prefs prefs = _Prefs(
        mappings: <String, Map<String, String>>{
          _typeMember: <String, String>{
            _fieldMember: 'member-template',
            'm-field-0002': '{reading}',
          },
          _typeCanon: <String, String>{_fieldCanon: 'canon-template'},
        },
      );
      final _FakeKernel k = _FakeKernel(<String, String>{
        _typeMember: _typeCanon,
        _fieldMember: _fieldCanon,
        'm-field-0002': 'c-field-0002',
      });
      await srsNormalizePersistedIds(prefs.sites, k.lookup);
      expect(prefs.mappings, <String, Map<String, String>>{
        _typeCanon: <String, String>{
          _fieldCanon: 'canon-template',
          'c-field-0002': '{reading}',
        },
      });
    });

    test('归一不到的笔记类型 / 字段保留原键，不清空映射', () async {
      final Map<String, Map<String, String>> before =
          <String, Map<String, String>>{
            'gone-type': <String, String>{'gone-field': ''},
          };
      final _Prefs prefs = _Prefs(mappings: before);
      final _FakeKernel k = _FakeKernel();
      expect(await srsNormalizePersistedIds(prefs.sites, k.lookup), isEmpty);
      expect(prefs.mappings, before);
      expect(prefs.writes, isEmpty);
    });
  });

  group('读时归一（制卡解析落点）', () {
    test('srsCanonicalizeMiningDestination 一次问齐全部 ID', () async {
      final _FakeKernel k = _FakeKernel(<String, String>{
        _deckMember: _deckCanon,
        _typeMember: _typeCanon,
        _fieldMember: _fieldCanon,
      });
      final SrsMiningDestination d = await srsCanonicalizeMiningDestination(
        const SrsMiningDestination(
          deckId: _deckMember,
          noteTypeId: _typeMember,
          fieldMappingsByType: <String, Map<String, String>>{
            _typeMember: <String, String>{_fieldMember: 'x'},
          },
        ),
        k.lookup,
      );
      expect(
        d,
        const SrsMiningDestination(
          deckId: _deckCanon,
          noteTypeId: _typeCanon,
          fieldMappingsByType: <String, Map<String, String>>{
            _typeCanon: <String, String>{_fieldCanon: 'x'},
          },
        ),
      );
      expect(k.batches, hasLength(1));
      expect(k.batches.single, <String>[
        _deckMember,
        _typeMember,
        _fieldMember,
      ]);
    });
  });

  group('统一入口的批量上限', () {
    test('超过内核上限按 kSrsCanonicalIdsBatchMax 分批，去重后逐项对应', () async {
      final List<String> ids = <String>[
        for (int i = 0; i < 2 * kSrsCanonicalIdsBatchMax + 1; i++) 'id-$i',
        'id-0',
        '',
      ];
      final _FakeKernel k = _FakeKernel(<String, String>{
        'id-5000': 'canon-5000',
      });
      final Map<String, String> m = await srsCanonicalIdMap(ids, k.lookup);
      expect(k.batches.map((List<String> b) => b.length), <int>[
        kSrsCanonicalIdsBatchMax,
        kSrsCanonicalIdsBatchMax,
        1,
      ]);
      expect(m, hasLength(2 * kSrsCanonicalIdsBatchMax + 1));
      expect(m['id-5000'], 'canon-5000');
      expect(m['id-8192'], 'id-8192');
      expect(m.containsKey(''), isFalse);
    });

    test('偏好位置的 ID 多过上限时同样分批', () async {
      final _Prefs prefs = _Prefs(
        mappings: <String, Map<String, String>>{
          for (int t = 0; t < 3; t++)
            'type-$t': <String, String>{
              for (int f = 0; f < 2000; f++) 'type-$t-field-$f': '',
            },
        },
      );
      final _FakeKernel k = _FakeKernel(<String, String>{
        'type-2-field-1999': 'canon-field',
      });
      expect(await srsNormalizePersistedIds(prefs.sites, k.lookup), <String>[
        'srs_mining_field_mappings',
      ]);
      expect(k.batches, hasLength(2));
      expect(prefs.mappings['type-2']!.containsKey('canon-field'), isTrue);
      expect(prefs.mappings['type-2'], hasLength(2000));
    });

    test('回包条数不对是内核契约被破坏：明确抛错，不猜着对齐', () async {
      Future<List<String>> short(List<String> ids) async =>
          ids.sublist(0, ids.length - 1);
      await expectLater(
        srsCanonicalIdMap(<String>['a', 'b'], short),
        throwsStateError,
      );
    });
  });
}
