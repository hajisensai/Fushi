import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// 全局「远程查词」并入每台 host 的「用这台服务器查词典」（用户拍板 2026-11-09）的
/// 一次性迁移：[PreferencesRepository.settleRemoteLookupHostSwitches]。
///
/// 判据：存量全局开关关着（或从没设过 = 默认关）且有配对 host ⇒ 一次性把它们的
/// host 开关全关，更新后不会突然开始查服务器；全局开着 ⇒ host 开关原样。只跑一次
/// （标记键），之后用户再打开 host 开关不会被改回去。
void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late SyncRepository sync;

  const List<FushiClientUrl> paired = <FushiClientUrl>[
    FushiClientUrl(url: 'https://192.168.1.10:38765', hostId: 'h1'),
    FushiClientUrl(url: 'http://10.0.0.5:38765', hostId: 'h2'),
  ];

  setUp(() async {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    sync = SyncRepository(db);
  });

  tearDown(() async {
    prefs.dispose();
    await db.close();
  });

  Future<Set<String>> lookupHosts() async =>
      remoteDictionaryLookupHostIdsOf(await sync.getFushiClientUrls());

  test('global switch never set (default off) + paired hosts ⇒ all host '
      'switches turned off once', () async {
    await sync.setFushiClientUrls(paired);
    expect(await lookupHosts(), <String>{'h1', 'h2'});

    expect(await prefs.settleRemoteLookupHostSwitches(sync), isTrue);
    expect(await lookupHosts(), isEmpty);
    final List<FushiClientUrl> after = await sync.getFushiClientUrls();
    expect(after.map((FushiClientUrl u) => u.url), <String>[
      'https://192.168.1.10:38765',
      'http://10.0.0.5:38765',
    ], reason: '只改开关，地址与顺序不动');
    expect(
      prefs.getPref(
        PreferencesRepository.remoteLookupHostSwitchesMigratedKey,
        defaultValue: false,
      ),
      isTrue,
    );
  });

  test('global switch explicitly off ⇒ host switches off', () async {
    await prefs.setPref(
      PreferencesRepository.legacyRemoteLookupEnabledKey,
      false,
    );
    await sync.setFushiClientUrls(paired);
    await prefs.settleRemoteLookupHostSwitches(sync);
    expect(await lookupHosts(), isEmpty);
  });

  test('global switch on ⇒ host switches left as they are', () async {
    await prefs.setPref(
      PreferencesRepository.legacyRemoteLookupEnabledKey,
      true,
    );
    await sync.setFushiClientUrls(<FushiClientUrl>[
      paired.first,
      paired.last.copyWith(lookupEnabled: false),
    ]);
    expect(await prefs.settleRemoteLookupHostSwitches(sync), isFalse);
    expect(await lookupHosts(), <String>{'h1'});
  });

  test('runs once: a host switch turned on afterwards stays on', () async {
    await sync.setFushiClientUrls(paired);
    await prefs.settleRemoteLookupHostSwitches(sync);
    await sync.updateFushiClientUrls(
      (List<FushiClientUrl> urls) => <FushiClientUrl>[
        for (final FushiClientUrl u in urls)
          u.hostId == 'h1' ? u.copyWith(lookupEnabled: true) : u,
      ],
    );
    expect(await prefs.settleRemoteLookupHostSwitches(sync), isFalse);
    expect(await lookupHosts(), <String>{'h1'});

    // 标记落库：重开（新进程）同样不再跑。
    final PreferencesRepository reopened = PreferencesRepository(db);
    await reopened.loadFromDb();
    expect(await reopened.settleRemoteLookupHostSwitches(sync), isFalse);
    expect(await lookupHosts(), <String>{'h1'});
    reopened.dispose();
  });

  test('nothing paired ⇒ nothing to change; marker still set, so a host '
      'paired later keeps its default (on)', () async {
    expect(await prefs.settleRemoteLookupHostSwitches(sync), isFalse);
    await sync.setFushiClientUrls(paired.take(1).toList());
    expect(await prefs.settleRemoteLookupHostSwitches(sync), isFalse);
    expect(await lookupHosts(), <String>{'h1'});
  });

  test('marker is install-scoped (not synced, not in profile snapshots)', () {
    expect(
      SyncRepository.installScopedPrefKeys,
      contains(PreferencesRepository.remoteLookupHostSwitchesMigratedKey),
    );
    expect(
      SyncRepository.deviceLocalPrefKeys,
      contains(PreferencesRepository.remoteLookupHostSwitchesMigratedKey),
    );
  });
}
