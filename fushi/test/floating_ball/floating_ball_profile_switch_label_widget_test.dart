import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/floating_ball/app_floating_ball_host.dart';
import 'package:fushi/src/floating_ball/floating_ball_config.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

class _GatedSnapshotRepository extends ProfileRepository {
  _GatedSnapshotRepository(super.db, super.anki, {super.isDictionaryInstalled});
  Completer<void>? snapshotGate;

  @override
  Future<void> snapshotCurrentSettings(int profileId) async {
    final Completer<void>? gate = snapshotGate;
    if (gate != null) await gate.future;
    return super.snapshotCurrentSettings(profileId);
  }
}

class _SlowApplyAppModel extends AppModel {
  _SlowApplyAppModel() : super(testPlatformServices());

  Completer<void>? applyGate;

  @override
  bool get isInitialised => true;

  @override
  bool get einkMode => false;

  @override
  bool isDictionaryInstalledOnDisk(String name) => true;

  @override
  Future<void> refreshPrefCache() async {}

  @override
  Future<void> reloadDictionariesFromDb() async {
    final Completer<void>? gate = applyGate;
    if (gate != null) await gate.future;
  }
}

class _FakePlatformServices implements PlatformServices {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 真实悬浮球宿主里的「切换配置」按钮：在一次慢切换的每个阶段（快照 / 应用卡住 /
/// 视图模型因 ankiRepositoryProvider 失效而重建）都必须显示目标配置名，
/// 且全程不出现旧名字或通用文案。
void main() {
  testWidgets('慢切换全程悬浮球胶囊显示目标配置名，不回退旧名 / 通用文案', (WidgetTester tester) async {
    LocaleSettings.setLocale(AppLocale.en);
    final FushiDatabase db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory dir = Directory.systemTemp.createTempSync('fushi_fb_prof');
    final _SlowApplyAppModel app = _SlowApplyAppModel()
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: dir)
      ..wireDatabaseForTesting(db);
    final Completer<void> snapGate = Completer<void>();
    final Completer<void> applyGate = Completer<void>();
    app.applyGate = applyGate;
    addTearDown(() async {
      if (!snapGate.isCompleted) snapGate.complete();
      if (!applyGate.isCompleted) applyGate.complete();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await db.close();
      });
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    await prefs.setFloatingBallShowLabels(true);
    late _GatedSnapshotRepository repo;
    await prefs.setFloatingBallButtons(
      FloatingBallScope.general,
      const <String>['switch_profile'],
    );

    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        fushiDatabaseProvider.overrideWithValue(db),
        appProvider.overrideWith((Ref ref) => app),
        platformServicesProvider.overrideWithValue(_FakePlatformServices()),
        ankiRepositoryProvider.overrideWith((Ref ref) => FakeAnkiRepository()),
        profileRepositoryProvider.overrideWith((Ref ref) {
          repo = _GatedSnapshotRepository(
            db,
            ref.watch(ankiRepositoryProvider),
            isDictionaryInstalled: app.isDictionaryInstalledOnDisk,
          );
          return repo;
        }),
      ],
    );
    addTearDown(container.dispose);
    await tester.runAsync(() async {
      container.read(profileViewModelProvider);
      for (int i = 0; i < 100; i++) {
        final ProfileUiState st = container.read(profileViewModelProvider);
        if (!st.isLoading && st.profiles.isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: app.navigatorKey,
            home: const Scaffold(body: SizedBox()),
            builder: (BuildContext context, Widget? child) =>
                Stack(children: <Widget>[child!, const AppFloatingBallHost()]),
          ),
        ),
      ),
    );
    Future<void> real(int ms) async {
      await tester.runAsync(
        () => Future<void>.delayed(Duration(milliseconds: ms)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    await real(100);
    for (int i = 0; i < 40; i++) {
      final ProfileUiState st = container.read(profileViewModelProvider);
      if (!st.isLoading && st.profiles.isNotEmpty) break;
      await real(50);
    }
    await real(100);
    await tester.tap(
      find.byKey(const ValueKey<String>('fushi_reader_floating_ball_icon')),
    );
    await tester.pumpAndSettle();

    // 配置名只在 tooltip（= 无障碍名）里：「切换配置（当前：<名>）」；通用文案
    // 则不带名字。可见的标签始终是「切换配置」（BUG-3800），不随配置名变化。
    Finder labelOf(String name) => find.byWidgetPredicate(
      (Widget w) =>
          w is Tooltip &&
          w.message ==
              t.floating_ball_action_switch_profile_tooltip(name: name),
    );
    Finder genericLabel() => find.byWidgetPredicate(
      (Widget w) =>
          w is Tooltip && w.message == t.floating_ball_action_switch_profile,
    );
    expect(labelOf('Default'), findsOneWidget);
    expect(
      find.text(t.floating_ball_action_switch_profile),
      findsOneWidget,
      reason: '可见标签始终是「切换配置」',
    );

    final int targetId = (await tester.runAsync(
      () => container.read(profileRepositoryProvider).createProfile('Target'),
    ))!;
    await tester.runAsync(
      () => container.read(profileViewModelProvider.notifier).reload(),
    );
    await real(50);
    expect(labelOf('Default'), findsOneWidget);

    // 阶段 1：快照还没做完。
    repo.snapshotGate = snapGate;
    late Future<void> switching;
    await tester.runAsync(() async {
      switching = container
          .read(profileViewModelProvider.notifier)
          .switchProfile(targetId);
    });
    await real(100);
    expect(labelOf('Target'), findsOneWidget, reason: '快照阶段已显示目标');
    expect(labelOf('Default'), findsNothing);

    // 阶段 2：快照放行，应用卡在「重载词典」（此时 ankiRepositoryProvider 已失效、
    // 视图模型已重建）。
    snapGate.complete();
    await real(500);
    expect(labelOf('Target'), findsOneWidget, reason: '应用 / 重建阶段仍显示目标');
    expect(labelOf('Default'), findsNothing);
    expect(genericLabel(), findsNothing, reason: '不得退回通用文案');

    // 阶段 3：完成。
    applyGate.complete();
    await tester.runAsync(() => switching);
    await real(100);
    expect(labelOf('Target'), findsOneWidget);
    expect(labelOf('Default'), findsNothing);
    expect(find.text(t.floating_ball_action_switch_profile), findsOneWidget);
    expect(find.text('Target'), findsNothing, reason: '配置名不得出现在可见标签上');
  });
}
