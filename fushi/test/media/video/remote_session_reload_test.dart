import 'dart:async';
import 'dart:io';

import 'package:fushi/src/media/video/remote_session_reload.dart';
import 'package:test/test.dart';

import '../../helpers/source_guard.dart';

/// 页面远端播放状态的最小模型，语义照 `_VideoFushiPageState`：
/// `_loadRemoteEpisode` 第一句同步 `++_remotePlaybackGeneration`、`++_episodeLoadSeq`，
/// 取完流（await）后只有仍是最新一程才把 `_currentEpisode` 落到目标集。
class _FakeRemotePage {
  int generation = 0;
  int loadSeq = 0;
  int currentEpisode = 0;
  bool mounted = true;
  final List<String> events = <String>[];

  /// 已开始的载入（集号, 起点覆盖）。
  final List<(int, int?)> loads = <(int, int?)>[];

  Future<void> loadEpisode(int index, {int? startMs}) async {
    ++generation;
    final int seq = ++loadSeq;
    loads.add((index, startMs));
    await Future<void>.delayed(Duration.zero);
    if (seq != loadSeq || !mounted) return;
    currentEpisode = index;
  }

  /// 页面 `_reloadRemoteEpisodeInSession` 的同构：info / 集号在调用时取定。
  Future<bool> reload({
    required int sessionGeneration,
    required int positionMs,
    required Future<void> Function() reportStopped,
  }) {
    final int episode = currentEpisode;
    return reloadRemoteEpisodeInSession(
      generation: sessionGeneration,
      currentGeneration: () => generation,
      isMounted: () => mounted,
      release: () => events.add('release:$sessionGeneration'),
      reportStopped: () async {
        events.add('stop:$sessionGeneration');
        await reportStopped();
      },
      load: () => loadEpisode(episode, startMs: positionMs),
    );
  }
}

void main() {
  group('reloadRemoteEpisodeInSession (HBK-AUDIT-005)', () {
    test('停止上报阻塞期间用户换集：不再载入，新集只载一次且保留自己的起点', () async {
      final _FakeRemotePage page = _FakeRemotePage()..currentEpisode = 3;
      final Completer<void> stopGate = Completer<void>();
      final int session = page.generation;

      final Future<bool> reload = page.reload(
        sessionGeneration: session,
        positionMs: 1234000,
        reportStopped: () => stopGate.future,
      );
      // 换线路已经释放旧流、正卡在停止上报上。
      expect(page.events, <String>['release:$session', 'stop:$session']);

      // 用户此时手动切到第 4 集（无显式起点，由新集自己的断点定）。
      final Future<void> manual = page.loadEpisode(4);
      stopGate.complete();
      final bool reloaded = await reload;
      await manual;

      expect(reloaded, isFalse);
      expect(page.loads, <(int, int?)>[(4, null)]);
      expect(page.currentEpisode, 4);
    });

    test('新集已落定后停止上报才回来：不拿旧集位置重载新集', () async {
      final _FakeRemotePage page = _FakeRemotePage()..currentEpisode = 0;
      final Completer<void> stopGate = Completer<void>();
      final Future<bool> reload = page.reload(
        sessionGeneration: page.generation,
        positionMs: 900000,
        reportStopped: () => stopGate.future,
      );
      await page.loadEpisode(1);
      expect(page.currentEpisode, 1);

      stopGate.complete();
      expect(await reload, isFalse);
      expect(page.loads, <(int, int?)>[(1, null)]);
    });

    test('发起前的等待（问线路 / 写偏好）里会话已换：不释放、不上报、不载入', () async {
      final _FakeRemotePage page = _FakeRemotePage();
      final int session = page.generation;
      await page.loadEpisode(2);

      final bool reloaded = await page.reload(
        sessionGeneration: session,
        positionMs: 5000,
        reportStopped: () async {},
      );

      expect(reloaded, isFalse);
      expect(page.events, isEmpty);
      expect(page.loads, <(int, int?)>[(2, null)]);
    });

    test('停止上报期间页面退出：不载入', () async {
      final _FakeRemotePage page = _FakeRemotePage();
      final Completer<void> stopGate = Completer<void>();
      final Future<bool> reload = page.reload(
        sessionGeneration: page.generation,
        positionMs: 5000,
        reportStopped: () => stopGate.future,
      );
      page.mounted = false;
      stopGate.complete();

      expect(await reload, isFalse);
      expect(page.loads, isEmpty);
    });

    test('重载自己的取流期间被换集接管：返回 false（调用方不弹「已切换」）', () async {
      final _FakeRemotePage page = _FakeRemotePage()..currentEpisode = 5;
      final Completer<void> stopGate = Completer<void>();
      final Future<bool> reload = page.reload(
        sessionGeneration: page.generation,
        positionMs: 7000,
        reportStopped: () => stopGate.future,
      );
      stopGate.complete();
      await Future<void>.delayed(Duration.zero);
      // 重载那一程已开始取流，用户此刻换集。
      expect(page.loads, <(int, int?)>[(5, 7000)]);
      final Future<void> manual = page.loadEpisode(6);

      expect(await reload, isFalse);
      await manual;
      expect(page.currentEpisode, 6);
    });

    test('没有并发换集：释放 → 停止上报 → 当前集回到原位置，只载一次', () async {
      final _FakeRemotePage page = _FakeRemotePage()..currentEpisode = 7;
      final int session = page.generation;

      final bool reloaded = await page.reload(
        sessionGeneration: session,
        positionMs: 61000,
        reportStopped: () async {},
      );

      expect(reloaded, isTrue);
      expect(page.events, <String>['release:$session', 'stop:$session']);
      expect(page.loads, <(int, int?)>[(7, 61000)]);
      expect(page.currentEpisode, 7);
    });
  });

  // 页面上「同会话重载当前集」的四条路都必须经 [_reloadRemoteEpisodeInSession]，且代际
  // 在各自第一个 await 之前取——直接 `_loadRemoteEpisode(_currentEpisode ...)` 就是
  // HBK-AUDIT-005 的原形。
  group('video page reload paths are bound to the playback session', () {
    String read(String path) => File(path).readAsStringSync();
    final String page = read(
      'lib/src/pages/implementations/video_fushi_page.dart',
    );
    final String episode = read(
      'lib/src/pages/implementations/video_fushi/episode.part.dart',
    );
    final String quality = read(
      'lib/src/pages/implementations/video_fushi/quality.part.dart',
    );

    String body(String source, String signature) {
      final int start = source.indexOf(signature);
      expect(start, isNot(-1), reason: '找不到 $signature');
      final int end = source.indexOf('\n  }\n', start);
      expect(end, isNot(-1));
      return maskComments(source.substring(start, end));
    }

    for (final (String name, String source, String signature)
        in <(String, String, String)>[
          ('断流换线路', episode, 'Future<void> _recoverInterruptedStream('),
          ('自适应换档', quality, 'Future<void> _applyAdaptiveQuality('),
          ('手动换档', quality, 'Future<void> _switchMediaServerQuality('),
          ('换版本 / 线路', quality, 'Future<void> _switchStreamVariant('),
        ]) {
      test('$name：经会话绑定的重载，代际在第一个 await 之前取', () {
        final String b = body(source, signature);
        expect(b, contains('_reloadRemoteEpisodeInSession('));
        expect(b, isNot(contains('_loadRemoteEpisode(')));
        expect(b, isNot(contains('_reportRemotePlaybackStopped(')));
        final int firstAwait = b.indexOf('await ');
        final int captured = b.indexOf('_remotePlaybackGeneration');
        expect(captured, isNot(-1), reason: '$name 必须取发起时的代际');
        expect(captured, lessThan(firstAwait));
      });
    }

    test('页面 helper 把发起时的代际交给 reloadRemoteEpisodeInSession', () {
      final String b = body(
        page,
        'Future<bool> _reloadRemoteEpisodeInSession(',
      );
      expect(b, contains('reloadRemoteEpisodeInSession('));
      expect(b, contains('currentGeneration: () => _remotePlaybackGeneration'));
      expect(b, contains('generation: generation'));
    });
  });
}
