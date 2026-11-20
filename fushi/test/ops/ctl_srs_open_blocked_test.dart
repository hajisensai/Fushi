// R0（SRS 协议 4 换代）复核：控制通道碰到「库处在代际 / 身份状态」（没升级的旧库、正在升级、上次升级失败……）
// 回可机读的 409 + 稳定错误码，不再是 500 internal（R0 实测：v3.3.0 根上 `srs/decks|cards|stats` 都是 500
// `SrsStoreNotMigrated(needsMigration)`，调用方只能认文本）。真错误照旧原样抛（ctl 回 500）。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ops/ctl_srs_routes.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/srs/srs_db_store.dart'
    show SrsDbStore, SrsProfileIdentityPending;
import 'package:fushi_engine/srs/srs_storage.dart'
    show SrsLegacyMainDatabasePending;
import 'package:fushi_srs/fushi_srs.dart'
    show
        SrsGenState,
        SrsStoreLegacyUnmigrated,
        SrsStoreMigrating,
        SrsStoreNotMigrated;

SrsCtlDeps _deps(Object error) => SrsCtlDeps(
  store: () async => throw error,
  moduleEnabled: () => true,
  changed: () {},
);

Matcher _blocked(String code) => throwsA(
  isA<CtlFailure>()
      .having((CtlFailure f) => f.status, 'status', 409)
      .having((CtlFailure f) => f.code, 'code', code),
);

void main() {
  final List<(Object, String)> cases = <(Object, String)>[
    (
      const SrsStoreNotMigrated('x', SrsGenState.needsMigration),
      'srs_needs_migration',
    ),
    (
      const SrsStoreNotMigrated('x', SrsGenState.migrationFailed),
      'srs_migration_failed',
    ),
    (
      const SrsStoreNotMigrated('x', SrsGenState.migratingElsewhere),
      'srs_upgrading',
    ),
    (const SrsStoreMigrating('x'), 'srs_upgrading'),
    (
      const SrsStoreNotMigrated('x', SrsGenState.sealedOldOnly),
      'srs_sealed_old_only',
    ),
    (const SrsStoreLegacyUnmigrated('x'), 'srs_legacy_unmigrated'),
    (const SrsStoreNotMigrated('x', SrsGenState.ready), 'srs_open_blocked'),
    (const SrsLegacyMainDatabasePending(), 'srs_legacy_main_db'),
    (const SrsProfileIdentityPending('p1'), 'srs_profile_identity_pending'),
  ];

  for (final (Object error, String code) in cases) {
    test('取库报 ${error.runtimeType}（$code）→ 409 $code', () {
      expect(requireSrsCtlStore(_deps(error)), _blocked(code));
    });
  }

  test('牌组 / 统计路由在没升级的旧库上回 409 srs_needs_migration，不是 500', () async {
    final List<CtlRoute> routes = buildSrsCtlRoutesFor(
      _deps(const SrsStoreNotMigrated('x', SrsGenState.needsMigration)),
    );
    for (final String path in <String>[
      '$kSrsCtlRoot/decks',
      '$kSrsCtlRoot/stats',
    ]) {
      final CtlRoute route = routes.firstWhere(
        (CtlRoute r) => r.method == 'GET' && r.match(path) != null,
      );
      await expectLater(
        route.handler(CtlCall(method: 'GET', path: path)),
        _blocked('srs_needs_migration'),
        reason: path,
      );
    }
  });

  test('真错误不归进代际码：原样抛（ctl 回 500 internal）', () {
    expect(
      requireSrsCtlStore(_deps(StateError('disk on fire'))),
      throwsA(isA<StateError>()),
    );
    expect(srsCtlOpenBlockedFailure(StateError('x')), isNull);
  });

  test('模块关 / 库没就绪仍是 422', () {
    expect(
      requireSrsCtlStore(
        SrsCtlDeps(
          store: () async => null,
          moduleEnabled: () => true,
          changed: () {},
        ),
      ),
      throwsA(
        isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 422),
      ),
    );
    expect(
      requireSrsCtlStore(
        SrsCtlDeps(
          store: () async => null,
          moduleEnabled: () => false,
          changed: () {},
        ),
      ),
      throwsA(
        isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 422),
      ),
    );
  });
}
