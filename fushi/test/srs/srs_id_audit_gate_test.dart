// ID 审计门的自检（协议 4：native/fushi_fsrs/src/store/gen4/id_audit.rs，挂在新代每条连接上，原始通道 `G4Core::exec_raw`
// 跑完交回）：CI 的主应用单测用 `--features id_audit` 编的库并设 FUSHI_FSRS_ID_AUDIT=1（.github/actions/test-native-linux、
// main.yml / release.yml 的 unit-tests）。新代的 ID 列（`notes.id`、`cards.note_id` 等，声明成 BLOB / 无类型）存 16 字节
// Ref，没有协议 3 的 `srs_id(?)` 包装层：不变量是「拿 UUID **文本**去和 ID 列比较 / 写进 ID 列必报错」，而不是像发布
// 构建那样静默查不到行。这里走 Dart 侧测试原始通道（`SrsCore.debugSelectRaw` / `debugExecRaw`）故意绑文本，证明这道门是
// 通电的；按 ID 类型绑定（[srsIdType]，打包成 16 字节）、拿文本和按文本存 uid 的列（`collections.profile_uid`）比较照常
// 执行。只在审计构建里跑；库被换成不带审计的构建时 CI 上这里会红（CI 上 skip 条件看的是它设的环境变量，不看库）。本机 /
// 测试 worker 上加载到的是 prebuilt/<平台>/id_audit/ 那份（`FushiFsrs.isIdAuditVariant`，调试构建与测试宿主默认用它）时
// 同样跑：那个目录里被放进一份不带审计的库就红。

import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_srs/fushi_srs.dart' show FushiFsrs;

import 'srs_test_support.dart';
import '../../../packages/fushi_engine/test/srs/support/srs_raw_sql.dart';

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

  test('拿 UUID 文本和 ID 列比较：审计构建里直接报错', () async {
    final SrsStorage st = await openSrsTestStorage();
    await expectLater(
      st.core
          .customSelect(
            'SELECT COUNT(*) AS c FROM notes WHERE id = ?',
            variables: <Variable<Object>>[Variable<String>(kUuid)],
          )
          .getSingle(),
      _idAuditError,
    );
  }, skip: skip);

  test('同一条语句里一个按 ID 类型绑、另一个绑文本：仍然报错（不被别的参数担保）', () async {
    final SrsStorage st = await openSrsTestStorage();
    await expectLater(
      st.core
          .customSelect(
            'SELECT COUNT(*) AS c FROM cards WHERE id = ? AND note_id = ?',
            variables: <Variable<Object>>[
              Variable<String>(kUuid, srsIdType),
              Variable<String>(kUuid),
            ],
          )
          .getSingle(),
      _idAuditError,
    );
  }, skip: skip);

  test('原始写把 UUID 文本写进 ID 列：审计构建里直接报错', () async {
    final SrsStorage st = await openSrsTestStorage();
    await expectLater(
      st.core.customStatement(
        'INSERT INTO cache_log (col, gen, note) VALUES (1, 1, ?)',
        <Object?>[kUuid],
      ),
      _idAuditError,
    );
  }, skip: skip);

  test('写对了（ID 类型绑定 / 文本列绑文本）照常执行', () async {
    final SrsStorage st = await openSrsTestStorage();
    final SrsRawRow typed = await st.core
        .customSelect(
          'SELECT COUNT(*) AS c FROM cards WHERE id = ? AND note_id = ?',
          variables: <Variable<Object>>[
            Variable<String>(kUuid, srsIdType),
            Variable<String>(kUuid, srsIdType),
          ],
        )
        .getSingle();
    expect(typed.read<int>('c'), 0);
    final SrsRawRow text = await st.core
        .customSelect(
          'SELECT COUNT(*) AS c FROM collections WHERE profile_uid = ?',
          variables: <Variable<Object>>[Variable<String>(kUuid)],
        )
        .getSingle();
    expect(text.read<int>('c'), 0);
  }, skip: skip);
}
