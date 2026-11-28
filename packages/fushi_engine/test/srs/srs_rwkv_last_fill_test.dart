// BUG-5547（反馈 gPPVTfHm1b「srs 打不开，进入复习页面后一直在加载」）：缓存推导口径 6 → 7 只多了 `rwkv_last`，
// 以前开库的 `cache_config_set` 为此在一个写事务里整层重建，手机上要几分钟，切后台被系统回收就整笔回滚、下次从头
// 再来。现在按 6 物化的库开库时只记下修订号与回填游标（回包 `rwkvLastFill`），[SrsDbStore] 在后台一批一笔地填；
// 填完之前 RWKV 末条读对没填到的卡逐卡重放，结果不变。
@TestOn('vm')
library;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_projections.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';
import 'support/srs_test_storage.dart';

const String _uid = '01928c3e-0000-7000-8000-000000005532';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  int t = DateTime.utc(2026, 11, 26, 3).millisecondsSinceEpoch;

  Future<SrsDbStore> open(SrsStorage storage) => openTestStore(
    profileUid: _uid,
    deviceId: 'a',
    now: () => t += 1000,
    storage: storage,
  );

  List<String> shape(List<SrsRwkvLastRating?> rows) => <String>[
    for (final SrsRwkvLastRating? r in rows)
      r == null ? '-' : '${r.at}/${r.rating}/${r.reviewType}',
  ];

  /// 读一个 `derive_cfg` 项（内核没有读它的命令）。走内核自己连接上的测试原始通道
  /// （[SrsCore.debugSelectRaw]），不另开 `package:sqlite3` 连接：同进程两份 SQLite 在 POSIX 上不共享
  /// fcntl 锁记账，另一份 `close()` 会连带放掉内核的锁，Linux CI 上内核看不到外部改动（PR #4520 CI 红）。
  String? cfg(SrsDbStore s, String key) {
    final List<Map<String, Object?>> r = s.core.debugSelectRaw(
      'SELECT value FROM derive_cfg WHERE key = ?',
      <Object?>[key],
    );
    return r.isEmpty ? null : r.first['value'] as String?;
  }

  test('按口径 6 物化的库：开库不整层重建，后台分批回填 rwkv_last，末条读前后一致', () async {
    final SrsStorage storage = await openTestSrsStorage();
    final SrsDbStore s = await open(storage);
    final List<String> cards = <String>[];
    for (int i = 0; i < 70; i++) {
      final String note = await s.createNote(
        noteTypeId: s.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(_uid, 'Expression'): '語$i',
        },
      );
      for (final c in await s.cardsOfNote(note)) {
        cards.add(c.id);
        if (i.isEven) await s.answer(c.id, 1 + i % 4);
      }
    }
    final List<String> want = shape(await s.rwkvLastRatings(cards));
    expect(want.where((String r) => r != '-'), isNotEmpty, reason: '要有保留评分');
    expect(s.debugRwkvLastFill, isNull, reason: '新库是按当前口径物化的');
    expect(cfg(s, 'rwkvLastFill'), isNull);

    // 退回口径 6 的样子（升级前的库）：表是空的、修订号记 6。
    s.core.debugExecRaw('DELETE FROM rwkv_last');
    s.core.debugExecRaw(
      "UPDATE derive_cfg SET value = '6' WHERE key = 'cacheRules'",
    );

    final SrsDbStore reopened = await open(storage);
    expect(cfg(reopened, 'cacheRules'), '7', reason: '就地记成当前口径，不整层重建');
    final Future<void>? fill = reopened.debugRwkvLastFill;
    expect(fill, isNotNull, reason: '开库后在后台回填');
    // 回填进行中读到的与填满后相同（没填到的卡内核逐卡重放）。
    expect(shape(await reopened.rwkvLastRatings(cards)), want);
    await fill;
    expect(reopened.debugRwkvLastFill, isNull);
    expect(cfg(reopened, 'rwkvLastFill'), isNull, reason: '填完删游标');
    expect(shape(await reopened.rwkvLastRatings(cards)), want);

    // 再开一次：表是完整的，不再回填。
    final SrsDbStore again = await open(storage);
    expect(again.debugRwkvLastFill, isNull);
    expect(shape(await again.rwkvLastRatings(cards)), want);
  });
}
