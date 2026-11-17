// 牌组页「每日上限单位改缺省」提醒的计数（srsLimitUnitLegacyCountProvider）按库的指纹复用上次结果：评分只落今天的日志，
// 不必重扫；但它取决于改缺省之前的复习，一批只含旧复习日志的同步并进来时必须重算（内容指纹在这种合并下不变）。
//
// 两份内存库模拟两台设备（同一 profile、不同设备号），经 `.fushisrs` 操作包（sync2ExportOps / sync2ImportOps）合并。
// 新代按文件导出 / 导入（G11-3）；第一次导入是另一个集合，用户确认后并入（[_ship]）。
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';

import 'srs_test_support.dart';

/// 把 [from] 的操作包导出成文件、确认后并进 [to]（新代的 `.fushisrs` 按文件走，G11-3）。
Future<void> _ship(SrsDbStore from, SrsDbStore to) async {
  final Directory tmp = Directory.systemTemp.createTempSync('srs_lu_');
  try {
    final String path = '${tmp.path}${Platform.pathSeparator}ops.bin';
    await from.sync2ExportOps(path);
    await to.sync2ImportOps(path: path, confirmed: true);
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

Future<int> _count(ProviderContainer container) async {
  container.read(srsRevisionProvider.notifier).state++;
  return container.read(srsLimitUnitLegacyCountProvider.future);
}

void main() {
  test('只同步进来改缺省之前的复习日志：提醒计数重算，不沿用合并前的结果；本机评分不重扫', () async {
    // 测试时钟（2026-10-01）在改缺省（kSrsLimitUnitDefaultChangedAtMs）之前。
    final SrsTestClock clock = SrsTestClock();
    final (FushiDatabase dbA, SrsDbStore a) = await openSrsTestStore(
      deviceId: 'dev-a',
      clock: clock,
    );
    addTearDown(dbA.close);
    final (FushiDatabase dbB, SrsDbStore b) = await openSrsTestStore(
      deviceId: 'dev-b',
      clock: clock,
    );
    addTearDown(dbB.close);

    final String note = await a.createNote(
      noteTypeId: a.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(a.profileUid, 'Expression'): '聞く',
      },
    );
    final String card = (await a.cardsOfNote(note)).single.id;
    // 先把笔记 / 卡片同步过去：B 有这张卡，但还没有任何复习。
    await _ship(a, b);

    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        srsStoreProvider.overrideWith((Ref ref) async => b),
      ],
    );
    addTearDown(container.dispose);
    expect(await _count(container), 0);

    // A 在改缺省之前评了分；这一批只多出这条复习日志。
    clock.advance(const Duration(minutes: 1));
    await a.answer(card, 3);
    final String contentBefore = b.contentFingerprint;
    await _ship(a, b);
    expect(
      b.contentFingerprint,
      contentBefore,
      reason: '前提：只并入复习日志不推进内容指纹（推进了就测不到这条路径）',
    );
    expect(await b.limitUnitLegacyDecks(), <String>{b.defaultDeckId});
    expect(await _count(container), 1);

    // 本机评分只落日志：结果不变。
    final Future<int> first = container.read(
      srsLimitUnitLegacyCountProvider.future,
    );
    clock.advance(const Duration(minutes: 1));
    await b.answer(card, 3);
    container.read(srsRevisionProvider.notifier).state++;
    final Future<int> second = container.read(
      srsLimitUnitLegacyCountProvider.future,
    );
    expect(await second, 1);
    expect(await first, 1);
  });
}
