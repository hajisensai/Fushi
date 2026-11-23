// BUG-5275（反馈 s9Gq2L_ao9）：复习库打不开（上次升级没完成，SrsStoreNotMigrated(migrationFailed)）时，配置管理页
// 的删除按钮点了没反应——`_showDeleteDialog` 先统计复习数据规模，统计经 SrsProfileCleanup 打开复习库抛错，异常逃出
// 按钮回调只进 UncaughtZone，确认框不弹、也没有任何提示。
//
// 这里经真实的 ProfileManagementBody → ProfileViewModel → SrsProfileCleanup 走一遍（只把 `storage()` 换成抛
// migrationFailed 的打开）：点删除必须弹出确认框、写明为什么现在删不了，删除按钮不可点，Profile 原样保留。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/profile_management_page.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/srs/srs_profile_cleanup.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsGenState, SrsStoreNotMigrated;
import 'package:material_ui/material_ui.dart';

import '../helpers/fake_anki_repository.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets(
    'deleting a profile while the review library cannot be opened explains '
    'why instead of doing nothing',
    (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 1600);
      addTearDown(tester.view.reset);

      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      final ProfileRepository repo = ProfileRepository(
        db,
        FakeAnkiRepository(),
      );
      final Directory support = Directory.systemTemp.createTempSync(
        'fushi_bug5275_',
      );
      int storageOpens = 0;
      final SrsProfileCleanup cleanup = SrsProfileCleanup(
        SrsProfileCleanupDeps(
          storage: () async {
            storageOpens++;
            throw const SrsStoreNotMigrated(
              'store not migrated {"state":"migrationFailed"}',
              SrsGenState.migrationFailed,
            );
          },
          activeStore: () async => null,
          deviceId: () async => 'dev',
          supportRoot: () async => support,
          backupRoot: () async => Directory('${support.path}/backups'),
        ),
      );
      late ProfileViewModel vm;
      late int goneId;
      await tester.runAsync(() async {
        await repo.ensureDefaultProfile();
        goneId = await repo.createProfile('Second');
        // 用过复习的 Profile 都有 uid（复习数据按它归属）；没有 uid 的不碰复习库。
        await db.profileUidOf(goneId);
        vm = ProfileViewModel(
          repo,
          () async {},
          ProfileDraftCoordinator(),
          deletionCascade: cleanup,
        );
        await vm.stream.firstWhere(
          (ProfileUiState s) => !s.isLoading && s.profiles.length == 2,
        );
      });
      addTearDown(() async {
        await tester.runAsync(() async {
          await db.close();
          try {
            support.deleteSync(recursive: true);
          } on FileSystemException {
            // 句柄滞后；留给系统清理。
          }
        });
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            profileViewModelProvider.overrideWith((Ref ref) => vm),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(child: ProfileManagementBody()),
              ),
            ),
          ),
        ),
      );
      // 进页面的一次性存量扫描：库在换代状态下不扫、不报错。
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(tester.takeException(), isNull);

      final Finder deleteButtons = find.byTooltip(t.profile_delete);
      expect(deleteButtons, findsNWidgets(2));
      await tester.tap(deleteButtons.last);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(ProfileDeleteDialog), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('profile_delete_blocked_reason')),
        findsOneWidget,
      );
      expect(find.text(t.profile_delete_srs_unavailable), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('profile_delete_srs_impact')),
        findsNothing,
      );
      final int opensBeforeConfirm = storageOpens;

      // 删除按钮不可点：点了什么都不做，对话框还在，Profile 原样保留。
      // 标题也是「Delete」：按钮在底部，取最后一个。
      final Finder confirm = find
          .descendant(
            of: find.byType(ProfileDeleteDialog),
            matching: find.text(t.profile_delete),
          )
          .last;
      await tester.tap(confirm, warnIfMissed: false);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ProfileDeleteDialog), findsOneWidget);
      expect(storageOpens, opensBeforeConfirm);

      await tester.tap(find.text(t.dialog_close));
      await tester.pumpAndSettle();
      expect(find.byType(ProfileDeleteDialog), findsNothing);
      final List<ProfileRow> left = (await tester.runAsync(
        repo.getAllProfiles,
      ))!;
      expect(left.map((ProfileRow r) => r.id), contains(goneId));
    },
  );
}
