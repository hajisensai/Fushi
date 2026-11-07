import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_study_accrual_arbiter.dart';

/// 视频学习时长跨面去重：app 内视频与浏览器扩展视频同时在播时只一边入账。
void main() {
  group('videoStudyTimeAllowed 纯判据', () {
    test('只有一边想计：那一边入账', () {
      expect(
        videoStudyTimeAllowed(
          surface: VideoStudySurface.inApp,
          inAppForeground: false,
          browserWanted: false,
        ),
        isTrue,
        reason: 'app 失焦仍在播、浏览器没在放：照常计（切走仍在播照常计时）',
      );
      expect(
        videoStudyTimeAllowed(
          surface: VideoStudySurface.browser,
          inAppForeground: false,
          browserWanted: true,
        ),
        isTrue,
      );
    });

    test('两边都在计：本 app 持有焦点 → app 内入账，否则浏览器入账', () {
      expect(
        videoStudyTimeAllowed(
          surface: VideoStudySurface.inApp,
          inAppForeground: true,
          browserWanted: true,
        ),
        isTrue,
      );
      expect(
        videoStudyTimeAllowed(
          surface: VideoStudySurface.browser,
          inAppForeground: true,
          browserWanted: true,
        ),
        isFalse,
      );
      expect(
        videoStudyTimeAllowed(
          surface: VideoStudySurface.inApp,
          inAppForeground: false,
          browserWanted: true,
        ),
        isFalse,
        reason: 'app 失焦时前台是浏览器',
      );
      expect(
        videoStudyTimeAllowed(
          surface: VideoStudySurface.browser,
          inAppForeground: false,
          browserWanted: true,
        ),
        isTrue,
      );
    });
  });

  group('VideoStudyAccrualArbiter', () {
    test('翻转前先让翻转方按旧结论结算，释放后对方恢复', () {
      final VideoStudyAccrualArbiter arbiter = VideoStudyAccrualArbiter();
      final List<String> log = <String>[];
      late final VideoStudyAccrualClaim app;
      late final VideoStudyAccrualClaim browser;
      app = arbiter.claim(
        surface: VideoStudySurface.inApp,
        settle: () => log.add('app settle allowed=${app.timeAllowed}'),
      );
      browser = arbiter.claim(
        surface: VideoStudySurface.browser,
        settle: () => log.add('browser settle allowed=${browser.timeAllowed}'),
      );
      expect(app.timeAllowed, isTrue);
      expect(browser.timeAllowed, isTrue);

      // app 失焦仍在播，浏览器开播：app 让位。
      app.update(running: true, foreground: false);
      browser.update(running: true);
      expect(app.timeAllowed, isFalse);
      expect(browser.timeAllowed, isTrue);
      expect(log, <String>['app settle allowed=true']);

      // 切回 app：浏览器让位，结算发生在翻转之前（读到的还是旧值）。
      log.clear();
      app.update(running: true, foreground: true);
      expect(app.timeAllowed, isTrue);
      expect(browser.timeAllowed, isFalse);
      expect(
        log,
        unorderedEquals(<String>[
          'app settle allowed=false',
          'browser settle allowed=true',
        ]),
      );

      // app 页关掉：浏览器恢复入账。
      log.clear();
      app.release();
      expect(browser.timeAllowed, isTrue);
      expect(log, <String>['browser settle allowed=false']);
      // 重复释放 / 释放后报到都是 no-op。
      app.release();
      app.update(running: true, foreground: true);
      expect(browser.timeAllowed, isTrue);
    });

    test('app 内视频没在计时（暂停 / 停表）不压浏览器', () {
      final VideoStudyAccrualArbiter arbiter = VideoStudyAccrualArbiter();
      final VideoStudyAccrualClaim app = arbiter.claim(
        surface: VideoStudySurface.inApp,
        settle: () {},
      );
      final VideoStudyAccrualClaim browser = arbiter.claim(
        surface: VideoStudySurface.browser,
        settle: () {},
      );
      app.update(running: false, foreground: true);
      browser.update(running: true);
      expect(browser.timeAllowed, isTrue);
    });
  });
}
