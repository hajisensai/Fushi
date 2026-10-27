import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/ctl_settings_body_downloads.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/ops/ctl_settings_body_video_providers.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart' show t;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/torrent/anime_download_config.dart';
import 'package:fushi_engine/media/torrent/bt_site_config.dart';
import 'package:fushi_engine/media/torrent/torznab_client.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../helpers/test_platform_services.dart';

/// 下载设置 / 视频外部提供方的控制通道条目：读写真写穿 prefs，校验不过不写。
void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late AppModel appModel;
  late SettingsContext sc;
  late Directory tempDir;

  Map<String, SettingsItem> itemsOf(List<CtlBodyPage> pages) =>
      <String, SettingsItem>{
        for (final CtlBodyPage page in pages)
          for (final SettingsItem item in page.items) item.id: item,
      };

  late Map<String, SettingsItem> dl;
  late Map<String, SettingsItem> vp;

  T item<T extends SettingsItem>(Map<String, SettingsItem> m, String id) {
    final SettingsItem? found = m[id];
    expect(found, isA<T>(), reason: id);
    return found! as T;
  }

  QbConnectionConfig cfg() => effectiveTorrentConfig(prefs.qbConnectionConfig);

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    tempDir = Directory.systemTemp.createTempSync('fushi_dl_cli_');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tempDir)
      ..wireDatabaseForTesting(db);
    dl = itemsOf(buildCtlDownloadsBodyPages());
    vp = itemsOf(buildCtlVideoProvidersBodyPages());
  });

  tearDown(() => db.close());

  Future<void> pumpContext(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              sc = SettingsContext(
                context: context,
                appModel: appModel,
                ref: ref,
                readerSource: ReaderFushiSource.instance,
                refresh: () {},
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
  }

  test('ids are unique and carry the cli prefix', () {
    final List<String> ids = <String>[
      for (final CtlBodyPage page in <CtlBodyPage>[
        ...buildCtlDownloadsBodyPages(),
        ...buildCtlVideoProvidersBodyPages(),
      ])
        for (final SettingsItem item in page.items) item.id,
    ];
    expect(ids.toSet(), hasLength(ids.length));
    for (final String id in ids) {
      expect(id, contains('.cli.'), reason: id);
    }
    for (final SettingsActionItem action in <SettingsItem>[
      ...dl.values,
      ...vp.values,
    ].whereType<SettingsActionItem>()) {
      expect(action.cli, isNotNull, reason: action.id);
    }
  });

  testWidgets('torrent values write through QbConnectionConfig', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    await prefs.setQbConnectionConfig(
      cfg().copyWith(backend: QbConnectionConfig.backendEmbedded),
    );

    final SettingsNumberItem limit = item(
      dl,
      'downloads.cli.download_limit_kbps',
    );
    expect(limit.isVisible(sc), isTrue);
    await limit.onChanged(sc, 512);
    expect(cfg().downloadLimitKbps, 512);
    expect(limit.value(sc), 512);

    await item<SettingsSwitchItem>(
      dl,
      'downloads.cli.dht',
    ).onChanged(sc, false);
    expect(cfg().enableDht, isFalse);

    final SettingsNumberItem uploadLimit = item(
      dl,
      'downloads.cli.upload_limit_kbps',
    );
    await item<SettingsSwitchItem>(
      dl,
      'downloads.cli.upload_enabled',
    ).onChanged(sc, false);
    expect(uploadLimit.isVisible(sc), isFalse, reason: '与页面同一可见性');
    await item<SettingsSwitchItem>(
      dl,
      'downloads.cli.upload_enabled',
    ).onChanged(sc, true);
    expect(uploadLimit.isVisible(sc), isTrue);

    await item<SettingsNumberItem>(
      dl,
      'downloads.cli.seed_ratio_limit',
    ).onChanged(sc, 1.5);
    expect(cfg().seedRatioLimit, 1.5);

    final SettingsSegmentedItem<String> enc = item(
      dl,
      'downloads.cli.encryption',
    );
    expect(
      enc.options.map((SettingsSegmentOption<String> o) => o.value),
      <String>['prefer', 'forced', 'disabled'],
    );
    await enc.onChanged(sc, 'forced');
    expect(cfg().encryptionMode, QbConnectionConfig.encryptionForced);
    expect(enc.selected(sc), 'forced');

    await item<SettingsTextItem>(
      dl,
      'downloads.cli.category',
    ).onChanged(sc, '  ');
    expect(cfg().category, 'fushi', reason: '清空兜底 fushi，与页面一致');

    // 切到外接 qB：连接行可见、内置引擎行隐藏。
    final SettingsSegmentedItem<String> backend = item(
      dl,
      'downloads.cli.backend',
    );
    await backend.onChanged(sc, QbConnectionConfig.backendQbittorrent);
    expect(backend.selected(sc), QbConnectionConfig.backendQbittorrent);
    expect(limit.isVisible(sc), isFalse);
    final SettingsTextItem password = item(dl, 'downloads.cli.qb_password');
    expect(password.secret, isTrue);
    expect(password.isVisible(sc), isTrue);
    await password.onChanged(sc, 'pw');
    await item<SettingsTextItem>(
      dl,
      'downloads.cli.qb_url',
    ).onChanged(sc, ' http://127.0.0.1:8080 ');
    expect(cfg().password, 'pw');
    expect(cfg().baseUrl, 'http://127.0.0.1:8080');
    expect(
      item<SettingsActionItem>(
        dl,
        'downloads.cli.test_connection',
      ).isVisible(sc),
      isTrue,
    );
  });

  testWidgets(
    'save root: absolute dir writes, relative rejected, reset clears',
    (WidgetTester tester) async {
      await pumpContext(tester);
      final SettingsCustomItem root = item(dl, 'downloads.cli.save_root');
      final String target = p.join(tempDir.path, 'dl_root');
      // 下载目录校验会真建目录、写探针文件：真 IO 必须在 runAsync 里跑。
      await tester.runAsync(() => root.cliValue!.write(sc, target));
      expect(prefs.downloadSaveRoot, target);
      expect(root.cliValue!.read(sc), target);
      await expectLater(
        root.cliValue!.write(sc, 'relative/dir'),
        throwsArgumentError,
      );
      expect(prefs.downloadSaveRoot, target, reason: '校验不过不写');
      await item<SettingsActionItem>(
        dl,
        'downloads.cli.save_root_reset',
      ).onTap(sc);
      expect(prefs.downloadSaveRoot, isEmpty);
    },
  );

  testWidgets('execution host: local clears, unpaired address rejected', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    final SettingsCustomItem host = item(dl, 'downloads.cli.execution_host');
    await prefs.setDownloadExecutionHostUrl('https://stale.test:1');
    await host.cliValue!.write(sc, 'local');
    expect(prefs.downloadExecutionHostUrl, isEmpty);
    expect(host.cliValue!.read(sc), 'local');
    await expectLater(
      host.cliValue!.write(sc, 'https://nobody.test:9'),
      throwsArgumentError,
    );
    final Object? candidates = await item<SettingsActionItem>(
      dl,
      'downloads.cli.execution_host_candidates',
    ).cli!.run!(sc, const <String, String>{});
    expect(jsonEncode(candidates), contains('"local"'));
  });

  testWidgets('torznab cliList: add/update/rm, api key redacted, bad input', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    final SettingsCliList cli = item<SettingsCustomItem>(
      vp,
      'services.torznab.cli.indexers',
    ).cliList!;
    expect(
      cli.fields
          .singleWhere((SettingsCliParam f) => f.name == 'api_key')
          .secret,
      isTrue,
    );
    final Object? added = await cli.add!(sc, <String, String>{
      'name': 'Jackett',
      'endpoint': 'https://jackett.test/api/v2.0/indexers/all/results/torznab',
      'api_key': 'SECRET-KEY',
      'categories': '5000,5070',
    });
    final String id = (added! as Map<String, Object?>)['id']! as String;
    final List<TorznabIndexerConfig> stored = prefs.videoResourceTorznabConfigs;
    expect(stored.single.apiKey, 'SECRET-KEY');
    expect(stored.single.categories, <int>[5000, 5070]);
    final List<Map<String, Object?>> rows = await cli.list(sc);
    expect(jsonEncode(rows), isNot(contains('SECRET-KEY')));

    await cli.update!(sc, id, <String, String>{
      'enabled': 'false',
      'priority': '5',
    });
    expect(prefs.videoResourceTorznabConfigs.single.enabled, isFalse);
    expect(prefs.videoResourceTorznabConfigs.single.priority, 5);
    expect(prefs.videoResourceTorznabConfigs.single.apiKey, 'SECRET-KEY');

    await expectLater(
      cli.update!(sc, id, <String, String>{'endpoint': 'http://remote.test/x'}),
      throwsArgumentError,
      reason: '非 loopback 明文 http 未开 insecure_http',
    );
    await expectLater(
      cli.update!(sc, id, <String, String>{'categories': 'a,b'}),
      throwsArgumentError,
    );
    await expectLater(
      cli.add!(sc, <String, String>{'endpoint': 'https://x.test/api'}),
      throwsArgumentError,
      reason: 'name 为空',
    );
    expect(prefs.videoResourceTorznabConfigs, hasLength(1));
    await expectLater(cli.remove!(sc, 'nope'), throwsArgumentError);
    await cli.remove!(sc, id);
    expect(prefs.videoResourceTorznabConfigs, isEmpty);
  });

  // Fushi 不内置任何 BT 站：控制通道列出用户 BT 站，只回显名称 / 主机名，
  // 不回显完整地址（可能带 passkey）与接口格式；改名 / 域 / 启停不重新识别。
  testWidgets('bt sites cliList: list hides url, update/rm, neutral errors', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    final SettingsCliList cli = item<SettingsCustomItem>(
      vp,
      'services.bt_sites.cli.sites',
    ).cliList!;
    expect(
      cli.fields.singleWhere((SettingsCliParam f) => f.name == 'url').secret,
      isTrue,
      reason: '地址可能带 passkey，按凭据收',
    );
    await appModel.setBtSites(<BtSiteConfig>[
      BtSiteConfig(
        id: 'site1',
        baseUrl: Uri.parse('https://bt.example.com/passkey-SECRET'),
        format: BtSiteFormat.nyaa,
        domains: const <BtSiteDomain>{BtSiteDomain.anime},
        nyaaCategories: const <BtSiteDomain, String>{BtSiteDomain.anime: '1_0'},
      ),
    ]);
    final List<Map<String, Object?>> rows = await cli.list(sc);
    expect(rows.single['host'], 'bt.example.com');
    expect(rows.single['name'], 'bt.example.com');
    expect(rows.single['effectiveDomains'], <String>['anime']);
    final String encoded = jsonEncode(rows);
    expect(encoded, isNot(contains('SECRET')));
    expect(encoded, isNot(contains('nyaa')), reason: '接口格式是内部字段');

    await cli.update!(sc, 'site1', <String, String>{
      'name': 'Mine',
      'enabled': 'false',
      'domains': 'anime,tv',
    });
    final BtSiteConfig updated = appModel.btSites.single;
    expect(updated.name, 'Mine');
    expect(updated.enabled, isFalse);
    expect(updated.domains, <BtSiteDomain>{
      BtSiteDomain.anime,
      BtSiteDomain.tv,
    });
    expect(
      updated.baseUrl.toString(),
      'https://bt.example.com/passkey-SECRET',
      reason: '没改地址不重新识别、不动地址',
    );

    await expectLater(
      cli.update!(sc, 'site1', <String, String>{'domains': 'anime,nope'}),
      throwsArgumentError,
    );
    await expectLater(
      cli.add!(sc, <String, String>{
        'url': 'http://remote.test/x',
        'domains': 'anime',
      }),
      throwsA(
        isA<ArgumentError>().having(
          (ArgumentError e) => e.message,
          'message',
          t.bt_site_url_insecure_error,
        ),
      ),
      reason: '非局域网明文 http 未开 insecure_http：探测前就拒，报中性提示',
    );
    await expectLater(
      cli.add!(sc, <String, String>{'url': 'https://bt.example.org'}),
      throwsArgumentError,
      reason: '至少一个媒体域',
    );
    expect(appModel.btSites, hasLength(1));
    await expectLater(cli.remove!(sc, 'nope'), throwsArgumentError);
    await cli.remove!(sc, 'site1');
    expect(appModel.btSites, isEmpty);
    expect(prefs.btSites, isEmpty);
  });

  testWidgets('path mapping cliList: add/update/rm with page validation', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    final SettingsCliList cli = item<SettingsCustomItem>(
      vp,
      'downloads.routing.cli.path_mappings',
    ).cliList!;
    final String local = p.join(tempDir.path, 'mapped');
    final Object? added = await cli.add!(sc, <String, String>{
      'profile': 'qb-profile',
      'remote_root': '/downloads',
      'local_root': local,
    });
    final String id = (added! as Map<String, Object?>)['id']! as String;
    expect(id, 'qb-profile:/downloads');
    expect(prefs.videoDownloadBackendPathMappings.single.localRoot, local);
    await expectLater(
      cli.add!(sc, <String, String>{
        'profile': 'qb-profile',
        'remote_root': '/downloads',
        'local_root': local,
      }),
      throwsArgumentError,
      reason: '重复映射',
    );
    await expectLater(
      cli.update!(sc, id, <String, String>{'local_root': 'relative'}),
      throwsArgumentError,
    );
    final Object? updated = await cli.update!(sc, id, <String, String>{
      'remote_root': '/data',
    });
    expect((updated! as Map<String, Object?>)['id'], 'qb-profile:/data');
    expect((await cli.list(sc)).single['remoteRoot'], '/data');
    await cli.remove!(sc, 'qb-profile:/data');
    expect(prefs.videoDownloadBackendPathMappings, isEmpty);

    final SettingsCustomItem target = item(
      vp,
      'downloads.routing.cli.target_source',
    );
    await target.cliValue!.write(sc, 'none');
    expect(prefs.videoDownloadTargetSourceId, isNull);
    await expectLater(target.cliValue!.write(sc, '999'), throwsArgumentError);
  });

  testWidgets('subtitle providers & builtin sources write through', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    final SettingsTextItem jimakuKey = item(vp, 'services.jimaku.cli.api_key');
    expect(jimakuKey.secret, isTrue);
    await jimakuKey.onChanged(sc, '  jk  ');
    expect(prefs.jimakuApiKey, 'jk');
    await item<SettingsSwitchItem>(
      vp,
      'services.subdl.cli.enabled',
    ).onChanged(sc, false);
    expect(appModel.videoSubtitleSubdlEnabled, isFalse);

    final SettingsCustomItem ua = item(
      vp,
      'services.opensubtitles.cli.user_agent',
    );
    await ua.cliValue!.write(sc, 'Fushi-Test v1');
    expect(prefs.videoSubtitleOpenSubtitlesConfig.userAgent, 'Fushi-Test v1');
    await expectLater(ua.cliValue!.write(sc, '  '), throwsArgumentError);
    final SettingsCustomItem endpoint = item(
      vp,
      'services.opensubtitles.cli.endpoint',
    );
    final String before = endpoint.cliValue!.read(sc);
    await expectLater(
      endpoint.cliValue!.write(sc, 'http://remote.test/api'),
      throwsArgumentError,
    );
    expect(endpoint.cliValue!.read(sc), before, reason: '校验不过不写');
    await item<SettingsTextItem>(
      vp,
      'services.opensubtitles.cli.password',
    ).onChanged(sc, 'os-pw');
    expect(prefs.videoSubtitleOpenSubtitlesConfig.password, 'os-pw');
    expect(
      prefs.videoSubtitleOpenSubtitlesConfig.userAgent,
      'Fushi-Test v1',
      reason: '只改给出的字段',
    );
  });
}
