// Jellyfin/Emby 服务器**多线路**（同一台服务器的多条访问地址，可切换）。
//
// 本文件锁住：
//  [A] 模型：登录地址恒在 routeUrls 首位；active 缺省 / 不在清单内 → 回落登录地址；
//      备用线路去空、去重、剔登录地址；copyWithRoutes 删掉正在用的线路自动回落；
//  [B] JSON 往返：新字段只在非缺省时才写；旧 JSON（没有这两个字段）读回单线路；
//  [C] buildClient：请求走当前线路（stream / image URL 的 host 是当前线路），
//      但缓存槽身份与封面缓存命名空间**仍按登录地址**——切线路不换身份；
//  [D] 仓库：切线路 upsert 后仍是同一条记录（不多一张卡）、字段落库、读回一致。

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';

const String _lan = 'http://192.168.1.10:8096';
const String _wan = 'https://emby.example.com';
const String _proxy = 'https://proxy.example.net';

const JellyfinServerConfig _base = JellyfinServerConfig(
  serverUrl: _lan,
  username: 'alice',
  userId: 'u-alice',
  accessToken: 'tok-1',
  serverName: 'NAS',
  deviceId: 'dev-1',
  libraryIds: <String>['lib-anime'],
);

String _idOf(JellyfinServerConfig c) =>
    JellyfinVideoClient.sourceIdFor(serverUrl: c.serverUrl, userId: c.userId);

void main() {
  group('[A] 模型', () {
    test('单线路：routeUrls 只有登录地址，effective = 登录地址', () {
      expect(_base.routeUrls, <String>[_lan]);
      expect(_base.effectiveServerUrl, _lan);
      expect(_base.activeServerUrl, isEmpty);
    });

    test('多线路：登录地址恒在首位，active 指向备用线路时 effective 跟着走', () {
      final JellyfinServerConfig c = _base.copyWithRoutes(
        alternateUrls: <String>[_wan, _proxy],
        activeServerUrl: _wan,
      );
      expect(c.routeUrls, <String>[_lan, _wan, _proxy]);
      expect(c.effectiveServerUrl, _wan);
      expect(c.activeServerUrl, _wan);
    });

    test('active 不在清单内 → 回落登录地址（防御脏配置）', () {
      const JellyfinServerConfig c = JellyfinServerConfig(
        serverUrl: _lan,
        username: 'alice',
        userId: 'u-alice',
        accessToken: 'tok-1',
        alternateUrls: <String>[_wan],
        activeServerUrl: 'https://gone.example.com',
      );
      expect(c.effectiveServerUrl, _lan);
    });

    test('备用线路整理：去空、去重、剔掉登录地址、保持首次出现顺序', () {
      expect(
        JellyfinServerConfig.normalizeAlternateUrls(_lan, <String>[
          '',
          _wan,
          _lan,
          _proxy,
          _wan,
        ]),
        <String>[_wan, _proxy],
      );
      final JellyfinServerConfig c = _base.copyWithRoutes(
        alternateUrls: <String>[_lan, _wan, _wan],
      );
      expect(c.alternateUrls, <String>[_wan]);
    });

    test('切到登录地址 = active 清空（持久化不写冗余值）', () {
      final JellyfinServerConfig c = _base
          .copyWithRoutes(alternateUrls: <String>[_wan], activeServerUrl: _wan)
          .copyWithRoutes(activeServerUrl: _lan);
      expect(c.activeServerUrl, isEmpty);
      expect(c.effectiveServerUrl, _lan);
      expect(c.alternateUrls, <String>[_wan], reason: '只换 active 不动清单');
    });

    test('删掉正在用的线路 → 自动回落登录地址', () {
      final JellyfinServerConfig c = _base
          .copyWithRoutes(
            alternateUrls: <String>[_wan, _proxy],
            activeServerUrl: _wan,
          )
          .copyWithRoutes(alternateUrls: <String>[_proxy]);
      expect(c.routeUrls, <String>[_lan, _proxy]);
      expect(c.effectiveServerUrl, _lan);
      expect(c.activeServerUrl, isEmpty);
    });

    test('ownsRoute：登录地址与备用线路都算这台；别的地址不算', () {
      final JellyfinServerConfig c = _base.copyWithRoutes(
        alternateUrls: <String>[_wan],
      );
      expect(c.ownsRoute(_lan), isTrue);
      expect(c.ownsRoute(_wan), isTrue);
      expect(c.ownsRoute(_proxy), isFalse);
    });

    test('withRefreshedSession：经备用线路重登只换令牌，身份/线路/库选择照旧、'
        'active 切到本次登录地址；经登录地址重登 active 清空', () {
      final JellyfinServerConfig c = _base.copyWithRoutes(
        alternateUrls: <String>[_wan, _proxy],
        activeServerUrl: _proxy,
      );
      final JellyfinServerConfig viaWan = c.withRefreshedSession(
        username: 'alice',
        accessToken: 'tok-2',
        deviceId: 'dev-2',
        signedInUrl: _wan,
      );
      expect(viaWan.serverUrl, _lan, reason: '身份锚不变，sourceId 不变');
      expect(_idOf(viaWan), _idOf(_base));
      expect(viaWan.accessToken, 'tok-2');
      expect(viaWan.deviceId, 'dev-2');
      expect(viaWan.serverName, 'NAS', reason: '没给 serverName 时沿用旧值');
      expect(viaWan.libraryIds, <String>['lib-anime']);
      expect(viaWan.alternateUrls, <String>[_wan, _proxy]);
      expect(viaWan.effectiveServerUrl, _wan);

      final JellyfinServerConfig viaLan = c.withRefreshedSession(
        username: 'alice',
        accessToken: 'tok-3',
        deviceId: 'dev-1',
        signedInUrl: _lan,
        serverName: 'NAS2',
      );
      expect(viaLan.activeServerUrl, '');
      expect(viaLan.effectiveServerUrl, _lan);
      expect(viaLan.serverName, 'NAS2');
    });

    test('copyWithLibraryIds 保留线路', () {
      final JellyfinServerConfig c = _base
          .copyWithRoutes(alternateUrls: <String>[_wan], activeServerUrl: _wan)
          .copyWithLibraryIds(<String>['lib-movies']);
      expect(c.alternateUrls, <String>[_wan]);
      expect(c.effectiveServerUrl, _wan);
      expect(c.libraryIds, <String>['lib-movies']);
    });
  });

  group('[B] JSON 往返', () {
    test('单线路 JSON 不带新字段（与旧版本产出逐字相同）', () {
      final Map<String, Object?> json = _base.toJson();
      expect(json.containsKey('alternateUrls'), isFalse);
      expect(json.containsKey('activeServerUrl'), isFalse);
    });

    test('多线路往返：alternateUrls + activeServerUrl 一致', () {
      final JellyfinServerConfig c = _base.copyWithRoutes(
        alternateUrls: <String>[_wan, _proxy],
        activeServerUrl: _proxy,
      );
      final Map<String, dynamic> json =
          jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>;
      final JellyfinServerConfig? back = JellyfinServerConfig.fromJson(json);
      expect(back, isNotNull);
      expect(back!.serverUrl, _lan);
      expect(back.alternateUrls, <String>[_wan, _proxy]);
      expect(back.activeServerUrl, _proxy);
      expect(back.effectiveServerUrl, _proxy);
      expect(back.deviceId, 'dev-1');
      expect(back.libraryIds, <String>['lib-anime']);
    });

    test('旧 JSON（无线路字段）读回单线路', () {
      final JellyfinServerConfig? back =
          JellyfinServerConfig.fromJson(<String, dynamic>{
            'serverUrl': _lan,
            'username': 'alice',
            'userId': 'u-alice',
            'accessToken': 'tok-1',
          });
      expect(back!.routeUrls, <String>[_lan]);
      expect(back.effectiveServerUrl, _lan);
    });

    test('脏 JSON：备用清单里混着登录地址 / 重复 / 非字符串，读回时整理干净', () {
      final JellyfinServerConfig? back = JellyfinServerConfig.fromJson(
        <String, dynamic>{
          'serverUrl': _lan,
          'username': 'alice',
          'userId': 'u-alice',
          'accessToken': 'tok-1',
          'alternateUrls': <Object?>[_lan, _wan, 42, _wan, ''],
          'activeServerUrl': _wan,
        },
      );
      expect(back!.alternateUrls, <String>[_wan]);
      expect(back.effectiveServerUrl, _wan);
    });

    test('JSON 里的线路带尾斜杠 / 大写 scheme：读回时归一化，active 仍命中', () {
      final JellyfinServerConfig? back = JellyfinServerConfig.fromJson(
        <String, dynamic>{
          'serverUrl': _lan,
          'username': 'alice',
          'userId': 'u-alice',
          'accessToken': 'tok-1',
          'alternateUrls': <Object?>['HTTPS://emby.example.com/'],
          'activeServerUrl': 'https://emby.example.com/',
        },
      );
      expect(back!.alternateUrls, <String>[_wan]);
      expect(back.effectiveServerUrl, _wan);
    });
  });

  group('[C] buildClient：请求走当前线路，身份按登录地址', () {
    final JellyfinServerConfig onWan = _base.copyWithRoutes(
      alternateUrls: <String>[_wan],
      activeServerUrl: _wan,
    );

    test('api.serverUrl / stream / image URL 的 host 是当前线路', () {
      final JellyfinVideoClient client = onWan.buildClient();
      expect(client.api.serverUrl, _wan);
      expect(client.serverUrl, _wan, reason: '浏览页卡片展示当前线路');
      expect(
        client.api.streamUrl('item-1'),
        startsWith('$_wan/Videos/item-1/'),
      );
      expect(client.api.imageUrl('item-1'), startsWith('$_wan/Items/item-1/'));
      client.api.close();
    });

    test('remoteLibrarySourceId / coverCacheNamespace 与单线路时逐字相同', () {
      final JellyfinVideoClient lan = _base.buildClient();
      final JellyfinVideoClient wan = onWan.buildClient();
      expect(wan.remoteLibrarySourceId, lan.remoteLibrarySourceId);
      expect(wan.remoteLibrarySourceId, _idOf(_base));
      expect(wan.coverCacheNamespace, lan.coverCacheNamespace);
      expect(wan.serverId, lan.serverId, reason: '浏览页 PageStorage / 焦点键不变');
      lan.api.close();
      wan.api.close();
    });

    test('直接 new 的 client（测试 / 单线路路径）身份缺省 = api 地址', () {
      final JellyfinVideoClient c = JellyfinVideoClient(
        api: JellyfinApi(serverUrl: _wan, accessToken: 'tok-1'),
        userId: 'u-alice',
      );
      expect(c.identityServerUrl, _wan);
      expect(
        c.remoteLibrarySourceId,
        JellyfinVideoClient.sourceIdFor(serverUrl: _wan, userId: 'u-alice'),
      );
      c.api.close();
    });
  });

  group('[D] 仓库', () {
    late FushiDatabase db;
    late SyncRepository repo;

    setUp(() {
      db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      repo = SyncRepository(db);
    });

    tearDown(() => db.close());

    test('添加线路 + 切换：仍是同一条记录，字段落库、读回一致', () async {
      await repo.upsertJellyfinServer(_base);
      await repo.upsertJellyfinServer(
        _base.copyWithRoutes(alternateUrls: <String>[_wan]),
      );
      List<JellyfinServerConfig> servers = await repo.getJellyfinServers();
      expect(servers, hasLength(1), reason: '加线路不多一张卡');
      expect(servers.single.routeUrls, <String>[_lan, _wan]);
      expect(servers.single.effectiveServerUrl, _lan, reason: '添加不切换');

      await repo.upsertJellyfinServer(
        servers.single.copyWithRoutes(activeServerUrl: _wan),
      );
      servers = await repo.getJellyfinServers();
      expect(servers, hasLength(1), reason: '切线路身份不变');
      expect(_idOf(servers.single), _idOf(_base));
      expect(servers.single.effectiveServerUrl, _wan);
      expect(servers.single.buildClient().api.serverUrl, _wan);
      expect(servers.single.accessToken, 'tok-1', reason: '令牌跨线路共用');
    });

    test('切了线路再按登录地址登出：整条记录一起删', () async {
      await repo.upsertJellyfinServer(
        _base.copyWithRoutes(
          alternateUrls: <String>[_wan],
          activeServerUrl: _wan,
        ),
      );
      await repo.removeJellyfinServer(
        serverUrl: _base.serverUrl,
        userId: _base.userId,
      );
      expect(await repo.getJellyfinServers(), isEmpty);
    });
  });
}
