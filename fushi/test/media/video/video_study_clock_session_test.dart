import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';
import 'package:fushi/src/lookup/overlay_window_channel.dart'
    show GlobalLookupRoute;
import 'package:fushi/src/media/video/video_study_accrual_arbiter.dart';
import 'package:fushi/src/media/video/video_study_clock_session.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// 视频页学习计时装配（[VideoStudyClockSession]）的行为测试：真 [StudyClock] + 独立
/// [VideoStudyAccrualArbiter] 实例，按视频页的调用顺序喂生命周期 / 播放态，断言时钟
/// 起停与跨面仲裁的结论。两页只实例化它、喂输入（接线由源码守卫
/// video_study_clock_gate_test.dart 钉住）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late VideoStudyAccrualArbiter arbiter;
  late VideoStudyClockSession session;
  late StudyClock clock;
  late VideoStudyAccrualClaim browser;
  int settled = 0;

  setUp(() {
    settled = 0;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    arbiter = VideoStudyAccrualArbiter();
    browser = arbiter.claim(surface: VideoStudySurface.browser, settle: () {});
    session = VideoStudyClockSession(
      clock: () => clock,
      idleTimeout: () => const Duration(minutes: 10),
      settle: () {
        settled++;
      },
      arbiter: arbiter,
    );
    clock = StudyClock(
      database: db,
      mediaKind: 'video',
      mediaKey: 'video-1',
      title: 'V',
      idleTimeout: const Duration(minutes: 10),
      isActive: () => session.timeAllowed,
      deviceId: () async => 'dev-A',
    );
  });

  tearDown(() async {
    session.dispose();
    browser.release();
    await clock.stop();
    await db.close();
  });

  test('前台起表：app 持焦入账，浏览器同时在播被压下', () {
    session.gate.sync();
    expect(clock.isRunning, isTrue);
    browser.update(running: true);
    expect(session.timeAllowed, isTrue);
    expect(browser.timeAllowed, isFalse);
    expect(clock.idleTimeout, const Duration(minutes: 10), reason: '起表时刷空闲门');
  });

  test('失焦且视频停着：停表、让出焦点，浏览器那段入账', () {
    session.gate.sync();
    browser.update(running: true);
    session.onAppLifecycleChanged(AppLifecycleState.inactive);
    expect(clock.isRunning, isFalse);
    expect(session.gate.appForeground, isFalse);
    expect(browser.timeAllowed, isTrue);
  });

  test('失焦但仍在播放：照常计（用户拍板），时长让给在播的浏览器面', () {
    session.gate.setPlaying(true);
    session.gate.sync();
    browser.update(running: true);
    session.onAppLifecycleChanged(AppLifecycleState.inactive);
    expect(clock.isRunning, isTrue);
    expect(session.timeAllowed, isFalse);
    expect(browser.timeAllowed, isTrue);
    expect(settled, greaterThan(0), reason: '翻转前按旧结论结算 app 侧时钟');
  });

  // PR #3020 审查 F22：桌面查词卡在场（路由仍有效）时切走，旧装配把「路由有效」当成
  // 「焦点在本 app 查词窗」，暂停的视频照计、appForeground 恒真，浏览器那段被丢。
  test('桌面查词卡在场时切走（视频停着）：照样停表、不占前台；关卡后仍停', () {
    final GlobalLookupController lookup = GlobalLookupController.instance;
    final GlobalLookupRoute route = lookup.debugActivateDesktopRoute();
    addTearDown(() {
      if (lookup.desktopLookupInFlight) {
        lookup.debugDispatchOverlayHidden(route);
      }
    });
    expect(lookup.desktopLookupInFlight, isTrue);
    session.gate.sync();
    browser.update(running: true);
    expect(clock.isRunning, isTrue, reason: '主窗持焦查词：暂停查词照计');

    session.onAppLifecycleChanged(AppLifecycleState.inactive);
    expect(clock.isRunning, isFalse);
    expect(session.gate.appForeground, isFalse);
    expect(browser.timeAllowed, isTrue);

    lookup.debugDispatchOverlayHidden(route);
    expect(lookup.desktopLookupInFlight, isFalse);
    expect(clock.isRunning, isFalse);
    expect(browser.timeAllowed, isTrue);
  });

  test('真后台停表；回前台一次落定续表、重新占前台', () {
    session.gate.sync();
    browser.update(running: true);
    session.onAppLifecycleChanged(AppLifecycleState.inactive);
    session.onAppLifecycleChanged(AppLifecycleState.paused);
    expect(clock.isRunning, isFalse);
    session.onAppLifecycleChanged(AppLifecycleState.resumed);
    expect(clock.isRunning, isTrue);
    expect(session.gate.appForeground, isTrue);
    expect(browser.timeAllowed, isFalse);
  });

  test('被盖住 / 手动暂停时回前台不续表', () {
    session.gate.sync();
    session.onAppLifecycleChanged(AppLifecycleState.hidden);
    session.gate.setManualPause(true);
    session.onAppLifecycleChanged(AppLifecycleState.resumed);
    expect(clock.isRunning, isFalse);
    session.gate.setManualPause(false);
    session.gate.setLocallyCovered(true);
    expect(clock.isRunning, isFalse);
    session.gate.setLocallyCovered(false);
    expect(clock.isRunning, isTrue);
  });

  test('dispose：离开仲裁，浏览器面恢复入账；之后的生命周期不再起表', () async {
    session.gate.sync();
    browser.update(running: true);
    expect(browser.timeAllowed, isFalse);
    await clock.stop();
    session.dispose();
    expect(browser.timeAllowed, isTrue);
    session.onAppLifecycleChanged(AppLifecycleState.resumed);
    expect(clock.isRunning, isFalse);
  });
}
