// 视频面学习计时门（2026-11-07 所有者拍板「视频也像小说一样暂停计时；计时按实际
// 看了多久算，查词暂停也算」）。
//
// 两层：
//  * 纯判据 [videoStudyClockLocallyCovered]：哪些页内非路由层算「压着画面」；
//  * 源码守卫：本地视频页 / 网页档视频页 / 浏览器扩展桥的时钟必须是墙钟 + 空闲门、
//    起表只经计时门，全屏路由声明豁免——这些装配在整页 widget 测试里起不来
//    （libmpv / WebView），只能钉源码。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_study_clock_cover.dart';

String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

/// 从 [source] 里取出以 [signature] 开头的方法体（花括号配对）。
String _body(String source, String signature) {
  final int start = source.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: 'missing $signature');
  final int open = source.indexOf('{', start);
  int depth = 0;
  for (int i = open; i < source.length; i++) {
    final String c = source[i];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return source.substring(open, i + 1);
    }
  }
  fail('unbalanced body for $signature');
}

const String _videoPage = 'lib/src/pages/implementations/video_fushi_page.dart';
const String _videoParts = 'lib/src/pages/implementations/video_fushi';
const String _webPage =
    'lib/src/pages/implementations/web_video_fushi_page.dart';
const String _bridge = 'lib/src/media/video/browser_video_study_bridge.dart';

void main() {
  group('videoStudyClockLocallyCovered（页内遮挡判据）', () {
    bool covered({bool panel = false, bool stats = false, bool edit = false}) =>
        videoStudyClockLocallyCovered(
          sidePanelOpen: panel,
          statisticsPanelOpen: stats,
          controlEditMode: edit,
        );

    test('什么都没开：不算遮挡', () {
      expect(covered(), isFalse);
    });

    test('设置 / 字幕 / 画质等侧板压着画面：停', () {
      expect(covered(panel: true), isTrue);
    });

    test('统计侧板开着不停（同小说统计侧栏：秒表要看得见它在走）', () {
      expect(covered(panel: true, stats: true), isFalse);
    });

    test('控件布局编辑：停（剧集列表把画面挤开、不盖视频，不再是判据输入）', () {
      expect(covered(edit: true), isTrue);
      expect(covered(panel: true, stats: true, edit: true), isTrue);
    });
  });

  group('视频面时钟装配（源码守卫）', () {
    test('三处视频写入面都不再是显式记账（时长 = 墙钟，不再按首次覆盖推入）', () {
      for (final String path in <String>[_videoPage, _webPage, _bridge]) {
        final String src = _read(path);
        expect(
          src.contains('StudyAccrual.explicit'),
          isFalse,
          reason: '$path：视频时钟必须是墙钟（VideoWatchTracker 构造期也断言）',
        );
        expect(src.contains('addActiveMs'), isFalse, reason: path);
      }
    });

    test('本地视频页 / 网页档：空闲门取阅读面同一设置、退出拆栈的写交给 ExitFlushRegistry', () {
      expect(
        _read(_videoPage).contains('idleTimeout: appModel.readingIdleTimeout,'),
        isTrue,
      );
      expect(
        _read(_webPage).contains('idleTimeout: _appModel.readingIdleTimeout,'),
        isTrue,
      );
      for (final String path in <String>[_videoPage, _webPage]) {
        expect(
          _read(path).contains('deferWrite: ExitFlushRegistry.instance.defer,'),
          isTrue,
          reason: path,
        );
      }
    });

    test('本地视频页：建 tracker 后经计时门对齐（tracker.start 不起表），播放态喂门', () {
      final String body = _body(_read(_videoPage), 'void _ensureWatchTracker(');
      expect(body, contains('onPlayingChanged: _studyClockGate.setPlaying,'));
      expect(
        body.indexOf('_studyClockGate.sync();'),
        greaterThan(body.indexOf('..start();')),
        reason: '先起采样再按门起表；建表时已在后台 / 被盖住就不起',
      );
    });

    test('本地视频页：计时门挂本页路由、页内遮挡层经纯判据喂门', () {
      final String src = _read(_videoPage);
      expect(
        _body(src, 'void didChangeDependencies('),
        contains('_studyClockGate.attach(ModalRoute.of(context));'),
      );
      final String cover = _body(src, 'void _syncStudyClockLocalCover(');
      expect(cover, contains('videoStudyClockLocallyCovered('));
      expect(
        cover,
        contains('panel == _VideoSidePanelKind.statistics'),
        reason: '统计侧板不算遮挡',
      );
      for (final String notifier in <String>[
        '_videoSidePanel',
        '_videoControlEditMode',
      ]) {
        expect(
          src.contains('$notifier.addListener(_syncStudyClockLocalCover);'),
          isTrue,
          reason: '$notifier 开关要喂计时门',
        );
      }
      // 剧集列表与字幕列表一样只把画面挤开（所有者 2026-11-07 拍板不停表）。
      expect(
        src.contains(
          '_episodeListVisible.addListener(_syncStudyClockLocalCover)',
        ),
        isFalse,
      );
      // 门 + 跨面仲裁登记由 VideoStudyClockSession 装配（行为见
      // video_study_clock_session_test.dart），随页面一起释放。
      expect(src, contains('_studySession.dispose();'));
      expect(src, contains('isActive: () => _studySession.timeAllowed,'));
      // 门只在 tracker 采样期间起表：采样停了（离开前 / 进后台）就没人喂空闲门。
      expect(src, contains('if (tracker == null || !tracker.isSampling)'));
    });

    test('全屏路由声明豁免：进全屏不停表', () {
      final String fullscreen = _read('$_videoParts/fullscreen.part.dart');
      final int route = fullscreen.indexOf(
        'WindowFullscreenHostPageRoute<void>(',
      );
      expect(route, greaterThanOrEqualTo(0));
      expect(
        fullscreen.indexOf(
          'settings: studyClockRouteSettings(transparent: true),',
          route,
        ),
        greaterThan(route),
      );
    });

    test('统计侧栏：视频口径、宿主外壳不画重复页头；完整记录进统计中心观看页签', () {
      final String stats = _read('$_videoParts/study_stats.part.dart');
      expect(stats, contains('media: ReaderStatsMedia.video,'));
      expect(stats, contains('showHeader: false,'));
      expect(
        stats,
        contains('StatisticsCenterPage(initialTab: StatsCenterTab.video)'),
      );
      // 统计身份与时钟 mediaKey、查词 / 制卡计数同一个键（_studyStatsIdentity）。
      expect(
        stats,
        contains('final String key = _studyStatsIdentity.bookKey;'),
      );
      final String page = _read(_videoPage);
      expect(
        page,
        contains('bookKey: _watchStatsIdentity.\$1'),
        reason: '_studyStatsIdentity 取观看统计身份的 uid',
      );
      expect(
        page,
        contains(
          '({String? bookKey, String? title})? get lookupBookIdentity =>\n'
          '      _studyStatsIdentity;',
        ),
      );
    });

    test('网页档：暂停不停采样（暂停查词照计），只在采样没跑时续上并按门对齐', () {
      final String src = _read(_webPage);
      final String body = _body(src, 'void _syncWatchTracker(');
      expect(body.contains('tracker.stop()'), isFalse);
      expect(body, contains('onPlayingChanged: _studyClockGate.setPlaying,'));
      expect(body, contains('if (!tracker.isSampling) {'));
      expect(body, contains('_studyClockGate.sync();'));
      expect(
        _body(src, 'void didChangeDependencies('),
        contains('_studyClockGate.attach(ModalRoute.of(context));'),
      );
      expect(
        src,
        contains(
          'void _onStudyLifecycleChanged(AppLifecycleState state) =>\n'
          '      _studySession.onAppLifecycleChanged(state);',
        ),
      );
      expect(src, contains('_studySession.dispose();'));
      expect(src, contains('isActive: () => _studySession.timeAllowed,'));
    });

    // PR #3020 审查：「桌面查词路由仍有效」被当成「焦点在本 app 的查词窗」，切走时
    // 暂停的视频照计、仲裁把浏览器那段判给 app。查词窗三端都不抢焦点，这路输入不存在。
    test('两页的计时门都不读查词路由冒充焦点', () {
      for (final String path in <String>[_videoPage, _webPage]) {
        final String src = _read(path);
        expect(src.contains('desktopLookupInFlight'), isFalse, reason: path);
        expect(src.contains('focusHeldByOwnWindow'), isFalse, reason: path);
        expect(
          src.contains('addHiddenListener(_studyClockGate.sync)'),
          isFalse,
          reason: '$path：关查词窗不是计时门的输入',
        );
      }
    });
  });
}
