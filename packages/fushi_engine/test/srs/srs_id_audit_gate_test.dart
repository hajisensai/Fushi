// ID 审计门的自检（新代：native/fushi_fsrs/src/store/gen4/id_audit.rs）：CI 的包测试用 `--features id_audit` 编的库并设
// FUSHI_FSRS_ID_AUDIT=1（.github/workflows/main.yml「Build fushi_fsrs (Linux x64, id_audit)」）。这里走的是 Dart 侧
// 测试原始通道（`SrsCore.debugExecRaw` / `debugSelectRaw`，内核 G4Core `exec_raw`，与分发器命令同受审计）——故意拿 UUID
// 文本去比新代的 ID 列（存 16 字节 Ref）、或把 UUID 文本写进 ID 列，证明这道门是通电的：直接报错，而不是像发布构建那样静默
// 查不到行 / 写进另一个值。只在审计构建里跑；库被换成不带审计的构建时 CI 上这里会红（CI 上 skip 条件看的是它设的环境变量，
// 不看库）。本机 / 测试 worker 上加载到的是 prebuilt/<平台>/id_audit/ 那份（`FushiFsrs.isIdAuditVariant`，调试构建与测试
// 宿主默认用它）时同样跑：那个目录里被放进一份不带审计的库就红。
//
// 新代没有协议 3 的 `srs_id(?)` 这一层：ID 参数一律按 Ref 绑（测试里是 [srsIdType]，规范 UUID 打包成 16 字节），按文本存
// 的列（`collections.profile_uid` 等）照常绑文本。
import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart' show FushiFsrs;
import 'package:test/test.dart';

import 'support/srs_test_storage.dart';
import 'support/srs_raw_sql.dart';

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

  test('拿 UUID 文本去比 ID 列：审计构建里直接报错', () async {
    final SrsStorage st = await openTestSrsStorage();
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

  test('同一条语句里一个按 Ref 绑、另一个漏成文本：仍然报错（不被别的参数担保）', () async {
    final SrsStorage st = await openTestSrsStorage();
    await expectLater(
      st.core
          .customSelect(
            'SELECT COUNT(*) AS c FROM cards WHERE note_id = ? AND id = ?',
            variables: <Variable<Object>>[
              Variable<String>(kUuid, srsIdType),
              Variable<String>(kUuid),
            ],
          )
          .getSingle(),
      _idAuditError,
    );
  }, skip: skip);

  test('原始通道把 UUID 文本写进 ID 列：写完扫存储报错', () async {
    final SrsStorage st = await openTestSrsStorage();
    await expectLater(
      st.core.customStatement(
        'INSERT INTO cache_log (col, gen, note) VALUES (?, ?, ?)',
        <Object?>[987654, 1, kUuid],
      ),
      _idAuditError,
    );
  }, skip: skip);

  test('写对了（ID 按 Ref 绑、文本列绑文本）照常执行', () async {
    final SrsStorage st = await openTestSrsStorage();
    final SrsRawRow typed = await st.core
        .customSelect(
          'SELECT COUNT(*) AS c FROM cards WHERE note_id = ? AND id = ?',
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
    await st.core.customStatement(
      'INSERT INTO cache_log (col, gen, note) VALUES (?, ?, ?)',
      <Object?>[987654, 1, packSrsTestId(kUuid)],
    );
    final SrsRawRow stored = await st.core
        .customSelect(
          'SELECT COUNT(*) AS c FROM cache_log WHERE col = ? AND note = ?',
          variables: <Variable<Object>>[
            const Variable<int>(987654),
            Variable<String>(kUuid, srsIdType),
          ],
        )
        .getSingle();
    expect(stored.read<int>('c'), 1);
  }, skip: skip);
}
