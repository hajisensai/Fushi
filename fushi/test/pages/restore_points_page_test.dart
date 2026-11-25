import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show buildFushiFallbackTheme;
import 'package:fushi/src/pages/implementations/library_recovery_page.dart';
import 'package:fushi/src/storage/orphan_book_recovery.dart';
import 'package:fushi/src/sync/auto_backup/restore_point_catalog.dart';
import 'package:fushi/src/sync/backup_service.dart'
    show OverwriteSnapshotPreview;

import '../../integration_test/helpers/focus_driver.dart';

/// 还原点页：列出更新前与定时还原点（种类、内容）；删除走行内确认面板，全程焦点驱动（Enter）。
class _DirHost implements RestorePointsHost {
  _DirHost(this.dir);

  final String dir;

  @override
  List<RestorePointEntry> listEntries() =>
      listRestorePointEntries(dbDirectory: dir);

  @override
  void deleteEntry(RestorePointEntry entry) => deleteRestorePointEntry(entry);

  @override
  Future<OverwriteSnapshotPreview?> previewFillIn(
    RestorePointEntry entry,
  ) async => null;

  @override
  Future<void> fillIn(RestorePointEntry entry) async {}

  @override
  Future<void> replace(RestorePointEntry entry) async {}

  @override
  Future<bool> export(RestorePointEntry entry) async => false;

  @override
  Future<OrphanBookRecovery?> orphanRecovery() async => null;
}

void main() {
  late Directory tmp;
  late RestorePoint scheduled;
  late RestorePoint preUpdate;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fushi_restore_points_page_');
    final RestorePointStore store = RestorePointStore(tmp.path);
    final int base = DateTime.utc(2026, 11, 25, 12).millisecondsSinceEpoch;

    final RestorePointDraft update = store.begin(
      kind: RestorePointKind.preUpdate,
      nowMs: base,
    );
    File(
      p.join(update.directory, RestorePointDatabase.fushi.fileName),
    ).writeAsStringSync('db');
    preUpdate = store.commit(
      update,
      fromSchema: kFushiDbSchemaVersion - 1,
      toSchema: kFushiDbSchemaVersion,
    );

    final RestorePointDraft backup = store.begin(
      kind: RestorePointKind.scheduled,
      nowMs: base + const Duration(hours: 1).inMilliseconds,
    );
    File(
      p.join(backup.directory, kRestorePointArchiveFileName),
    ).writeAsStringSync('zip');
    scheduled = store.commit(
      backup,
      fromSchema: kFushiDbSchemaVersion,
      toSchema: kFushiDbSchemaVersion,
      categories: <String>['settings', 'srs'],
      excludedCategories: <String>['books'],
      includesSrsMedia: false,
    );
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildFushiFallbackTheme(Brightness.light),
          home: RestorePointsPage.withHost(host: _DirHost(tmp.path)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('列出更新前与定时还原点：种类与内容', (WidgetTester tester) async {
    await pumpPage(tester);
    expect(find.text(t.restore_points_kind_scheduled), findsOneWidget);
    expect(find.text(t.restore_points_kind_pre_update), findsOneWidget);
    expect(
      find.textContaining(t.restore_points_contents_without_media),
      findsOneWidget,
    );
    expect(
      find.textContaining(t.restore_points_contents_full_db),
      findsOneWidget,
    );
    // 两份都能补回、替换（schema 在本版本可用区间内）。
    for (final RestorePoint point in <RestorePoint>[scheduled, preUpdate]) {
      expect(
        find.byKey(ValueKey<String>('restore-point-fill-${point.id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey<String>('restore-point-replace-${point.id}')),
        findsOneWidget,
      );
    }
  });

  testWidgets('删除：键盘到「删除」→ 行内确认 → Enter 删掉那一个还原点', (WidgetTester tester) async {
    await pumpPage(tester);
    final FocusDriver driver = FocusDriver(tester);
    final bool reached = await driver.focusWidget(
      find.byKey(ValueKey<String>('restore-point-delete-${scheduled.id}')),
    );
    expect(reached, isTrue, reason: '「删除」必须能用键盘走到');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey<String>('restore-point-panel-${scheduled.id}')),
      findsOneWidget,
    );
    expect(find.text(t.restore_points_delete_body), findsOneWidget);
    expect(Directory(scheduled.directory).existsSync(), isTrue);

    // 确认键随面板出现就拿到焦点：Enter 即确认。
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(Directory(scheduled.directory).existsSync(), isFalse);
    expect(Directory(preUpdate.directory).existsSync(), isTrue);
    expect(find.text(t.restore_points_kind_scheduled), findsNothing);
    expect(find.text(t.restore_points_kind_pre_update), findsOneWidget);
  });

  testWidgets('没有还原点：显示空状态', (WidgetTester tester) async {
    Directory(
      p.join(tmp.path, kRestorePointsDirName),
    ).deleteSync(recursive: true);
    await pumpPage(tester);
    expect(find.text(t.restore_points_empty), findsOneWidget);
  });
}
