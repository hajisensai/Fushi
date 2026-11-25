import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../helpers/source_guard.dart';

/// 网页视频制卡队列的接线守卫。页面（`web_video_fushi_page.dart`）与会话
/// （`web_video_session.dart`）都要真 WebView2 才跑得起来，行为规则已抽到
/// `web_mine_queue_run.dart` 单测（`test/mining/web_mine_queue_run_test.dart`）；这里只钉
/// 「页面确实走了那套规则 / 没有把删掉的调用加回来」。
void main() {
  const String pagePath =
      'lib/src/pages/implementations/web_video_fushi_page.dart';
  const String sessionPath = 'lib/src/media/video/web_video_session.dart';

  late String page;
  late String session;

  setUpAll(() {
    page = File(pagePath).readAsStringSync();
    session = File(sessionPath).readAsStringSync();
  });

  group('BUG-4818：窗口宿主档会话不把可捕获档的旧 cookie 抄回共享罐', () {
    test('WebVideoSession 不回抄；唯一的复制是可捕获档开页时从共享罐抄进本环境', () {
      final String code = maskComments(session);
      final int start = code.indexOf('class WebVideoSession {');
      expect(start, greaterThanOrEqualTo(0));
      final String body = code.substring(start);
      expect(body, isNot(contains('syncWebVideoLoginToBrowser(')));
      // gap-webvideo-11：内置档页改用本会话后，BUG-3801 的「开页从共享罐抄登录态」挪进了
      // prepare，方向是共享罐 → 可捕获档（to: env），只在可捕获档发起；窗口宿主档就住在
      // 共享罐里，从不复制。
      final Iterable<RegExpMatch> copies = RegExp(
        r'copyWebVideoLoginCookies\(',
      ).allMatches(body);
      expect(copies, hasLength(1));
      final String prepare = compactCode(
        methodBody(body, 'Future<void> prepare('),
      );
      expect(prepare, contains('if(hosting==WebVideoHosting.builtin){'));
      expect(
        prepare.indexOf('copyWebVideoLoginCookies(uri:site,to:env)'),
        greaterThan(prepare.indexOf('if(hosting==WebVideoHosting.builtin){')),
      );
    });

    test('回抄只在可捕获档的页关页时发起（窗口宿主档住在共享罐里，不抄）', () {
      // 重放宿主页恒为可捕获档：关页无条件回抄一次。
      final String code = maskComments(page);
      expect(
        RegExp(r'syncWebVideoLoginToBrowser\(').allMatches(code),
        hasLength(1),
      );
      // 原生播放器页：只有「制卡优先」档（非底层合成 = 可捕获档）回抄。
      final String native = maskComments(
        File(
          'lib/src/pages/implementations/video_fushi/web_source.part.dart',
        ).readAsStringSync(),
      );
      final Iterable<RegExpMatch> calls = RegExp(
        r'syncWebVideoLoginToBrowser\(',
      ).allMatches(native);
      expect(calls, hasLength(1));
      final String before = native.substring(
        calls.single.start - 400,
        calls.single.start,
      );
      expect(before, contains('!session.underlay'));
    });

    test('复制 cookie 不再预读目标罐、不回报新增数（没有调用方用）', () {
      final String body = methodBody(
        session,
        'Future<void> copyWebVideoLoginCookies({',
      );
      expect(maskComments(body), isNot(contains('dst.getCookies(')));
      expect(
        maskComments(session),
        contains('Future<void> syncWebVideoLoginToBrowser(Uri uri)'),
      );
    });
  });

  group('BUG-4829 / BUG-4832：一轮重放走 web_mine_queue_run 的规则', () {
    late String run;

    setUpAll(() {
      run = maskComments(
        methodBody(page, 'Future<void> _runMineQueue({bool auto = false})'),
      );
    });

    test('采集起好之后的步骤都在 runWebMineQueueRound 里，没有裸 try/finally', () {
      expect(run, contains('runWebMineQueueRound('));
      expect(run, isNot(contains('finally')));
      // 收尾在骨架返回之后、无条件执行。
      final int round = run.indexOf('runWebMineQueueRound(');
      final int finish = run.lastIndexOf('_finishMining(');
      expect(finish, greaterThan(round));
      expect(run.substring(finish), contains('WebMineAutoFinished('));
      // BUG-5039：出错中止（准备步骤抛出 / 一行抛出 / 表面死亡）要带进结果，否则提示
      // 仍是「已制卡 0，失败 0」。
      expect(
        compactCode(run.substring(finish)),
        contains('errored:webMineRoundEndedOnError(rowsEnd),'),
      );
      // 「无条件」= 这次调用是方法体顶层的语句，没有被 if (...) { } 之类的块包住
      // （包进一个只在正常跑完时才进的分支，BUG-4829 就原样回来了）。
      final String finishLine = run.substring(
        run.lastIndexOf('\n', finish) + 1,
        finish,
      );
      expect(finishLine, '    ', reason: '_finishMining 必须是方法体顶层语句');
      // 骨架的返回值（是否正常跑完）不拿来决定要不要收尾。
      expect(run, isNot(contains('= await runWebMineQueueRound(')));
    });

    test('空闲自动制卡跨轮记住本次空闲已放弃的视频 / 书（进程级，不是本页字段）', () {
      // 开跑前排除到不了的视频的行；到不了的视频记进去；出错 / 只剩到不了的视频时整本放弃。
      expect(run, contains('WebMineIdleGiveUps.instance'));
      expect(run, contains('giveUps.startable(widget.bookUid, queued)'));
      expect(run, contains('giveUps.giveUpVideo(widget.bookUid, videoKey)'));
      expect(run, contains('giveUps.giveUpBook(widget.bookUid)'));
      expect(run, contains('giveUps.settleAfterRound('));
      // 空闲调度（含窗口宿主档的交接）开跑前先查这本书有没有被放弃。
      final String canStart = maskComments(
        methodBody(page, 'bool _canStartIdleMining()'),
      );
      expect(
        canStart,
        contains('!WebMineIdleGiveUps.instance.isBookGivenUp(widget.bookUid)'),
      );
    });

    test('逐行循环交给 runWebMineQueueRows，行先按视频归组', () {
      expect(run, contains('runWebMineQueueRows('));
      expect(run, contains('groupWebMineRowsByVideo('));
      expect(run, isNot(contains('for (final WebMineQueueRow row in rows)')));
      // 标失败只经回调，页面的循环里不再自己写 navigate_timeout。
      expect(maskComments(page), isNot(contains("'navigate_timeout'")));
    });

    test('导航被叫停与等满期限是两种结果', () {
      final String nav = maskComments(
        methodBody(page, 'Future<WebMineNavigateOutcome> _navigateForMining('),
      );
      expect(
        compactCode(nav),
        contains(
          compactCode(
            'if (!mounted || _mineStopRequested ||'
            ' session.surfaceGeneration != surfaceGen) {'
            ' return WebMineNavigateOutcome.interrupted; }',
          ),
        ),
      );
      expect(nav, contains('WebMineNavigateOutcome.timedOut'));
      expect(nav, contains('WebMineNavigateOutcome.ready'));
    });
  });

  group('BUG-4834：制卡宿主页不把机器驱动的播放头当用户进度', () {
    test('判据包含重放期间与制卡宿主页（交接页 + 后台制卡页）', () {
      final String code = compactCode(maskComments(page));
      expect(
        code,
        contains(
          compactCode(
            'bool get _playheadIsUsers => !_mineRunning && !_isMiningHost;',
          ),
        ),
      );
      expect(
        code,
        contains(
          compactCode(
            'bool get _isMiningHost => '
            'widget.returnHostingAfterMining != null || '
            'widget.closeAfterMining;',
          ),
        ),
      );
    });

    test('续播点写库只有 _persistPosition 一个出口，且先过判据', () {
      final String code = maskComments(page);
      expect(RegExp(r'\.updatePosition\(').allMatches(code), hasLength(1));
      final String persist = maskComments(
        methodBody(page, 'Future<void> _persistPosition(int posMs) async'),
      );
      expect(persist, contains('.updatePosition('));
      final int gate = persist.indexOf('if (!_playheadIsUsers) return;');
      expect(gate, greaterThanOrEqualTo(0));
      expect(gate, lessThan(persist.indexOf('setPref(')));
    });

    test('观看采样只在判据成立时起', () {
      final String code = maskComments(page);
      final Iterable<RegExpMatch> calls = RegExp(
        r'(?<!void )_syncWatchTracker\(\);',
      ).allMatches(code);
      expect(calls, hasLength(1));
      final int at = calls.single.start;
      final int gate = code.lastIndexOf('if (_playheadIsUsers) {', at);
      expect(gate, greaterThanOrEqualTo(0));
      // 判据与调用之间没有收口的花括号 = 调用在这个 if 块里。
      expect(code.substring(gate, at), isNot(contains('}')));
    });
  });

  // 行为规则（表面换代后在途行留待办、不标 navigate_timeout）在
  // test/mining/web_mine_queue_run_test.dart；这里钉页面把表面的代接进了那套规则。
  group('BUG-4983：内置档页 WebView 进程死亡后恢复，重放循环知情', () {
    // gap-webvideo-11：内置档页的 WebView 由共享会话建（WebVideoSurface），死亡守卫的恢复
    // 钩子是会话的 recoverFromProcessGone，页面自己的那一半经 onProcessGone 接进去。
    test('死亡守卫先跑恢复钩子；重建回到死前的页面而不是起始页', () {
      final String sessionCode = compactCode(maskComments(session));
      expect(
        sessionCode,
        contains('flushBeforeRebuild:widget.session.recoverFromProcessGone,'),
      );
      expect(sessionCode, contains('WebUri(session.surfaceUrl)'));
      final String recover = compactCode(
        maskComments(
          methodBody(session, 'Future<void> recoverFromProcessGone('),
        ),
      );
      for (final String stale in <String>[
        '_surfaceGeneration+=1;',
        '_abandonInflight();',
        '_surfaceUrl=current;',
        '_web=null;',
        'awaitonProcessGone?.call();',
        'discardWebVideoCapturableEnvironment();',
      ]) {
        expect(recover, contains(stale), reason: stale);
      }
      final String code = compactCode(maskComments(page));
      expect(code, contains('WebVideoSurface(session:session)'));
      expect(code, contains('onProcessGone:_onSurfaceGone,'));
      final String gone = compactCode(
        maskComments(methodBody(page, 'Future<void> _onSurfaceGone(')),
      );
      for (final String stale in <String>[
        '_state=null;',
        '_preStartFuture=null;',
        '_shaderActive=false;',
      ]) {
        expect(gone, contains(stale), reason: stale);
      }
    });

    test('一轮重放把表面的代交给 runWebMineQueueRows，录完先验表面再落卡', () {
      final String run = compactCode(
        maskComments(methodBody(page, 'Future<void> _runMineQueue(')),
      );
      expect(run, contains('surfaceLost:surfaceLost,'));
      final int check = run.indexOf('if(surfaceLost())throw');
      final int mine = run.indexOf('await_mineQueuedRow(');
      expect(check, greaterThanOrEqualTo(0));
      expect(mine, greaterThan(check));
    });

    test('页面调用随死表面作废，不挂在死进程上', () {
      // 页面命令唯一出口委托给会话（两个宿主页同一个包装）。
      expect(
        compactCode(maskComments(methodBody(page, 'Future<Object?> _js('))),
        contains('_session?.evaluate(expression)'),
      );
      final String js = compactCode(
        maskComments(methodBody(session, 'Future<Object?> evaluate(')),
      );
      // 每次调用一个局部 Completer 登记进 _inflight、结束即移出；不在长寿 future 上挂监听
      // （表面不死时那些监听只增不减）。
      expect(js, contains('_inflight.add(call);'));
      expect(js, contains('_inflight.remove(call);'));
      expect(js, isNot(contains('Future.any')));
      final String abandon = compactCode(
        maskComments(methodBody(session, 'void _abandonInflight(')),
      );
      expect(abandon, contains('_inflight.clear();'));
      expect(abandon, contains('call.complete(null);'));
    });
  });
}
