// ID 审计门的自检（native/fushi_fsrs/src/store/ids.rs `audit`）：CI 的主应用单测用 `--features id_audit` 编的库并设
// FUSHI_FSRS_ID_AUDIT=1（.github/actions/test-native-linux、main.yml / release.yml 的 unit-tests）。这里走的是 Dart 侧
// 真实的那条路——Drift 自定义语句经 `ffsrs_store_exec` 进内核——故意漏写 `srs_id(?)`，证明这道门是通电的：漏写
// 直接报错，而不是像发布构建那样静默查不到行。只在审计构建里跑；库被换成不带审计的构建时 CI 上这里会红
// （CI 上 skip 条件看的是它设的环境变量，不看库）。本机 / 测试 worker 上加载到的是 prebuilt/<平台>/id_audit/ 那份
// （`FushiFsrs.isIdAuditVariant`，调试构建与测试宿主默认用它）时同样跑：那个目录里被放进一份不带审计的库就红。
import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:fushi_core/fushi_core.dart' show srsIdType;
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_srs/fushi_srs.dart' show FushiFsrs;

import 'srs_test_support.dart';

const String kUuid = '0193a1b2-0005-7000-8000-00000000fffe';

Matcher get _idAuditError =>
    throwsA(predicate((Object e) => '$e'.contains('id audit'), 'id audit'));

void main() {
  final Object skip =
      Platform.environment['FUSHI_FSRS_ID_AUDIT'] == '1' ||
          (FushiFsrs.instance?.isIdAuditVariant ?? false)
      ? false
      : 'needs a fushi_fsrs built with --features id_audit '
            '(FUSHI_FSRS_ID_AUDIT=1, or the prebuilt id_audit variant)';

  test('Drift 语句漏写 srs_id(?)：审计构建里直接报错', () async {
    final SrsStorage st = await openSrsTestStorage();
    await expectLater(
      st.db
          .customSelect(
            'SELECT COUNT(*) AS c FROM srs_review_logs WHERE id = ?',
            variables: <Variable<Object>>[Variable<String>(kUuid)],
          )
          .getSingle(),
      _idAuditError,
    );
  }, skip: skip);

  test('同一条语句里套了一个、漏了另一个：仍然报错（不被别的参数担保）', () async {
    final SrsStorage st = await openSrsTestStorage();
    await expectLater(
      st.db
          .customSelect(
            'SELECT COUNT(*) AS c FROM srs_review_logs '
            'WHERE profile_uid = srs_id(?) AND id = ?',
            variables: <Variable<Object>>[
              Variable<String>(kUuid),
              Variable<String>(kUuid),
            ],
          )
          .getSingle(),
      _idAuditError,
    );
  }, skip: skip);

  test('写对了（srs_id(?) / ID 类型绑定）照常执行', () async {
    final SrsStorage st = await openSrsTestStorage();
    final QueryRow wrapped = await st.db
        .customSelect(
          'SELECT COUNT(*) AS c FROM srs_review_logs '
          'WHERE profile_uid = srs_id(?) AND id = srs_id(?)',
          variables: <Variable<Object>>[
            Variable<String>(kUuid),
            Variable<String>(kUuid),
          ],
        )
        .getSingle();
    expect(wrapped.read<int>('c'), 0);
    final QueryRow typed = await st.db
        .customSelect(
          'SELECT COUNT(*) AS c FROM srs_review_logs WHERE id = ?',
          variables: <Variable<Object>>[Variable<String>(kUuid, srsIdType)],
        )
        .getSingle();
    expect(typed.read<int>('c'), 0);
  }, skip: skip);
}
