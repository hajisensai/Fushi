import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';

import 'srs_test_support.dart' show openSrsTestStorage;

const String _kProfile = '01928c3e-0000-7000-8000-0000000000c7';

/// H1：牌组列表的冲突角标按 store 的内容指纹复用上次结果——[srsRevisionProvider] 递增（评分、
/// 收起 / 展开等）但内容没变时不重扫库；内容变了（标志 / 笔记修改记录落库）才重算。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('冲突角标：修订信号递增但内容指纹没变 → 复用；内容变了 → 重算', () async {
    final SrsStorage srs = await openSrsTestStorage();
    final SrsDbStore store = await SrsDbStore.open(
      db: srs.db,
      core: srs.core,
      profileUid: _kProfile,
      deviceId: 'memo-test',
    );
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        srsStoreProvider.overrideWith((Ref ref) async => store),
      ],
    );
    addTearDown(container.dispose);
    final ProviderSubscription<AsyncValue<int>> sub = container.listen(
      srsConflictCountProvider,
      (_, _) {},
    );
    addTearDown(sub.close);

    final String note = await store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(_kProfile, 'Expression'): '猫',
      },
    );
    container.read(srsRevisionProvider.notifier).state++;
    expect(await container.read(srsConflictCountProvider.future), 0);

    // 绕过事件直接在缓存里造一条「待裁决」：不推进内容指纹。信号递增后仍是上次的结果，
    // 说明这次没有重扫库。
    final String fp = store.contentFingerprint;
    await srs.db.customStatement(
      'UPDATE srs_notes_cache SET pending_decision = 1 WHERE id = srs_id(?)',
      <Object>[note],
    );
    container.read(srsRevisionProvider.notifier).state++;
    expect(store.contentFingerprint, fp);
    expect(await container.read(srsConflictCountProvider.future), 0);

    // 一条牌组收起（界面状态）同样不推进指纹。
    await store.setDeckCollapsed(store.defaultDeckId, true);
    container.read(srsRevisionProvider.notifier).state++;
    expect(store.contentFingerprint, fp);
    expect(await container.read(srsConflictCountProvider.future), 0);

    // 内容修改记录落库：指纹变，重算（读到缓存里那条待裁决）。
    await store.setFlag((await store.cardsOfNote(note)).single.id, 2);
    container.read(srsRevisionProvider.notifier).state++;
    expect(store.contentFingerprint, isNot(fp));
    expect(await container.read(srsConflictCountProvider.future), 1);
  });
}
