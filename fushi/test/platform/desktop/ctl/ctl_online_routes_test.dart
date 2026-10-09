import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/media/video/video_playback_remote.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_online_routes.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_online_support.dart';
import 'package:fushi/src/platform/desktop/ctl/desktop_ctl_context.dart';

/// 路由表构建期不碰 ref；任何访问都说明构建期越界读了 app 状态。
class _NoRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('构建路由表时不应访问 ref：${invocation.memberName}');
}

Matcher _badRequest() => throwsA(
  isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 400),
);

void main() {
  group('buildOnlineCtlRoutes', () {
    final List<CtlRoute> routes = buildOnlineCtlRoutes(
      DesktopCtlContext(ref: _NoRef(), focusMainWindow: () async {}),
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
