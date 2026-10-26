import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/op_catalog_assembly.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_routes.dart';
import 'package:fushi/src/pages/implementations/video_download_subscription_edit_dialog.dart'
    show editVideoSubscriptionFilterJson, videoSubscriptionFilterValues;

/// 在线源 / 下载域撤销往返（spec §11）：真实描述 + 真实目录装配，路由 handler 换成
/// 内存替身（同 METHOD + pattern），验证「执行 → 撤销 → 回到执行前」与
/// 「执行后被手动改过 → 撤销报 superseded 且不覆盖」。

class _FakeApp implements AppModel {
  @override
  bool moduleEnabled(ModuleId module) => true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('撤销测试不应访问 AppModel.${invocation.memberName}');
}

class _FakeRef implements WidgetRef {
  final _FakeApp app = _FakeApp();

  @override
  T read<T>(ProviderListenable<T> provider) => app as T;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('撤销测试不应访问 ref.${invocation.memberName}');
}

typedef _Handler = Future<Object?> Function(CtlCall call);

/// 内存里的在线源 / 下载 / 书架 / 播放状态，外加按 `METHOD pattern` 的替身 handler。
class _World {
  final Map<String, List<Map<String, Object?>>> repos =
      <String, List<Map<String, Object?>>>{
        'manga': <Map<String, Object?>>[
          <String, Object?>{'url': 'http://old.example/index.json'},
        ],
      };
  final Map<String, Map<String, Object?>> installed =
      <String, Map<String, Object?>>{
        'eu.ext.a': <String, Object?>{
          'id': 'eu.ext.a',
          'version': '1.0',
          'enabled': true,
        },
      };
  final List<Map<String, Object?>> preferences = <Map<String, Object?>>[
    <String, Object?>{
      'key': 'quality',
      'kind': 'list',
      'value': 0,
      'entries': <String>['Low', 'High', 'Max'],
    },
  ];
  final Map<String, Map<String, Object?>> shelf =
      <String, Map<String, Object?>>{};
  final Map<String, Map<String, Object?>> mangaJobs =
      <String, Map<String, Object?>>{};
  final Map<String, Map<String, Object?>> episodes =
      <String, Map<String, Object?>>{};
  Map<String, Object?> subscription = <String, Object?>{
    'subscriptionId': 's1',
    'searchQuery': 'frieren',
    'startAfterEpisode': null,
    'subtitlePolicy': 'auto',
    'targetSourceId': 3,
    'enabled': true,
    'filterJson': '{"releaseGroup":["SubsPlease"]}',
  };
  Map<String, Object?> playback = <String, Object?>{
    'active': true,
    'kind': 'video',
    'ready': true,
    'bookUid': 'video/1',
    'playing': true,
    'positionMs': 10000,
    'speed': 1.0,
  };
  int _nextJob = 0;
  final List<String> deletedBooks = <String>[];

  static Never _missing(String what) => throw CtlFailure.notFound(what);

  Map<String, _Handler> handlers() => <String, _Handler>{
    'GET /api/admin/extensions/repos': (CtlCall c) async => <String, Object?>{
      'repos': repos[c.optString('kind')] ?? <Map<String, Object?>>[],
    },
    'POST /api/admin/extensions/repos': (CtlCall c) async {
      final String url = c.requireString('url');
      if (url.startsWith('http:') && c.optBool('allowInsecure') != true) {
        throw const CtlFailure.rejected('plain http');
      }
      final List<Map<String, Object?>> list = repos.putIfAbsent(
        c.optString('kind')!,
        () => <Map<String, Object?>>[],
      );
      if (!list.any((Map<String, Object?> r) => r['url'] == url)) {
        list.add(<String, Object?>{'url': url});
      }
      return <String, Object?>{'url': url};
    },
    'DELETE /api/admin/extensions/repos': (CtlCall c) async {
      expect(c.optBool('confirm'), isTrue);
      final List<Map<String, Object?>> list =
          repos[c.optString('kind')] ?? <Map<String, Object?>>[];
      final int before = list.length;
      list.removeWhere(
        (Map<String, Object?> r) => r['url'] == c.requireString('url'),
      );
      if (list.length == before) _missing('repo');
      return null;
    },
    'GET /api/admin/extensions': (CtlCall c) async => <String, Object?>{
      'installed': installed.values.toList(),
    },
    'POST /api/admin/extensions/install': (CtlCall c) async {
      final String id = c.requireString('id');
      installed[id] = <String, Object?>{
        'id': id,
        'version': '2.0',
        'enabled': true,
      };
      return <String, Object?>{'id': id, 'version': '2.0'};
    },
    'DELETE /api/admin/extensions/:id': (CtlCall c) async {
      expect(c.optBool('confirm'), isTrue);
      expect(c.optBool('clearData'), isNot(true));
      if (installed.remove(c.params['id']) == null) _missing('ext');
      return null;
    },
    'POST /api/admin/extensions/:id/enabled': (CtlCall c) async {
      final Map<String, Object?> row =
          installed[c.params['id']] ?? _missing('ext');
      row['enabled'] = c.optBool('enabled');
      return <String, Object?>{'id': c.params['id'], 'enabled': row['enabled']};
    },
    'GET /api/admin/sources/:sourceId/preferences': (CtlCall c) async =>
        <String, Object?>{'preferences': preferences},
    'POST /api/admin/sources/:sourceId/preferences': (CtlCall c) async {
      final Map<String, Object?> pref = preferences.firstWhere(
        (Map<String, Object?> p) => p['key'] == c.requireString('key'),
      );
      final String raw = '${c.body['value']}';
      final List<String> entries = pref['entries']! as List<String>;
      pref['value'] = raw.startsWith('#')
          ? int.parse(raw.substring(1)) - 1
          : entries.indexOf(raw);
      return <String, Object?>{'preferences': preferences};
    },
    'POST /api/admin/sources/:sourceId/library': (CtlCall c) async {
      shelf['book:m1'] = <String, Object?>{'key': 'book:m1', 'percent': 0};
      return <String, Object?>{'bookKey': 'm1', 'title': 'Manga'};
    },
    'POST /api/admin/sources/:sourceId/downloads': (CtlCall c) async {
      shelf['book:m1'] = <String, Object?>{'key': 'book:m1', 'percent': 0};
      for (int i = 0; i < 2; i++) {
        final String id = 'j${++_nextJob}';
        mangaJobs[id] = <String, Object?>{
          'id': id,
          'bookKey': 'm1',
          'status': 'queued',
        };
      }
      return <String, Object?>{'bookKey': 'm1', 'title': 'Manga', 'queued': 2};
    },
    'GET /api/admin/library/items': (CtlCall c) async => <String, Object?>{
      'items': shelf.values.toList(),
    },
    'GET /api/admin/library/items/:key': (CtlCall c) async =>
        shelf[c.params['key']] ?? _missing('item'),
    'DELETE /api/admin/library/items/:key': (CtlCall c) async {
      expect(c.optBool('confirm'), isTrue);
      expect(c.optBool('deleteFiles'), isNot(true));
      if (shelf.remove(c.params['key']) == null) _missing('item');
      deletedBooks.add(c.params['key']!);
      return null;
    },
    'GET /api/admin/online/manga-downloads': (CtlCall c) async =>
        <String, Object?>{
          'jobs': <Map<String, Object?>>[
            for (final Map<String, Object?> j in mangaJobs.values)
              if (c.optString('book') == null ||
                  j['bookKey'] == c.optString('book'))
                j,
          ],
        },
    'POST /api/admin/online/manga-downloads/:id/cancel': (CtlCall c) async {
      final Map<String, Object?> job =
          mangaJobs[c.params['id']] ?? _missing('job');
      if (job['status'] != 'queued' && job['status'] != 'running') {
        throw const CtlFailure.conflict('finished');
      }
      job['status'] = 'cancelled';
      return job;
    },
    'POST /api/admin/online/manga-downloads/:id/retry': (CtlCall c) async {
      final Map<String, Object?> job =
          mangaJobs[c.params['id']] ?? _missing('job');
      if (job['status'] != 'failed' && job['status'] != 'cancelled') {
        throw const CtlFailure.conflict('not retryable');
      }
      job['status'] = 'queued';
      return job;
    },
    'DELETE /api/admin/online/manga-downloads/:id': (CtlCall c) async {
      expect(c.optBool('confirm'), isTrue);
      if (mangaJobs.remove(c.params['id']) == null) _missing('job');
      return null;
    },
    'POST /api/admin/online/episode-downloads/:id/pause': (CtlCall c) async {
      final Map<String, Object?> task =
          episodes[c.params['id']] ?? _missing('task');
      if (task['status'] != 'running') throw const CtlFailure.conflict('no');
      task['status'] = 'paused';
      return task;
    },
    'POST /api/admin/online/episode-downloads/:id/resume': (CtlCall c) async {
      final Map<String, Object?> task =
          episodes[c.params['id']] ?? _missing('task');
      if (task['status'] != 'paused') throw const CtlFailure.conflict('no');
      task['status'] = 'running';
      return task;
    },
    'GET /api/admin/subscriptions/:id': (CtlCall c) async =>
        c.params['id'] == 's1' ? subscription : _missing('sub'),
    'POST /api/admin/subscriptions/:id/enable': (CtlCall c) async {
      subscription = <String, Object?>{
        ...subscription,
        'enabled': c.optBool('enabled'),
      };
      return subscription;
    },
    'PUT /api/admin/subscriptions/:id': (CtlCall c) async {
      final Map<String, Object?> next = <String, Object?>{...subscription};
      for (final String key in <String>['searchQuery', 'subtitlePolicy']) {
        if (c.body.containsKey(key)) next[key] = c.body[key];
      }
      if (c.body.containsKey('startAfterEpisode')) {
        next['startAfterEpisode'] = c.optInt('startAfterEpisode');
      }
      if (c.body.containsKey('source')) {
        next['targetSourceId'] = c.optInt('source');
      }
      const List<String> rules = <String>[
        'releaseGroups',
        'resolutions',
        'titleIncludes',
        'titleExcludes',
      ];
      if (rules.any(c.body.containsKey)) {
        final String old = '${subscription['filterJson']}';
        List<String> rule(String body, String key) => c.body.containsKey(body)
            ? c.stringList(body)
            : videoSubscriptionFilterValues(old, key);
        next['filterJson'] = editVideoSubscriptionFilterJson(
          old,
          releaseGroups: rule('releaseGroups', 'releaseGroup'),
          resolutions: rule('resolutions', 'resolution'),
          titleIncludes: rule('titleIncludes', 'titleInclude'),
          titleExcludes: rule('titleExcludes', 'titleExclude'),
        );
      }
      subscription = next;
      return subscription;
    },
    'GET /api/admin/playback': (CtlCall c) async => playback,
    'POST /api/admin/playback/seek': (CtlCall c) async {
      final num seconds = c.body['seconds']! as num;
      final int ms = (seconds * 1000).round();
      playback = <String, Object?>{
        ...playback,
        'positionMs': c.optBool('relative') == true
            ? (playback['positionMs']! as int) + ms
            : ms,
      };
      return playback;
    },
    'POST /api/admin/playback/control': (CtlCall c) async {
      playback = <String, Object?>{
        ...playback,
        'playing': switch (c.requireString('action')) {
          'pause' => false,
          'resume' => true,
          'toggle' => playback['playing'] != true,
          _ => playback['playing'],
        },
      };
      return playback;
    },
    'POST /api/admin/playback/rate': (CtlCall c) async {
      playback = <String, Object?>{...playback, 'speed': c.body['rate']};
      return playback;
    },
  };
}

void main() {
  late _World world;
  late OpCatalog catalog;
  late OpInvoker invoker;

  setUp(() {
    world = _World();
    final OpContext context = OpContext(ref: _FakeRef());
    final Map<String, _Handler> fakes = world.handlers();
    final List<CtlRoute> routes = <CtlRoute>[
      for (final CtlRoute route in buildDomainOpRoutes(context))
        if (fakes['${route.method} ${route.pattern}'] case final _Handler fake)
          CtlRoute(route.method, route.pattern, fake)
        else
          route,
    ];
    final Set<String> registered = <String>{
      for (final CtlRoute r in routes) '${r.method} ${r.pattern}',
    };
    expect(
      fakes.keys.where((String k) => !registered.contains(k)),
      isEmpty,
      reason: '替身对应的路由必须真实存在',
    );
    catalog = buildAppOpCatalog(context, routes);
    invoker = OpInvoker(catalog);
  });

  Future<OpUndoRecord> run(
    String id,
    Map<String, Object?> args, {
    Set<String> gates = const <String>{},
  }) async {
    final FushiOp op = catalog[id]!;
    final OpInvocation invocation = await invoker.invoke(
      id,
      args,
      caller: OpCaller.model,
      // 可逆操作：运行时直接注入全部表态参数（spec §5.2）。
      grantedGates: <String>{
        for (final OpParam p in op.params)
          if (p.userGate && gates.contains(p.name)) p.name,
      },
      captureUndo: true,
    );
    expect(invocation.undo, isNotNull, reason: '$id 应返回撤销载荷');
    // 载荷要能持久化进 ai_agent_actions：JSON 往返不变。
    final Map<String, Object?> payload = invocation.undo!.payload;
    expect(jsonDecode(jsonEncode(payload)), payload);
    return invocation.undo!;
  }

  Future<OpUndoOutcome> revert(String id, OpUndoRecord record) =>
      catalog[id]!.undo!.revert(
        (jsonDecode(jsonEncode(record.payload)) as Map).cast<String, Object?>(),
      );

  group('扩展仓库', () {
    test('添加仓库 → 撤销删掉新仓库', () async {
      final OpUndoRecord r = await run('online.repo.add', <String, Object?>{
        'kind': 'manga',
        'url': 'https://new.example/index.json',
      });
      expect(world.repos['manga'], hasLength(2));
      expect((await revert('online.repo.add', r)).status, OpUndoStatus.done);
      expect(
        world.repos['manga']!.map((Map<String, Object?> e) => e['url']),
        <Object?>['http://old.example/index.json'],
      );
    });

    test('添加的是已有仓库 → 撤销不删', () async {
      final OpUndoRecord r = await run(
        'online.repo.add',
        <String, Object?>{
          'kind': 'manga',
          'url': 'http://old.example/index.json',
        },
        gates: <String>{'allowInsecure'},
      );
      expect((await revert('online.repo.add', r)).status, OpUndoStatus.done);
      expect(world.repos['manga'], hasLength(1));
    });

    test('删除明文仓库 → 撤销按原 scheme 放行加回', () async {
      final OpUndoRecord r = await run(
        'online.repo.remove',
        <String, Object?>{
          'kind': 'manga',
          'url': 'http://old.example/index.json',
        },
        gates: <String>{'confirm'},
      );
      expect(world.repos['manga'], isEmpty);
      expect((await revert('online.repo.remove', r)).status, OpUndoStatus.done);
      expect(world.repos['manga'], hasLength(1));
    });

    test('删除后用户手动加回 → 撤销 superseded', () async {
      final OpUndoRecord r = await run(
        'online.repo.remove',
        <String, Object?>{
          'kind': 'manga',
          'url': 'http://old.example/index.json',
        },
        gates: <String>{'confirm'},
      );
      world.repos['manga']!.add(<String, Object?>{
        'url': 'http://old.example/index.json',
      });
      expect(
        (await revert('online.repo.remove', r)).status,
        OpUndoStatus.superseded,
      );
      expect(world.repos['manga'], hasLength(1));
    });
  });

  group('扩展', () {
    test('安装新扩展 → 撤销卸载（不清数据）', () async {
      final OpUndoRecord r = await run(
        'online.extension.install',
        <String, Object?>{'kind': 'manga', 'id': 'eu.ext.b'},
        gates: <String>{'trustSigner'},
      );
      expect(world.installed, contains('eu.ext.b'));
      expect(
        (await revert('online.extension.install', r)).status,
        OpUndoStatus.done,
      );
      expect(world.installed.keys, <String>['eu.ext.a']);
    });

    test('覆盖安装已装扩展 → 撤销拒绝卸载', () async {
      final OpUndoRecord r = await run(
        'online.extension.install',
        <String, Object?>{'kind': 'manga', 'id': 'eu.ext.a'},
      );
      expect(
        (await revert('online.extension.install', r)).status,
        OpUndoStatus.failed,
      );
      expect(world.installed, contains('eu.ext.a'));
    });

    test('启停 → 撤销恢复；之后被手动改过 → superseded 不覆盖', () async {
      OpUndoRecord r = await run(
        'online.extension.set-enabled',
        <String, Object?>{'kind': 'manga', 'id': 'eu.ext.a', 'enabled': false},
      );
      expect(world.installed['eu.ext.a']!['enabled'], isFalse);
      expect(
        (await revert('online.extension.set-enabled', r)).status,
        OpUndoStatus.done,
      );
      expect(world.installed['eu.ext.a']!['enabled'], isTrue);

      r = await run('online.extension.set-enabled', <String, Object?>{
        'kind': 'manga',
        'id': 'eu.ext.a',
        'enabled': false,
      });
      world.installed['eu.ext.a']!['enabled'] = true; // 用户手动又打开
      expect(
        (await revert('online.extension.set-enabled', r)).status,
        OpUndoStatus.superseded,
      );
      expect(world.installed['eu.ext.a']!['enabled'], isTrue);
    });
  });

  group('源偏好', () {
    test('改 list 偏好 → 撤销按 #N 写回旧下标', () async {
      final OpUndoRecord r = await run(
        'online.source.set-pref',
        <String, Object?>{
          'kind': 'manga',
          'sourceId': '42',
          'key': 'quality',
          'value': 'High',
        },
      );
      expect(world.preferences.single['value'], 1);
      expect(
        (await revert('online.source.set-pref', r)).status,
        OpUndoStatus.done,
      );
      expect(world.preferences.single['value'], 0);
    });

    test('改完用户又改 → superseded 不覆盖', () async {
      final OpUndoRecord r = await run(
        'online.source.set-pref',
        <String, Object?>{
          'kind': 'manga',
          'sourceId': '42',
          'key': 'quality',
          'value': 'High',
        },
      );
      world.preferences.single['value'] = 2; // 用户在偏好弹窗里又改了
      expect(
        (await revert('online.source.set-pref', r)).status,
        OpUndoStatus.superseded,
      );
      expect(world.preferences.single['value'], 2);
    });
  });

  group('入书架 / 下载', () {
    test('加入书架 → 撤销删掉新建的书架条目', () async {
      final OpUndoRecord r = await run('online.source.add', <String, Object?>{
        'kind': 'manga',
        'sourceId': '42',
        'url': '/m/1',
      });
      expect(world.shelf, contains('book:m1'));
      expect((await revert('online.source.add', r)).status, OpUndoStatus.done);
      expect(world.shelf, isEmpty);
    });

    test('加入书架后读过 → superseded 保留', () async {
      final OpUndoRecord r = await run('online.source.add', <String, Object?>{
        'kind': 'manga',
        'sourceId': '42',
        'url': '/m/1',
      });
      world.shelf['book:m1']!['percent'] = 12;
      expect(
        (await revert('online.source.add', r)).status,
        OpUndoStatus.superseded,
      );
      expect(world.shelf, contains('book:m1'));
    });

    test('书执行前就在书架 → 撤销不删', () async {
      world.shelf['book:m1'] = <String, Object?>{'key': 'book:m1'};
      final OpUndoRecord r = await run('online.source.add', <String, Object?>{
        'kind': 'manga',
        'sourceId': '42',
        'url': '/m/1',
      });
      expect((await revert('online.source.add', r)).status, OpUndoStatus.done);
      expect(world.shelf, contains('book:m1'));
    });

    test('漫画下载 → 撤销取消并删除新入队任务与新书架条目，旧任务不动', () async {
      world.mangaJobs['old'] = <String, Object?>{
        'id': 'old',
        'bookKey': 'm1',
        'status': 'done',
      };
      final OpUndoRecord r = await run(
        'online.source.download',
        <String, Object?>{'kind': 'manga', 'sourceId': '42', 'url': '/m/1'},
      );
      expect(world.mangaJobs, hasLength(3));
      expect(
        (await revert('online.source.download', r)).status,
        OpUndoStatus.done,
      );
      expect(world.mangaJobs.keys, <String>['old']);
      expect(world.shelf, isEmpty);
    });

    test('anime 加入媒体库不可追踪 → 撤销如实失败', () async {
      final OpUndoRecord r = await run('online.source.add', <String, Object?>{
        'kind': 'anime',
        'sourceId': '42',
        'url': '/a/1',
      });
      expect(
        (await revert('online.source.add', r)).status,
        OpUndoStatus.failed,
      );
    });
  });

  group('下载队列（反向路由）', () {
    test('取消漫画任务 → 撤销重新入队；被手动重试过 → superseded', () async {
      world.mangaJobs['j'] = <String, Object?>{'id': 'j', 'status': 'queued'};
      OpUndoRecord r = await run(
        'online.manga-download.cancel',
        <String, Object?>{'id': 'j'},
      );
      expect(world.mangaJobs['j']!['status'], 'cancelled');
      expect(
        (await revert('online.manga-download.cancel', r)).status,
        OpUndoStatus.done,
      );
      expect(world.mangaJobs['j']!['status'], 'queued');

      r = await run('online.manga-download.cancel', <String, Object?>{
        'id': 'j',
      });
      world.mangaJobs['j']!['status'] = 'done'; // 用户手动重试且已下完
      expect(
        (await revert('online.manga-download.cancel', r)).status,
        OpUndoStatus.superseded,
      );
      expect(world.mangaJobs['j']!['status'], 'done');
    });

    test('暂停剧集 → 撤销继续；继续 → 撤销暂停', () async {
      world.episodes['e'] = <String, Object?>{'id': 'e', 'status': 'running'};
      final OpUndoRecord paused = await run(
        'online.episode-download.pause',
        <String, Object?>{'id': 'e'},
      );
      expect(world.episodes['e']!['status'], 'paused');
      expect(
        (await revert('online.episode-download.pause', paused)).status,
        OpUndoStatus.done,
      );
      expect(world.episodes['e']!['status'], 'running');

      world.episodes['e']!['status'] = 'paused';
      final OpUndoRecord resumed = await run(
        'online.episode-download.resume',
        <String, Object?>{'id': 'e'},
      );
      expect(
        (await revert('online.episode-download.resume', resumed)).status,
        OpUndoStatus.done,
      );
      expect(world.episodes['e']!['status'], 'paused');
    });
  });

  group('订阅', () {
    test('启停 → 撤销恢复；被手动改过 → superseded', () async {
      OpUndoRecord r = await run(
        'downloads.subscription.set-enabled',
        <String, Object?>{'id': 's1', 'enabled': false},
      );
      expect(world.subscription['enabled'], isFalse);
      expect(
        (await revert('downloads.subscription.set-enabled', r)).status,
        OpUndoStatus.done,
      );
      expect(world.subscription['enabled'], isTrue);

      r = await run('downloads.subscription.set-enabled', <String, Object?>{
        'id': 's1',
        'enabled': false,
      });
      world.subscription = <String, Object?>{
        ...world.subscription,
        'enabled': true,
      };
      expect(
        (await revert('downloads.subscription.set-enabled', r)).status,
        OpUndoStatus.superseded,
      );
      expect(world.subscription['enabled'], isTrue);
    });

    test('编辑查询词与字幕组 → 撤销只写回改过的列', () async {
      final Map<String, Object?> before = <String, Object?>{
        ...world.subscription,
      };
      final OpUndoRecord r = await run(
        'downloads.subscription.edit',
        <String, Object?>{
          'id': 's1',
          'searchQuery': 'sousou no frieren',
          'releaseGroups': <String>['Erai'],
        },
      );
      expect(world.subscription['searchQuery'], 'sousou no frieren');
      expect(
        videoSubscriptionFilterValues(
          '${world.subscription['filterJson']}',
          'releaseGroup',
        ),
        <String>['Erai'],
      );
      expect(
        (await revert('downloads.subscription.edit', r)).status,
        OpUndoStatus.done,
      );
      expect(world.subscription['searchQuery'], before['searchQuery']);
      expect(
        videoSubscriptionFilterValues(
          '${world.subscription['filterJson']}',
          'releaseGroup',
        ),
        <String>['SubsPlease'],
      );
      expect(world.subscription['subtitlePolicy'], before['subtitlePolicy']);
    });

    test('编辑后用户又改了查询词 → superseded 不覆盖', () async {
      final OpUndoRecord r = await run(
        'downloads.subscription.edit',
        <String, Object?>{'id': 's1', 'searchQuery': 'a'},
      );
      world.subscription = <String, Object?>{
        ...world.subscription,
        'searchQuery': 'b',
      };
      expect(
        (await revert('downloads.subscription.edit', r)).status,
        OpUndoStatus.superseded,
      );
      expect(world.subscription['searchQuery'], 'b');
    });
  });

  group('播放', () {
    test('跳转 → 撤销回到原位置', () async {
      final OpUndoRecord r = await run('playback.seek', <String, Object?>{
        'seconds': 90,
      });
      expect(world.playback['positionMs'], 90000);
      expect((await revert('playback.seek', r)).status, OpUndoStatus.done);
      expect(world.playback['positionMs'], 10000);
    });

    test('暂停 → 撤销恢复播放；换了视频 → superseded', () async {
      OpUndoRecord r = await run('playback.control', <String, Object?>{
        'action': 'pause',
      });
      expect(world.playback['playing'], isFalse);
      expect((await revert('playback.control', r)).status, OpUndoStatus.done);
      expect(world.playback['playing'], isTrue);

      r = await run('playback.control', <String, Object?>{'action': 'pause'});
      world.playback = <String, Object?>{
        ...world.playback,
        'bookUid': 'video/2',
      };
      expect(
        (await revert('playback.control', r)).status,
        OpUndoStatus.superseded,
      );
      expect(world.playback['playing'], isFalse);
    });

    test('倍速 → 撤销恢复；之后被手动改过 → superseded', () async {
      OpUndoRecord r = await run('playback.rate', <String, Object?>{
        'rate': 1.5,
      });
      expect((await revert('playback.rate', r)).status, OpUndoStatus.done);
      expect(world.playback['speed'], 1.0);

      r = await run('playback.rate', <String, Object?>{'rate': 1.5});
      world.playback = <String, Object?>{...world.playback, 'speed': 2.0};
      expect(
        (await revert('playback.rate', r)).status,
        OpUndoStatus.superseded,
      );
      expect(world.playback['speed'], 2.0);
    });
  });

  test('本域装扩展类操作都强制确认，表态参数不进模型 schema', () {
    for (final String id in <String>[
      'online.repo.add',
      'online.extension.install',
      'online.extension.update',
    ]) {
      final FushiOp op = catalog[id]!;
      expect(op.spec.needsConfirmation, isTrue, reason: id);
      final Map<String, Object?> properties =
          (op.spec.modelSchema()['properties']! as Map).cast<String, Object?>();
      for (final OpParam gate in op.params.where((OpParam p) => p.userGate)) {
        expect(properties.containsKey(gate.name), isFalse, reason: id);
      }
    }
    expect(catalog['online.repo.add']!.undo, isNotNull);
    expect(catalog['online.extension.install']!.undo, isNotNull);
  });
}
