import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_schema_card_creation.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_settings_schema.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('isOAuthSyncBackend', () {
    test('true only for cloud OAuth backends (account/sign-in row)', () {
      expect(isOAuthSyncBackend(SyncBackendType.googleDrive), isTrue);
      expect(isOAuthSyncBackend(SyncBackendType.oneDrive), isTrue);
      expect(isOAuthSyncBackend(SyncBackendType.dropbox), isTrue);
      expect(isOAuthSyncBackend(SyncBackendType.webDav), isFalse);
      expect(isOAuthSyncBackend(SyncBackendType.ftp), isFalse);
      expect(isOAuthSyncBackend(SyncBackendType.sftp), isFalse);
      expect(isOAuthSyncBackend(SyncBackendType.hibikiServer), isFalse);
    });

    test('covers every backend type (no orphan after enum changes)', () {
      for (final SyncBackendType t in SyncBackendType.values) {
        // Must not throw for any value; pure total function.
        isOAuthSyncBackend(t);
      }
    });
  });

  group('buildSyncBackupDestination structure', () {
    late SettingsDestination dest;
    setUpAll(() => dest = buildSyncBackupDestination());

    List<String> idsOf(SettingsSection s) =>
        s.items.map((SettingsItem i) => i.id).toList();

    test(
        'regroups into four intent-based sections + a desktop data-storage tail',
        () {
      // 互联（client 配置 / LAN 发现 / host 模式）已拆到独立的
      // buildInterconnectDestination（见下方 group），同步分类剩：
      // method / content / actions / backup + 桌面 data-storage 尾巴。
      expect(dest.sections, hasLength(5));
      // The appended section is desktop-gated and carries only the data-root row.
      expect(dest.sections[4].visible, isNotNull,
          reason: 'data-storage section must be desktop-only gated');
      expect(idsOf(dest.sections[4]), <String>['sync.data_storage_location']);
    });

    test('group 1 (sync method) holds selector + scoped account/config', () {
      // BUG-1088：互联回到「同步方式」选择器；选中时显示一行指引（连接配置在
      // 「Hibiki 互联」分类），其余后端各自的凭据/配置行不变。
      expect(idsOf(dest.sections[0]), <String>[
        'sync.mode',
        'sync.account_status',
        'sync.google_drive_hoshi_compat',
        'sync.webdav_config',
        'sync.ftp_config',
        'sync.sftp_config',
        'sync.interconnect_config_note',
      ]);
    });

    test('selector is unconditional; account config is gated', () {
      final SettingsSection method = dest.sections[0];
      SettingsItem byId(String id) =>
          method.items.firstWhere((SettingsItem i) => i.id == id);
      expect(byId('sync.mode').visible, isNull);
      expect(byId('sync.account_status').visible, isNotNull);
      // Hoshi 兼容开关只在 Google Drive 后端可见（切换存储空间/scope）。
      expect(byId('sync.google_drive_hoshi_compat').visible, isNotNull);
    });

    test('content / actions / backup groups remain global', () {
      expect(idsOf(dest.sections[1]), <String>[
        'sync.auto_sync',
        'sync.statistics',
        'sync.dictionary',
        'sync.local_audio',
        'sync.content',
        'sync.audiobook_files',
        'sync.video_files',
        // 多端库联合视图（spec §2.1）：「显示远端条目」占位卡混排开关（纯显示偏好）。
        'sync.show_remote_entries',
      ]);
      expect(idsOf(dest.sections[2]), <String>[
        'sync.server_mode_note',
        'sync.sync_now',
        'sync.compare',
      ]);
      expect(idsOf(dest.sections[3]),
          <String>['sync.backup_export', 'sync.backup_import']);
    });

    test(
        'auto-sync and upload switches are gated; content-scope switches are not',
        () {
      // Auto-sync 与三个「上传X文件」开关都带可见性谓词（见下方 source guard 对
      // 谓词内容的锁定）；统计/词典/本地音频是 content-scope 设置，恒显。
      final SettingsSection content = dest.sections[1];
      SettingsItem byId(String id) =>
          content.items.firstWhere((SettingsItem i) => i.id == id);
      expect(byId('sync.auto_sync').visible, isNotNull,
          reason:
              'auto-sync hides when the sync method itself has no outbound');
      for (final String id in <String>[
        'sync.statistics',
        'sync.dictionary',
        'sync.local_audio',
      ]) {
        expect(byId(id).visible, isNull,
            reason: '$id is a content-scope setting, global to every backend');
      }
      for (final String id in <String>[
        'sync.content',
        'sync.audiobook_files',
        'sync.video_files',
      ]) {
        expect(byId(id).visible, isNotNull,
            reason: '$id is a cloud-channel upload switch, gated on backend');
      }
    });

    test(
        'upload switches hide only when the sync method is the interconnect '
        '(BUG-1088)', () {
      // Source guard: BUG-988 起互联通道读互联专属上传开关（互联分类里那四个），
      // 共享 sync.* 上传开关只管云通道——它们唯一的死区是「同步方式=互联」（该通道
      // 按互联专属开关走）。绝不能再按 _isHostingInterconnect 隐藏：host 身份不影响
      // 云后端出站，旧门控把 host 设备上 Google Drive 的上传开关整排藏掉（BUG-1088）。
      final String src =
          File('lib/src/sync/sync_settings_schema.dart').readAsStringSync();
      for (final String id in <String>[
        'sync.content',
        'sync.audiobook_files',
        'sync.video_files',
      ]) {
        final int at = src.indexOf("id: '$id'");
        expect(at, greaterThanOrEqualTo(0));
        final String block = src.substring(at, at + 500);
        expect(block, contains('!= SyncBackendType.hibikiServer'),
            reason: '$id governs the cloud channel; dead when method=互联');
        expect(block, isNot(contains('_isHostingInterconnect')),
            reason: '$id must not hide on host identity (BUG-1088)');
      }
    });

    test('auto-sync gate keys off cloud-outbound availability (BUG-1088)', () {
      // Source guard: auto_sync must hide via !_cloudOutboundUnavailable — the
      // combined "method is interconnect AND hosting" predicate shared with
      // sync_now / compare. Host identity alone (cloud backend selected) must
      // NOT hide it: the cloud channel keeps its outbound while hosting.
      final String src =
          File('lib/src/sync/sync_settings_schema.dart').readAsStringSync();
      final int autoSyncAt = src.indexOf("id: 'sync.auto_sync'");
      expect(autoSyncAt, greaterThanOrEqualTo(0));
      final String autoSyncBlock = src.substring(autoSyncAt, autoSyncAt + 900);
      expect(autoSyncBlock, contains('!_cloudOutboundUnavailable('),
          reason:
              'auto-sync hides only when the cloud channel has no outbound');
    });

    test('manual-sync actions are gated on server mode (BUG-084)', () {
      // A pure Hibiki host has no outbound sync, so "sync now" / "compare" must
      // be hidden in server mode and an explanatory note shown instead — every
      // one of the three carries a visibility predicate (none is unconditional).
      final SettingsSection actions = dest.sections[2];
      SettingsItem byId(String id) =>
          actions.items.firstWhere((SettingsItem i) => i.id == id);
      expect(byId('sync.sync_now').visible, isNotNull,
          reason: 'sync_now must be hidden when hosting as a server');
      expect(byId('sync.compare').visible, isNotNull,
          reason: 'compare must be hidden when hosting as a server');
      expect(byId('sync.server_mode_note').visible, isNotNull,
          reason: 'the server-mode note shows only while hosting');
    });

    test(
        'the action gates key off cloud-outbound availability '
        '(BUG-084 / BUG-1088)', () {
      // Source guard: the gates must branch on _cloudOutboundUnavailable, which
      // requires the sync method to BE the interconnect AND the hosting role —
      // so neither a stale serverEnabled flag nor genuine hosting can hide
      // sync-now on a cloud backend (a host still uploads to Google Drive).
      final String src =
          File('lib/src/sync/sync_settings_schema.dart').readAsStringSync();
      final int noteAt = src.indexOf("id: 'sync.server_mode_note'");
      final int nowAt = src.indexOf("id: 'sync.sync_now'");
      final int compareAt = src.indexOf("id: 'sync.compare'");
      expect(noteAt, greaterThanOrEqualTo(0));
      for (final int at in <int>[noteAt, nowAt, compareAt]) {
        expect(
            src.substring(at, at + 200), contains('_cloudOutboundUnavailable'),
            reason: 'manual-sync gate must use cloud-outbound availability');
      }
      // 谓词链自身必须同时咬住三个条件：backendType==hibikiServer（同步方式是互联）
      // + serverEnabled + interconnectEnabled（_isHostingInterconnect 的两条件，
      // BUG-084 的 stale serverEnabled 防线保持不变）。
      final int helperAt = src.indexOf('bool _cloudOutboundUnavailable(');
      expect(helperAt, greaterThanOrEqualTo(0));
      final String helper = src.substring(helperAt, helperAt + 300);
      expect(helper, contains('== SyncBackendType.hibikiServer'),
          reason: 'outbound only vanishes when the method itself is 互联');
      expect(helper, contains('_isHostingInterconnect'),
          reason: 'and only while actually hosting');
      final int hostingAt = src.indexOf('bool _isHostingInterconnect(');
      expect(hostingAt, greaterThanOrEqualTo(0));
      final String hosting = src.substring(hostingAt, hostingAt + 200);
      expect(hosting, contains('serverEnabled'));
      expect(hosting, contains('interconnectEnabled'),
          reason: 'hosting role must also require interconnect to be enabled');
    });

    test('server-mode explanatory note uses compact row layout', () {
      final String src =
          File('lib/src/sync/sync_settings_schema.dart').readAsStringSync();
      final int noteAt = src.indexOf("id: 'sync.server_mode_note'");
      final int syncNowAt = src.indexOf("id: 'sync.sync_now'");
      expect(noteAt, greaterThanOrEqualTo(0));
      expect(syncNowAt, greaterThan(noteAt));

      final String noteBlock = src.substring(noteAt, syncNowAt);
      expect(noteBlock, contains('AdaptiveSettingsRow('));
      expect(noteBlock, isNot(contains('controlBelow: true')),
          reason: '说明行没有下方控件，不应预留控件行高度');
    });

    test('the fake SMB config option is gone', () {
      final allIds = dest.sections
          .expand((SettingsSection s) => s.items)
          .map((SettingsItem i) => i.id)
          .toList();
      expect(allIds, isNot(contains('sync.smb_config')));
    });

    test('the backend picker lists the interconnect again (BUG-1088)', () {
      // Source guard: _isBackendSelectable 对 hibikiServer 必须 return true。
      // 解耦时它被从选择器摘掉，唯一补偿入口（互联页「设为备份后端」按钮）又被
      // host 门控藏住，host 设备上「备份写到已配对设备」入口彻底消失。
      final String src =
          File('lib/src/sync/sync_settings_schema/backend_config.part.dart')
              .readAsStringSync();
      final int fnAt = src.indexOf('bool _isBackendSelectable(');
      expect(fnAt, greaterThanOrEqualTo(0));
      final String fn = src.substring(fnAt, src.indexOf('\n}', fnAt));
      final int caseAt = fn.indexOf('case SyncBackendType.hibikiServer:');
      expect(caseAt, greaterThanOrEqualTo(0));
      final String afterCase = fn.substring(caseAt, caseAt + 80);
      expect(afterCase, contains('return true'),
          reason: 'hibikiServer must be selectable as a sync method');
    });

    test(
        'selecting the interconnect as sync method enables interconnect '
        '(BUG-1088)', () {
      // Source guard: _selectBackend 选中 hibikiServer 时必须顺手
      // setInterconnectEnabled(true)——不开互联总开关，连接配置区不显示、通道认证
      // 也过不去，选完就是个死后端。
      final String src =
          File('lib/src/sync/sync_settings_schema/backend_config.part.dart')
              .readAsStringSync();
      final int fnAt = src.indexOf('Future<void> _selectBackend(');
      expect(fnAt, greaterThanOrEqualTo(0));
      final String fn = src.substring(fnAt, fnAt + 1200);
      expect(fn, contains('setInterconnectEnabled(true)'),
          reason: 'picking 互联 must flip the interconnect master toggle on');
    });
  });

  group('buildInterconnectDestination structure', () {
    late SettingsDestination dest;
    setUpAll(() => dest = buildInterconnectDestination());

    List<String> idsOf(SettingsSection s) =>
        s.items.map((SettingsItem i) => i.id).toList();

    test('is its own top-level destination (not inside syncBackup)', () {
      expect(dest.id, SettingsDestinationId.interconnect);
      // 启用开关 + 连接设备 + 上传到互联对端（BUG-988）+ 交给已配对设备（制卡/备份
      // 后端）+ 本机服务器 + 互联相关配置镜像（远端词典/音频来源/远端占位卡）。
      expect(dest.sections, hasLength(6));
    });

    test('enable toggle is unconditional; config sections gated on the toggle',
        () {
      // 互联总开关（独立于 backendType 云备份后端）常显、无门控；连接设备 / 上传到
      // 互联对端 / 本机服务器 三个配置区仅在互联启用（interconnectEnabled）时可见——
      // 取代解耦前的 backendType == hibikiServer 门控。
      expect(idsOf(dest.sections[0]), <String>['interconnect.enabled']);
      expect(dest.sections[0].visible, isNull,
          reason: 'the enable toggle must always be visible');
      expect(idsOf(dest.sections[1]),
          <String>['sync.hibiki_server_config', 'sync.lan_devices']);
      expect(dest.sections[1].visible, isNotNull);
      // BUG-988：互联专属上传分项开关，与云备份/连接开关解耦，默认全关；仅互联启用时
      // 可见（host 无 outbound 时进一步隐藏）。
      expect(idsOf(dest.sections[2]), <String>[
        'interconnect.upload_content',
        'interconnect.upload_dictionary',
        'interconnect.upload_audiobook_files',
        'interconnect.upload_video_files',
      ]);
      expect(dest.sections[2].visible, isNotNull);
      // 交给已配对设备：制卡到已配对设备（原在「制卡」分类）+ 用互联做备份后端。
      expect(idsOf(dest.sections[3]), <String>[
        'interconnect.mine_to_server',
        'interconnect.backup_backend',
      ]);
      expect(dest.sections[3].visible, isNotNull);
      expect(idsOf(dest.sections[4]), <String>['sync.server_mode']);
      expect(dest.sections[4].visible, isNotNull);
    });

    test('delegate section lives with interconnect, not in card creation', () {
      // 用户诉求：「制卡到已配对设备要放到 hibiki 互联里面」。开关的前置条件（配对）、
      // 目标设备、失效条件全由互联决定，故唯一归宿是互联分类——「制卡」分类里不得再有
      // 第二份，否则互联关掉时那份就是纯死开关。
      final List<String> allIds = dest.sections
          .expand((SettingsSection s) => s.items)
          .map((SettingsItem i) => i.id)
          .toList();
      expect(allIds, contains('interconnect.mine_to_server'));
      final List<String> cardIds = buildCardCreationDestination()
          .sections
          .expand((SettingsSection s) => s.items)
          .map((SettingsItem i) => i.id)
          .toList();
      expect(cardIds, isNot(contains('interconnect.mine_to_server')));
    });

    test('mirrors interconnect-related settings from lookup/sync categories',
        () {
      // 远端词典查询/管理音频来源/远端占位卡在查词、同步分类各有其位，但逻辑上都
      // 作用于互联对端；在互联分类镜像同一入口（共享 builder，非复制），仅互联被选为
      // 同步方式时可见（与其它互联配置区一致）。
      expect(
        idsOf(dest.sections[5]),
        <String>[
          'lookup.remote_lookup',
          'lookup.audio_sources',
          'sync.show_remote_entries',
        ],
      );
      expect(dest.sections[5].visible, isNotNull);
    });

    test('host-server group keeps its explanatory footer', () {
      expect(dest.sections[4].footer, isNotNull);
    });
  });
}
