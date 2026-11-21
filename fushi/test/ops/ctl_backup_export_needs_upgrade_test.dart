import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart' show CtlFailure;
import 'package:fushi/src/ops/ctl_data_routes.dart'
    show dropBackupCategoriesNeedingUpgrade;
import 'package:fushi/src/sync/backup_service.dart';

/// ctl `backup export` 对「需先升级」类别的处理（G7-5b 复核）：本机复习库还没迁移成新代时，缺省 / all 跳过复习、
/// 其余照常并在回包里写明；显式点名 srs 才明确报错。与设置页导出框同一口径。
void main() {
  const BackupContentSummary blocked = BackupContentSummary(
    present: <BackupCategory>{BackupCategory.srs},
    needsUpgrade: <BackupCategory>{BackupCategory.srs},
  );
  const BackupContentSummary ready = BackupContentSummary(
    counts: <BackupCategory, int>{BackupCategory.srs: 2},
    present: <BackupCategory>{BackupCategory.srs},
  );

  Future<BackupContentSummary> Function() summaryOf(
    BackupContentSummary s,
    List<int> calls,
  ) => () async {
    calls.add(1);
    return s;
  };

  test('all（categories 为 null）：去掉复习，其余全部照常，记进 skipped', () async {
    final ({Set<BackupCategory>? categories, Set<BackupCategory> skipped}) r =
        await dropBackupCategoriesNeedingUpgrade(
          categories: null,
          named: false,
          summarize: summaryOf(blocked, <int>[]),
        );
    expect(
      r.categories,
      BackupCategory.values.toSet()..remove(BackupCategory.srs),
    );
    expect(r.skipped, <BackupCategory>{BackupCategory.srs});
  });

  test('缺省类别：去掉复习，记进 skipped', () async {
    final Set<BackupCategory> defaults = <BackupCategory>{
      BackupCategory.games,
      BackupCategory.srs,
    };
    final ({Set<BackupCategory>? categories, Set<BackupCategory> skipped}) r =
        await dropBackupCategoriesNeedingUpgrade(
          categories: defaults,
          named: false,
          summarize: summaryOf(blocked, <int>[]),
        );
    expect(r.categories, <BackupCategory>{BackupCategory.games});
    expect(r.skipped, <BackupCategory>{BackupCategory.srs});
  });

  test('显式点名 srs：明确拒绝（422），不出半份包', () async {
    await expectLater(
      dropBackupCategoriesNeedingUpgrade(
        categories: <BackupCategory>{BackupCategory.srs, BackupCategory.games},
        named: true,
        summarize: summaryOf(blocked, <int>[]),
      ),
      throwsA(
        isA<CtlFailure>()
            .having((CtlFailure f) => f.status, 'status', 422)
            .having((CtlFailure f) => f.message, 'message', contains('srs')),
      ),
    );
  });

  test('复习库已是新代：原样不动；没要复习时不为它整机数一遍', () async {
    final List<int> calls = <int>[];
    final ({Set<BackupCategory>? categories, Set<BackupCategory> skipped}) r =
        await dropBackupCategoriesNeedingUpgrade(
          categories: null,
          named: false,
          summarize: summaryOf(ready, calls),
        );
    expect(r.categories, isNull);
    expect(r.skipped, isEmpty);
    expect(calls, hasLength(1));

    final ({Set<BackupCategory>? categories, Set<BackupCategory> skipped})
    noSrs = await dropBackupCategoriesNeedingUpgrade(
      categories: <BackupCategory>{BackupCategory.games},
      named: true,
      summarize: summaryOf(blocked, calls),
    );
    expect(noSrs.categories, <BackupCategory>{BackupCategory.games});
    expect(calls, hasLength(1), reason: 'srs not requested: no summary');
  });
}
