import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_library_switcher.dart';
import 'package:fushi/src/profile/combo/combo_repository.dart';
import 'package:fushi/src/profile/combo/srs_library_resolver.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/srs/srs_library.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/inert_profile_repository.dart';
import '../helpers/test_platform_services.dart';

class _FixedLibraries extends SrsLibrariesNotifier {
  _FixedLibraries(this._value);

  final SrsLibraries _value;

  @override
  Future<SrsLibraries> build() async {
    final String? choice = ref.watch(srsLibraryChoiceProvider);
    final bool valid =
        choice != null &&
        _value.entries.any((SrsLibraryEntry e) => e.uid == choice);
    return SrsLibraries(
      activeUid: _value.activeUid,
      viewedUid: valid ? choice : _value.activeUid,
      entries: _value.entries,
    );
  }
}

class _AppModel extends AppModel {
  _AppModel(this._db) : super(testPlatformServices());

  final FushiDatabase _db;

  @override
  FushiDatabase get database => _db;
}

/// 下一次现算卡在 [gate] 上的真实解析（其余照常读表）。
class _GatedLibraries extends SrsLibrariesNotifier {
  Completer<void>? gate;

  @override
  Future<SrsLibraries> compute(
    FushiDatabase db,
    int activeProfileId,
    String? choice,
  ) async {
    final Completer<void>? held = gate;
    gate = null;
    if (held != null) await held.future;
    return super.compute(db, activeProfileId, choice);
  }
}

/// 复习库解析的 app 侧读口与复习页库切换（组合阶段 4，设计 §4.1）。
void main() {
  late FushiDatabase db;
  late int defaultId;
  late int mangaId;
  late int jaId;

  Future<void> put(int id, String key, String value) => db.upsertProfileSetting(
    ProfileSettingsCompanion.insert(
      profileId: id,
      category: kComboSyntheticCategory,
      key: key,
      value: value,
    ),
  );

  Future<int> profile(String name, ComboRole role) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int id = await db.insertProfile(
      ProfilesCompanion.insert(name: name, createdAt: now, updatedAt: now),
    );
    await put(id, kComboRoleKey, role.wire);
    return id;
  }

  Future<void> splitOwn(int id) async {
    await put(id, kComboSrsLibrarySplitKey, '1');
    await put(id, kComboSrsLibrarySettingKey, kComboSrsLibraryOwnValue);
  }

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    defaultId = await profile('Default', ComboRole.defaults);
    mangaId = await profile('Manga', ComboRole.named);
    jaId = await profile('JA', ComboRole.named);
    await put(
      defaultId,
      kComboSrsSharedUidKey,
      await db.profileUidOf(defaultId),
    );
  });

  tearDown(() => db.close());

  test('没拆 srs.library 的组合都解析到共享库（两份组合导入同一份 .apkg 落同一个集合）', () async {
    final String shared = await db.profileUidOf(defaultId);
    expect(await resolveSrsLibraryUid(db, baseProfileId: defaultId), shared);
    expect(await resolveSrsLibraryUid(db, baseProfileId: mangaId), shared);
    expect(
      await resolveSrsLibraryUid(
        db,
        baseProfileId: defaultId,
        layers: <ComboScope, int>{
          ComboScope.mediaType: mangaId,
          ComboScope.language: jaId,
        },
      ),
      shared,
    );
    expect(await profileIdOfSrsLibrary(db, shared), defaultId);
  });

  test('拆出独立库的组合落自己那份；库列表 = 共享库 + 独立库', () async {
    await splitOwn(mangaId);
    expect(
      await resolveSrsLibraryUid(
        db,
        baseProfileId: defaultId,
        layers: <ComboScope, int>{ComboScope.mediaType: mangaId},
      ),
      await db.profileUidOf(mangaId),
    );
    final SrsLibraries l = srsLibrariesOf(
      libraries: await loadComboSrsLibraries(db),
      activeProfileId: defaultId,
      profileNames: <int, String>{defaultId: 'Default', mangaId: 'Manga'},
    );
    expect(l.switchable, isTrue);
    expect(l.activeUid, await db.profileUidOf(defaultId));
    expect(l.viewedUid, l.activeUid, reason: '默认显示共享库');
    expect(l.entries.first.shared, isTrue);
    expect(l.entries.last.ownerName, 'Manga');
  });

  test('复习页切库：切到的库消失后回到激活配置的库', () async {
    await splitOwn(mangaId);
    final String manga = await db.profileUidOf(mangaId);
    final SrsLibraries chosen = srsLibrariesOf(
      libraries: await loadComboSrsLibraries(db),
      activeProfileId: defaultId,
      profileNames: const <int, String>{},
      choice: manga,
    );
    expect(chosen.viewedUid, manga);
    expect(chosen.activeUid, isNot(manga), reason: '制卡仍落激活配置的库');

    // 恢复继承（撤销拆分）：那份独立库不再列出，选择失效。
    await db.deleteProfileSetting(
      mangaId,
      kComboSyntheticCategory,
      kComboSrsLibrarySplitKey,
    );
    final SrsLibraries after = srsLibrariesOf(
      libraries: await loadComboSrsLibraries(db),
      activeProfileId: defaultId,
      profileNames: const <int, String>{},
      choice: manga,
    );
    expect(after.switchable, isFalse);
    expect(after.viewedUid, after.activeUid);
  });

  test('采用对端 uid（铁律 E）时共享库指针跟着改指', () async {
    final String old = await db.profileUidOf(defaultId);
    await db.adoptProfileUid(defaultId, 'peer-uid');
    expect(
      (await db.profileSettingValuesOf(
        kComboSyntheticCategory,
        kComboSrsSharedUidKey,
      ))[defaultId],
      'peer-uid',
    );
    expect(await resolveSrsLibraryUid(db, baseProfileId: mangaId), 'peer-uid');
    expect(old, isNot('peer-uid'));

    // 共享库挂在别的配置上时，改别的配置的 uid 不碰共享库指针。
    await db.adoptProfileUid(jaId, 'other-peer');
    expect(await resolveSrsLibraryUid(db, baseProfileId: jaId), 'peer-uid');
  });

  test('共享库待定（迁移时复习库打不开）：落激活配置自己那份，不列库切换', () async {
    await db.deleteProfileSetting(
      defaultId,
      kComboSyntheticCategory,
      kComboSrsSharedUidKey,
    );
    expect(
      await resolveSrsLibraryUid(db, baseProfileId: mangaId),
      await db.profileUidOf(mangaId),
    );
    expect(
      srsLibrariesOf(
        libraries: await loadComboSrsLibraries(db),
        activeProfileId: mangaId,
        profileNames: const <int, String>{},
      ).switchable,
      isFalse,
    );
  });

  test('写入触发的现算晚于切库重建回来：旧结果不覆盖新选择（复习页不回到旧库）', () async {
    await splitOwn(mangaId);
    final String manga = await db.profileUidOf(mangaId);
    final String shared = await db.profileUidOf(defaultId);
    final InertProfileRepository repo = InertProfileRepository(
      activeProfileId: defaultId,
    );
    final _GatedLibraries notifier = _GatedLibraries();
    final ProviderContainer c = ProviderContainer(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => _AppModel(db)),
        profileRepositoryProvider.overrideWithValue(repo),
        profileViewModelProvider.overrideWith(
          (Ref ref) =>
              ProfileViewModel(repo, () async {}, ProfileDraftCoordinator()),
        ),
        srsLibrariesProvider.overrideWith(() => notifier),
      ],
    );
    addTearDown(c.dispose);
    c.listen<AsyncValue<SrsLibraries>>(
      srsLibrariesProvider,
      (AsyncValue<SrsLibraries>? previous, AsyncValue<SrsLibraries> next) {},
    );
    expect((await c.read(srsLibrariesProvider.future)).viewedUid, shared);

    // 一次 profile_settings 写入触发按「未切库」现算，卡住不返回。
    final Completer<void> held = Completer<void>();
    notifier.gate = held;
    await put(jaId, 'probe', '1');
    await pumpEventQueue();

    // 期间用户切到独立库：重建按新选择算完。
    c.read(srsLibraryChoiceProvider.notifier).state = manga;
    expect((await c.read(srsLibrariesProvider.future)).viewedUid, manga);

    // 卡住的旧现算这时才回来：结果已过时，不能把复习页拉回共享库。
    held.complete();
    await pumpEventQueue();
    expect(c.read(srsLibrariesProvider).requireValue.viewedUid, manga);

    // 之后的写入照常现算，仍按当前选择。
    await put(jaId, 'probe', '2');
    await pumpEventQueue();
    expect(c.read(srsLibrariesProvider).requireValue.viewedUid, manga);
  });

  for (final bool apple in <bool>[false, true]) {
    testWidgets('复习页库切换：只有共享库时不出现；有独立库时可切，选回激活库清掉选择（apple=$apple）', (
      WidgetTester tester,
    ) async {
      Future<ProviderContainer> pump(List<SrsLibraryEntry> entries) async {
        final ProviderContainer container = ProviderContainer(
          overrides: <Override>[
            srsLibrariesProvider.overrideWith(
              () => _FixedLibraries(
                SrsLibraries(
                  activeUid: 'shared',
                  viewedUid: 'shared',
                  entries: entries,
                ),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: buildFushiThemeData(
                scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
                textTheme: Typography.material2021().black,
                glass: FushiGlassMaterial.off,
                glassDesign: apple,
              ),
              home: const FushiGlassScope(
                child: Scaffold(body: SrsLibrarySwitcher()),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        return container;
      }

      await pump(const <SrsLibraryEntry>[
        SrsLibraryEntry(uid: 'shared', shared: true),
      ]);
      expect(find.text(t.srs_library_shared), findsNothing);

      final ProviderContainer c = await pump(const <SrsLibraryEntry>[
        SrsLibraryEntry(uid: 'shared', shared: true),
        SrsLibraryEntry(uid: 'own', shared: false, ownerName: 'Manga'),
      ]);
      expect(find.text('Manga'), findsOneWidget);
      await tester.tap(find.text('Manga'));
      await tester.pumpAndSettle();
      expect(c.read(srsLibraryChoiceProvider), 'own');
      await tester.tap(find.text(t.srs_library_shared));
      await tester.pumpAndSettle();
      expect(c.read(srsLibraryChoiceProvider), isNull);
    });
  }
}
