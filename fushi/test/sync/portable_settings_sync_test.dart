import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart'
    show backupContentRegistryPrefKeys;
import 'package:fushi/src/sync/settings_sync.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';

import 'fake_asset_store.dart';
import 'sync_orchestrator_test.dart' show FakeSyncBackend;

/// 反馈 AWp-0BtDDv：备份 / 同步可选包含全部可移植偏好设置。
///
/// 1. 排除清单（[PortableSettingsPolicy]）：凭据、设备本地、本机路径、窗口几何、
///    平台专属、外部工具连接、内容注册表、本库状态标记一律不可移植；普通设置可移植。
/// 2. 合并规则：每项按真实修改时刻严格 LWW，平局保留本机；没有「首次以远端为准」。
///    值没变的重写不刷新修改时刻（`FushiDatabase.setPref`），从没改过的默认值不会
///    凭「后开同步」压过别处真改过的设置。
/// 3. 编排器「同步设置」阶段：两台设备经同一资产存储往返，只搬可移植项。
FushiDatabase _memDb() => FushiDatabase.forTesting(NativeDatabase.memory());

/// 以指定时刻写一行（只用于空行或更晚的时刻，[FushiDatabase.setPrefIfNewer]）。
Future<void> _setPrefAt(FushiDatabase db, String key, String v, int t) async {
  final bool wrote = await db.setPrefIfNewer(key, v, updatedAt: t);
  expect(wrote, isTrue, reason: '测试前置：$key 应以时刻 $t 落盘');
}

void main() {
  group('PortableSettingsPolicy 排除清单', () {
    // 每一条都写明它为什么不能跨设备：清单本身就是这份测试。
    const Map<String, String> nonPortable = <String, String>{
      // 凭据 / 设备本地（PrefRedactionPolicy + deviceLocalPrefKeys）
      'sync_webdav_password': 'credential',
      'yomitan_api_key': 'credential',
      'qb_connection_config': 'external tool connection with password',
      'sync_device_id': 'device identity',
      'sync_settings_enabled': 'the settings-sync switch itself',
      'backup_merge_import_settings': 'device behaviour of backup import',
      // 本库状态标记 / 界面布局（ProfileKeys）
      'prefs_version': 'database change counter',
      'first_time_setup': 'install state',
      'active_profile_id': 'local autoincrement id',
      'app_ui_scale': 'per-screen layout',
      'app_locale': 'per-device language',
      'current_home_tab_index': 'UI state',
      // 本机路径
      'download_save_root': 'local path',
      'video_screenshot_directory': 'local path',
      'app_icon_custom_path': 'local path',
      'data_root': 'local data directory',
      // 窗口 / 平台专属
      'desktop_main_window_width': 'window geometry',
      'floating_lyric_window_rect': 'window geometry',
      'gal_hook_text_font_size': 'Windows-only galgame hook',
      // 外部工具 / 服务连接
      'qb_url': 'qBittorrent address',
      'download_execution_host': 'remote host',
      'music_subsonic_servers': 'server list with credentials',
      // 内容注册表（自己的同步通道，值里是本机路径）
      'local_audio_dbs': 'content registry',
      'src:reader_fushi:font_catalog': 'font files on this device',
      'favorite_sentences': 'content',
      // 按条目的内容状态
      'audiobook_pos_book1': 'reading progress',
      'src:reader_fushi:override_title://fushi://book/abc': 'book rename',
    };
    for (final MapEntry<String, String> e in nonPortable.entries) {
      test('不可移植：${e.key}（${e.value}）', () {
        expect(
          PortableSettingsPolicy.isPortable(e.key),
          isFalse,
          reason: '${e.key} 不能跨设备：${e.value}',
        );
        expect(PortableSettingsPolicy.exclusionReason(e.key), isNotNull);
      });
    }

    test('内容注册表整份清单都被排除', () {
      for (final String k in backupContentRegistryPrefKeys) {
        expect(PortableSettingsPolicy.isPortable(k), isFalse, reason: k);
      }
    });

    test('普通偏好设置可移植（切词匹配，不做子串误伤）', () {
      for (final String k in <String>[
        'theme_follow_app_icon',
        'selected_custom_theme_id',
        'custom_themes',
        'hover_lookup_modifier',
        'lookup_library_sentences',
        'theme_tint_app_logo',
        'reader_settings_panel_side',
        'invert_swipe_direction',
        'manga_reading_direction',
        // `export` 不命中 `port`、`portrait` 也不命中：按词比较而不是子串。
        'srs_export_card_order',
        'reader_portrait_columns',
      ]) {
        expect(
          PortableSettingsPolicy.exclusionReason(k),
          isNull,
          reason: '$k 是普通设置，应可移植',
        );
      }
    });

    test('对端快照里的不可移植项读入时被丢弃（不因对端发了就收）', () {
      final SettingsSnapshot s = SettingsSnapshot.fromJson(<String, Object?>{
        'format': SettingsSnapshot.format,
        'version': 1,
        'deviceId': 'peer',
        'entries': <String, Object?>{
          'custom_themes': <String, Object?>{'v': 's:[]', 't': 5},
          'download_save_root': <String, Object?>{'v': 's:/x', 't': 5},
          'sync_webdav_password': <String, Object?>{'v': 's:pw', 't': 5},
        },
      });
      expect(s.entries.keys, <String>['custom_themes']);
    });
  });

  group('合并规则', () {
    const PortableSettingValue old = PortableSettingValue('s:old', 100);
    const PortableSettingValue newer = PortableSettingValue('s:new', 200);

    test('LWW：远端严格更新才采纳，平局 / 本机更新保留本机，本机缺项采纳', () {
      final Map<String, PortableSettingValue> adopt = settingsToAdopt(
        local: <String, PortableSettingValue>{
          'custom_themes': old,
          'hover_lookup_modifier': newer,
          'reader_settings_panel_side': const PortableSettingValue('s:a', 300),
        },
        remote: <String, PortableSettingValue>{
          'custom_themes': newer,
          'hover_lookup_modifier': old,
          'reader_settings_panel_side': const PortableSettingValue('s:b', 300),
          'theme_tint_app_logo': const PortableSettingValue('s:v', 0),
        },
      );
      expect(adopt.keys.toSet(), <String>{
        'custom_themes',
        'theme_tint_app_logo',
      });
    });

    test('没有「远端整批为准」：远端更旧的值不覆盖本机', () {
      final Map<String, PortableSettingValue> adopt = settingsToAdopt(
        local: <String, PortableSettingValue>{'custom_themes': newer},
        remote: <String, PortableSettingValue>{'custom_themes': old},
      );
      expect(adopt, isEmpty);
    });

    test('多份对端快照按 key 取最新，与折叠顺序无关', () {
      const SettingsSnapshot a = SettingsSnapshot(
        deviceId: 'a',
        entries: <String, PortableSettingValue>{'custom_themes': old},
      );
      const SettingsSnapshot b = SettingsSnapshot(
        deviceId: 'b',
        entries: <String, PortableSettingValue>{'custom_themes': newer},
      );
      expect(
        foldSettingsSnapshots(<SettingsSnapshot>[a, b])['custom_themes'],
        newer,
      );
      expect(
        foldSettingsSnapshots(<SettingsSnapshot>[b, a])['custom_themes'],
        newer,
      );
    });
  });

  group('修改时刻只记真实修改（值没变的重写不刷新 updated_at）', () {
    late FushiDatabase db;
    setUp(() {
      db = _memDb();
      addTearDown(db.close);
    });

    test('setPref：同值重写保留时刻，改值才前进', () async {
      await _setPrefAt(db, 'custom_themes', 's:default', 500);
      await db.setPref('custom_themes', 's:default');
      expect(await db.getPrefUpdatedAt('custom_themes'), 500);
      await db.setPref('custom_themes', 's:custom');
      expect(await db.getPref('custom_themes'), 's:custom');
      expect(await db.getPrefUpdatedAt('custom_themes'), greaterThan(500));
    });

    test('setPrefs：一组里值没变的键保留时刻，变了的键与新键取 now', () async {
      await _setPrefAt(db, 'custom_themes', 's:a', 500);
      await _setPrefAt(db, 'hover_lookup_modifier', 's:alt', 500);
      await db.setPrefs(<String, String>{
        'custom_themes': 's:a',
        'hover_lookup_modifier': 's:ctrl',
        'theme_tint_app_logo': 'b:1',
      });
      expect(await db.getPrefUpdatedAt('custom_themes'), 500);
      expect(
        await db.getPrefUpdatedAt('hover_lookup_modifier'),
        greaterThan(500),
      );
      expect(
        await db.getPrefUpdatedAt('theme_tint_app_logo'),
        greaterThan(500),
      );
      expect(await db.getPref('hover_lookup_modifier'), 's:ctrl');
    });

    test('compareAndSetPref：同值不刷新时刻', () async {
      await _setPrefAt(db, 'custom_themes', 's:a', 500);
      expect(
        await db.compareAndSetPref(
          'custom_themes',
          expectedValue: 's:a',
          newValue: 's:a',
        ),
        isTrue,
      );
      expect(await db.getPrefUpdatedAt('custom_themes'), 500);
    });
  });

  group('编排器「同步设置」阶段（两台设备共用一个云）', () {
    late Directory work;
    late FakeAssetStore store;
    late FushiDatabase dbA;
    late FushiDatabase dbB;

    SyncOrchestrator orch(FushiDatabase db, String id) => SyncOrchestrator(
      db: db,
      backend: FakeSyncBackend(store),
      dictionaryResourceRoot: work,
      audioDatabaseRoot: work,
      tempDir: work,
      deviceId: id,
      syncStats: false,
      syncSettings: true,
      syncAudioBookPosition: false,
      syncContent: false,
      syncMangaContent: false,
      syncAudioBookFiles: false,
      syncDictionary: false,
    );

    setUp(() async {
      work = await Directory.systemTemp.createTemp('settings_sync_');
      store = FakeAssetStore();
      dbA = _memDb();
      dbB = _memDb();
      addTearDown(() async {
        await dbA.close();
        await dbB.close();
        await work.delete(recursive: true);
      });
    });

    test('新设备先开同步：它没改过的默认值不覆盖老设备的自定义值，关掉再开也不重演', () async {
      // 新设备 B：一行默认值落于 500（装机时），随后被 Profile 套用 / 设置页整组保存
      // 以同一个值重写——这不是修改，时刻不得刷新成「现在」。
      await _setPrefAt(dbB, 'custom_themes', 's:B-default', 500);
      await dbB.setPref('custom_themes', 's:B-default');
      // 老设备 A：用户真改过的设置（1000，晚于 B 的默认值落盘）。
      await _setPrefAt(dbA, 'custom_themes', 's:A-custom', 1000);

      // B 先开同步（云上还没有任何对端快照）→ 发出自己的默认值。
      await SyncRepository(dbB).setSettingsSyncEnabled(true);
      final SyncRunReport rb = SyncRunReport();
      await orch(dbB, 'devB').syncPortableSettingsForTest(rb);
      expect(rb.errors, isEmpty);

      // A 随后开同步：自定义值必须保留。
      await SyncRepository(dbA).setSettingsSyncEnabled(true);
      final SyncRunReport ra = SyncRunReport();
      await orch(dbA, 'devA').syncPortableSettingsForTest(ra);
      expect(ra.errors, isEmpty);
      expect(ra.settingsImported, 0);
      expect(
        await dbA.getPref('custom_themes'),
        's:A-custom',
        reason: '新设备没改过的默认值不能盖掉老设备真改过的设置',
      );

      // B 下一轮收敛到 A 的自定义值。
      await orch(dbB, 'devB').syncPortableSettingsForTest(SyncRunReport());
      expect(await dbB.getPref('custom_themes'), 's:A-custom');

      // A 关掉再开：不重演，值不动。
      await SyncRepository(dbA).setSettingsSyncEnabled(false);
      await SyncRepository(dbA).setSettingsSyncEnabled(true);
      final SyncRunReport ra2 = SyncRunReport();
      await orch(dbA, 'devA').syncPortableSettingsForTest(ra2);
      expect(ra2.settingsImported, 0);
      expect(await dbA.getPref('custom_themes'), 's:A-custom');
    });

    test('A 发布 → B 采纳可移植项、不碰不可移植项；之后按时刻双向 LWW', () async {
      await _setPrefAt(dbA, 'custom_themes', 's:A-themes', 1000);
      await _setPrefAt(dbA, 'hover_lookup_modifier', 's:alt', 1000);
      await _setPrefAt(dbA, 'download_save_root', 's:/a/downloads', 1000);
      await _setPrefAt(dbA, 'app_ui_scale', 'd:1.5', 1000);
      // B 的默认值落盘早于 A 的修改；本机路径时刻再晚也不跨设备。
      await _setPrefAt(dbB, 'custom_themes', 's:B-default', 500);
      await _setPrefAt(dbB, 'download_save_root', 's:/b/downloads', 5000);

      final SyncRunReport ra = SyncRunReport();
      await orch(dbA, 'devA').syncPortableSettingsForTest(ra);
      expect(ra.errors, isEmpty);
      expect(ra.settingsImported, 0);

      final SyncRunReport rb = SyncRunReport();
      await orch(dbB, 'devB').syncPortableSettingsForTest(rb);
      expect(rb.errors, isEmpty);
      expect(rb.settingsImported, 2);
      expect(await dbB.getPref('custom_themes'), 's:A-themes');
      expect(await dbB.getPref('hover_lookup_modifier'), 's:alt');
      expect(
        await dbB.getPref('download_save_root'),
        's:/b/downloads',
        reason: '本机路径不可移植，绝不被别的设备覆盖',
      );
      expect(await dbB.getPref('app_ui_scale'), isNull);

      // 对齐之后：B 改一项（更新的时刻）→ A 下一轮采纳；A 上更旧的值不回盖。
      await _setPrefAt(dbB, 'hover_lookup_modifier', 's:ctrl', 9000);
      await orch(dbB, 'devB').syncPortableSettingsForTest(SyncRunReport());
      final SyncRunReport ra2 = SyncRunReport();
      await orch(dbA, 'devA').syncPortableSettingsForTest(ra2);
      expect(ra2.settingsImported, 1);
      expect(await dbA.getPref('hover_lookup_modifier'), 's:ctrl');
      expect(await dbA.getPref('download_save_root'), 's:/a/downloads');

      // 再跑一轮：没有变化就不再写（幂等）。
      final SyncRunReport ra3 = SyncRunReport();
      await orch(dbA, 'devA').syncPortableSettingsForTest(ra3);
      expect(ra3.settingsImported, 0);
    });

    test('快照文件里不含任何不可移植项（凭据 / 路径不出境）', () async {
      await _setPrefAt(dbA, 'custom_themes', 's:t', 10);
      await _setPrefAt(dbA, 'sync_webdav_password', 's:secret', 10);
      await _setPrefAt(dbA, 'download_save_root', 's:/a', 10);
      await orch(dbA, 'devA').syncPortableSettingsForTest(SyncRunReport());
      final FakeSyncBackend probe = FakeSyncBackend(store);
      final String ns = await probe.ensureNamespace(kSyncSettingsNamespace);
      final AssetEntry? own = await probe.findAsset(
        ns,
        settingsSnapshotNameFor('devA'),
      );
      expect(own, isNotNull);
      // 看的是落在云上的原始文件，不是解析后（解析会再过滤一遍）的结果。
      final Object? rawJson = await probe.getJsonAsset(own!.id);
      final String raw = jsonEncode(rawJson);
      expect(raw.contains('custom_themes'), isTrue);
      expect(raw.contains('secret'), isFalse);
      expect(raw.contains('sync_webdav_password'), isFalse);
      expect(raw.contains('download_save_root'), isFalse);
    });
  });
}
