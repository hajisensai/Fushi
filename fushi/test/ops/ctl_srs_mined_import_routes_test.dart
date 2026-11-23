import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';

import 'package:fushi/src/ops/ctl_srs_mined_import_routes.dart';
import 'package:fushi/src/ops/ctl_srs_routes.dart';

import '../srs/srs_test_support.dart';

Matcher _status(int status) => throwsA(
  isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', status),
);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('要 confirm；导入后重复导入全部跳过；写后通知界面；模块关 422', () async {
    final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore();
    addTearDown(db.close);
    await db
        .into(db.minedSentences)
        .insert(
          MinedSentencesCompanion.insert(
            expression: const Value<String>('雪'),
            reading: const Value<String>('ゆき'),
            sentence: const Value<String>('雪が降る。'),
            source: 'book',
            dateKey: '2026-09-01',
            createdAt: 1000,
          ),
        );
    int changed = 0;
    bool enabled = true;
    final CtlRoute route = buildSrsMinedImportCtlRoutesFor(
      srs: SrsCtlDeps(
        store: () async => store,
        moduleEnabled: () => enabled,
        changed: () => changed++,
      ),
      database: () => db,
    ).single;
    Future<Object?> call(Map<String, Object?> body) => route.handler(
      CtlCall(
        method: 'POST',
        path: kSrsMinedImportCtlPath,
        params: const <String, String>{},
        body: body,
      ),
    );

    expect(() => call(const <String, Object?>{}), _status(400));
    expect(changed, 0);
    expect(
      await call(const <String, Object?>{'confirm': true}),
      <String, Object?>{'imported': 1, 'skipped': 0},
    );
    expect(changed, 1);
    expect(
      await call(const <String, Object?>{'confirm': true}),
      <String, Object?>{'imported': 0, 'skipped': 1},
    );
    enabled = false;
    expect(() => call(const <String, Object?>{'confirm': true}), _status(422));
  });
}
