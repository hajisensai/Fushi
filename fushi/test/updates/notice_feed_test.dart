import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/sync/pref_redaction_policy.dart';
import 'package:fushi/src/updates/build_info.dart';
import 'package:fushi/src/updates/notice_feed.dart';
import 'package:fushi_core/fushi_core.dart';

/// 服务端通知：请求体形状、响应解析、缓存持久化 / 清除、对话框只弹一次的记账。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<PreferencesRepository> makePrefs() async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository repo = PreferencesRepository(db);
    await repo.loadFromDb();
    return repo;
  }

  group('buildNoticeRequest', () {
    test('字段名与取值按约定', () {
      final Map<String, Object?> body = buildNoticeRequest(
        version: '1.2.3',
        platform: 'android',
        channel: 'beta',
        locale: 'zh-CN',
        info: const BuildInfo(
          id: 'app.example',
          h: <String>['aa'],
          k: <String>['bb', 'cc'],
        ),
      );
      expect(body, <String, Object?>{
        'v': '1.2.3',
        'p': 'android',
        'c': 'beta',
        'l': 'zh-CN',
        'id': 'app.example',
        'h': <String>['aa'],
        'k': <String>['bb', 'cc'],
      });
      // 可直接 JSON 编码。
      expect(jsonDecode(jsonEncode(body)), body);
    });

    test('非 Android：id 为 null、h / k 为空数组', () {
      final Map<String, Object?> body = buildNoticeRequest(
        version: '1',
        platform: 'windows',
        channel: 'stable',
        locale: 'en',
        info: const BuildInfo(),
      );
      expect(body['id'], isNull);
      expect(body['h'], isEmpty);
      expect(body['k'], isEmpty);
    });
  });

  group('parseNoticeResponse', () {
    test('三种级别都解析，未知级别丢弃，url 为 null 或非 https 时为 null', () {
      final NoticeResponse? res = parseNoticeResponse(
        jsonEncode(<String, Object?>{
          'notices': <Object?>[
            <String, Object?>{
              'id': 'a',
              'level': 'banner',
              'title': 'T',
              'body': 'B',
              'url': 'https://example.com/x',
            },
            <String, Object?>{
              'id': 'b',
              'level': 'dialog',
              'title': 'T2',
              'body': '',
              'url': null,
            },
            <String, Object?>{
              'id': 'c',
              'level': 'block',
              'title': '',
              'body': 'B3',
              'url': 'http://example.com',
            },
            <String, Object?>{
              'id': 'd',
              'level': 'toast',
              'title': 'x',
              'body': 'y',
            },
            <String, Object?>{'id': 'e', 'level': 'banner'},
            'garbage',
          ],
          'ttl': 3600,
          'extra': true,
        }),
      );
      expect(res, isNotNull);
      expect(res!.notices.map((RemoteNotice n) => n.id), <String>[
        'a',
        'b',
        'c',
      ]);
      expect(res.notices[0].level, RemoteNoticeLevel.banner);
      expect(res.notices[0].url, Uri.parse('https://example.com/x'));
      expect(res.notices[1].level, RemoteNoticeLevel.dialog);
      expect(res.notices[1].url, isNull);
      expect(res.notices[2].level, RemoteNoticeLevel.block);
      expect(res.notices[2].url, isNull);
      expect(res.ttl, const Duration(hours: 1));
    });

    test('ttl 夹在范围内，缺省用默认值', () {
      expect(parseNoticeResponse('{"notices":[],"ttl":1}')!.ttl, kNoticeMinTtl);
      expect(
        parseNoticeResponse('{"notices":[],"ttl":99999999}')!.ttl,
        kNoticeMaxTtl,
      );
      expect(parseNoticeResponse('{"notices":[]}')!.ttl, kNoticeDefaultTtl);
    });

    test('超长字段截断、超长 id 丢弃、重复 id 只留第一条、条数有上限', () {
      final List<RemoteNotice> notices = parseRemoteNotices(<Object?>[
        <String, Object?>{
          'id': 'x' * (kNoticeMaxIdLength + 1),
          'level': 'banner',
          'title': 't',
        },
        <String, Object?>{
          'id': 'long',
          'level': 'banner',
          'title': 't' * (kNoticeMaxTitleLength + 50),
          'body': 'b' * (kNoticeMaxBodyLength + 50),
        },
        <String, Object?>{'id': 'long', 'level': 'dialog', 'title': 'dup'},
        for (int i = 0; i < kNoticeMaxCount + 5; i++)
          <String, Object?>{'id': 'n$i', 'level': 'banner', 'title': 't'},
      ]);
      expect(notices, hasLength(kNoticeMaxCount));
      expect(notices.first.id, 'long');
      expect(notices.first.level, RemoteNoticeLevel.banner);
      expect(notices.first.title, hasLength(kNoticeMaxTitleLength));
      expect(notices.first.body, hasLength(kNoticeMaxBodyLength));
    });

    test('不是对象 / 缺 notices 数组：返回 null', () {
      expect(parseNoticeResponse('not json'), isNull);
      expect(parseNoticeResponse('[]'), isNull);
      expect(parseNoticeResponse('{"ttl":10}'), isNull);
    });

    test('缓存往返不变', () {
      const List<RemoteNotice> notices = <RemoteNotice>[
        RemoteNotice(
          id: 'a',
          level: RemoteNoticeLevel.block,
          title: 'T',
          body: 'B',
        ),
      ];
      expect(decodeCachedNotices(encodeCachedNotices(notices)), notices);
      expect(decodeCachedNotices(null), isEmpty);
      expect(decodeCachedNotices('{broken'), isEmpty);
    });
  });

  group('对话框只弹一次', () {
    const RemoteNotice dialogA = RemoteNotice(
      id: 'a',
      level: RemoteNoticeLevel.dialog,
      title: 'A',
      body: '',
    );
    const RemoteNotice dialogB = RemoteNotice(
      id: 'b',
      level: RemoteNoticeLevel.dialog,
      title: 'B',
      body: '',
    );
    const RemoteNotice banner = RemoteNotice(
      id: 'c',
      level: RemoteNoticeLevel.banner,
      title: 'C',
      body: '',
    );

    test('pendingDialogNotices 只给没弹过的对话框级通知', () {
      expect(
        pendingDialogNotices(
          <RemoteNotice>[dialogA, banner, dialogB],
          <String>['a'],
        ),
        <RemoteNotice>[dialogB],
      );
    });

    test('rememberSeenNoticeId 去重并限长', () {
      final List<String> seen = <String>['a'];
      expect(identical(rememberSeenNoticeId(seen, 'a'), seen), isTrue);
      expect(rememberSeenNoticeId(<String>['a', 'b'], 'c', cap: 2), <String>[
        'b',
        'c',
      ]);
    });
  });

  group('NoticeFeed', () {
    test('拉到通知即展示并缓存；重启先读缓存；空列表清掉缓存', () async {
      final PreferencesRepository prefs = await makePrefs();
      final List<Map<String, Object?>> requests = <Map<String, Object?>>[];
      String reply = jsonEncode(<String, Object?>{
        'notices': <Object?>[
          <String, Object?>{
            'id': 'a',
            'level': 'banner',
            'title': 'T',
            'body': 'B',
            'url': null,
          },
        ],
        'ttl': 600,
      });
      NoticeFeed makeFeed() => NoticeFeed(
        prefs: prefs,
        post: (Map<String, Object?> body) async {
          requests.add(body);
          return reply;
        },
        version: () => '9.9.9',
        channel: () => 'stable',
        locale: () => 'en',
        buildInfo: () async => const BuildInfo(),
        operatingSystem: 'linux',
      );

      final NoticeFeed first = makeFeed();
      first.start();
      expect(await first.refresh(), isTrue);
      expect(requests.last['v'], '9.9.9');
      expect(requests.last['p'], 'linux');
      expect(first.notices.value.single.id, 'a');
      expect(prefs.getPref(kNoticesCachePrefKey), isA<String>());
      await first.stop();
      first.dispose();

      // 重启后、请求回来之前：先展示缓存。
      reply = '{"notices":[],"ttl":600}';
      final NoticeFeed second = makeFeed();
      second.start();
      expect(second.notices.value.single.id, 'a');
      expect(await second.refresh(), isTrue);
      expect(second.notices.value, isEmpty);
      expect(prefs.getPref(kNoticesCachePrefKey), isNull);
      await second.stop();
      second.dispose();
    });

    test('请求失败：保留现有通知与缓存', () async {
      final PreferencesRepository prefs = await makePrefs();
      await prefs.setPref(
        kNoticesCachePrefKey,
        encodeCachedNotices(const <RemoteNotice>[
          RemoteNotice(
            id: 'a',
            level: RemoteNoticeLevel.banner,
            title: 'T',
            body: '',
          ),
        ]),
      );
      final NoticeFeed feed = NoticeFeed(
        prefs: prefs,
        post: (Map<String, Object?> body) async => throw StateError('offline'),
        version: () => '1',
        channel: () => 'stable',
        locale: () => 'en',
        buildInfo: () async => const BuildInfo(),
        operatingSystem: 'windows',
      );
      feed.start();
      expect(await feed.refresh(), isFalse);
      expect(feed.notices.value.single.id, 'a');
      expect(prefs.getPref(kNoticesCachePrefKey), isNotNull);
      await feed.stop();
      feed.dispose();
    });

    test('iOS 不拉取', () async {
      final PreferencesRepository prefs = await makePrefs();
      int calls = 0;
      final NoticeFeed feed = NoticeFeed(
        prefs: prefs,
        post: (Map<String, Object?> body) async {
          calls++;
          return '{"notices":[]}';
        },
        version: () => '1',
        channel: () => 'stable',
        locale: () => 'en',
        buildInfo: () async => const BuildInfo(),
        operatingSystem: 'ios',
      );
      feed.start();
      expect(feed.isSupported, isFalse);
      expect(await feed.refresh(), isFalse);
      expect(calls, 0);
      feed.dispose();
    });

    test('markDialogSeen 持久化，之后不再待弹', () async {
      final PreferencesRepository prefs = await makePrefs();
      final NoticeFeed feed = NoticeFeed(
        prefs: prefs,
        post: (Map<String, Object?> body) async => jsonEncode(<String, Object?>{
          'notices': <Object?>[
            <String, Object?>{'id': 'd', 'level': 'dialog', 'title': 'T'},
          ],
        }),
        version: () => '1',
        channel: () => 'stable',
        locale: () => 'en',
        buildInfo: () async => const BuildInfo(),
        operatingSystem: 'android',
      );
      feed.start();
      await feed.refresh();
      expect(feed.pendingDialogs.single.id, 'd');
      await feed.markDialogSeen('d');
      expect(feed.pendingDialogs, isEmpty);
      expect(decodeSeenNoticeIds(prefs.getPref(kNoticesSeenPrefKey)), <String>[
        'd',
      ]);
      await feed.stop();
      feed.dispose();
    });
  });

  test('通知相关偏好都是设备本地：不进备份 / 同步 / Profile 快照', () {
    for (final String key in <String>[
      kNoticesCachePrefKey,
      kNoticesSeenPrefKey,
    ]) {
      expect(PrefRedactionPolicy.isDeviceLocalOrCredential(key), isTrue);
      expect(ProfileKeys.isExcludedPref(key), isTrue, reason: key);
    }
  });
}
