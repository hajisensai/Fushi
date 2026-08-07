import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/pages/implementations/dictionary_settings_dialog_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

final Provider<ProfileDraftCoordinator> _testProfileDraftCoordinatorProvider =
    Provider<ProfileDraftCoordinator>(
  (ref) => ProfileDraftCoordinator(),
);

class _FakeCssAppModel extends AppModel {
  _FakeCssAppModel()
      : _dictionaries = [
          Dictionary(name: 'JMdict', formatKey: 'yomichan', order: 0),
          Dictionary(
            name: 'Very long dictionary name that must not overflow dialogs',
            formatKey: 'yomichan',
            order: 1,
          ),
        ],
        super(testPlatformServices());

  final List<Dictionary> _dictionaries;
  final Map<String, String> savedCustomCss = <String, String>{};
  final Map<int, String> _savedGlobalCssByProfile = <int, String>{
    1: '.glossary-content { font-size: 18px; }',
  };
  int activeProfileId = 1;

  String get savedGlobalCss => _savedGlobalCssByProfile[activeProfileId] ?? '';

  set savedGlobalCss(String value) {
    _savedGlobalCssByProfile[activeProfileId] = value;
  }

  void switchToProfile(int profileId, {required String globalCss}) {
    activeProfileId = profileId;
    _savedGlobalCssByProfile.putIfAbsent(profileId, () => globalCss);
  }

  String globalCssForProfile(int profileId) =>
      _savedGlobalCssByProfile[profileId] ?? '';

  @override
  List<Dictionary> get dictionaries => _dictionaries;

  @override
  String get globalDictCSS => savedGlobalCss;

  @override
  Map<String, String> get customDictCSS => savedCustomCss;

  @override
  String getCustomCSSForDict(String dictName) => savedCustomCss[dictName] ?? '';

  @override
  Future<void> setCustomCSSForDict(String dictName, String css) async {
    savedCustomCss[dictName] = css;
  }

  @override
  Future<void> setGlobalDictCSS(String css) async {
    savedGlobalCss = css;
  }
}

class _GatedProfileRepository extends ProfileRepository {
  _GatedProfileRepository(HibikiDatabase db) : super(db, FakeAnkiRepository());

  int? pausedApplyProfileId;
  final Completer<void> pausedApplyStarted = Completer<void>();
  final Completer<void> continuePausedApply = Completer<void>();
  final Completer<void> deleteStarted = Completer<void>();
  final Completer<void> importStarted = Completer<void>();

  @override
  Future<void> applyProfile(int profileId) async {
    if (profileId == pausedApplyProfileId && !pausedApplyStarted.isCompleted) {
      pausedApplyStarted.complete();
      await continuePausedApply.future;
    }
    await super.applyProfile(profileId);
  }

  @override
  Future<void> deleteProfile(int id) async {
    if (!deleteStarted.isCompleted) {
      deleteStarted.complete();
    }
    await super.deleteProfile(id);
  }

  @override
  Future<int> importProfileFromJson(
    String json, {
    ProfileImportMode mode = ProfileImportMode.createNew,
    int? targetProfileId,
  }) async {
    if (!importStarted.isCompleted) {
      importStarted.complete();
    }
    return super.importProfileFromJson(
      json,
      mode: mode,
      targetProfileId: targetProfileId,
    );
  }
}

Future<({int profileA, int profileB})> _seedTwoProfiles(
  HibikiDatabase db,
  _GatedProfileRepository repo,
) async {
  await repo.ensureDefaultProfile();
  final int profileA = await repo.getActiveProfileId();
  await db.setPref(
    'global_dict_css',
    '.profile-a-stored { color: orange; }',
  );
  await repo.snapshotCurrentSettings(profileA);

  final int profileB = await repo.createProfile('Profile B');
  await db.setPref(
    'global_dict_css',
    '.profile-b-stored { color: blue; }',
  );
  await repo.snapshotCurrentSettings(profileB);

  await repo.setActiveProfileId(profileA);
  await repo.applyProfile(profileA);
  return (profileA: profileA, profileB: profileB);
}

Widget _buildApp({
  required AppModel appModel,
  required Widget home,
  bool overrideProfileDraftCoordinator = true,
}) {
  return ProviderScope(
    overrides: [
      appProvider.overrideWith((ref) => appModel),
      platformServicesProvider.overrideWithValue(testPlatformServices()),
      if (overrideProfileDraftCoordinator)
        profileDraftCoordinatorProvider.overrideWith(
          (ref) => ref.watch(_testProfileDraftCoordinatorProvider),
        ),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF386A58),
          ),
        ),
        home: home,
      ),
    ),
  );
}

class _CssDialogLauncher extends StatelessWidget {
  const _CssDialogLauncher();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () {
            showAppDialog<void>(
              context: context,
              builder: (_) => const DictCssEditorDialog(),
            );
          },
          child: const Text('打开 CSS'),
        ),
      ),
    );
  }
}

Finder _cssEditorField() {
  return find.byWidgetPredicate(
    (widget) => widget is TextField && widget.expands,
  );
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('Profile change finishes before an intermediate draft can Save',
      () async {
    final ProfileDraftCoordinator coordinator = ProfileDraftCoordinator();
    final Completer<void> changeStarted = Completer<void>();
    final Completer<void> finishChange = Completer<void>();
    bool wroteDraft = false;

    final Future<void> change = coordinator.runProfileChange(() async {
      changeStarted.complete();
      await finishChange.future;
    });
    await changeStarted.future;
    final Object intermediateScope = coordinator.draftScope;

    final Future<bool> save = coordinator.saveDraftIfCurrent(
      intermediateScope,
      () async {
        wroteDraft = true;
      },
    );
    await Future<void>.delayed(Duration.zero);
    expect(wroteDraft, isFalse);

    finishChange.complete();
    await change;
    expect(await save, isFalse);
    expect(wroteDraft, isFalse);
  });

  test('Profile change waits for an in-flight draft Save', () async {
    final ProfileDraftCoordinator coordinator = ProfileDraftCoordinator();
    final Object initialScope = coordinator.draftScope;
    final Completer<void> saveStarted = Completer<void>();
    final Completer<void> finishSave = Completer<void>();
    bool profileChangeStarted = false;

    final Future<bool> save = coordinator.saveDraftIfCurrent(
      initialScope,
      () async {
        saveStarted.complete();
        await finishSave.future;
      },
    );
    await saveStarted.future;

    final Future<void> change = coordinator.runProfileChange(() async {
      profileChangeStarted = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(profileChangeStarted, isFalse);

    finishSave.complete();
    expect(await save, isTrue);
    await change;
    expect(profileChangeStarted, isTrue);
    expect(identical(coordinator.draftScope, initialScope), isFalse);
  });

  test('every active Profile mutation path rotates the draft scope', () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    final ProfileRepository repo = ProfileRepository(
      db,
      FakeAnkiRepository(),
    );
    final ProfileDraftCoordinator coordinator = ProfileDraftCoordinator();
    final ProfileViewModel viewModel = ProfileViewModel(
      repo,
      () async {},
      coordinator,
    );
    addTearDown(() async {
      viewModel.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await db.close();
    });

    final ProfileUiState loadedState = await viewModel.stream.firstWhere(
      (ProfileUiState state) => state.activeProfileId > 0,
    );
    final int profileA = loadedState.activeProfileId;
    expect(profileA, greaterThan(0));

    Future<void> expectRotation(Future<void> Function() operation) async {
      final Object before = coordinator.draftScope;
      await operation();
      expect(identical(coordinator.draftScope, before), isFalse);
    }

    await expectRotation(() => viewModel.createProfile('Profile B'));
    final int profileB = await repo.getActiveProfileId();
    expect(profileB, isNot(profileA));

    await expectRotation(() => viewModel.switchProfile(profileA));
    final String exported = await viewModel.exportProfile(profileA);
    await expectRotation(
      () async {
        await viewModel.importProfile(
          exported,
          mode: ProfileImportMode.overwrite,
          targetProfileId: profileA,
        );
      },
    );

    await expectRotation(() => viewModel.switchProfile(profileB));
    await expectRotation(() => viewModel.deleteProfile(profileB));
    expect(await repo.getActiveProfileId(), profileA);
  });

  test(
      'switch then delete target serializes before rejecting an intermediate stale Save',
      () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    final _GatedProfileRepository repo = _GatedProfileRepository(db);
    final ({int profileA, int profileB}) profiles =
        await _seedTwoProfiles(db, repo);
    final ProfileDraftCoordinator coordinator = ProfileDraftCoordinator();
    final ProfileViewModel viewModel = ProfileViewModel(
      repo,
      () async {},
      coordinator,
    );
    addTearDown(() async {
      viewModel.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await db.close();
    });
    ProfileUiState latestState = await viewModel.stream.firstWhere(
      (ProfileUiState state) =>
          state.activeProfileId == profiles.profileA && !state.isLoading,
    );
    final StreamSubscription<ProfileUiState> stateSubscription =
        viewModel.stream.listen((ProfileUiState state) {
      latestState = state;
    });
    addTearDown(stateSubscription.cancel);

    repo.pausedApplyProfileId = profiles.profileB;
    final Future<void> switchProfile =
        viewModel.switchProfile(profiles.profileB);
    await repo.pausedApplyStarted.future;
    expect(await repo.getActiveProfileId(), profiles.profileB);
    expect(latestState.activeProfileId, profiles.profileA);

    final Object intermediateScope = coordinator.draftScope;
    final Future<void> deleteTarget =
        viewModel.deleteProfile(profiles.profileB);
    bool staleSaveRan = false;
    final Future<bool> staleSave = coordinator.saveDraftIfCurrent(
      intermediateScope,
      () async {
        staleSaveRan = true;
        await db.setPref(
          'global_dict_css',
          '.stale-profile-b-draft { color: red; }',
        );
      },
    );
    await Future<void>.delayed(Duration.zero);
    final bool deleteEnteredWhileSwitchHeldLock =
        repo.deleteStarted.isCompleted;

    repo.continuePausedApply.complete();
    await switchProfile;
    await deleteTarget;
    final bool staleSaveAccepted = await staleSave;

    expect(
      deleteEnteredWhileSwitchHeldLock,
      isFalse,
      reason:
          'delete must enter the coordinator before reading whether its target is active',
    );
    expect(staleSaveAccepted, isFalse);
    expect(staleSaveRan, isFalse);
    expect(await repo.getActiveProfileId(), profiles.profileA);
    expect(latestState.activeProfileId, profiles.profileA);
    expect(await repo.getProfileById(profiles.profileB), isNull);
    expect(
      await db.getPref('global_dict_css'),
      '.profile-a-stored { color: orange; }',
    );
  });

  test(
      'Save lock serializes switch then target overwrite import without crossing scope',
      () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    final _GatedProfileRepository repo = _GatedProfileRepository(db);
    final ({int profileA, int profileB}) profiles =
        await _seedTwoProfiles(db, repo);

    final int importSource = await repo.createProfile('Import source');
    await db.setPref(
      'global_dict_css',
      '.imported-profile-b { color: purple; }',
    );
    await repo.snapshotCurrentSettings(importSource);
    final String importJson = await repo.exportProfileToJson(importSource);
    await repo.setActiveProfileId(profiles.profileA);
    await repo.applyProfile(profiles.profileA);

    final ProfileDraftCoordinator coordinator = ProfileDraftCoordinator();
    final ProfileViewModel viewModel = ProfileViewModel(
      repo,
      () async {},
      coordinator,
    );
    addTearDown(() async {
      viewModel.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await db.close();
    });
    ProfileUiState latestState = await viewModel.stream.firstWhere(
      (ProfileUiState state) =>
          state.activeProfileId == profiles.profileA && !state.isLoading,
    );
    final StreamSubscription<ProfileUiState> stateSubscription =
        viewModel.stream.listen((ProfileUiState state) {
      latestState = state;
    });
    addTearDown(stateSubscription.cancel);

    final Object profileAScope = coordinator.draftScope;
    final Completer<void> saveStarted = Completer<void>();
    final Completer<void> finishSave = Completer<void>();
    final Future<bool> save = coordinator.saveDraftIfCurrent(
      profileAScope,
      () async {
        saveStarted.complete();
        await finishSave.future;
        await db.setPref(
          'global_dict_css',
          '.profile-a-saved { color: green; }',
        );
      },
    );
    await saveStarted.future;

    final Future<void> switchProfile =
        viewModel.switchProfile(profiles.profileB);
    final Future<int> overwriteTarget = viewModel.importProfile(
      importJson,
      mode: ProfileImportMode.overwrite,
      targetProfileId: profiles.profileB,
    );
    await Future<void>.delayed(Duration.zero);
    final bool importEnteredWhileSaveHeldLock = repo.importStarted.isCompleted;

    finishSave.complete();
    expect(await save, isTrue);
    await switchProfile;
    expect(await overwriteTarget, profiles.profileB);

    expect(
      importEnteredWhileSaveHeldLock,
      isFalse,
      reason:
          'import must enter the coordinator before reading whether its overwrite target is active',
    );
    expect(await repo.getActiveProfileId(), profiles.profileB);
    expect(latestState.activeProfileId, profiles.profileB);
    expect(
      await db.getPref('global_dict_css'),
      '.imported-profile-b { color: purple; }',
    );
    final List<ProfileSettingRow> profileASettings =
        await db.getProfileSettings(profiles.profileA);
    expect(
      profileASettings
          .singleWhere(
            (ProfileSettingRow row) =>
                row.category == 'pref' && row.key == 'global_dict_css',
          )
          .value,
      '.profile-a-saved { color: green; }',
    );
    expect(identical(coordinator.draftScope, profileAScope), isFalse);
  });

  // TODO-422：词典管理页本身不实现任何自定义 CSS 编辑——行尾旧三点菜单（含
  // 「自定义 CSS」项）已被独立删除按钮取代。自定义 CSS 编辑由设置 → 词典设置的
  // 全局入口 DictCssEditorDialog（可下拉选本词典）承担，故词典管理页里不再调起
  // DictCssEditorDialog，也不内联自己的 CSS 对话框。
  test('dictionary manager delegates custom CSS editing to settings dialog',
      () {
    final source = File(
      'lib/src/pages/implementations/dictionary_dialog_page.dart',
    ).readAsStringSync();

    // 词典管理页不内联自己的 CSS 对话框。
    expect(source, isNot(contains('_showCustomCSSDialog')));
    expect(source, isNot(contains('custom_css_title')));
    // 行尾三点菜单移除后，词典管理页不再从行内调起 CSS 编辑器。
    expect(source, isNot(contains('DictCssEditorDialog(')));

    // 自定义 CSS 编辑仍可达：由设置 schema 的全局入口委托给 DictCssEditorDialog。
    final settingsSource =
        File('lib/src/settings/settings_schema_lookup.dart').readAsStringSync();
    expect(settingsSource, contains('DictCssEditorDialog('));
  });

  testWidgets('dictionary CSS editor fits a compact mobile dialog', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 852);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _buildApp(
        appModel: _FakeCssAppModel(),
        home: const DictCssEditorDialog(),
      ),
    );

    expect(tester.takeException(), isNull);

    final Rect dialogRect = tester.getRect(find.byType(Dialog));
    expect(dialogRect.left, greaterThanOrEqualTo(0));
    expect(dialogRect.right, lessThanOrEqualTo(393));

    final Finder cssEditorField = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.expands,
    );
    final Rect menuRect = tester.getRect(find.byType(DropdownMenu<int>));
    final Rect textFieldRect = tester.getRect(cssEditorField);
    expect(menuRect.left, greaterThanOrEqualTo(dialogRect.left));
    expect(menuRect.right, lessThanOrEqualTo(dialogRect.right));
    expect(textFieldRect.left, greaterThanOrEqualTo(dialogRect.left));
    expect(textFieldRect.right, lessThanOrEqualTo(dialogRect.right));
  });

  testWidgets('dictionary CSS editor can start on a specific dictionary', (
    WidgetTester tester,
  ) async {
    final _FakeCssAppModel appModel = _FakeCssAppModel();
    appModel.savedCustomCss['JMdict'] = '.entry { color: red; }';

    await tester.pumpWidget(
      _buildApp(
        appModel: appModel,
        home: const DictCssEditorDialog(initialDictionaryName: 'JMdict'),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('JMdict'), findsOneWidget);
    expect(find.textContaining('color: red'), findsOneWidget);
  });

  testWidgets('barrier dismissal keeps CSS draft and cancel discards it', (
    WidgetTester tester,
  ) async {
    final _FakeCssAppModel appModel = _FakeCssAppModel();
    final String savedCss = appModel.savedGlobalCss;

    await tester.pumpWidget(
      _buildApp(
        appModel: appModel,
        home: const _CssDialogLauncher(),
      ),
    );

    await tester.tap(find.text('打开 CSS'));
    await tester.pumpAndSettle();
    await tester.enterText(_cssEditorField(), '.draft { color: orange; }');
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();

    expect(appModel.savedGlobalCss, savedCss);
    expect(find.byType(DictCssEditorDialog), findsNothing);

    await tester.tap(find.text('打开 CSS'));
    await tester.pumpAndSettle();
    expect(find.textContaining('.draft { color: orange; }'), findsOneWidget);

    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();
    expect(appModel.savedGlobalCss, savedCss);

    await tester.tap(find.text('打开 CSS'));
    await tester.pumpAndSettle();
    expect(find.textContaining(savedCss), findsOneWidget);
    expect(find.textContaining('.draft { color: orange; }'), findsNothing);
  });

  testWidgets('scope changes stay in draft until Save persists every edit', (
    WidgetTester tester,
  ) async {
    final _FakeCssAppModel appModel = _FakeCssAppModel();
    final String savedGlobalCss = appModel.savedGlobalCss;

    await tester.pumpWidget(
      _buildApp(
        appModel: appModel,
        home: const _CssDialogLauncher(),
      ),
    );

    await tester.tap(find.text('打开 CSS'));
    await tester.pumpAndSettle();
    await tester.enterText(_cssEditorField(), '.global-draft { color: blue; }');

    await tester.tap(find.byType(DropdownMenu<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('JMdict').last);
    await tester.pumpAndSettle();

    expect(appModel.savedGlobalCss, savedGlobalCss);
    await tester.enterText(_cssEditorField(), '.entry { color: red; }');
    expect(appModel.savedCustomCss, isEmpty);

    await tester.tap(find.text(t.dialog_save));
    await tester.pumpAndSettle();

    expect(appModel.savedGlobalCss, '.global-draft { color: blue; }');
    expect(
      appModel.savedCustomCss['JMdict'],
      '.entry { color: red; }',
    );
  });

  testWidgets('first-open Save survives lazy Profile initialization', (
    WidgetTester tester,
  ) async {
    final _FakeCssAppModel appModel = _FakeCssAppModel();
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    appModel.wireDatabaseForTesting(db);

    await tester.pumpWidget(
      _buildApp(
        appModel: appModel,
        home: const _CssDialogLauncher(),
        overrideProfileDraftCoordinator: false,
      ),
    );

    await tester.tap(find.text('打开 CSS'));
    await tester.pumpAndSettle();
    await tester.enterText(
      _cssEditorField(),
      '.first-open-draft { color: purple; }',
    );

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(DictCssEditorDialog)),
    );
    final ProfileDraftCoordinator draftCoordinator =
        container.read(profileDraftCoordinatorProvider);
    final Object initialDraftScope = draftCoordinator.draftScope;
    container.read(profileViewModelProvider);
    await tester.runAsync(() async {
      for (int attempt = 0;
          attempt < 100 &&
              container.read(profileViewModelProvider).activeProfileId < 0;
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(
      container.read(profileViewModelProvider).activeProfileId,
      greaterThan(0),
      reason: 'The regression must exercise the completed lazy Profile load.',
    );
    expect(
      identical(
        draftCoordinator.draftScope,
        initialDraftScope,
      ),
      isTrue,
      reason: 'Initial Profile loading must not invalidate the open draft.',
    );

    await tester.tap(find.text(t.dialog_save));
    await tester.pumpAndSettle();

    expect(
      appModel.savedGlobalCss,
      '.first-open-draft { color: purple; }',
    );
    expect(find.byType(DictCssEditorDialog), findsNothing);

    await tester.runAsync(
      () => container
          .read(profileViewModelProvider.notifier)
          .createProfile('Scope rotation regression'),
    );
    expect(
      identical(
        draftCoordinator.draftScope,
        initialDraftScope,
      ),
      isFalse,
      reason: 'A real Profile identity change must rotate the draft scope.',
    );
  });

  testWidgets(
      'same AppModel does not reuse a CSS draft after the active Profile changes',
      (WidgetTester tester) async {
    final _FakeCssAppModel appModel = _FakeCssAppModel();
    final String profileAStoredCss = appModel.savedGlobalCss;

    await tester.pumpWidget(
      _buildApp(
        appModel: appModel,
        home: const _CssDialogLauncher(),
      ),
    );

    await tester.tap(find.text('打开 CSS'));
    await tester.pumpAndSettle();
    await tester.enterText(
      _cssEditorField(),
      '.profile-a-draft { color: orange; }',
    );
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();

    appModel.switchToProfile(
      2,
      globalCss: '.profile-b-stored { color: blue; }',
    );
    ProviderScope.containerOf(
      tester.element(find.byType(_CssDialogLauncher)),
    ).read(_testProfileDraftCoordinatorProvider).invalidateDrafts();
    await tester.pump();

    await tester.tap(find.text('打开 CSS'));
    await tester.pumpAndSettle();

    expect(find.textContaining('.profile-b-stored'), findsOneWidget);
    expect(find.textContaining('.profile-a-draft'), findsNothing);

    await tester.enterText(
      _cssEditorField(),
      '.profile-b-saved { color: green; }',
    );
    await tester.tap(find.text(t.dialog_save));
    await tester.pumpAndSettle();

    expect(appModel.globalCssForProfile(1), profileAStoredCss);
    expect(
      appModel.globalCssForProfile(2),
      '.profile-b-saved { color: green; }',
    );
  });

  testWidgets('Save cannot write an open draft after the Profile changes', (
    WidgetTester tester,
  ) async {
    final _FakeCssAppModel appModel = _FakeCssAppModel();
    final String profileAStoredCss = appModel.savedGlobalCss;
    const String profileBStoredCss = '.profile-b-stored { color: blue; }';

    await tester.pumpWidget(
      _buildApp(
        appModel: appModel,
        home: const _CssDialogLauncher(),
      ),
    );

    await tester.tap(find.text('打开 CSS'));
    await tester.pumpAndSettle();
    await tester.enterText(
      _cssEditorField(),
      '.profile-a-draft { color: orange; }',
    );

    appModel.switchToProfile(2, globalCss: profileBStoredCss);
    ProviderScope.containerOf(
      tester.element(find.byType(DictCssEditorDialog)),
    ).read(_testProfileDraftCoordinatorProvider).invalidateDrafts();
    await tester.pump();

    await tester.tap(find.text(t.dialog_save));
    await tester.pumpAndSettle();

    expect(appModel.globalCssForProfile(1), profileAStoredCss);
    expect(appModel.globalCssForProfile(2), profileBStoredCss);
    expect(find.byType(DictCssEditorDialog), findsNothing);
  });
}
