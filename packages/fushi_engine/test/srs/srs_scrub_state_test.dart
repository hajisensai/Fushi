// 彻底清除的字节层收尾状态（内核读命令 `scrub_state`，gen4/scrub.rs；K2 合并条件②）：Dart 经 [SrsDbStore.scrubState]
// 读到 `{due, error}`；收尾出错时内核把原因记进 `srs_meta.gen4_scrub_error`，这里直接写那一行模拟（内核测试
// `purge_scrub_tests.rs` 覆盖真实的整理出错），核对原因原样带到 Dart。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:test/test.dart';

import 'support/srs_fake_engine.dart';
import 'support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000de';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('scrub_state reports nothing owed, then the recorded error', () async {
    final SrsStorage st = await openTestSrsStorage();
    final SrsDbStore s = await SrsDbStore.open(
      core: st.core,
      profileUid: kProfile,
      deviceId: 'dev',
      engine: const SrsFakeEngine(),
    );
    expect(await s.scrubState(), (due: false, error: null));
    st.core.debugExecRaw(
      "INSERT OR REPLACE INTO srs_meta (key, value) VALUES ('gen4_scrub_error', ?1)",
      <Object?>['database or disk is full'],
    );
    final SrsScrubState after = await s.scrubState();
    expect(after.error, 'database or disk is full');
    expect(after.due, isFalse);
  });
}
