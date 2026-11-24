import 'package:fushi_engine/profile/combo/combo_migration.dart';
import 'package:fushi_engine/profile/combo/combo_rows.dart';
import 'package:fushi_engine/profile/combo/combo_srs_library.dart';
import 'package:fushi_engine/profile/combo/settings_tree.dart';
import 'package:test/test.dart';

/// 复习库解析（组合阶段 4，设计 §4.1）。id 1 = 默认组合，2 / 3 / 4 = 普通组合。
void main() {
  const Map<int, String> uids = <int, String>{
    1: 'u-default',
    2: 'u-video',
    3: 'u-manga',
    4: 'u-ja',
  };

  ComboSrsLibraries build({
    String? sharedUid = 'u-default',
    Map<int, String> libraryValues = const <int, String>{},
    Map<int, String>? roles,
  }) => ComboSrsLibraries.fromRows(
    uidById: uids,
    roles:
        roles ??
        <int, String>{
          1: ComboRole.defaults.wire,
          2: ComboRole.named.wire,
          3: ComboRole.named.wire,
          4: ComboRole.named.wire,
        },
    sharedUids: <int, String>{if (sharedUid != null) 1: sharedUid},
    librarySplits: <int, String>{
      for (final int id in libraryValues.keys) id: '1',
    },
    libraryValues: libraryValues,
  );

  test('都没拆 srs.library：默认组合、各绑定层都落共享库（同一份 .apkg 不再分到两份库）', () {
    final ComboSrsLibraries l = build();
    const ComboSrsLibrary shared = ComboSrsLibrary(
      uid: 'u-default',
      shared: true,
      ownerProfileId: 1,
    );
    expect(l.resolve(baseProfileId: 1), shared);
    expect(l.resolve(baseProfileId: 2), shared, reason: '激活的是普通组合也落共享库');
    expect(
      l.resolve(
        baseProfileId: 1,
        layers: <ComboScope, int>{
          ComboScope.work: 2,
          ComboScope.mediaType: 3,
          ComboScope.language: 4,
        },
      ),
      shared,
    );
    expect(l.libraries, <ComboSrsLibrary>[shared]);
  });

  test('共享库可以指向非默认组合的 uid（§4.2：只有它有复习数据）', () {
    final ComboSrsLibraries l = build(sharedUid: 'u-manga');
    expect(l.resolve(baseProfileId: 1)!.uid, 'u-manga');
    expect(l.sharedHostId, 3);
    expect(l.hostsSharedLibrary(3), isTrue);
    expect(l.hostsSharedLibrary(1), isFalse);
  });

  test('拆成 own：那一层用自己的 uid；最高的拆分层说了算，设回 shared 盖过更低层', () {
    final ComboSrsLibraries l = build(
      libraryValues: <int, String>{
        3: kComboSrsLibraryOwnValue,
        2: 'shared',
        4: kComboSrsLibraryOwnValue,
      },
    );
    expect(
      l.resolve(
        baseProfileId: 1,
        layers: <ComboScope, int>{ComboScope.mediaType: 3},
      ),
      const ComboSrsLibrary(uid: 'u-manga', shared: false, ownerProfileId: 3),
    );
    expect(
      l
          .resolve(
            baseProfileId: 1,
            layers: <ComboScope, int>{
              ComboScope.mediaType: 3,
              ComboScope.language: 4,
            },
          )!
          .uid,
      'u-manga',
      reason: '媒体类型高于语言',
    );
    expect(
      l
          .resolve(
            baseProfileId: 1,
            layers: <ComboScope, int>{
              ComboScope.work: 2,
              ComboScope.mediaType: 3,
            },
          )!
          .shared,
      isTrue,
      reason: '作品层明确设回共享',
    );
    expect(l.resolve(baseProfileId: 4)!.uid, 'u-ja', reason: '激活配置拆了独立库');
    expect(
      <String>[for (final ComboSrsLibrary x in l.libraries) x.uid],
      <String>['u-default', 'u-manga', 'u-ja'],
    );
  });

  test('待定（没有默认组合 / 没写共享库）：取激活配置自己的 uid，不列可切换的库', () {
    final ComboSrsLibraries pending = build(sharedUid: null);
    expect(pending.decided, isFalse);
    expect(
      pending.resolve(
        baseProfileId: 2,
        layers: <ComboScope, int>{ComboScope.work: 3},
      ),
      const ComboSrsLibrary(uid: 'u-video', shared: false, ownerProfileId: 2),
    );
    expect(pending.libraries, isEmpty);
    expect(pending.hostsSharedLibrary(1), isFalse);
    expect(pending.resolve(baseProfileId: 99), isNull);

    final ComboSrsLibraries legacy = build(roles: const <int, String>{});
    expect(legacy.defaultId, isNull);
    expect(legacy.resolve(baseProfileId: 1)!.uid, 'u-default');
  });

  test('存量快照 / 默认组合上的 srs.library 行不算拆分', () {
    final ComboSrsLibraries l = ComboSrsLibraries.fromRows(
      uidById: uids,
      roles: <int, String>{1: ComboRole.defaults.wire},
      sharedUids: const <int, String>{1: 'u-default'},
      librarySplits: const <int, String>{1: '1', 2: '1'},
      libraryValues: const <int, String>{
        1: kComboSrsLibraryOwnValue,
        2: kComboSrsLibraryOwnValue,
      },
    );
    expect(l.resolve(baseProfileId: 2)!.uid, 'u-default');
    expect(l.libraries, hasLength(1));
  });
}
