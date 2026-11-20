import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/discovery/opds_server_config.dart';
import 'package:fushi/src/sync/interconnect_source_share_kinds.dart';
import 'package:fushi/src/sync/interconnect_source_share_sync.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/interconnect_source_share.dart';
import 'package:fushi_engine/sync/tls/fushi_tls_identity.dart';

/// 互联「来源共享」（拍板台 wOMR4_Er7s）：合并规则、两端真实偏好读写、插件包、端点门。
///
/// 钉住的不变式：
/// - 本机自己的来源永远不被覆盖 / 删除；用户在本机改过 = 脱离跟随；在本机删了 = 不再加回来；
/// - host 删了（不再共享）只删「本机仍是收下时那份」的条目；
/// - 插件换了签名者不自动装；摘要与 host 上确认过的那份对不上不装；随 app 自带的插件不碰；
/// - 本机开关关着一个请求都不发；
/// - 端点：明文 / 共享 token / host 关着 / 不是「我的设备」一律 403，未装配 404；
/// - host 只出主人逐项勾选过的（默认一条都不出）；
/// - 「列不出」不等于「卸载了」：host 侧 unavailable、host 这一轮没枚举的种类、本机校验
///   不过的插件都不传播删除；
/// - 签名者以实际下载的包为准；client「也接收插件」关着时不装任何插件；
/// - 服务器清单经偏好缓存写回。

const String _hostId = 'host-1';

OpdsServerConfig _opds(String id, {String password = 'pw', String? name}) =>
    OpdsServerConfig(
      id: id,
      name: name ?? 'Books $id',
      catalogUrl: Uri.parse('https://books-$id.example.com/opds'),
      username: 'u',
      password: password,
    );

Future<void> _setOpds(FushiDatabase db, List<OpdsServerConfig> servers) =>
    db.setPref(
      'discovery_opds_servers',
      PrefCodec.encode(encodeOpdsServerConfigs(servers)),
    );

Future<List<OpdsServerConfig>> _opdsOf(FushiDatabase db) async =>
    decodeOpdsServerConfigs(
      PrefCodec.decode<String>(
        await db.getPref('discovery_opds_servers') ?? '',
        '',
      ),
    );

/// 假插件体系：包 = `pkg|id|digest|signer` 的 UTF-8 字节。
final class _FakeStore implements SharedPluginStore {
  _FakeStore(this.kind);

  @override
  final String kind;

  final Map<String, SharedPluginPackage> plugins =
      <String, SharedPluginPackage>{};
  final List<String> installs = <String>[];
  final List<String> uninstalls = <String>[];

  static Uint8List zipOf(SharedPluginPackage p) =>
      Uint8List.fromList(utf8.encode('pkg|${p.id}|${p.digest}|${p.signer}'));

  @override
  Future<List<SharedPluginPackage>> installed() async =>
      plugins.values.toList();

  @override
  Future<Uint8List?> exportPackage(String id) async =>
      plugins[id] == null || !plugins[id]!.available
      ? null
      : zipOf(plugins[id]!);

  @override
  Future<SharedPluginPackage> inspect(Uint8List zip) async {
    final List<String> parts = utf8.decode(zip).split('|');
    if (parts.length != 4 || parts[0] != 'pkg') {
      throw const FormatException('bad package');
    }
    return SharedPluginPackage(
      id: parts[1],
      label: parts[1],
      digest: parts[2],
      signer: parts[3] == 'null' ? null : parts[3],
    );
  }

  @override
  Future<void> install(Uint8List zip, String digest) async {
    final SharedPluginPackage p = await inspect(zip);
    installs.add('${p.id}@$digest');
    plugins[p.id] = p;
  }

  @override
  Future<void> uninstall(String id) async {
    uninstalls.add(id);
    plugins.remove(id);
  }
}

/// 直接接 host 实现的 remote（合并规则不依赖传输；传输与门另有端点测试）。
final class _DirectRemote implements SourceShareRemote {
  _DirectRemote(this.host);

  final InterconnectSourceShareHost host;
  int catalogCalls = 0;

  /// 非 null 时替换下发的包（模拟传输损坏 / host 中途换包）。
  Uint8List? Function(String kind, String id)? tamper;

  @override
  Future<InterconnectSourceShareCatalog?> getRemoteSourceShareCatalog() async {
    catalogCalls++;
    // 走一遍 wire 编解码，和真实链路一致。
    return InterconnectSourceShareCatalog.fromJson(
      (jsonDecode(jsonEncode((await host.sourceShareCatalog()).toJson()))
              as Map<Object?, Object?>)
          .cast<String, Object?>(),
    );
  }

  @override
  Future<Uint8List> getRemoteSourceSharePackage(String kind, String id) async {
    final Uint8List? tampered = tamper?.call(kind, id);
    if (tampered != null) return tampered;
    final Uint8List? zip = await host.sourceSharePackage(kind, id);
    if (zip == null) throw StateError('not shared');
    return zip;
  }
}

void main() {
  group('planSourceShare', () {
    InterconnectSharedSource offered(
      String id,
      String digest, {
      String? signer,
    }) => InterconnectSharedSource(
      kind: 'k',
      id: id,
      label: id,
      digest: digest,
      signer: signer,
    );

    test('新增 / 认领 / 本机自己的不动', () {
      final SourceSharePlan plan = planSourceShare(
        local: <String, SourceShareLocal>{
          'same': (digest: 'd1', signer: null),
          'mine': (digest: 'mine', signer: null),
        },
        offered: <String, InterconnectSharedSource>{
          'new': offered('new', 'n1'),
          'same': offered('same', 'd1'),
          'mine': offered('mine', 'host'),
        },
        ledger: const <String, SourceShareLedgerEntry>{},
      );
      expect(
        plan.steps.map((SourceShareStep s) => '${s.kind.name}:${s.id}'),
        <String>['add:new'],
      );
      expect(plan.ledger, <String, SourceShareLedgerEntry>{
        'same': const SourceShareLedgerEntry('d1'),
      });
    });

    test('跟随更新 / 本机改过脱离 / 本机删了不再接收', () {
      final SourceSharePlan plan = planSourceShare(
        local: <String, SourceShareLocal>{
          'follow': (digest: 'old', signer: null),
          'edited': (digest: 'edited', signer: null),
        },
        offered: <String, InterconnectSharedSource>{
          'follow': offered('follow', 'new'),
          'edited': offered('edited', 'new'),
          'deleted': offered('deleted', 'x'),
        },
        ledger: const <String, SourceShareLedgerEntry>{
          'follow': SourceShareLedgerEntry('old'),
          'edited': SourceShareLedgerEntry('old'),
          'deleted': SourceShareLedgerEntry('x'),
        },
      );
      expect(
        plan.steps.map((SourceShareStep s) => '${s.kind.name}:${s.id}'),
        <String>['update:follow'],
      );
      expect(plan.ledger['edited'], isNull);
      expect(
        plan.ledger['deleted'],
        const SourceShareLedgerEntry('x', declined: true),
      );
    });

    test('host 不再共享：只删仍是收下时那份的', () {
      final SourceSharePlan plan = planSourceShare(
        local: <String, SourceShareLocal>{
          'gone': (digest: 'g', signer: null),
          'gone-edited': (digest: 'changed', signer: null),
        },
        offered: const <String, InterconnectSharedSource>{},
        ledger: const <String, SourceShareLedgerEntry>{
          'gone': SourceShareLedgerEntry('g'),
          'gone-edited': SourceShareLedgerEntry('g'),
          'declined': SourceShareLedgerEntry('d', declined: true),
        },
      );
      expect(
        plan.steps.map((SourceShareStep s) => '${s.kind.name}:${s.id}'),
        <String>['remove:gone'],
      );
      // 「删」这一步做成了才销账（删失败下一轮重试）；另两条当场销账。
      expect(plan.ledger.keys, <String>['gone']);
      expect(plan.steps.single.ledgerAfter, isNull);
    });

    test('插件换签名者不更新；自带插件不碰', () {
      final SourceSharePlan plan = planSourceShare(
        local: <String, SourceShareLocal>{
          'p': (digest: 'v1', signer: 'alice'),
          'bundled': (digest: 'b', signer: null),
        },
        offered: <String, InterconnectSharedSource>{
          'p': offered('p', 'v2', signer: 'mallory'),
          'bundled': offered('bundled', 'other'),
        },
        ledger: const <String, SourceShareLedgerEntry>{
          'p': SourceShareLedgerEntry('v1'),
        },
        untouchable: const <String>{'bundled'},
        checkSigner: true,
      );
      expect(plan.steps, isEmpty);
      expect(plan.signerChanged, <String>['p']);
      expect(plan.ledger['p'], const SourceShareLedgerEntry('v1'));
    });

    test('列不出不等于删除：unavailable / 本机 held / 种类没枚举都不动、留账', () {
      final SourceSharePlan plan = planSourceShare(
        local: <String, SourceShareLocal>{
          'hostLocked': (digest: 'v1', signer: null),
          'gone': (digest: 'g', signer: null),
        },
        offered: const <String, InterconnectSharedSource>{
          'hostLocked': InterconnectSharedSource.unavailable(
            kind: 'k',
            id: 'hostLocked',
            label: 'L',
          ),
          'localBroken': InterconnectSharedSource(
            kind: 'k',
            id: 'localBroken',
            label: 'B',
            digest: 'v9',
          ),
        },
        ledger: const <String, SourceShareLedgerEntry>{
          'hostLocked': SourceShareLedgerEntry('v1'),
          'localBroken': SourceShareLedgerEntry('v1'),
          'gone': SourceShareLedgerEntry('g'),
        },
        held: const <String>{'localBroken'},
        propagateRemovals: false,
      );
      expect(plan.steps, isEmpty);
      expect(plan.ledger, const <String, SourceShareLedgerEntry>{
        'hostLocked': SourceShareLedgerEntry('v1'),
        'localBroken': SourceShareLedgerEntry('v1'),
        'gone': SourceShareLedgerEntry('g'),
      });
    });
  });

  group('两端真实偏好', () {
    late FushiDatabase hostDb;
    late FushiDatabase phoneDb;
    late _FakeStore hostPlugins;
    late _FakeStore phonePlugins;
    late _DirectRemote remote;
    late List<SharedPluginStore> hostStores;
    late AppInterconnectSourceShareHost host;

    setUp(() async {
      hostDb = FushiDatabase.forTesting(NativeDatabase.memory());
      phoneDb = FushiDatabase.forTesting(NativeDatabase.memory());
      hostPlugins = _FakeStore('musicPlugin');
      phonePlugins = _FakeStore('musicPlugin');
      hostStores = <SharedPluginStore>[hostPlugins];
      // 这一组测合并规则：host 主人把本机所有来源都勾上（勾选本身另有测试）。
      host = AppInterconnectSourceShareHost(
        db: hostDb,
        enabled: () async => true,
        isOwnerDevicePeer: (String _) async => true,
        pluginStores: () => hostStores,
        selected: () async => <String>{
          for (final InterconnectSharedSource s
              in (await host.shareableSources()).sources)
            s.key,
        },
      );
      remote = _DirectRemote(host);
      await SyncRepository(
        phoneDb,
      ).setInterconnectSourceSharePluginsEnabled(true);
    });

    tearDown(() async {
      await hostDb.close();
      await phoneDb.close();
    });

    Future<SourceShareResult> sync() => InterconnectSourceShareSync(
      phoneDb,
      pluginStores: <SharedPluginStore>[phonePlugins],
    ).run(remote, _hostId);

    test('服务器来源：新增、跟随更新、本机改过不覆盖、本机删了不再加回、host 删了跟着删', () async {
      await _setOpds(phoneDb, <OpdsServerConfig>[_opds('phone-own')]);
      await _setOpds(hostDb, <OpdsServerConfig>[_opds('a'), _opds('b')]);

      SourceShareResult r = await sync();
      expect(r.added, 2);
      expect(
        (await _opdsOf(phoneDb)).map((OpdsServerConfig c) => c.id),
        <String>['phone-own', 'a', 'b'],
      );
      expect((await _opdsOf(phoneDb))[1].password, 'pw');

      // host 改密码 → 本机跟随；本机自己改了 b → b 脱离跟随。
      await _setOpds(hostDb, <OpdsServerConfig>[
        _opds('a', password: 'new'),
        _opds('b', password: 'host-b'),
      ]);
      final List<OpdsServerConfig> phone = await _opdsOf(phoneDb);
      await _setOpds(phoneDb, <OpdsServerConfig>[
        phone[0],
        phone[1],
        _opds('b', password: 'phone-b'),
      ]);
      r = await sync();
      expect(r.updated, 1);
      expect(
        <String, String>{
          for (final OpdsServerConfig c in await _opdsOf(phoneDb))
            c.id: c.password,
        },
        <String, String>{'phone-own': 'pw', 'a': 'new', 'b': 'phone-b'},
      );

      // 本机删了 a → 不再加回来。
      await _setOpds(phoneDb, <OpdsServerConfig>[
        for (final OpdsServerConfig c in await _opdsOf(phoneDb))
          if (c.id != 'a') c,
      ]);
      r = await sync();
      expect(r.changed, 0);
      expect(
        (await _opdsOf(phoneDb)).map((OpdsServerConfig c) => c.id),
        <String>['phone-own', 'b'],
      );

      // host 新加 c 再删掉 → 本机跟着删；b（本机改过）留着。
      await _setOpds(hostDb, <OpdsServerConfig>[_opds('b'), _opds('c')]);
      expect((await sync()).added, 1);
      await _setOpds(hostDb, <OpdsServerConfig>[]);
      r = await sync();
      expect(r.removed, 1);
      expect(
        (await _opdsOf(phoneDb)).map((OpdsServerConfig c) => c.id),
        <String>['phone-own', 'b'],
      );
    });

    test('媒体服务器：本机当前线路不被 host 覆盖、也不算本机改过', () async {
      Map<String, Object?> jellyfin({
        required String token,
        String active = '',
      }) => <String, Object?>{
        'serverUrl': 'https://jf.example.com',
        'username': 'tom',
        'userId': 'user-1',
        'accessToken': token,
        'alternateUrls': <String>['https://jf-lan.example.com'],
        if (active.isNotEmpty) 'activeServerUrl': active,
      };
      await hostDb.setPref(
        'sync_jellyfin_servers',
        jsonEncode(<Object?>[jellyfin(token: 't1')]),
      );
      expect((await sync()).added, 1);

      // 本机切到局域网线路；host 换了令牌。
      await phoneDb.setPref(
        'sync_jellyfin_servers',
        jsonEncode(<Object?>[
          jellyfin(token: 't1', active: 'https://jf-lan.example.com'),
        ]),
      );
      await hostDb.setPref(
        'sync_jellyfin_servers',
        jsonEncode(<Object?>[jellyfin(token: 't2')]),
      );
      expect((await sync()).updated, 1);
      final List<Object?> stored =
          jsonDecode((await phoneDb.getPref('sync_jellyfin_servers'))!)
              as List<Object?>;
      final Map<Object?, Object?> server =
          stored.single! as Map<Object?, Object?>;
      expect(server['accessToken'], 't2');
      expect(server['activeServerUrl'], 'https://jf-lan.example.com');
    });

    test('插件：装新插件、跟随更新、签名者变了不装、自带不碰、host 卸载跟着卸', () async {
      hostPlugins.plugins['p'] = const SharedPluginPackage(
        id: 'p',
        label: 'P',
        digest: 'v1',
        signer: 'alice',
      );
      hostPlugins.plugins['bundled'] = const SharedPluginPackage(
        id: 'bundled',
        label: 'B',
        digest: 'b',
        signer: null,
        bundled: true,
      );
      SourceShareResult r = await sync();
      expect(r.added, 1);
      expect(phonePlugins.installs, <String>['p@v1']);

      hostPlugins.plugins['p'] = const SharedPluginPackage(
        id: 'p',
        label: 'P',
        digest: 'v2',
        signer: 'alice',
      );
      r = await sync();
      expect(r.updated, 1);
      expect(phonePlugins.installs.last, 'p@v2');

      hostPlugins.plugins['p'] = const SharedPluginPackage(
        id: 'p',
        label: 'P',
        digest: 'v3',
        signer: 'mallory',
      );
      r = await sync();
      expect(r.changed, 0);
      expect(r.signerChanged, <String>['P']);
      expect(phonePlugins.plugins['p']!.digest, 'v2');

      hostPlugins.plugins.remove('p');
      r = await sync();
      expect(r.removed, 1);
      expect(phonePlugins.uninstalls, <String>['p']);
    });

    test('插件包摘要与目录对不上：不装、记错误、下一轮重试', () async {
      hostPlugins.plugins['p'] = const SharedPluginPackage(
        id: 'p',
        label: 'P',
        digest: 'v1',
        signer: null,
      );
      remote.tamper = (String _, String _) =>
          Uint8List.fromList(utf8.encode('pkg|p|evil|null'));
      SourceShareResult r = await sync();
      expect(r.added, 0);
      expect(r.errors.single, contains('digest mismatch'));
      expect(phonePlugins.installs, isEmpty);

      remote.tamper = null;
      r = await sync();
      expect(r.added, 1);
    });

    test('本机没有插件体系（iOS）：只收服务器，账本里的插件条目原样留着', () async {
      hostPlugins.plugins['p'] = const SharedPluginPackage(
        id: 'p',
        label: 'P',
        digest: 'v1',
        signer: null,
      );
      await sync();
      await _setOpds(hostDb, <OpdsServerConfig>[_opds('a')]);
      final SourceShareResult r = await InterconnectSourceShareSync(
        phoneDb,
        pluginStores: const <SharedPluginStore>[],
      ).run(remote, _hostId);
      expect(r.added, 1);
      final SourceShareLedger ledger = await SourceShareLedger.load(phoneDb);
      expect(
        ledger.hosts[_hostId]!.keys,
        containsAll(<String>['musicPlugin/p', 'opds/a']),
      );
    });

    test('host 一时列不出插件 / 这一轮没有插件体系：本机那份不卸载', () async {
      hostPlugins.plugins['p'] = const SharedPluginPackage(
        id: 'p',
        label: 'P',
        digest: 'v1',
        signer: null,
      );
      expect((await sync()).added, 1);

      // host 上文件正被更新 / 被锁：校验不过，列成 unavailable。
      hostPlugins.plugins['p'] = const SharedPluginPackage.unavailable(
        id: 'p',
        label: 'p',
      );
      SourceShareResult r = await sync();
      expect(r.changed, 0);
      expect(phonePlugins.uninstalls, isEmpty);

      // host 这一轮整个插件体系都没建好（目录 kinds 里没有 musicPlugin）。
      hostStores = <SharedPluginStore>[];
      r = await sync();
      expect(r.changed, 0);
      expect(phonePlugins.uninstalls, isEmpty);
      expect(
        (await SourceShareLedger.load(
          phoneDb,
        )).hosts[_hostId]!['musicPlugin/p'],
        const SourceShareLedgerEntry('v1'),
      );

      // 恢复后照常跟随；真卸载了才跟着卸。
      hostStores = <SharedPluginStore>[hostPlugins];
      hostPlugins.plugins.remove('p');
      r = await sync();
      expect(r.removed, 1);
      expect(phonePlugins.uninstalls, <String>['p']);
    });

    test('本机插件校验不过：不更新也不删', () async {
      hostPlugins.plugins['p'] = const SharedPluginPackage(
        id: 'p',
        label: 'P',
        digest: 'v1',
        signer: null,
      );
      await sync();
      phonePlugins.plugins['p'] = const SharedPluginPackage.unavailable(
        id: 'p',
        label: 'p',
      );
      hostPlugins.plugins.remove('p');
      final SourceShareResult r = await sync();
      expect(r.changed, 0);
      expect(phonePlugins.uninstalls, isEmpty);
    });

    test('签名者以下载的包为准：目录自报不变、包里换了人也不装', () async {
      hostPlugins.plugins['p'] = const SharedPluginPackage(
        id: 'p',
        label: 'P',
        digest: 'v1',
        signer: 'alice',
      );
      await sync();
      hostPlugins.plugins['p'] = const SharedPluginPackage(
        id: 'p',
        label: 'P',
        digest: 'v2',
        signer: 'alice',
      );
      remote.tamper = (String _, String _) =>
          Uint8List.fromList(utf8.encode('pkg|p|v2|mallory'));
      SourceShareResult r = await sync();
      expect(r.changed, 0);
      expect(r.signerChanged, <String>['P']);
      expect(phonePlugins.installs, <String>['p@v1']);

      remote.tamper = null;
      r = await sync();
      expect(r.updated, 1);
    });

    test('「也接收插件」关着：不装插件', () async {
      await SyncRepository(
        phoneDb,
      ).setInterconnectSourceSharePluginsEnabled(false);
      hostPlugins.plugins['p'] = const SharedPluginPackage(
        id: 'p',
        label: 'P',
        digest: 'v1',
        signer: null,
      );
      await _setOpds(hostDb, <OpdsServerConfig>[_opds('a')]);
      final SourceShareResult r = await sync();
      expect(r.added, 1);
      expect(phonePlugins.installs, isEmpty);
    });

    test('服务器清单经偏好缓存写回', () async {
      final List<String> written = <String>[];
      await _setOpds(hostDb, <OpdsServerConfig>[_opds('a')]);
      final SourceShareResult r = await InterconnectSourceShareSync(
        phoneDb,
        pluginStores: <SharedPluginStore>[phonePlugins],
        cachedPrefWriter: (String key, String value) async {
          written.add(key);
          await phoneDb.setPref(key, PrefCodec.encode(value));
        },
      ).run(remote, _hostId);
      expect(r.added, 1);
      expect(written, <String>['discovery_opds_servers']);
      expect((await _opdsOf(phoneDb)).single.id, 'a');
    });

    test('host 只出勾选过的：默认一条都不共享', () async {
      await _setOpds(hostDb, <OpdsServerConfig>[_opds('a'), _opds('b')]);
      hostPlugins.plugins['p'] = const SharedPluginPackage(
        id: 'p',
        label: 'P',
        digest: 'v1',
        signer: null,
      );
      final AppInterconnectSourceShareHost real =
          AppInterconnectSourceShareHost(
            db: hostDb,
            enabled: () async => true,
            isOwnerDevicePeer: (String _) async => true,
            pluginStores: () => hostStores,
          );
      InterconnectSourceShareCatalog catalog = await real.sourceShareCatalog();
      expect(catalog.sources, isEmpty);
      expect(catalog.kinds, containsAll(<String>['opds', 'musicPlugin']));
      expect(await real.sourceSharePackage('musicPlugin', 'p'), isNull);

      final SyncRepository repo = SyncRepository(hostDb);
      await repo.setInterconnectSourceShareHostItem('opds/b', shared: true);
      await repo.setInterconnectSourceShareHostItem(
        'musicPlugin/p',
        shared: true,
      );
      catalog = await real.sourceShareCatalog();
      expect(
        catalog.sources.map((InterconnectSharedSource s) => s.key),
        <String>['opds/b', 'musicPlugin/p'],
      );
      expect(await real.sourceSharePackage('musicPlugin', 'p'), isNotNull);

      await repo.setInterconnectSourceShareHostItem('opds/b', shared: false);
      catalog = await real.sourceShareCatalog();
      expect(
        catalog.sources.map((InterconnectSharedSource s) => s.key),
        <String>['musicPlugin/p'],
      );
    });

    test('本机开关关着：一个请求都不发', () async {
      await SyncRepository(phoneDb).setInterconnectSourceShareEnabled(false);
      await _setOpds(hostDb, <OpdsServerConfig>[_opds('a')]);
      final SourceShareResult r = await sync();
      expect(r.changed, 0);
      expect(remote.catalogCalls, 0);
    });

    test('账本与两个开关都是设备本地键', () {
      expect(
        SyncRepository.deviceLocalPrefKeys,
        containsAll(<String>[
          SourceShareLedger.prefKey,
          'interconnect_sync_source_share',
          'interconnect_source_share_host',
          'interconnect_source_share_host_items',
          'interconnect_sync_source_share_plugins',
        ]),
      );
    });
  });

  group('端点门', () {
    late Directory root;
    late FushiDatabase hostDb;
    FushiSyncServer? server;
    late bool enabled;
    late Set<String> ownerTokens;
    late _FakeStore plugins;

    setUp(() async {
      root = Directory.systemTemp.createTempSync('source_share_');
      hostDb = FushiDatabase.forTesting(NativeDatabase.memory());
      enabled = true;
      ownerTokens = <String>{'peer-token'};
      plugins = _FakeStore('musicPlugin')
        ..plugins['p'] = const SharedPluginPackage(
          id: 'p',
          label: 'P',
          digest: 'v1',
          signer: null,
        );
      await _setOpds(hostDb, <OpdsServerConfig>[
        _opds('a', password: 'secret'),
      ]);
      final SyncRepository repo = SyncRepository(hostDb);
      await repo.setInterconnectSourceShareHostItem('opds/a', shared: true);
      await repo.setInterconnectSourceShareHostItem(
        'musicPlugin/p',
        shared: true,
      );
    });

    tearDown(() async {
      await server?.stop();
      server = null;
      await hostDb.close();
      root.deleteSync(recursive: true);
    });

    Future<void> start({bool tls = true, bool wired = true}) async {
      SecurityContext? ctx;
      if (tls) {
        final ({String certificatePem, String privateKeyPem}) id =
            FushiSelfSignedCertGenerator.generate(
              commonName: 'fushi-test',
              sanIpAddresses: <String>['127.0.0.1'],
            );
        ctx = SecurityContext()
          ..useCertificateChainBytes(utf8.encode(id.certificatePem))
          ..usePrivateKeyBytes(utf8.encode(id.privateKeyPem));
      }
      final FushiSyncServer started =
          FushiSyncServer(
              syncDataDir: '${root.path}/sync',
              port: 0,
              token: 'shared-token',
              allowLan: false,
              securityContext: ctx,
            )
            ..pairedPeerTokensProvider = (() async => <String>{
              'peer-token',
              'other-peer',
            })
            ..sourceShareHost = wired
                ? AppInterconnectSourceShareHost(
                    db: hostDb,
                    enabled: () async => enabled,
                    isOwnerDevicePeer: (String t) async =>
                        ownerTokens.contains(t),
                    pluginStores: () => <SharedPluginStore>[plugins],
                  )
                : null;
      await started.start();
      server = started;
    }

    Future<({int status, String body})> get(
      String scheme,
      String path, {
      String token = 'peer-token',
    }) async {
      final HttpClient c = HttpClient()
        ..badCertificateCallback = (X509Certificate _, String _, int _) => true;
      try {
        final HttpClientRequest req = await c.getUrl(
          Uri.parse('$scheme://127.0.0.1:${server!.port}$path'),
        );
        req.headers.set(
          HttpHeaders.authorizationHeader,
          'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
        );
        final HttpClientResponse res = await req.close();
        return (status: res.statusCode, body: await utf8.decodeStream(res));
      } finally {
        c.close(force: true);
      }
    }

    test('明文：403 https_required', () async {
      await start(tls: false);
      final ({int status, String body}) r = await get(
        'http',
        kInterconnectSourceSharePath,
      );
      expect(r.status, 403);
      expect(r.body, contains('https_required'));
    });

    test('HTTPS：共享 token / host 关着 / 不是我的设备都 403，我的设备拿到目录与包', () async {
      await start();
      final ({int status, String body}) shared = await get(
        'https',
        kInterconnectSourceSharePath,
        token: 'shared-token',
      );
      expect(shared.status, 403);
      expect(shared.body, contains('paired_peer_required'));
      expect(shared.body, isNot(contains('secret')));

      final ({int status, String body}) other = await get(
        'https',
        kInterconnectSourceSharePath,
        token: 'other-peer',
      );
      expect(other.status, 403);
      expect(other.body, contains('not_owner_device'));

      enabled = false;
      final ({int status, String body}) off = await get(
        'https',
        kInterconnectSourceSharePath,
      );
      expect(off.status, 403);
      expect(off.body, contains('disabled'));

      enabled = true;
      final ({int status, String body}) ok = await get(
        'https',
        kInterconnectSourceSharePath,
      );
      expect(ok.status, 200);
      final InterconnectSourceShareCatalog catalog =
          InterconnectSourceShareCatalog.fromJson(
            (jsonDecode(ok.body) as Map<Object?, Object?>)
                .cast<String, Object?>(),
          );
      expect(
        catalog.sources.map((InterconnectSharedSource s) => s.key),
        <String>['opds/a', 'musicPlugin/p'],
      );

      final ({int status, String body}) pkg = await get(
        'https',
        '$kInterconnectSourceSharePackagePath?kind=musicPlugin&id=p',
      );
      expect(pkg.status, 200);
      expect(pkg.body, 'pkg|p|v1|null');
      final ({int status, String body}) missing = await get(
        'https',
        '$kInterconnectSourceSharePackagePath?kind=musicPlugin&id=nope',
      );
      expect(missing.status, 404);
    });

    test('未装配：404', () async {
      await start(wired: false);
      expect((await get('https', kInterconnectSourceSharePath)).status, 404);
    });
  });
}
