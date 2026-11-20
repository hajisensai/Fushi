// R0（SRS 协议 4 换代）实测：旧版本数据根上，复习页的牌组列表必须带着「要迁移」的错误落定（页面据此换成迁移页），
// 不能一直停在加载中（转圈、看不到「开始升级」）。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsGenState, SrsStoreNotMigrated;

import '../helpers/test_platform_services.dart';
import 'srs_test_support.dart';

class _AppModel extends AppModel {
  _AppModel(this._db) : super(testPlatformServices());

  final FushiDatabase _db;

  @override
  FushiDatabase get database => _db;
}

void main() {
  late FushiDatabase db;
  late Directory support;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    support = Directory.systemTemp.createTempSync('fushi_srs_not_migrated_');
    addTearDown(() async {
      await db.close();
      try {
        support.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows 句柄滞后：临时目录留给系统清理。
      }
    });
  });

  Future<void> expectSettlesWithError({
    required bool storeFirst,
    required bool bumpRevision,
  }) async {
    final ProviderContainer c = ProviderContainer(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => _AppModel(db)),
        srsModuleEnabledProvider.overrideWithValue(true),
        srsStorageProvider.overrideWith(
          (Ref ref) async => throw const SrsStoreNotMigrated(
            'gen4 store: not migrated yet',
            SrsGenState.needsMigration,
          ),
        ),
        srsEngineProvider.overrideWithValue(const SrsTestEngine()),
        srsSupportRootProvider.overrideWithValue(() async => support),
      ],
    );
    addTearDown(c.dispose);
    if (storeFirst) {
      // 别处（同步 / 备份 / 首页卡片）先读过库、已经落成错误，复习页之后才订阅牌组列表。
      c.listen<AsyncValue<SrsDbStore?>>(
        srsStoreProvider,
        (AsyncValue<SrsDbStore?>? previous, AsyncValue<SrsDbStore?> next) {},
      );
      await c
          .read(srsStoreProvider.future)
          .then<Object?>((SrsDbStore? v) => v)
          .catchError((Object e) => e);
      expect(c.read(srsStoreProvider).hasError, isTrue);
    }
    c.listen<AsyncValue<SrsDeckListData?>>(
      srsDeckListProvider,
      (
        AsyncValue<SrsDeckListData?>? previous,
        AsyncValue<SrsDeckListData?> next,
      ) {},
    );
    if (bumpRevision) c.read(srsRevisionProvider.notifier).state++;
    final Object? outcome = await c
        .read(srsDeckListProvider.future)
        .then<Object?>((SrsDeckListData? v) => v)
        .catchError((Object e) => e)
        .timeout(const Duration(seconds: 10), onTimeout: () => 'timeout');
    expect(outcome, isA<SrsStoreNotMigrated>());
    final AsyncValue<SrsDeckListData?> state = c.read(srsDeckListProvider);
    expect(state.hasError, isTrue);
    expect(state.isLoading, isFalse);
  }

  for (final bool storeFirst in <bool>[false, true]) {
    for (final bool bump in <bool>[false, true]) {
      test(
        '库要迁移时牌组列表以 SrsStoreNotMigrated 落定，不一直加载'
        '（先读库=$storeFirst，修订号跳=$bump）',
        () =>
            expectSettlesWithError(storeFirst: storeFirst, bumpRevision: bump),
      );
    }
  }
}
