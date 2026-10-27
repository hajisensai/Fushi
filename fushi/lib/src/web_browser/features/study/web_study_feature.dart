import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fushi_audio/fushi_audio.dart' show StudyClock;
import 'package:fushi_core/fushi_core.dart'
    show FushiDatabase, kActivityMediaBook;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/startup/exit_flush_registry.dart';
import 'package:fushi/src/stats/study_diag_log.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_video_activity.dart';
import 'package:fushi/src/web_browser/features/study/web_study_script.dart';
import 'package:fushi/src/web_browser/features/study/web_study_session.dart';
import 'package:fushi/src/web_browser/features/web_browser_feature.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';
import 'package:fushi/src/webview/web_payload_limits.dart';
import 'package:fushi/utils.dart' show ErrorLogService;

/// 生产时钟：一页一个 [StudyClock]（阅读面墙钟记账 + 阅读设置的空闲门）。
///
/// 媒体种类记 `book`（阅读域）：网页阅读就是阅读，统计中心「阅读」tab、每日目标、
/// 学习日历直接覆盖它，不必新增 `ActivityMediaKind`；身份 `web:<host><path>`，与扩展
/// 视频的 `web:` 身份同一命名空间、不会与书的 bookKey 撞。
class StudyClockWebPort implements WebStudyClockPort {
  StudyClockWebPort({
    required FushiDatabase database,
    required String mediaKey,
    required String title,
    required Duration idleTimeout,
  }) : _clock = StudyClock(
         database: database,
         mediaKind: kActivityMediaBook,
         mediaKey: mediaKey,
         title: title,
         idleTimeout: idleTimeout,
         onWriteError: (Object e, StackTrace st) =>
             ErrorLogService.instance.log('StudyClock.write(web)', e, st),
         deferWrite: ExitFlushRegistry.instance.defer,
       ) {
    studyDiag('web', 'clock $mediaKey title=$title');
  }

  final StudyClock _clock;

  @override
  void start() => _clock.start();

  @override
  Future<void> stop() => _clock.stop();

  @override
  void detach() => _clock.detach();

  @override
  void touch() => _clock.touch();

  @override
  void addChars(int chars) => _clock.addChars(chars);
}

/// 浏览器阅读 → 学习统计（时长 + 翻走的字数），见 [WebStudySession]。
///
/// 每个标签页一个会话；前台标签页 / app 前台 / 页面可见 / 日文页 / 有交互五条同时
/// 成立才走表。无痕标签页不计。
class WebBrowserStudyFeature extends WebBrowserFeature {
  WebBrowserStudyFeature({
    required WebStudyClockFactory clockFactory,
    this.videoActivity,
  }) : _clockFactory = clockFactory {
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    videoActivity?.addListener(_onVideoActivity);
  }

  final WebStudyClockFactory _clockFactory;

  /// 网页视频在播的登记处（扩展宿主推样本）；在播的标签页阅读计时让位。
  final WebBrowserVideoActivity? videoActivity;
  final Map<String, WebStudySession> _sessions = <String, WebStudySession>{};
  late final AppLifecycleListener _lifecycle;
  bool _appForeground = true;

  @override
  String get id => 'study';

  /// 切屏即停：`resumed` 之外（`inactive` / `hidden` / `paused`）一律算不在前台，与
  /// 阅读面同律（docs/agent/statistics.md）。
  void _onLifecycle(AppLifecycleState state) {
    final bool fg = state == AppLifecycleState.resumed;
    if (fg == _appForeground) return;
    _appForeground = fg;
    for (final WebStudySession s in _sessions.values) {
      s.setAppForeground(fg);
    }
  }

  void _onVideoActivity() {
    final WebBrowserVideoActivity? activity = videoActivity;
    if (activity == null) return;
    for (final MapEntry<String, WebStudySession> e in _sessions.entries) {
      e.value.setVideoPlaying(activity.isPlaying(e.key));
    }
  }

  WebStudySession _sessionOf(WebBrowserTab tab) => _sessions[tab.id] ??=
      WebStudySession(incognito: tab.incognito, clockFactory: _clockFactory)
        ..setAppForeground(_appForeground)
        ..setVideoPlaying(videoActivity?.isPlaying(tab.id) ?? false);

  @override
  void onWebViewCreated(WebBrowserTab tab, InAppWebViewController controller) {
    if (tab.incognito) return;
    _sessionOf(tab);
    controller.addJavaScriptHandler(
      handlerName: kWebStudyHandler,
      callback: limitWebPayload(kWebStudyHandler, kWebPayloadTinyMaxChars, (
        List<dynamic> args,
      ) {
        final WebStudyReport? report = parseWebStudyReport(args);
        final WebStudySession? session = _sessions[tab.id];
        if (report == null || session == null) return null;
        // SPA 改地址不触发 onLoadStop：以标签页当前地址为准。
        unawaited(session.navigate(tab.url));
        session.report(report, title: tab.displayTitle);
        return null;
      }),
    );
  }

  @override
  Future<void> onLoadStop(
    WebBrowserTab tab,
    InAppWebViewController controller,
    Uri? url,
  ) async {
    final WebStudySession? session = _sessions[tab.id];
    if (session == null) return;
    unawaited(session.navigate(url ?? tab.url));
    if (webStudyMediaKey(url ?? tab.url) == null) return;
    try {
      await controller.evaluateJavascript(source: webStudyInstallSource());
    } on Object catch (e, st) {
      ErrorLogService.instance.log('WebBrowserStudy.install', e, st);
    }
  }

  @override
  void onTabActiveChanged(WebBrowserTab tab, {required bool active}) {
    if (tab.incognito) return;
    _sessionOf(tab).setTabActive(active);
  }

  @override
  void onTabClosed(WebBrowserTab tab) {
    final WebStudySession? s = _sessions.remove(tab.id);
    if (s != null) unawaited(s.close());
  }

  @override
  void dispose() {
    videoActivity?.removeListener(_onVideoActivity);
    _lifecycle.dispose();
    for (final WebStudySession s in _sessions.values) {
      s.detach();
    }
    _sessions.clear();
  }
}
