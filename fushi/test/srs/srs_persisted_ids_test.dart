// 偏好里持久化的 SRS 实体 ID 归一（G9-6，lib/src/srs/srs_persisted_ids.dart）：真偏好仓库（内存主库）+ 假的
// `canonical_ids`。三条制卡偏好（键名冻结）读时归一、写回规范 ID；并入后再跑重归一；归一不到的原值保留；只读视图
// （别的配置的快照）不写。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/srs/srs_persisted_ids.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  final Map<String, String> aliases = <String, String>{};
  final List<int> batchSizes = <int>[];

  Future<List<String>> lookup(List<String> ids) async {
    batchSizes.add(ids.length);
    return <String>[for (final String id in ids) aliases[id] ?? id];
  }

  setUp(() async {
    aliases.clear();
    batchSizes.clear();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
  });
  tearDown(() => db.close());

  Future<String> stored(String key) async =>
      PrefCodec.decode<String>(await db.getPref(key) ?? '', '');

  test('带盐成员 ID 换成规范 ID 并写回三条偏好（键名不变）', () async {
    await prefs.setSrsMiningDeckId('member-deck');
    await prefs.setSrsMiningNoteTypeId('member-type');
    await prefs.setSrsMiningFieldMappings(<String, Map<String, String>>{
      'member-type': <String, String>{'member-field': '{expression}'},
    });
    aliases.addAll(<String, String>{
      'member-deck': 'canon-deck',
      'member-type': 'canon-type',
      'member-field': 'canon-field',
    });
    final List<String> written = await srsNormalizePersistedPreferenceIds(
      lookup: lookup,
      prefs: prefs,
    );
    expect(written, <String>[
      'srs_mining_deck_id',
      'srs_mining_note_type_id',
      'srs_mining_field_mappings',
    ]);
    expect(batchSizes, <int>[3], reason: '三条偏好的 ID 合成一批问');
    expect(prefs.srsMiningDeckId, 'canon-deck');
    expect(prefs.srsMiningNoteTypeId, 'canon-type');
    expect(prefs.srsMiningFieldMappings, <String, Map<String, String>>{
      'canon-type': <String, String>{'canon-field': '{expression}'},
    });
    // 落进了主库同一个键（存量偏好键名冻结）。
    expect(await stored('srs_mining_deck_id'), 'canon-deck');
    expect(await stored('srs_mining_note_type_id'), 'canon-type');
  });

  test('并入后（别名类变了）再跑一次：重归一并落盘', () async {
    await prefs.setSrsMiningDeckId('member-deck');
    expect(
      await srsNormalizePersistedPreferenceIds(lookup: lookup, prefs: prefs),
      isEmpty,
    );
    expect(prefs.srsMiningDeckId, 'member-deck');
    aliases['member-deck'] = 'joined-canon';
    expect(
      await srsNormalizePersistedPreferenceIds(lookup: lookup, prefs: prefs),
      <String>['srs_mining_deck_id'],
    );
    expect(await stored('srs_mining_deck_id'), 'joined-canon');
  });

  test('归一不到（实体已不存在）保留原值，「没选过」的空串不动', () async {
    await prefs.setSrsMiningDeckId('deleted-deck');
    await prefs.setSrsMiningFieldMappings(<String, Map<String, String>>{
      'deleted-type': <String, String>{'f': 'x'},
    });
    expect(
      await srsNormalizePersistedPreferenceIds(lookup: lookup, prefs: prefs),
      isEmpty,
    );
    expect(prefs.srsMiningDeckId, 'deleted-deck');
    expect(prefs.srsMiningNoteTypeId, '');
    expect(prefs.srsMiningFieldMappings, <String, Map<String, String>>{
      'deleted-type': <String, String>{'f': 'x'},
    });
  });

  test('只读视图（别的配置的快照）不写，也不问内核', () async {
    final PreferencesRepository view = PreferencesRepository.readOnlySnapshot(
      db,
      <String, String>{'srs_mining_deck_id': PrefCodec.encode('member-deck')},
    );
    aliases['member-deck'] = 'canon-deck';
    expect(
      await srsNormalizePersistedPreferenceIds(lookup: lookup, prefs: view),
      isEmpty,
    );
    expect(view.srsMiningDeckId, 'member-deck');
    expect(batchSizes, isEmpty);
  });
}
