import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart'
    show DuplicatePolicy;

import 'package:fushi_core/fushi_core.dart'
    show LocalFileDeleteFailure, LocalFileDeleteReport, MangaDownloadJobRow;
import 'package:fushi_engine/media/video/video_book_repository.dart'
    show VideoBookDeleteFailure;

import 'package:fushi/src/media/downloads/download_start_result.dart';
import 'package:fushi/src/media/novel/online/lnreader_book_download.dart';
import 'package:fushi/src/ops/ctl_online_downloads.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';

import 'package:fushi/src/media/video/video_playback_remote.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/ops/ctl_online_routes.dart';
import 'package:fushi/src/ops/ctl_online_support.dart';
import 'package:fushi/src/ops/op_context.dart';

/// 路由表构建期不碰 ref；任何访问都说明构建期越界读了 app 状态。
class _NoRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('构建路由表时不应访问 ref：${invocation.memberName}');
}

/// 下载替身：等 [gate] 放行后逐章报进度，章节之间看取消标记（同真实实现的检查点）。
class _FakeDownload implements LnReaderBookDownload {
  final Completer<void> gate = Completer<void>();

  @override
  Future<String> run({
    required LnReaderInstalledPlugin plugin,
    required LnReaderNovel novel,
    required List<LnReaderChapter> chapters,
    required DuplicatePolicy policy,
    LnReaderDownloadProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    await gate.future;
    for (int i = 0; i < chapters.length; i++) {
      if (isCancelled?.call() ?? false) throw const LnReaderDownloadCancelled();
      onProgress?.call(i + 1, chapters.length);
    }
    return 'book-1';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

Matcher _badRequest() => throwsA(
  isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 400),
);

void main() {
  group('buildOnlineCtlRoutes', () {
    final List<CtlRoute> routes = buildOnlineCtlRoutes(
      OpContext(ref: _NoRef(), focusMainWindow: () async {}),
    );

    test('路径都在 /api/admin/ 下，method + path 不重复', () {
      expect(routes, isNotEmpty);
      final Set<String> seen = <String>{};
      for (final CtlRoute route in routes) {
        expect(route.pattern, startsWith('/api/admin/'));
        expect(
          seen.add('${route.method} ${route.pattern}'),
          isTrue,
          reason: '重复路由 ${route.method} ${route.pattern}',
        );
      }
    });

    test('静态段路由不会被同长度的参数路由抢先匹配', () {
      // 服务端按注册顺序取第一条匹配：`/extensions/repos` 必须排在
      // `/extensions/:id` 之前（DELETE 两条同形）。
      CtlRoute? first(String method, String path) {
        for (final CtlRoute route in routes) {
          if (route.method == method && route.match(path) != null) return route;
        }
        return null;
      }

      expect(
        first('DELETE', '/api/admin/extensions/repos')?.pattern,
        '/api/admin/extensions/repos',
      );
      expect(
        first('DELETE', '/api/admin/extensions/eu.x')?.pattern,
        '/api/admin/extensions/:id',
      );
      expect(
        first('GET', '/api/admin/sources/123/search')?.pattern,
        '/api/admin/sources/:sourceId/search',
      );
      expect(
        first('POST', '/api/admin/extensions/repos/sync')?.pattern,
        '/api/admin/extensions/repos/sync',
      );
      expect(
        first('POST', '/api/admin/extensions/eu.x/enabled')?.pattern,
        '/api/admin/extensions/:id/enabled',
      );
    });

    test('源管理 / 筛选浏览 / 任务取消 / AI 下载会话都已注册', () {
      final Set<String> registered = <String>{
        for (final CtlRoute route in routes) '${route.method} ${route.pattern}',
      };
      expect(
        registered,
        containsAll(<String>[
          'POST /api/admin/extensions/:id/enabled',
          'POST /api/admin/sources/:sourceId/settings',
          'GET /api/admin/sources/:sourceId/preferences',
          'POST /api/admin/sources/:sourceId/preferences',
          'DELETE /api/admin/sources/:sourceId/data',
          'GET /api/admin/sources/:sourceId/filters',
          'POST /api/admin/sources/:sourceId/browse',
          'POST /api/admin/online/tasks/:id/cancel',
          'POST /api/admin/ai-download/sessions',
          'GET /api/admin/ai-download/sessions/:id',
          'POST /api/admin/ai-download/sessions/:id/choose',
          'POST /api/admin/ai-download/sessions/:id/confirm',
          'POST /api/admin/ai-download/sessions/:id/cancel',
          'DELETE /api/admin/ai-download/sessions/:id',
          'GET /api/admin/online/manga-downloads',
          'DELETE /api/admin/online/manga-downloads',
          'POST /api/admin/online/manga-downloads/:id/cancel',
          'POST /api/admin/online/manga-downloads/:id/retry',
          'DELETE /api/admin/online/manga-downloads/:id',
          'GET /api/admin/online/episode-downloads',
          'GET /api/admin/online/episode-downloads/:id',
          'POST /api/admin/online/episode-downloads/:id/pause',
          'POST /api/admin/online/episode-downloads/:id/resume',
          'DELETE /api/admin/online/episode-downloads/:id',
        ]),
      );
    });
  });

  group('OnlineCtlKind.parse', () {
    test('名字与别名', () {
      expect(OnlineCtlKind.parse('manga'), OnlineCtlKind.manga);
      expect(OnlineCtlKind.parse('Video'), OnlineCtlKind.anime);
      expect(OnlineCtlKind.parse('anime'), OnlineCtlKind.anime);
      expect(OnlineCtlKind.parse('book'), OnlineCtlKind.novel);
      expect(
        OnlineCtlKind.parse(null, fallback: OnlineCtlKind.novel),
        OnlineCtlKind.novel,
      );
    });

    test('缺失 / 未知抛 400', () {
      expect(() => OnlineCtlKind.parse(null), _badRequest());
      expect(() => OnlineCtlKind.parse('music'), _badRequest());
    });
  });

  group('parseCtlIndexRanges', () {
    test('空 / all = 全部', () {
      expect(parseCtlIndexRanges(null, 3), <int>[0, 1, 2]);
      expect(parseCtlIndexRanges('all', 2), <int>[0, 1]);
    });

    test('区间、单项、开放尾、去重排序', () {
      expect(parseCtlIndexRanges('1-3,5', 6), <int>[0, 1, 2, 4]);
      expect(parseCtlIndexRanges('5-', 6), <int>[4, 5]);
      expect(parseCtlIndexRanges('-2', 6), <int>[0, 1]);
      expect(parseCtlIndexRanges('3,1-2,2', 6), <int>[0, 1, 2]);
      expect(parseCtlIndexRanges(' 2 - 3 ', 6), <int>[1, 2]);
    });

    test('越界与坏格式抛 400，不静默截断', () {
      expect(() => parseCtlIndexRanges('1-10', 8), _badRequest());
      expect(() => parseCtlIndexRanges('0', 8), _badRequest());
      expect(() => parseCtlIndexRanges('3-1', 8), _badRequest());
      expect(() => parseCtlIndexRanges('a', 8), _badRequest());
      expect(() => parseCtlIndexRanges('-', 8), _badRequest());
      expect(() => parseCtlIndexRanges(',', 8), _badRequest());
    });
  });

  group('CtlOnlineTaskRegistry', () {
    test('登记、查询、结束，超出上限只淘汰最旧的已结束任务', () {
      int now = 0;
      final CtlOnlineTaskRegistry registry = CtlOnlineTaskRegistry(
        clock: () => ++now,
        maxFinished: 2,
      );
      final CtlOnlineTask a = registry.start(
        kind: 'novel',
        title: 'a',
        total: 3,
      );
      final CtlOnlineTask b = registry.start(
        kind: 'novel',
        title: 'b',
        total: 1,
      );
      final CtlOnlineTask c = registry.start(
        kind: 'novel',
        title: 'c',
        total: 1,
      );
      final CtlOnlineTask running = registry.start(
        kind: 'novel',
        title: 'd',
        total: 1,
      );
      expect(registry.byId(a.id), same(a));
      registry
        ..finish(a, status: 'done', resultKey: 'k')
        ..finish(b, status: 'failed', error: 'x')
        ..finish(c, status: 'cancelled');
      expect(registry.byId(a.id), isNull);
      expect(registry.tasks, <CtlOnlineTask>[b, c, running]);
      expect(b.toJson()['error'], 'x');
      expect(running.toJson()['status'], 'running');
      expect(c.toJson()['finishedAt'], isNotNull);
    });

    test('取消：运行中的任务打上标记，已结束 409，不存在 404', () {
      final CtlOnlineTaskRegistry registry = CtlOnlineTaskRegistry();
      final CtlOnlineTask task = registry.start(
        kind: 'novel',
        title: 'a',
        total: 3,
      );
      expect(registry.cancel(task.id), same(task));
      expect(task.cancelRequested, isTrue);
      expect(task.toJson()['cancelRequested'], isTrue);
      registry.finish(task, status: 'cancelled');
      expect(task.toJson().containsKey('cancelRequested'), isFalse);
      expect(
        () => registry.cancel(task.id),
        throwsA(
          isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 409),
        ),
      );
      expect(
        () => registry.cancel('t999'),
        throwsA(
          isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 404),
        ),
      );
    });
  });

  group('startCtlNovelDownloadTask', () {
    const LnReaderInstalledPlugin plugin = LnReaderInstalledPlugin(
      id: 'p',
      name: 'P',
      site: 'https://p',
      lang: 'ja',
      version: '1',
      url: 'https://p/p.js',
      iconUrl: '',
      storeUrl: 'https://store',
      enabled: true,
      pinned: false,
      sortOrder: 0,
      installedAt: 0,
    );
    const LnReaderNovel novel = LnReaderNovel(
      name: '书',
      path: '/n',
      totalPages: 1,
      chapters: <LnReaderChapter>[
        LnReaderChapter(name: '一', path: '/1'),
        LnReaderChapter(name: '二', path: '/2'),
      ],
    );

    Future<void> settle(CtlOnlineTask task) async {
      for (int i = 0; i < 50 && task.status == 'running'; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('完成：进度、入库 key、书架刷新', () async {
      final _FakeDownload download = _FakeDownload();
      final CtlOnlineTaskRegistry registry = CtlOnlineTaskRegistry();
      int refreshed = 0;
      final CtlOnlineTask task = startCtlNovelDownloadTask(
        download: download,
        plugin: plugin,
        novel: novel,
        chapters: novel.chapters,
        onShelfChanged: () => refreshed++,
        registry: registry,
      );
      expect(task.status, 'running');
      download.gate.complete();
      await settle(task);
      expect(task.status, 'done');
      expect(task.done, 2);
      expect(task.resultKey, 'book-1');
      expect(refreshed, 1);
    });

    test('取消：标记经 isCancelled 传到下载，任务转为 cancelled', () async {
      final _FakeDownload download = _FakeDownload();
      final CtlOnlineTaskRegistry registry = CtlOnlineTaskRegistry();
      final CtlOnlineTask task = startCtlNovelDownloadTask(
        download: download,
        plugin: plugin,
        novel: novel,
        chapters: novel.chapters,
        onShelfChanged: () => fail('取消后不应刷新书架'),
        registry: registry,
      );
      registry.cancel(task.id);
      download.gate.complete();
      await settle(task);
      expect(task.status, 'cancelled');
      expect(task.resultKey, isNull);
    });
  });

  group('在线源下载任务应答', () {
    test('漫画任务行', () {
      final Map<String, Object?> json = ctlMangaDownloadJobJson(
        const MangaDownloadJobRow(
          jobId: 'j1',
          kind: 'chapter',
          bookKey: 'bk',
          chapterKey: 'c1',
          runtime: 'mihon',
          title: 'T',
          chapterTitle: '第1话',
          status: 'failed',
          pagesDone: 3,
          pagesTotal: 20,
          attemptCount: 2,
          lastError: 'HTTP 403',
          autoOcr: false,
          createdAt: 1,
          updatedAt: 2,
        ),
      );
      expect(json['id'], 'j1');
      expect(json['chapter'], '第1话');
      expect(json['status'], 'failed');
      expect(json['error'], 'HTTP 403');
      expect(json.containsKey('completedAt'), isFalse);
    });

    test('剧集任务：带下载页按钮判据', () {
      final Map<String, Object?> json = ctlEpisodeDownloadTaskJson(
        const InterconnectDownloadTask(
          id: 'ep1',
          title: '第1集',
          status: InterconnectDownloadStatus.paused,
          progress: 0.25,
          origin: InterconnectDownloadOrigin.extension,
          receivedBytes: 10,
        ),
        canPause: false,
        canRestart: true,
      );
      expect(json['status'], 'paused');
      expect(json['origin'], 'extension');
      expect(json['progress'], 0.25);
      expect(json['canResume'], isTrue);
      expect(json['canPause'], isFalse);
      expect(json.containsKey('totalBytes'), isFalse);
    });
  });

  test('删成品失败的原因：库行与文件失败逐条列出', () {
    expect(describeCtlVideoDeleteFailure(null), '未知原因');
    expect(
      describeCtlVideoDeleteFailure((
        deleted: 0,
        failed: <VideoBookDeleteFailure>[
          VideoBookDeleteFailure(
            bookUid: 'u1',
            error: 'locked',
            stackTrace: StackTrace.empty,
          ),
        ],
        localFiles: const LocalFileDeleteReport(
          failures: <LocalFileDeleteFailure>[
            LocalFileDeleteFailure('D:/a.mp4', 'in use'),
          ],
        ),
      )),
      '库行 u1: locked；D:/a.mp4: in use',
    );
  });

  group('DownloadStartResult', () {
    test('开始 / 失败 / 静默拒绝的原因来源', () {
      const DownloadStartResult started = DownloadStartResult.started(
        <DownloadStartNotice>[DownloadStartNotice.success('已加入下载')],
      );
      expect(started.failureReason, isNull);
      expect(started.summary, '已加入下载');
      const DownloadStartResult failed =
          DownloadStartResult.failed(<DownloadStartNotice>[
            DownloadStartNotice.info('跳过 2 个锁定章节'),
            DownloadStartNotice.error('源站要求登录'),
          ]);
      expect(failed.failureReason, '跳过 2 个锁定章节；源站要求登录');
      const DownloadStartResult declined = DownloadStartResult.declined('用户取消');
      expect(declined.notices, isEmpty, reason: '静默拒绝在页面上不弹提示');
      expect(declined.failureReason, '用户取消');
    });
  });

  test('CtlDiscoveryResultCache：短 id 与容量', () {
    final CtlDiscoveryResultCache<String> cache =
        CtlDiscoveryResultCache<String>(capacity: 2);
    final String a = cache.put('a');
    final String b = cache.put('b');
    final String c = cache.put('c');
    expect(<String>[a, b, c], <String>['r1', 'r2', 'r3']);
    expect(cache[a], isNull);
    expect(cache[c], 'c');
    expect(cache.length, 2);
  });

  group('导航名', () {
    test('每个顶层页签的规范名都能解析回自己', () {
      for (final HomeTab tab in HomeTab.values) {
        expect(homeTabFromCtlName(ctlNavigationName(tab)), tab);
      }
      expect(homeTabFromCtlName(' Downloads '), HomeTab.browse);
    });

    test('未知名抛 400', () {
      expect(() => homeTabFromCtlName('nowhere'), _badRequest());
    });
  });

  group('播放目标选择', () {
    test('缺省 / auto：视频页优先，其次有声书，都没有为 null', () {
      for (final String? requested in <String?>[null, '', 'auto', ' AUTO ']) {
        expect(
          resolveCtlPlaybackTarget(
            requested: requested,
            hasVideo: true,
            hasAudiobook: true,
          ),
          CtlPlaybackTarget.video,
        );
        expect(
          resolveCtlPlaybackTarget(
            requested: requested,
            hasVideo: false,
            hasAudiobook: true,
          ),
          CtlPlaybackTarget.audiobook,
        );
        expect(
          resolveCtlPlaybackTarget(
            requested: requested,
            hasVideo: false,
            hasAudiobook: false,
          ),
          isNull,
        );
      }
    });

    test('显式 target 照办，不看对方在不在', () {
      expect(
        resolveCtlPlaybackTarget(
          requested: 'audiobook',
          hasVideo: true,
          hasAudiobook: false,
        ),
        CtlPlaybackTarget.audiobook,
      );
      expect(
        resolveCtlPlaybackTarget(
          requested: 'Video',
          hasVideo: false,
          hasAudiobook: true,
        ),
        CtlPlaybackTarget.video,
      );
    });

    test('未知 target 抛 400', () {
      expect(
        () => resolveCtlPlaybackTarget(
          requested: 'tv',
          hasVideo: true,
          hasAudiobook: true,
        ),
        _badRequest(),
      );
    });
  });

  group('视频播放状态应答', () {
    test('未就绪：ready false', () {
      expect(ctlVideoPlaybackJson(null), <String, Object?>{
        'active': true,
        'kind': 'video',
        'ready': false,
      });
    });

    test('就绪：字段齐全', () {
      expect(
        ctlVideoPlaybackJson(
          const VideoPlaybackSnapshot(
            title: '第1話',
            bookUid: 'uid-1',
            positionMs: 1000,
            durationMs: 2000,
            playing: true,
            speed: 1.5,
            cue: 'こんにちは',
          ),
        ),
        <String, Object?>{
          'active': true,
          'kind': 'video',
          'ready': true,
          'bookUid': 'uid-1',
          'title': '第1話',
          'playing': true,
          'positionMs': 1000,
          'durationMs': 2000,
          'speed': 1.5,
          'cue': 'こんにちは',
        },
      );
    });
  });
}
