import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/updates/update_check_scheduler.dart';
import 'package:fushi/src/updates/update_feed_service.dart';
import 'package:fushi/src/updates/update_probes.dart';
import 'package:fushi_engine/updates/update_feed_kind.dart';

/// 扩展后台检查 + 后台自动更新（反馈 tp0HM4UhRg）：真 in-memory DB + 真
/// `UpdateFeedService`，安装动作换成可编排的假实现（真实 `installMany` 的签名门
/// 由 `mihon_manager_install_test.dart` 覆盖）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late PreferencesRepository prefs;
  late UpdateFeedService feed;
  late List<List<String>> installCalls;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    feed = UpdateFeedService(database: db, prefs: prefs);
    installCalls = <List<String>>[];
  });

  tearDown(() => db.close());

  final List<MangaExtensionRow> installed = <MangaExtensionRow>[
    _installedRow('org.example.same'),
    _installedRow('org.example.resigned'),
  ];
  final List<MihonAvailableExtension> available = <MihonAvailableExtension>[
    _available('org.example.same'),
    _available('org.example.resigned'),
  ];

  /// 假安装：same 装上，resigned 以「换了签名」失败——与真 `installMany` 在
  /// `upgrade: true, trustSigner: false` 下的结局一致。
  Future<MihonBulkInstallReport> fakeInstall(
    List<MihonAvailableExtension> targets,
    bool Function() isCancelled,
  ) async {
    installCalls.add(<String>[
      for (final MihonAvailableExtension t in targets) t.packageName,
    ]);
    final Set<String> asked = <String>{
      for (final MihonAvailableExtension t in targets) t.packageName,
    };
    return MihonBulkInstallReport(
      installed: <String>[
        if (asked.contains('org.example.same')) 'org.example.same',
      ],
      skipped: const <String>[],
      failed: <String, String>{
        if (asked.contains('org.example.resigned'))
          'org.example.resigned':
              'MihonRuntimeException(SIGNATURE_CHANGED): Extension update '
              'signer does not match the installed version',
      },
      failureCodes: <String, String>{
        if (asked.contains('org.example.resigned'))
          'org.example.resigned': 'SIGNATURE_CHANGED',
      },
    );
  }

  Future<int> probe({
    MihonExtensionAutoUpdater? autoUpdate,
    UpdateFeedKind kind = UpdateFeedKind.mangaExtension,
  }) => runMihonExtensionUpdateProbe(
    feed: feed,
    kind: kind,
    refreshStores: () async {},
    available: () => available,
    installed: () => installed,
    autoUpdate: autoUpdate,
  );

  Future<Map<String, UpdateFeedEntryRow>> entriesById() async =>
      <String, UpdateFeedEntryRow>{
        for (final UpdateFeedEntryRow row in await feed.entries())
          row.entryId: row,
      };

  String availableId(
    String pkg, [
    UpdateFeedKind kind = UpdateFeedKind.mangaExtension,
  ]) => updateFeedEntryId(
    kind,
    mangaExtensionTargetKey(packageName: pkg, versionCode: 9),
  );
  String outcomeId(String pkg, ExtensionAutoUpdateOutcome outcome) =>
      updateFeedEntryId(
        UpdateFeedKind.mangaExtension,
        extensionAutoUpdateTargetKey(
          packageName: pkg,
          versionCode: 9,
          outcome: outcome,
        ),
      );

  test('自动更新关着（autoUpdate = null）：不装，只投递「有新版」', () async {
    expect(await probe(), 2);
    expect(installCalls, isEmpty);
    final Map<String, UpdateFeedEntryRow> rows = await entriesById();
    expect(rows.keys.toSet(), <String>{
      availableId('org.example.same'),
      availableId('org.example.resigned'),
    });
  });

  test('开着且空闲：同签名的装上并留「已自动更新」记录，换签名的进「需手动处理」', () async {
    await probe(
      autoUpdate: MihonExtensionAutoUpdater(
        isIdle: () => true,
        install: fakeInstall,
      ),
    );

    expect(installCalls, <List<String>>[
      <String>['org.example.same', 'org.example.resigned'],
    ]);
    final Map<String, UpdateFeedEntryRow> rows = await entriesById();
    final UpdateFeedEntryRow done =
        rows[outcomeId(
          'org.example.same',
          ExtensionAutoUpdateOutcome.installed,
        )]!;
    expect(jsonDecode(done.detailJson!)['autoUpdate'], 'installed');
    final UpdateFeedEntryRow failed =
        rows[outcomeId(
          'org.example.resigned',
          ExtensionAutoUpdateOutcome.failed,
        )]!;
    final Map<String, Object?> detail =
        (jsonDecode(failed.detailJson!) as Map<Object?, Object?>)
            .cast<String, Object?>();
    expect(detail['autoUpdate'], 'failed');
    expect(detail['reasonCode'], 'SIGNATURE_CHANGED');
    expect(detail['manual'], isTrue);
    expect(failed.seenAt, isNull, reason: '需手动处理的条目必须是未读，用户才看得到');
  });

  test('结果条目取代先前投递过的「有新版」：那条被标已读', () async {
    await probe(); // 自动更新关着时先投递过「有新版」
    await probe(
      autoUpdate: MihonExtensionAutoUpdater(
        isIdle: () => true,
        install: fakeInstall,
      ),
    );
    final Map<String, UpdateFeedEntryRow> rows = await entriesById();
    expect(rows[availableId('org.example.same')]!.seenAt, isNotNull);
    expect(rows[availableId('org.example.resigned')]!.seenAt, isNotNull);
  });

  test('正在使用在线源（不空闲）：一个都不装，照旧投递「有新版」', () async {
    await probe(
      autoUpdate: MihonExtensionAutoUpdater(
        isIdle: () => false,
        install: fakeInstall,
      ),
    );
    expect(installCalls, isEmpty);
    final Map<String, UpdateFeedEntryRow> rows = await entriesById();
    expect(rows.keys.toSet(), <String>{
      availableId('org.example.same'),
      availableId('org.example.resigned'),
    });
  });

  test('换签名失败过的同一版本，下一轮不再重下重撞', () async {
    final MihonExtensionAutoUpdater updater = MihonExtensionAutoUpdater(
      isIdle: () => true,
      install: fakeInstall,
    );
    await probe(autoUpdate: updater);
    installCalls.clear();

    await probe(autoUpdate: updater);

    expect(
      installCalls,
      <List<String>>[
        <String>['org.example.same'],
      ],
      reason:
          'resigned 这一版已记为需手动处理，不再重试；same 仍在（快照是固定的'
          '假数据，真实场景装上后 installed 已是新版、不会再出现）',
    );
  });

  test('视频扩展域：投递落 animeExtension，不混进漫画扩展域', () async {
    await probe(kind: UpdateFeedKind.animeExtension);
    final Map<String, UpdateFeedEntryRow> rows = await entriesById();
    expect(rows.keys.toSet(), <String>{
      availableId('org.example.same', UpdateFeedKind.animeExtension),
      availableId('org.example.resigned', UpdateFeedKind.animeExtension),
    });
    expect(rows.values.map((UpdateFeedEntryRow r) => r.kind).toSet(), <String>{
      'animeExtension',
    });
  });

  test('调度器 dueOnStart：间隔内的扩展域在启动这一轮照查一次，之后回到间隔', () async {
    DateTime clock = DateTime.utc(2026, 10, 16, 8);
    await prefs.setPref(
      updateLastCheckPrefKey(UpdateFeedKind.mangaExtension),
      clock.millisecondsSinceEpoch,
    );
    int calls = 0;
    final UpdateCheckScheduler scheduler = UpdateCheckScheduler(
      prefs: prefs,
      isKindEnabled: (_) => true,
      probes: <UpdateFeedKind, UpdateProbe>{
        UpdateFeedKind.mangaExtension: () async => calls++,
      },
      dueOnStart: const <UpdateFeedKind>{UpdateFeedKind.mangaExtension},
      now: () => clock,
    );
    clock = clock.add(const Duration(hours: 1));
    await scheduler.runDue();
    expect(calls, 1, reason: '启动这一轮无视 24 小时间隔');
    clock = clock.add(const Duration(hours: 1));
    await scheduler.runDue();
    expect(calls, 1, reason: '豁免只有一次');
  });
}

MangaExtensionRow _installedRow(String packageName) => MangaExtensionRow(
  mediaKind: 'manga',
  packageName: packageName,
  storeUrl: 'https://repo.example/index.json',
  name: packageName,
  versionCode: 1,
  versionName: '1.6.1',
  libVersion: '1.6',
  language: 'ja',
  contentWarning: 0,
  apkPath: '$packageName.apk',
  apkSha256: 'x',
  signerSha256: 'aabb',
  enabled: true,
  installedAt: 0,
);

MihonAvailableExtension _available(String packageName) =>
    MihonAvailableExtension(
      storeUrl: 'https://repo.example/index.json',
      name: packageName,
      packageName: packageName,
      apkUrl: 'https://repo.example/apk/$packageName.apk',
      iconUrl: 'https://repo.example/icons/$packageName.png',
      libVersion: '1.6',
      extensionVersionCode: 9,
      versionName: '1.6.9',
      language: 'ja',
      contentWarning: 0,
      sources: const <MihonAvailableSource>[],
    );
