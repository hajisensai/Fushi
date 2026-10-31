import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/separated_audio_load_guard.dart';

/// PR #2688 review：分离音轨载入在途按令牌归属、回退按集序号作废、被拒按集记账。
///
/// 页面（`video_fushi_page.dart` + `quality.part.dart`）的这三件事全部委托给
/// [SeparatedAudioLoadGuard]；页面本身要真 libmpv 才能跑，这里在纯逻辑层把重叠载入 /
/// 回退途中换集 / 被拒后再切档这几条竞态钉死。
class _Page {
  int seq = 1;
  bool alive = true;
  late final SeparatedAudioLoadGuard guard = SeparatedAudioLoadGuard(
    currentEpisodeSeq: () => seq,
    isAlive: () => alive,
  );
}

class _Calls {
  int noFallback = 0;
  int fellBack = 0;
  final List<String> reloads = <String>[];
}

Future<SeparatedAudioRecovery> _recover(
  _Page page,
  _Calls calls, {
  bool failed = true,
  String? fallbackUrl = 'http://127.0.0.1:1/yt/muxed18',
  Completer<void>? reload,
}) {
  return page.guard.recover(
    externalAudioFailed: () => failed,
    fallbackUrl: fallbackUrl,
    reloadWithFallback: (String url) {
      calls.reloads.add(url);
      return reload?.future ?? Future<void>.value();
    },
    onNoFallback: () => calls.noFallback++,
    onFellBack: () => calls.fellBack++,
  );
}

void main() {
  group('载入在途按令牌归属', () {
    test('先开始的载入先结束，不清掉后一程的在途', () async {
      final _Page page = _Page();
      final Completer<void> a = Completer<void>();
      final Completer<void> b = Completer<void>();
      final Future<void> loadA = page.guard.runLoad<void>(() => a.future);
      final Future<void> loadB = page.guard.runLoad<void>(() => b.future);
      expect(page.guard.loadInFlight, isTrue);

      a.complete();
      await loadA;
      expect(
        page.guard.loadInFlight,
        isTrue,
        reason: '旧实现的共享 bool 在这里被 A 的 finally 清成 false，B 还在途',
      );

      b.complete();
      await loadB;
      expect(page.guard.loadInFlight, isFalse);
    });

    test('载入抛错也释放在途', () async {
      final _Page page = _Page();
      await expectLater(
        page.guard.runLoad<void>(() async => throw StateError('open failed')),
        throwsStateError,
      );
      expect(page.guard.loadInFlight, isFalse);
    });

    test('有载入在途时回退不动作（失败等那程收尾再处理）', () async {
      final _Page page = _Page();
      final _Calls calls = _Calls();
      final Completer<void> load = Completer<void>();
      final Future<void> inFlight = page.guard.runLoad<void>(() => load.future);

      expect(await _recover(page, calls), SeparatedAudioRecovery.none);
      expect(calls.reloads, isEmpty);
      expect(page.guard.separatedAudioRefused, isFalse);

      load.complete();
      await inFlight;
      expect(await _recover(page, calls), SeparatedAudioRecovery.fellBack);
      expect(calls.reloads, hasLength(1));
    });

    test('回退重载在途时再报失败（重入）不会叠第二程回退', () async {
      final _Page page = _Page();
      final _Calls calls = _Calls();
      final Completer<void> reload = Completer<void>();
      final Future<SeparatedAudioRecovery> first = _recover(
        page,
        calls,
        reload: reload,
      );
      expect(page.guard.loadInFlight, isTrue);

      expect(await _recover(page, calls), SeparatedAudioRecovery.none);
      expect(calls.reloads, hasLength(1));

      reload.complete();
      expect(await first, SeparatedAudioRecovery.fellBack);
      expect(calls.fellBack, 1);
    });
  });

  group('回退按集序号作废', () {
    test('回退重载期间换集：静默放弃，不给新集弹「已换兼容流」', () async {
      final _Page page = _Page();
      final _Calls calls = _Calls();
      final Completer<void> reload = Completer<void>();
      final Future<SeparatedAudioRecovery> recovery = _recover(
        page,
        calls,
        reload: reload,
      );

      // 用户换到下一集：集序号前进，新一集的载入开始。
      page.seq++;
      final Completer<void> nextEpisode = Completer<void>();
      final Future<void> nextLoad = page.guard.runLoad<void>(
        () => nextEpisode.future,
      );

      reload.complete();
      expect(await recovery, SeparatedAudioRecovery.stale);
      expect(calls.fellBack, 0);
      expect(page.guard.loadInFlight, isTrue, reason: '旧回退收尾不得清掉新集载入的在途');
      expect(
        page.guard.separatedAudioRefused,
        isFalse,
        reason: '被拒记在旧集名下，新集不继承',
      );

      nextEpisode.complete();
      await nextLoad;
      expect(page.guard.loadInFlight, isFalse);
    });

    test('回退重载期间页面销毁：静默放弃', () async {
      final _Page page = _Page();
      final _Calls calls = _Calls();
      final Completer<void> reload = Completer<void>();
      final Future<SeparatedAudioRecovery> recovery = _recover(
        page,
        calls,
        reload: reload,
      );
      page.alive = false;
      reload.complete();
      expect(await recovery, SeparatedAudioRecovery.stale);
      expect(calls.fellBack, 0);
    });

    test('页面已销毁时不起回退', () async {
      final _Page page = _Page()..alive = false;
      final _Calls calls = _Calls();
      expect(await _recover(page, calls), SeparatedAudioRecovery.none);
      expect(calls.reloads, isEmpty);
      expect(calls.noFallback, 0);
    });
  });

  group('本集分离音轨被拒记账', () {
    test('音轨没失败：不动作、不记被拒', () async {
      final _Page page = _Page();
      final _Calls calls = _Calls();
      expect(
        await _recover(page, calls, failed: false),
        SeparatedAudioRecovery.none,
      );
      expect(page.guard.separatedAudioRefused, isFalse);
    });

    test('回退到 muxed 后本集记为被拒（画质菜单据此禁用分离档）', () async {
      final _Page page = _Page();
      final _Calls calls = _Calls();
      expect(await _recover(page, calls), SeparatedAudioRecovery.fellBack);
      expect(calls.reloads, <String>['http://127.0.0.1:1/yt/muxed18']);
      expect(calls.fellBack, 1);
      expect(page.guard.separatedAudioRefused, isTrue);
    });

    test('无可回退流：提示无声，本集同样记为被拒', () async {
      final _Page page = _Page();
      final _Calls calls = _Calls();
      expect(
        await _recover(page, calls, fallbackUrl: null),
        SeparatedAudioRecovery.promptedNoAudio,
      );
      expect(calls.noFallback, 1);
      expect(calls.reloads, isEmpty);
      expect(page.guard.separatedAudioRefused, isTrue);
    });

    test('换集后被拒自动失效（新一集重新解析出新的流）', () async {
      final _Page page = _Page();
      final _Calls calls = _Calls();
      await _recover(page, calls);
      expect(page.guard.separatedAudioRefused, isTrue);
      page.seq++;
      expect(page.guard.separatedAudioRefused, isFalse);
    });
  });
}
