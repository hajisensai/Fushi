// SyncRepository 的 Jellyfin/Emby **多服务器**配置（真 DB）。
//
// 视频页「媒体服务器」栏目一台一张卡片，配置从单值键 `sync_jellyfin_server`
// （一条 JSON）变成列表键 `sync_jellyfin_servers`（JSON 数组）。本文件锁住：
//  [A] 列表往返 / 空表删键；
//  [B] 旧单值键的一次性迁移在**读路径**完成：读一次 → 旧键消失、列表键出现、值一致；
//  [C] upsert 按 `(serverUrl, userId)` 身份替换（原位）vs 追加；remove 只删一台；
//  [D] 过渡口径：getJellyfinServer = 第一项；setJellyfinServer(null) = 清空全部；
//  [E] 脏项逐项过滤，不整表作废；
//  [F] 新旧两个键都在设备本地黑名单（accessToken 绝不随备份跨设备）。

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';

const String _kLegacyKey = 'sync_jellyfin_server';
const String _kListKey = 'sync_jellyfin_servers';

const JellyfinServerConfig _nas = JellyfinServerConfig(
  serverUrl: 'http://nas:8096',
  username: 'alice',
  userId: 'u-nas',
  accessToken: 'tok-nas',
  serverName: 'NAS',
  libraryIds: <String>['lib-anime'],
);

const JellyfinServerConfig _emby = JellyfinServerConfig(
  serverUrl: 'https://emby.example.com',
  username: 'bob',
  userId: 'u-emby',
  accessToken: 'tok-emby',
  serverName: 'Public Emby',
);

void main() {
  late FushiDatabase db;
  late SyncRepository repo;

  setUp(() {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    repo = SyncRepository(db);
  });

  tearDown(() => db.close());

  Future<String?> rawPref(String key) async {
    final PreferenceRow? row = await (db.select(
      db.preferences,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> writeRaw(String key, String value) => db
      .into(db.preferences)
      .insertOnConflictUpdate(
        PreferencesCompanion.insert(key: key, value: value),
      );

  List<String> idsOf(List<JellyfinServerConfig> servers) => <String>[
    for (final JellyfinServerConfig s in servers)
      JellyfinVideoClient.sourceIdFor(serverUrl: s.serverUrl, userId: s.userId),
  ];

  group('[A] 列表往返', () {
    test('未配置 → 空列表，不建键', () async {
      expect(await repo.getJellyfinServers(), isEmpty);
      expect(await rawPref(_kListKey), isNull);
    });

    test('两台按顺序落库、按顺序读回，字段逐一一致', () async {
      await repo.setJellyfinServers(<JellyfinServerConfig>[_nas, _emby]);
      final List<JellyfinServerConfig> back = await repo.getJellyfinServers();
      expect(back, hasLength(2));
      expect(back[0].serverUrl, _nas.serverUrl);
      expect(back[0].userId, _nas.userId);
      expect(back[0].accessToken, _nas.accessToken);
      expect(back[0].serverName, _nas.serverName);
      expect(back[0].libraryIds, _nas.libraryIds);
      expect(back[1].serverUrl, _emby.serverUrl);
      expect(back[1].username, _emby.username);
      expect(back[1].libraryIds, isEmpty);

      final Object? decoded = jsonDecode((await rawPref(_kListKey))!);
      expect(decoded, isA<List<Object?>>(), reason: '列表键必须是 JSON 数组');
    });

    test('空列表 = 删键', () async {
      await repo.setJellyfinServers(<JellyfinServerConfig>[_nas]);
      expect(await rawPref(_kListKey), isNotNull);
      await repo.setJellyfinServers(const <JellyfinServerConfig>[]);
      expect(await rawPref(_kListKey), isNull);
      expect(await repo.getJellyfinServers(), isEmpty);
    });
  });

  group('[B] 旧单值键一次性迁移（读路径）', () {
    test('只有旧键：读一次 → 列表键出现、旧键消失、值一致', () async {
      await writeRaw(_kLegacyKey, jsonEncode(_nas.toJson()));

      final List<JellyfinServerConfig> first = await repo.getJellyfinServers();
      expect(first, hasLength(1));
      expect(first.single.serverUrl, _nas.serverUrl);
      expect(first.single.userId, _nas.userId);
      expect(first.single.accessToken, _nas.accessToken);
      expect(first.single.serverName, _nas.serverName);
      expect(
        first.single.libraryIds,
        _nas.libraryIds,
        reason: 'BUG-1891 的库点名必须跟着迁过来，不能迁一次就清回「全部」',
      );

      expect(await rawPref(_kLegacyKey), isNull, reason: '旧键迁完即删');
      final String? migrated = await rawPref(_kListKey);
      expect(migrated, isNotNull, reason: '列表键必须在读路径里被写出来');
      expect(jsonDecode(migrated!), <Object?>[_nas.toJson()]);

      // 幂等：第二次读不再碰旧键，结果一致。
      final List<JellyfinServerConfig> second = await repo.getJellyfinServers();
      expect(idsOf(second), idsOf(first));
    });

    test('旧键是脏 JSON：读成空表，旧键照样删掉、不再每次重跑迁移', () async {
      await writeRaw(_kLegacyKey, '{not json');
      expect(await repo.getJellyfinServers(), isEmpty);
      expect(await rawPref(_kLegacyKey), isNull);
      expect(await rawPref(_kListKey), isNull, reason: '空表不建列表键');
    });

    test('列表键已存在时旧键被忽略（不会把已登出的老服务器复活）', () async {
      await repo.setJellyfinServers(<JellyfinServerConfig>[_emby]);
      await writeRaw(_kLegacyKey, jsonEncode(_nas.toJson()));
      final List<JellyfinServerConfig> back = await repo.getJellyfinServers();
      expect(idsOf(back), idsOf(<JellyfinServerConfig>[_emby]));
    });
  });

  group('[C] upsert / remove 按 (serverUrl, userId) 身份', () {
    test('不同身份 → 追加到末尾（保持添加顺序）', () async {
      await repo.upsertJellyfinServer(_nas);
      await repo.upsertJellyfinServer(_emby);
      expect(
        idsOf(await repo.getJellyfinServers()),
        idsOf(<JellyfinServerConfig>[_nas, _emby]),
      );
    });

    test('同身份 → 原位替换（换令牌 / 改库），不多出一张卡', () async {
      await repo.upsertJellyfinServer(_nas);
      await repo.upsertJellyfinServer(_emby);
      const JellyfinServerConfig nasRelogin = JellyfinServerConfig(
        serverUrl: 'http://nas:8096',
        username: 'alice',
        userId: 'u-nas',
        accessToken: 'tok-nas-2',
        serverName: 'NAS renamed',
        libraryIds: <String>['lib-movies'],
      );
      await repo.upsertJellyfinServer(nasRelogin);

      final List<JellyfinServerConfig> back = await repo.getJellyfinServers();
      expect(back, hasLength(2), reason: '同身份不能追加成第三条');
      expect(back[0].accessToken, 'tok-nas-2', reason: '替换必须原位，不挪到末尾');
      expect(back[0].serverName, 'NAS renamed');
      expect(back[0].libraryIds, <String>['lib-movies']);
      expect(back[1].userId, _emby.userId);
    });

    test('同 URL 不同账号是两台（身份含 userId）', () async {
      await repo.upsertJellyfinServer(_nas);
      await repo.upsertJellyfinServer(
        const JellyfinServerConfig(
          serverUrl: 'http://nas:8096',
          username: 'carol',
          userId: 'u-carol',
          accessToken: 'tok-carol',
        ),
      );
      expect(await repo.getJellyfinServers(), hasLength(2));
    });

    test('remove 只删点名的一台，其它不动；不存在 = no-op', () async {
      await repo.setJellyfinServers(<JellyfinServerConfig>[_nas, _emby]);
      await repo.removeJellyfinServer(
        serverUrl: _nas.serverUrl,
        userId: _nas.userId,
      );
      expect(
        idsOf(await repo.getJellyfinServers()),
        idsOf(<JellyfinServerConfig>[_emby]),
      );

      await repo.removeJellyfinServer(serverUrl: 'http://nowhere', userId: 'x');
      expect(await repo.getJellyfinServers(), hasLength(1));

      await repo.removeJellyfinServer(
        serverUrl: _emby.serverUrl,
        userId: _emby.userId,
      );
      expect(await repo.getJellyfinServers(), isEmpty);
      expect(await rawPref(_kListKey), isNull, reason: '删到空 = 删键');
    });
  });

  group('[D] 过渡口径（旧单值 API 语义不破）', () {
    test('getJellyfinServer = 列表第一项；空表 → null', () async {
      // ignore: deprecated_member_use_from_same_package
      expect(await repo.getJellyfinServer(), isNull);
      await repo.setJellyfinServers(<JellyfinServerConfig>[_nas, _emby]);
      // ignore: deprecated_member_use_from_same_package
      final JellyfinServerConfig? first = await repo.getJellyfinServer();
      expect(first!.userId, _nas.userId);
    });

    test('setJellyfinServer(config) = upsert；同身份不重复', () async {
      // ignore: deprecated_member_use_from_same_package
      await repo.setJellyfinServer(_nas);
      // ignore: deprecated_member_use_from_same_package
      await repo.setJellyfinServer(_nas.copyWithLibraryIds(<String>['x']));
      final List<JellyfinServerConfig> back = await repo.getJellyfinServers();
      expect(back, hasLength(1));
      expect(back.single.libraryIds, <String>['x']);
      expect(await rawPref(_kLegacyKey), isNull, reason: '过渡 API 不再写旧键');
    });

    test('setJellyfinServer(null) = 清空全部（旧的「登出删键」语义）', () async {
      await repo.setJellyfinServers(<JellyfinServerConfig>[_nas, _emby]);
      // ignore: deprecated_member_use_from_same_package
      await repo.setJellyfinServer(null);
      expect(await repo.getJellyfinServers(), isEmpty);
      expect(await rawPref(_kListKey), isNull);
    });
  });

  group('[E] 脏项过滤', () {
    test('缺关键字段 / 非对象的项被丢掉，其它服务器保留', () async {
      await writeRaw(
        _kListKey,
        jsonEncode(<Object?>[
          _nas.toJson(),
          <String, Object?>{'serverUrl': 'http://broken'},
          'garbage',
          42,
          null,
          _emby.toJson(),
        ]),
      );
      expect(
        idsOf(await repo.getJellyfinServers()),
        idsOf(<JellyfinServerConfig>[_nas, _emby]),
      );
    });

    test('整个值不是 JSON 数组 → 空表（不崩）', () async {
      await writeRaw(_kListKey, jsonEncode(_nas.toJson()));
      expect(await repo.getJellyfinServers(), isEmpty);
      await writeRaw(_kListKey, '[not json');
      expect(await repo.getJellyfinServers(), isEmpty);
    });
  });

  group('[F] 设备本地黑名单', () {
    test('新列表键与旧单值键都不随备份跨设备（含 accessToken）', () {
      expect(SyncRepository.deviceLocalPrefKeys, contains(_kListKey));
      expect(SyncRepository.deviceLocalPrefKeys, contains(_kLegacyKey));
    });
  });
}
