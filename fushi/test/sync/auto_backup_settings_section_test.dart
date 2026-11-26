import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show buildFushiFallbackTheme;
import 'package:fushi/src/models/preference_keys.dart'
    show kAutoBackupServerPrefKey, kKnownPreferenceKeys;
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/storage/storage_usage_service.dart'
    show formatStorageBytes;
import 'package:fushi/src/sync/auto_backup/auto_backup_controller.dart'
    show AutoBackupBusyException;
import 'package:fushi/src/sync/auto_backup/auto_backup_messages.dart';
import 'package:fushi/src/sync/auto_backup/auto_backup_settings.dart';
import 'package:fushi/src/sync/auto_backup/auto_backup_status.dart';
import 'package:fushi/src/sync/auto_backup/backup_folder_mirror.dart';
import 'package:fushi/src/sync/backup_service.dart' show BackupCategory;
import 'package:fushi/src/sync/sync_repository.dart' show SyncRepository;
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show
        AutoBackupCloudRow,
        AutoBackupServerRow,
        autoBackupCloudStatusLine,
        autoBackupMeteredRowVisible,
        autoBackupServerStatusLine,
        autoBackupIntervalLabel,
        autoBackupMirrorStatusLine,
        autoBackupStatusLine,
        buildSyncBackupDestination;
import 'package:fushi/src/utils/components/settings_shared.dart'
    show AdaptiveSettingsSwitchRow;

/// 「复制到云端」那一行的测试台：设置在内存里，改设置即重建。
class _CloudRowHarness {
  _CloudRowHarness({
    required this.label,
    this.mobile = false,
    this.server = false,
    AutoBackupSettings settings = const AutoBackupSettings(),
    AutoBackupStatus status = const AutoBackupStatus(),
  }) : settings = ValueNotifier<AutoBackupSettings>(settings),
       status = ValueNotifier<AutoBackupStatus>(status);

  final String? label;

  /// 假扮移动端（可能走计费网络）。
  final bool mobile;

  /// 测「复制到服务器」那一行（[AutoBackupServerRow]）而不是云端。
  final bool server;
  final ValueNotifier<AutoBackupSettings> settings;
  final ValueNotifier<AutoBackupStatus> status;

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildFushiFallbackTheme(Brightness.light),
          home: Material(
            child: SingleChildScrollView(
              child: ValueListenableBuilder<AutoBackupSettings>(
                valueListenable: settings,
                builder:
                    (
                      BuildContext context,
                      AutoBackupSettings value,
                      Widget? _,
                    ) => server
                    ? AutoBackupServerRow(
                        settings: value,
                        statusChanges: status,
                        readStatus: () => status.value,
                        meteredNetworks: mobile,
                        backendLabel: () async => label,
                        onUpdate:
                            (
                              AutoBackupSettings Function(AutoBackupSettings)
                              update,
                            ) async => settings.value = update(settings.value),
                      )
                    : AutoBackupCloudRow(
                        settings: value,
                        statusChanges: status,
                        readStatus: () => status.value,
                        meteredNetworks: mobile,
                        backendLabel: () async => label,
                        onUpdate:
                            (
                              AutoBackupSettings Function(AutoBackupSettings)
                              update,
                            ) async => settings.value = update(settings.value),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

AdaptiveSettingsSwitchRow _switchRow(WidgetTester tester, String key) =>
    tester.widget<AdaptiveSettingsSwitchRow>(find.byKey(ValueKey<String>(key)));

/// 设置 › 同步与备份 ›「自动备份」：缺省值（D1 默认开、每日、小集合；D2 复习媒体默认不带）、
/// 偏好往返、状态行文案。
void main() {
  test('空偏好：每日、不指定时间、默认小集合、不带复习媒体、默认目录', () {
    final AutoBackupSettings s = readAutoBackupSettings((String _) => null);
    expect(s.interval, AutoBackupInterval.daily);
    expect(s.enabled, isTrue);
    expect(s.preferredMinuteOfDay, isNull);
    // 整库 + 挑文件（用户 2026-11-25）：数据恒在，文件默认只带字体。
    expect(s.categories, <BackupCategory>{BackupCategory.fonts});
    expect(s.includeSrsMedia, isFalse);
    expect(s.customFolder, isNull);
    expect(s.effectiveFolder(supportsCustomFolder: true), isNull);
  });

  test('写入再读回：间隔、时间、类别、复习媒体、文件夹原样往返', () async {
    final Map<String, Object?> prefs = <String, Object?>{};
    const AutoBackupSettings written = AutoBackupSettings(
      interval: AutoBackupInterval.every3Days,
      preferredMinuteOfDay: 3 * 60 + 30,
      categories: <BackupCategory>{
        BackupCategory.books,
        BackupCategory.dictionary,
      },
      includeSrsMedia: true,
      customFolder: '/backups/fushi',
    );
    await writeAutoBackupSettings(
      (Map<String, dynamic> values) async => prefs.addAll(values),
      written,
    );
    final AutoBackupSettings read = readAutoBackupSettings(
      (String key) => prefs[key],
    );
    expect(read, written);
    expect(read.categories, written.categories);
    expect(read.includeSrsMedia, isTrue);
    expect(read.effectiveFolder(supportsCustomFolder: false), isNull);

    // 清掉时间与文件夹（「任意时间」/「改回默认」）也能往返。
    await writeAutoBackupSettings(
      (Map<String, dynamic> values) async => prefs.addAll(values),
      read.copyWith(
        interval: AutoBackupInterval.off,
        preferredMinuteOfDay: () => null,
        customFolder: () => null,
      ),
    );
    final AutoBackupSettings cleared = readAutoBackupSettings(
      (String key) => prefs[key],
    );
    expect(cleared.interval, AutoBackupInterval.off);
    expect(cleared.enabled, isFalse);
    expect(cleared.preferredMinuteOfDay, isNull);
    expect(cleared.customFolder, isNull);
  });

  test('写入只落文件类别：数据类别不进偏好', () async {
    final Map<String, Object?> prefs = <String, Object?>{};
    await writeAutoBackupSettings(
      (Map<String, dynamic> values) async => prefs.addAll(values),
      const AutoBackupSettings(
        categories: <BackupCategory>{
          BackupCategory.fonts,
          BackupCategory.statistics,
        },
      ),
    );
    expect(
      readAutoBackupSettings((String key) => prefs[key]).categories,
      <BackupCategory>{BackupCategory.fonts},
    );
  });

  test('错误码换成本地化文案，其余原样', () {
    expect(
      autoBackupErrorText(kAutoBackupErrorInterrupted),
      t.auto_backup_error_interrupted,
    );
    expect(
      autoBackupErrorText(kAutoBackupErrorFolderUnavailable),
      t.auto_backup_error_folder_unavailable,
    );
    expect(autoBackupErrorText('disk full'), 'disk full');
    expect(autoBackupErrorText(null), '');
  });

  test('副本错误码（第三期）都有本地化文案；异常先归成错误码，平台原文不上界面', () {
    final Map<String, String> expected = <String, String>{
      kBackupMirrorErrorNotFound: t.auto_backup_error_copy_not_found,
      kBackupMirrorErrorLocalIo: t.auto_backup_error_copy_local_io,
      kBackupMirrorErrorUnsupported: t.auto_backup_error_copy_unsupported,
      kBackupMirrorErrorRenamed: t.auto_backup_error_copy_renamed,
      kBackupMirrorErrorLoading: t.auto_backup_error_copy_loading,
      kBackupMirrorErrorFailed: t.auto_backup_error_copy_failed,
      kBackupMirrorErrorCloudAuth: t.auto_backup_error_cloud_auth,
      kBackupMirrorErrorCloudUnreachable: t.auto_backup_error_cloud_unreachable,
      kBackupMirrorErrorCloudQuota: t.auto_backup_error_cloud_quota,
      kBackupMirrorErrorCloudFailed: t.auto_backup_error_cloud_failed,
    };
    for (final MapEntry<String, String> e in expected.entries) {
      expect(autoBackupErrorText(e.key), e.value, reason: e.key);
      expect(e.value, isNot(e.key), reason: '${e.key} must not show raw');
    }
    expect(
      autoBackupErrorText(
        const BackupMirrorException(kBackupMirrorErrorCloudQuota),
      ),
      t.auto_backup_error_cloud_quota,
    );
    expect(
      autoBackupErrorText(const BackupFolderUnavailableException('revoked')),
      t.auto_backup_error_folder_unavailable,
    );
    expect(
      autoBackupErrorText(const AutoBackupBusyException()),
      t.auto_backup_now_busy,
    );
    final String picked = autoBackupErrorText(
      PlatformException(code: 'pick_failed', message: 'content://secret/tree'),
    );
    expect(picked, t.auto_backup_error_copy_failed);
    expect(picked, isNot(contains('content://')));
  });

  test('每个间隔都有自己的文案', () {
    final Set<String> labels = <String>{
      for (final AutoBackupInterval v in AutoBackupInterval.values)
        autoBackupIntervalLabel(v),
    };
    expect(labels, hasLength(AutoBackupInterval.values.length));
  });

  test('状态行：没备份过 →「还没有备份」；有 → 时间 · 大小 · 保留份数', () {
    final DateTime now = DateTime(2026, 11, 25, 15);
    expect(
      autoBackupStatusLine(
        status: const AutoBackupStatus(),
        keptCount: 0,
        now: now,
      ),
      t.auto_backup_status_none,
    );
    final String line = autoBackupStatusLine(
      status: AutoBackupStatus(
        lastSuccessMs: now
            .subtract(const Duration(hours: 3))
            .millisecondsSinceEpoch,
        lastSuccessBytes: 412 * 1024 * 1024,
      ),
      keptCount: 14,
      now: now,
    );
    expect(line, contains(formatStorageBytes(412 * 1024 * 1024)));
    expect(line, contains('14'));
    expect(line, contains(t.activity_hours_ago(n: 3)));
  });

  test('用户文件夹（第三期）：句柄与显示名往返，只在支持的平台生效，停止复制清掉', () async {
    final Map<String, Object?> prefs = <String, Object?>{};
    const AutoBackupMirrorFolder folder = AutoBackupMirrorFolder(
      handle:
          'content://com.android.externalstorage.documents/tree/primary%3ABackups',
      label: 'Backups',
    );
    await writeAutoBackupSettings(
      (Map<String, dynamic> values) async => prefs.addAll(values),
      const AutoBackupSettings(mirrorFolder: folder),
    );
    final AutoBackupSettings read = readAutoBackupSettings(
      (String key) => prefs[key],
    );
    expect(read.mirrorFolder, folder);
    expect(read.effectiveMirrorFolder(supportsMirrorFolder: true), folder);
    expect(read.effectiveMirrorFolder(supportsMirrorFolder: false), isNull);
    // 换文件夹 = 设置不同（存设置后会补复制进新文件夹）。
    expect(
      read ==
          read.copyWith(
            mirrorFolder: () =>
                const AutoBackupMirrorFolder(handle: 'other', label: 'Backups'),
          ),
      isFalse,
    );
    await writeAutoBackupSettings(
      (Map<String, dynamic> values) async => prefs.addAll(values),
      read.copyWith(mirrorFolder: () => null),
    );
    expect(
      readAutoBackupSettings((String key) => prefs[key]).mirrorFolder,
      isNull,
    );
    // 不把书签 / URI 原文写进状态文件：只用短标识。
    expect(folder.key, hasLength(16));
    expect(folder.key, isNot(contains('content')));
  });

  test('用户文件夹状态行：没备份 → 不显示；已复制 / 待复制 / 失败', () {
    final DateTime now = DateTime(2026, 11, 25, 15);
    const AutoBackupMirrorFolder folder = AutoBackupMirrorFolder(
      handle: 'h',
      label: 'Backups',
    );
    expect(
      autoBackupMirrorStatusLine(
        status: const AutoBackupStatus(),
        folder: folder,
        now: now,
      ),
      isNull,
    );
    final AutoBackupStatus base = AutoBackupStatus(
      lastSuccessPointId: 'p1',
      lastSuccessMs: now.millisecondsSinceEpoch,
    );
    expect(
      autoBackupMirrorStatusLine(status: base, folder: folder, now: now)!.text,
      t.auto_backup_mirror_status_pending,
    );
    final AutoBackupStatus copied = base.withMirror(
      const AutoBackupMirrorStatus().succeeded(
        folderKey: folder.key,
        id: 'p1',
        atMs: now.subtract(const Duration(hours: 2)).millisecondsSinceEpoch,
      ),
    );
    final ({String text, bool failed}) done = autoBackupMirrorStatusLine(
      status: copied,
      folder: folder,
      now: now,
    )!;
    expect(done.failed, isFalse);
    expect(done.text, contains(t.activity_hours_ago(n: 2)));
    // 复制状态是另一个文件夹的：当作还没复制。
    expect(
      autoBackupMirrorStatusLine(
        status: copied,
        folder: const AutoBackupMirrorFolder(handle: 'x', label: 'X'),
        now: now,
      )!.text,
      t.auto_backup_mirror_status_pending,
    );
    final ({String text, bool failed}) failed = autoBackupMirrorStatusLine(
      status: copied.withMirror(
        copied.mirror.failed(
          folderKey: folder.key,
          error: kAutoBackupErrorFolderUnavailable,
          atMs: now.millisecondsSinceEpoch,
        ),
      ),
      folder: folder,
      now: now,
    )!;
    expect(failed.failed, isTrue);
    expect(
      failed.text,
      t.auto_backup_mirror_failed(
        reason: autoBackupErrorText(kAutoBackupErrorFolderUnavailable),
      ),
    );
    // 复制状态随状态文件往返，其它状态转换不丢它。
    final AutoBackupStatus roundTrip = AutoBackupStatus.fromJson(
      copied.toJson(),
    ).skipped(atMs: now.millisecondsSinceEpoch);
    expect(roundTrip.mirror.holds(folder.key, 'p1'), isTrue);
  });

  test('云端状态行：没备份 → 不显示；已上传 / 待上传（含等 Wi-Fi）/ 失败', () {
    final DateTime now = DateTime(2026, 11, 25, 15);
    expect(
      autoBackupCloudStatusLine(
        status: const AutoBackupStatus(),
        now: now,
        wifiOnly: false,
      ),
      isNull,
    );
    final AutoBackupStatus base = AutoBackupStatus(
      lastSuccessPointId: 'p1',
      lastSuccessMs: now.millisecondsSinceEpoch,
    );
    expect(
      autoBackupCloudStatusLine(status: base, now: now, wifiOnly: false)!.text,
      t.auto_backup_cloud_status_pending,
    );
    expect(
      autoBackupCloudStatusLine(status: base, now: now, wifiOnly: true)!.text,
      t.auto_backup_cloud_status_pending_wifi,
    );
    final AutoBackupStatus uploaded = base.withCloud(
      const AutoBackupMirrorStatus().succeeded(
        folderKey: 'cloud-googleDrive',
        id: 'p1',
        atMs: now.subtract(const Duration(hours: 2)).millisecondsSinceEpoch,
      ),
    );
    final ({String text, bool failed}) done = autoBackupCloudStatusLine(
      status: uploaded,
      now: now,
      wifiOnly: true,
    )!;
    expect(done.failed, isFalse);
    expect(done.text, contains(t.activity_hours_ago(n: 2)));
    // 上传过的是更早那份：最新这份还在等。
    expect(
      autoBackupCloudStatusLine(
        status: AutoBackupStatus(
          lastSuccessPointId: 'p2',
          lastSuccessMs: now.millisecondsSinceEpoch,
          cloud: uploaded.cloud,
        ),
        now: now,
        wifiOnly: false,
      )!.text,
      t.auto_backup_cloud_status_pending,
    );
    final ({String text, bool failed}) failed = autoBackupCloudStatusLine(
      status: uploaded.withCloud(
        uploaded.cloud.failed(
          folderKey: 'cloud-googleDrive',
          error: kBackupMirrorErrorCloudAuth,
          atMs: now.millisecondsSinceEpoch,
        ),
      ),
      now: now,
      wifiOnly: false,
    )!;
    expect(failed.failed, isTrue);
    expect(
      failed.text,
      t.auto_backup_cloud_failed(reason: t.auto_backup_error_cloud_auth),
    );
  });

  test('「复制到云端」排在文件夹之后，可见性与其它自动备份行同一判据（间隔为「关」时隐藏）', () {
    final List<SettingsItem> items = buildSyncBackupDestination().sections
        .expand((SettingsSection section) => section.items)
        .toList();
    final int folder = items.indexWhere(
      (SettingsItem i) => i.id == 'sync.auto_backup.folder',
    );
    final int cloud = items.indexWhere(
      (SettingsItem i) => i.id == 'sync.auto_backup.cloud',
    );
    expect(folder, isNonNegative);
    expect(cloud, folder + 1);
    expect(items[cloud].visible, isNotNull);
    expect(items[cloud].visible == items[folder].visible, isTrue);
  });

  group('「复制到云端」那一行', () {
    testWidgets('没有支持的同步后端：开关不可用，提示先去同步设置配置', (WidgetTester tester) async {
      final _CloudRowHarness h = _CloudRowHarness(label: null);
      await h.pump(tester);
      expect(_switchRow(tester, 'auto-backup-cloud').onChanged, isNull);
      expect(_switchRow(tester, 'auto-backup-cloud').value, isFalse);
      expect(
        find.byKey(const ValueKey<String>('auto-backup-cloud-no-backend')),
        findsOneWidget,
      );
      expect(find.text(t.auto_backup_cloud_no_service), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('auto-backup-cloud-retention')),
        findsNothing,
      );
    });

    testWidgets('后端被移除但开关还开着：仍可关掉', (WidgetTester tester) async {
      final _CloudRowHarness h = _CloudRowHarness(
        label: null,
        settings: const AutoBackupSettings(cloudCopies: true),
      );
      await h.pump(tester);
      _switchRow(tester, 'auto-backup-cloud').onChanged!(false);
      await tester.pumpAndSettle();
      expect(h.settings.value.cloudCopies, isFalse);
    });

    testWidgets('有后端：副标题写服务名，打开后出保留规则说明；桌面端没有移动数据开关', (
      WidgetTester tester,
    ) async {
      final _CloudRowHarness h = _CloudRowHarness(label: 'Google Drive');
      await h.pump(tester);
      expect(
        find.text(t.auto_backup_cloud_service(service: 'Google Drive')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('auto-backup-cloud-no-backend')),
        findsNothing,
      );
      _switchRow(tester, 'auto-backup-cloud').onChanged!(true);
      await tester.pumpAndSettle();
      expect(h.settings.value.cloudCopies, isTrue);
      expect(find.text(t.auto_backup_cloud_retention_hint), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('auto-backup-cloud-metered')),
        findsNothing,
      );
    });

    testWidgets('移动端：状态行按共用的「也用移动数据上传」说明要不要等 Wi-Fi（开关本身是单独一行）', (
      WidgetTester tester,
    ) async {
      final _CloudRowHarness h = _CloudRowHarness(
        label: 'WebDAV',
        mobile: true,
        settings: const AutoBackupSettings(cloudCopies: true),
        status: AutoBackupStatus(
          lastSuccessPointId: 'p1',
          lastSuccessMs: DateTime(2026, 11, 25).millisecondsSinceEpoch,
        ),
      );
      await h.pump(tester);
      // 「也用移动数据上传」与服务器副本共用，是单独一行（sync.auto_backup.metered），不在这一行里。
      expect(
        find.byKey(const ValueKey<String>('auto-backup-cloud-metered')),
        findsNothing,
      );
      expect(
        find.text(t.auto_backup_cloud_status_pending_wifi),
        findsOneWidget,
      );
      h.settings.value = h.settings.value.copyWith(cloudAllowMetered: true);
      await tester.pumpAndSettle();
      expect(find.text(t.auto_backup_cloud_status_pending), findsOneWidget);
    });

    testWidgets('修剪旧副本失败：多一行提示，修剪成功后消失', (WidgetTester tester) async {
      final _CloudRowHarness h = _CloudRowHarness(
        label: 'Dropbox',
        settings: const AutoBackupSettings(cloudCopies: true),
        status: const AutoBackupStatus(
          lastSuccessPointId: 'p1',
          lastSuccessMs: 1,
          cloud: AutoBackupMirrorStatus(
            target: 'cloud-dropbox',
            pointId: 'p1',
            atMs: 1,
            pruneError: kBackupMirrorErrorCloudFailed,
            pruneErrorAtMs: 1,
          ),
        ),
      );
      await h.pump(tester);
      expect(
        find.byKey(const ValueKey<String>('auto-backup-cloud-status')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('auto-backup-cloud-prune')),
        findsOneWidget,
      );
      expect(find.text(t.auto_backup_copies_prune_failed), findsOneWidget);
      h.status.value = const AutoBackupStatus(
        lastSuccessPointId: 'p1',
        lastSuccessMs: 1,
        cloud: AutoBackupMirrorStatus(
          target: 'cloud-dropbox',
          pointId: 'p1',
          atMs: 1,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('auto-backup-cloud-prune')),
        findsNothing,
      );
    });
  });

  group('「复制到服务器」（第四期 D12）', () {
    test('排在云端之后，可见性同一判据；共用的移动数据开关紧随其后', () {
      final List<SettingsItem> items = buildSyncBackupDestination().sections
          .expand((SettingsSection section) => section.items)
          .toList();
      int indexOf(String id) =>
          items.indexWhere((SettingsItem i) => i.id == id);
      final int cloud = indexOf('sync.auto_backup.cloud');
      final int server = indexOf('sync.auto_backup.server');
      final int metered = indexOf('sync.auto_backup.metered');
      expect(server, cloud + 1);
      expect(metered, server + 1);
      expect(items[server].visible == items[cloud].visible, isTrue);
      expect(items[metered].visible, isNotNull);
    });

    test('移动数据开关：自动备份开着、云端或服务器至少开了一个才出现', () {
      const AutoBackupSettings base = AutoBackupSettings();
      expect(autoBackupMeteredRowVisible(base), isFalse);
      expect(
        autoBackupMeteredRowVisible(base.copyWith(cloudCopies: true)),
        isTrue,
      );
      expect(
        autoBackupMeteredRowVisible(base.copyWith(serverCopies: true)),
        isTrue,
      );
      expect(
        autoBackupMeteredRowVisible(
          base.copyWith(serverCopies: true, interval: AutoBackupInterval.off),
        ),
        isFalse,
      );
    });

    test('偏好往返：auto_backup_server 设备本地，默认关', () async {
      expect(const AutoBackupSettings().serverCopies, isFalse);
      final Map<String, dynamic> prefs = <String, dynamic>{};
      await writeAutoBackupSettings(
        (Map<String, dynamic> values) async => prefs.addAll(values),
        const AutoBackupSettings(serverCopies: true),
      );
      expect(prefs[kAutoBackupServerPrefKey], isTrue);
      expect(
        readAutoBackupSettings((String k) => prefs[k]).serverCopies,
        isTrue,
      );
      expect(
        SyncRepository.deviceLocalPrefKeys,
        contains('auto_backup_server'),
      );
      expect(kKnownPreferenceKeys, contains('auto_backup_server'));
    });

    testWidgets('没有互联服务器：开关不可用，提示先去同步设置', (WidgetTester tester) async {
      final _CloudRowHarness h = _CloudRowHarness(label: null, server: true);
      await h.pump(tester);
      expect(_switchRow(tester, 'auto-backup-server').onChanged, isNull);
      expect(find.text(t.auto_backup_server_no_server), findsOneWidget);
      expect(find.text(t.auto_backup_server_subtitle), findsOneWidget);
    });

    testWidgets('有服务器：副标题写服务器名，打开后出保留规则说明与状态行', (WidgetTester tester) async {
      final _CloudRowHarness h = _CloudRowHarness(
        label: 'Desk PC',
        server: true,
        mobile: true,
        status: const AutoBackupStatus(
          lastSuccessPointId: 'p1',
          lastSuccessMs: 1,
        ),
      );
      await h.pump(tester);
      expect(
        find.text(t.auto_backup_server_service(server: 'Desk PC')),
        findsOneWidget,
      );
      _switchRow(tester, 'auto-backup-server').onChanged!(true);
      await tester.pumpAndSettle();
      expect(h.settings.value.serverCopies, isTrue);
      expect(h.settings.value.cloudCopies, isFalse);
      expect(find.text(t.auto_backup_server_retention_hint), findsOneWidget);
      expect(
        find.text(t.auto_backup_server_status_pending_wifi),
        findsOneWidget,
      );
    });

    test('状态行：失败 / 已复制 / 待复制，只看服务器那份状态', () {
      final DateTime now = DateTime(2026, 11, 25, 12);
      const AutoBackupStatus base = AutoBackupStatus(
        lastSuccessPointId: 'p1',
        lastSuccessMs: 1,
      );
      expect(
        autoBackupServerStatusLine(
          status: base,
          now: now,
          wifiOnly: false,
        )!.text,
        t.auto_backup_server_status_pending,
      );
      final AutoBackupStatus copied = base.withServer(
        const AutoBackupMirrorStatus().succeeded(
          folderKey: 'server-abc',
          id: 'p1',
          atMs: 1,
          leftovers: const <String>[],
        ),
      );
      final ({String text, bool failed}) done = autoBackupServerStatusLine(
        status: copied,
        now: now,
        wifiOnly: false,
      )!;
      expect(done.failed, isFalse);
      expect(done.text, startsWith(t.auto_backup_server_status_done(time: '')));
      // 云端那份成功不算服务器的。
      expect(
        autoBackupCloudStatusLine(
          status: copied,
          now: now,
          wifiOnly: false,
        )!.text,
        t.auto_backup_cloud_status_pending,
      );
      final ({String text, bool failed}) failed = autoBackupServerStatusLine(
        status: copied.withServer(
          copied.server.failed(
            folderKey: 'server-abc',
            error: kBackupMirrorErrorCloudUnreachable,
            atMs: 2,
            leftovers: const <String>[],
          ),
        ),
        now: now,
        wifiOnly: false,
      )!;
      expect(failed.failed, isTrue);
      expect(
        failed.text,
        t.auto_backup_server_failed(
          reason: t.auto_backup_error_cloud_unreachable,
        ),
      );
    });
  });
}
