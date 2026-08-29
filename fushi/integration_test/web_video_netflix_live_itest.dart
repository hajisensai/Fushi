// 内置网页播放器真机验证（Windows WebView2 + 真 Netflix）。
//
// 跑完整用户路径：书架里一本 videoPath=Netflix 播放页 URL 的流媒体书 → 焦点驱动打开 →
// `VideoFushiPage._init` 分流 pushReplacement 到 [WebVideoFushiPage] → 站点自己的播放器起播
// （PlayReady，正常观看模式）→ 主世界注入的 netflix-bridge 抓到整集明文字幕轨 → 字幕列表面板
// 出现 cue → 经 bridge seek 后播放头跟到目标。截 Flutter 帧留证（WebView2 纹理抓不到，只证外壳）。
//
// 依赖真实网络 + 已登录的 Netflix 会话（网页播放器用独立 WebView2 环境，profile 预置进 runner 的
// `isolated-root\webview2-profile-webvideo\EBWebView`），故**默认 skip**，仅在
// FUSHI_WEB_VIDEO_LIVE_ITEST=1 时跑：
//   $env:FUSHI_WEB_VIDEO_LIVE_ITEST=1; .\tool\run_windows_itest.ps1 -Visible -KeepUserDirs `
//     -RunId web-video-netflix-live integration_test\web_video_netflix_live_itest.dart
// 必须 -Visible（WebView2 / 站点播放器要 DWM 合成实窗）；必须 -KeepUserDirs——PlayReady 硬件
// DRM（MF CDM）要真实的 LOCALAPPDATA / USERPROFILE / TEMP，任一被 runner 重定向都报
// Netflix D7702/D7703（0x80070003），实测二分定位。可用 FUSHI_WEB_VIDEO_URL 换片。
//
// 4K 窗口宿主档：FUSHI_WEB_VIDEO_HOSTING=windowed，且必须
// FUSHI_WEB_VIDEO_4K_USER_DATA_FOLDER=%LOCALAPPDATA%\Fushi\WebVideoWebView2-4k-itest——硬件
// PlayReady 的 profile 放在仓库目录（隔离根）下报 D7702-1003，放 LOCALAPPDATA 下才起播（2026-08-30 实测）。
// 内置档超分（P2）：FUSHI_WEB_VIDEO_SHADER_TIER=medium|high|ultra（Anime4K 文件缺则经镜像下载）。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/src/media/video/url_stream_video.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/web_video_hosting.dart';
import 'package:fushi/src/media/video/web_video_shaders.dart';
import 'package:fushi/src/media/video/video_shader_tier.dart';
import 'package:fushi/src/lookup/global_lookup_channel.dart';
import 'package:fushi/src/mining/web_mine_queue_store.dart';
import 'package:fushi/src/mining/web_mine_replay.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_page.dart'
    show HomePage, HomeTab;
import 'package:fushi/src/pages/implementations/home_video_page.dart'
    show HomeVideoPage, openLocalVideoBook;
import 'package:fushi/src/pages/implementations/tag_filter_sheet.dart'
    show filteredVideoBookUidsProvider;
import 'package:fushi/src/pages/implementations/web_video_fushi_page.dart';

import 'helpers/focus_driver.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

bool get _live => Platform.environment['FUSHI_WEB_VIDEO_LIVE_ITEST'] == '1';

bool get _windowed =>
    Platform.environment['FUSHI_WEB_VIDEO_HOSTING'] == 'windowed';

String get _url =>
    Platform.environment['FUSHI_WEB_VIDEO_URL'] ??
    'https://www.netflix.com/watch/81236554';

Future<WebVideoDebugSnapshot?> _waitFor(
  WidgetTester tester,
  bool Function(WebVideoDebugSnapshot s) predicate, {
  required Duration timeout,
  required String what,
}) async {
  final int ticks = timeout.inMilliseconds ~/ 500;
  WebVideoDebugSnapshot? last;
  for (int i = 0; i < ticks; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    final WebVideoDebugSnapshot Function()? read =
        WebVideoFushiPage.debugSnapshot;
    if (read == null) continue;
    last = read();
    if (predicate(last)) return last;
  }
  debugPrint('[web-video-itest] timeout waiting for $what; last=$last');
  return null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Netflix 在内置网页播放器里起播、抓到字幕轨、bridge seek 生效', (
    WidgetTester tester,
  ) async {
    if (!_live) {
      debugPrint('[web-video-itest] FUSHI_WEB_VIDEO_LIVE_ITEST != 1, skipping');
      return;
    }
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint(
        '[web-video-itest] FlutterError: ${details.exceptionAsString()}',
      );
    };
    try {
      await launchFushiTestApp();
      expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
      await tester.pump(const Duration(seconds: 2));
      await enableFocusNavigation(tester);
      final FocusDriver driver = FocusDriver(tester);

      // ── 播种一本网页站流媒体书（与「粘贴 URL 导入」入库同形）──
      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp).first),
      );
      final AppModel appModel = container.read(appProvider);
      final VideoBookRepository repo = VideoBookRepository(appModel.database);
      final String uid = streamVideoBookUid(_url);
      await repo.saveVideoBook(
        VideoBooksCompanion(
          bookUid: Value(uid),
          title: const Value('Netflix live itest'),
          videoPath: Value(_url),
        ),
      );
      debugPrint('[web-video-itest] seeded uid=$uid url=$_url');
      // 视频页按 tag 筛选 provider 的缓存 uid 集过滤；seed 晚于首次求值必须失效重算，
      // 否则新种的卡永远不上屏（与 helpers/library_fixture.dart seedVideo 同步骤）。
      container.invalidate(filteredVideoBookUidsProvider);
      // FUSHI_WEB_VIDEO_HOSTING=windowed → 4K 窗口宿主档（硬件 PlayReady、DOM 字幕层、顶层查词窗）。
      // runner 的隔离 DB 跨次运行保留：两种模式都显式写偏好，不然上一次 windowed 运行留下的
      // 偏好会让「builtin」运行实际开成窗口档（profile 在仓库目录 → D7702，见文件头）。
      final bool windowedMode = _windowed;
      await appModel.prefsRepo.setPref(
        kWebVideoHostingPrefKey,
        (windowedMode ? WebVideoHosting.windowed : WebVideoHosting.builtin)
            .name,
      );
      debugPrint(
        '[web-video-itest] hosting=${windowedMode ? 'windowed' : 'builtin'}',
      );
      // 内置档超分（P2）：按环境变量预置档位偏好，页面创建 WebView 后自动喂给 fork。
      final String? shaderTierEnv =
          Platform.environment['FUSHI_WEB_VIDEO_SHADER_TIER'];
      if (shaderTierEnv != null && shaderTierEnv.isNotEmpty) {
        await appModel.prefsRepo.setPref(
          kWebVideoShaderTierPrefKey,
          shaderTierEnv,
        );
      }

      expect(HomePage.debugSelectTab, isNotNull);
      HomePage.debugSelectTab!(HomeTab.video);
      await tester.pump(const Duration(seconds: 1));
      HomeVideoPage.debugRefreshVideos?.call();
      await tester.pump(const Duration(seconds: 2));
      final Finder card = find.byKey(ValueKey<String>('home_video_$uid'));
      for (int i = 0; i < 30 && card.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (i == 2) HomeVideoPage.debugRefreshVideos?.call();
      }
      final int shelfRows = (await repo.listForShelf()).length;
      final int anyStage = find
          .byKey(ValueKey<String>('home_video_$uid'), skipOffstage: false)
          .evaluate()
          .length;
      debugPrint(
        '[web-video-itest] shelfRows=$shelfRows card(onstage='
        '${card.evaluate().isNotEmpty} anyStage=$anyStage)',
      );

      // 页面默认 = 软件 DRM 档 + 可捕获环境（独立 profile：登录态需预置到
      // <FUSHI_WEBVIEW2_USER_DATA_FOLDER>-webvideo\EBWebView，见文件头）。
      debugPrint(
        '[web-video-itest] env folder='
        '${WebVideoFushiPage.capturableUserDataFolder()}',
      );

      // ── 打开 → 分流到网页播放器 ──
      // 优先焦点驱动（禁坐标点击）；卡未上屏时走书架卡片同一条生产路由
      // [openLocalVideoBook]（首页 dashboard / 书架 hero 共用），分流逻辑在
      // VideoFushiPage._init 里，两条入口覆盖面相同。
      if (card.evaluate().isNotEmpty) {
        expect(await driver.focusWidget(card), isTrue, reason: '视频卡应可被焦点到达');
        await driver.activate();
      } else {
        debugPrint(
          '[web-video-itest] card not onstage; opening via '
          'openLocalVideoBook (shared shelf route)',
        );
        final BuildContext ctx = tester.element(find.byType(HomePage));
        // ignore: use_build_context_synchronously — 测试里刚从树上取的 element，同帧使用。
        unawaited(openLocalVideoBook(context: ctx, repo: repo, bookUid: uid));
      }
      bool pageUp = false;
      for (int i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byType(WebVideoFushiPage).evaluate().isNotEmpty) {
          pageUp = true;
          break;
        }
      }
      final ObserveShot afterOpen = await captureFlutterFrame(
        tester,
        'observe-web-video-after-open',
      );
      expect(
        pageUp,
        isTrue,
        reason: '网页站流媒体书应分流到 WebVideoFushiPage（截图 ${afterOpen.path}）',
      );

      // ── Netflix「谁在观看」头像门：真实用户在 WebView 里点自己的头像；这里替用户点第一个 ──
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(seconds: 1));
        final String? r = await WebVideoFushiPage.debugEvalJs?.call(
          "(() => { const p = document.querySelector('.profile-link, "
          "a[data-uia^=\"profile\"], [data-uia=\"action-select-profile+primary\"]'); "
          "if (p) { p.click(); return 'clicked'; } "
          "return document.querySelector('video') ? 'video' : location.href; })()",
        );
        if (r == 'clicked') {
          debugPrint('[web-video-itest] profile gate: clicked first profile');
          break;
        }
        if (r == 'video') break;
      }

      // ── 站点播放器起播（PlayReady 正常观看模式；登录态来自预置 profile）──
      final WebVideoDebugSnapshot? playing = await _waitFor(
        tester,
        (WebVideoDebugSnapshot s) =>
            s.hasVideo && s.playing && (s.positionMs ?? 0) > 0,
        timeout: const Duration(seconds: 90),
        what: 'video playing',
      );
      final ObserveShot playingShot = await captureFlutterFrame(
        tester,
        'observe-web-video-playing',
      );
      // 诊断：页面此刻在哪（登录页 / 谁在观看 / 播放页）+ CDP 截图（页面 UI 可见）。
      final String? where = await WebVideoFushiPage.debugEvalJs?.call(
        'JSON.stringify({href: location.href, title: document.title, '
        "text: document.body ? document.body.innerText.replace(/\\s+/g,' ').slice(0,300) : ''})",
      );
      debugPrint('[web-video-itest] page: $where');
      final Uint8List? png = await WebVideoFushiPage.debugScreenshot?.call();
      if (png != null) {
        final File f = File(
          '${observeScreenshotDir().path}/observe-web-video-webview.png',
        );
        await f.writeAsBytes(png);
        debugPrint(
          '[web-video-itest] webview screenshot ${f.path} '
          '(${png.length}B)',
        );
      }
      expect(
        playing,
        isNotNull,
        reason:
            'Netflix 应在 90s 内起播（未登录 / 网络不通会停在这里；'
            '截图 ${playingShot.path}）',
      );
      debugPrint('[web-video-itest] playing: $playing');

      // ── 字幕轨：netflix-bridge 抓整集明文轨 → providers store → glue → Dart ──
      final WebVideoDebugSnapshot? tracked = await _waitFor(
        tester,
        (WebVideoDebugSnapshot s) => s.cueCount > 0 && s.activeTrackKey != null,
        timeout: const Duration(seconds: 60),
        what: 'subtitle track',
      );
      expect(tracked, isNotNull, reason: '应抓到至少一条带 cue 的字幕轨');
      debugPrint('[web-video-itest] tracks: $tracked');
      // 诊断：store 里到底有哪些轨（整集明文轨 vs 仅 live）、EME 实际走了什么 keySystem、
      // netflix-bridge 的 JSON.parse hook 是否在位。
      final String? storeInfo = await WebVideoFushiPage.debugEvalJs?.call(
        'JSON.stringify({keys: Object.keys(window.fushiEpisodeCues || {}), '
        'eme: (window.__fushiEmeLog || []).slice(0, 8), '
        "parseHooked: String(JSON.parse).indexOf('timedtexttracks') >= 0, "
        'ua: navigator.userAgent.slice(-30)})',
      );
      debugPrint('[web-video-itest] store: $storeInfo');

      // ── 列表面板出现 cue 行（焦点面板），留证 ──
      expect(WebVideoFushiPage.debugToggleList, isNotNull);
      if (!tracked!.listVisible) WebVideoFushiPage.debugToggleList!();
      await tester.pump(const Duration(seconds: 2));
      expect(
        find.byKey(const ValueKey<String>('web-video-subtitle-jump-panel')),
        findsOneWidget,
        reason: '字幕列表面板应挂载',
      );
      final ObserveShot listShot = await captureFlutterFrame(
        tester,
        'observe-web-video-subtitle-list',
      );
      expect(listShot.nonBlank, isTrue, reason: '字幕列表外壳不应白屏（${listShot.path}）');

      // ── bridge seek：跳到当前位置 + 30s，播放头应在 8s 内跟到（Netflix 官方 API 路径）──
      final int from = tracked.positionMs ?? 0;
      final int target = from + 30000;
      expect(WebVideoFushiPage.debugSeek, isNotNull);
      await WebVideoFushiPage.debugSeek!(target);
      final WebVideoDebugSnapshot? sought = await _waitFor(
        tester,
        (WebVideoDebugSnapshot s) =>
            s.positionMs != null && (s.positionMs! - target).abs() < 4000,
        timeout: const Duration(seconds: 12),
        what: 'seek to $target',
      );
      expect(
        sought,
        isNotNull,
        reason: 'seek 后播放头应落到 $target±4s（bridge seek 失效会停在 $from 附近）',
      );
      debugPrint('[web-video-itest] sought: $sought');

      // 当前 cue 应随位置更新（controller 由外部态驱动）。
      await tester.pump(const Duration(seconds: 3));
      final WebVideoDebugSnapshot after = WebVideoFushiPage.debugSnapshot!();
      debugPrint('[web-video-itest] after seek: $after');

      if (windowedMode) {
        // ── 4K 窗口宿主档：画面归站点（硬件 DRM，期望 ≥1080p 阶梯）；字幕层在页面 DOM；
        // 点词 → callHandler → GlobalLookupController → 顶层 WS_POPUP 查词窗口。──
        final String? dims = await WebVideoFushiPage.debugEvalJs?.call(
          "(() => { const v = document.querySelector('video'); return JSON.stringify("
          '{vw: v && v.videoWidth, vh: v && v.videoHeight, '
          "dom: !!document.getElementById('fushi-dom-subtitle'), "
          "spans: document.querySelectorAll('#fushi-dom-subtitle [data-fushi-g]').length,"
          'cur: window.__fushiDomSubs && window.__fushiDomSubs.current()}); })()',
        );
        debugPrint('[web-video-itest] windowed page: $dims');
        // 等 DOM 字幕层渲染出当前 cue（字幕间隙时元素被摘掉，最多等 30 s）。
        int spans = 0;
        for (int i = 0; i < 60 && spans == 0; i++) {
          await tester.pump(const Duration(milliseconds: 500));
          final String? n = await WebVideoFushiPage.debugEvalJs?.call(
            "String(document.querySelectorAll('#fushi-dom-subtitle [data-fushi-g]').length)",
          );
          spans = int.tryParse(n ?? '') ?? 0;
        }
        expect(spans, greaterThan(0), reason: 'DOM 字幕层应渲染出逐字形 span');
        // 模拟点第一个字形（真实用户就是点它）。
        final String? clicked = await WebVideoFushiPage.debugEvalJs?.call(
          "(() => { const s = document.querySelector('#fushi-dom-subtitle [data-fushi-g]');"
          ' if (!s) return "none"; const r = s.getBoundingClientRect();'
          " s.dispatchEvent(new MouseEvent('click', {bubbles: true, clientX: r.left + 2, clientY: r.top + 2}));"
          " return 'clicked:' + s.textContent; })()",
        );
        debugPrint('[web-video-itest] dom click: $clicked');
        bool showing = false;
        for (int i = 0; i < 30 && !showing; i++) {
          await tester.pump(const Duration(milliseconds: 500));
          showing = await GlobalLookupChannel.isShowing();
        }
        expect(showing, isTrue, reason: 'DOM 字幕点词后顶层查词窗口应显示');
        final int? queuedId = await WebVideoFushiPage.debugEnqueueCurrentCue!(
          <String, String>{'term': 'itest', 'sentence': 'itest sentence'},
        );
        expect(queuedId, isNotNull, reason: '窗口宿主档制卡只入队');
        final WebVideoDebugSnapshot afterWin =
            WebVideoFushiPage.debugSnapshot!();
        debugPrint(
          '[web-video-itest] windowed end: $afterWin queued=$queuedId',
        );
        assertStrictErrors(errors);
        return;
      }

      // ── P2 超分：档位偏好预置后，fork 的 libplacebo 通道必须确认已启用，且 Flutter 帧仍在出
      //（着色器链把 WGC 帧渲染进共享纹理；任何失败 fail-open 回原帧，但那样 active 会是 false）。
      if (shaderTierEnv != null && shaderTierEnv.isNotEmpty) {
        bool active = false;
        for (int i = 0; i < 60 && !active; i++) {
          await tester.pump(const Duration(milliseconds: 500));
          active = WebVideoFushiPage.debugShaderActive?.call() ?? false;
        }
        final ObserveShot shaded = await captureFlutterFrame(
          tester,
          'observe-web-video-shaded',
        );
        debugPrint(
          '[web-video-itest] shader tier=$shaderTierEnv active=$active '
          'frame=${shaded.path} nonBlank=${shaded.nonBlank}',
        );
        expect(
          active,
          isTrue,
          reason: 'fork libplacebo 通道应确认着色器链已启用（DLL 随包 + Anime4K 文件在）',
        );
        expect(shaded.nonBlank, isTrue, reason: '着色器启用后画面不应黑屏');
        // 对照：暂停在同一帧上切到 off 再截一张，肉眼比对通道输出是「同一帧的增强」而非乱码。
        await WebVideoFushiPage.debugEvalJs?.call(
          "(() => { const v = document.querySelector('video'); if (v) v.pause(); return 'paused'; })()",
        );
        await tester.pump(const Duration(seconds: 1));
        final ObserveShot shadedPaused = await captureFlutterFrame(
          tester,
          'observe-web-video-shaded-paused',
        );
        await WebVideoFushiPage.debugSelectShaderTier!(VideoShaderTier.off);
        await tester.pump(const Duration(seconds: 2));
        final ObserveShot unshaded = await captureFlutterFrame(
          tester,
          'observe-web-video-unshaded-paused',
        );
        debugPrint(
          '[web-video-itest] compare: shaded=${shadedPaused.path} '
          'unshaded=${unshaded.path} activeAfterOff='
          '${WebVideoFushiPage.debugShaderActive?.call()}',
        );
        expect(
          WebVideoFushiPage.debugShaderActive?.call(),
          isFalse,
          reason: 'off 档 = 直通，fork 不再报启用',
        );
        await WebVideoFushiPage.debugSelectShaderTier!(VideoShaderTier.medium);
        await WebVideoFushiPage.debugEvalJs?.call(
          "(() => { const v = document.querySelector('video'); if (v) v.play(); return 'play'; })()",
        );
        await tester.pump(const Duration(seconds: 1));
      }

      // ── P3 自动制卡队列：入队当前 cue → 跑队列（真 seek/播/停 + WASAPI loopback 录音 +
      // CDP 截帧 → 沉浸制卡引擎）。测试环境无 Anki 后端，引擎落卡预期失败并写进队列行
      // error；这里验证的是重放链路本身抓到了真媒体：封面 PNG 非空、loopback 音频非空。
      expect(WebVideoFushiPage.debugEnqueueCurrentCue, isNotNull);
      final int? queuedId = await WebVideoFushiPage.debugEnqueueCurrentCue!(
        <String, String>{'term': 'itest', 'sentence': 'itest sentence'},
      );
      expect(queuedId, isNotNull, reason: '当前位置附近应有 cue 可入队');
      final List<WebMineReplayCapture> caps =
          await WebVideoFushiPage.debugRunMineQueue!();
      await tester.pump(const Duration(seconds: 1));
      // runner 的隔离 DB 跨次运行保留（上一次 windowed 运行入队的行仍 pending，也会被重放）：
      // 本次入队的行排在最后，取最后一次重放。
      expect(caps, isNotEmpty, reason: '至少重放本次入队的那一行');
      final WebMineReplayCapture cap = caps.last;
      debugPrint(
        '[web-video-itest] mine capture: audio=${cap.audio?.length}B '
        'cover=${cap.cover?.length}B warnings=${cap.warnings}',
      );
      final Directory shots = observeScreenshotDir();
      if (cap.cover != null) {
        await File(
          '${shots.path}/observe-web-video-mine-cover.png',
        ).writeAsBytes(cap.cover!);
      }
      if (cap.audio != null) {
        await File(
          '${shots.path}/observe-web-video-mine-audio.m4a',
        ).writeAsBytes(cap.audio!);
      }
      final List<WebMineQueueRow> rows = await WebMineQueueStore(
        appModel.database,
      ).db.select(appModel.database.webMineQueue).get();
      debugPrint(
        '[web-video-itest] queue rows: '
        '${rows.map((WebMineQueueRow r) => '${r.id}:${r.status}:${r.error}').join(' | ')}',
      );
      expect(cap.cover, isNotNull, reason: '重放中点应截到画面');
      expect(cap.cover!.length, greaterThan(10000), reason: '封面不应是空壳 PNG');
      expect(
        cap.audio,
        isNotNull,
        reason:
            'Windows 真机 WASAPI loopback 应录到 Netflix 音频（warnings=${cap.warnings}）',
      );
      expect(cap.audio!.length, greaterThan(1000));
      // runner 的隔离 DB 跨次运行保留：只看本次入队的那一行（上次的 failed 行不再是
      // pending、不会被重放；caps 恰一次已在上面断言）。
      final WebMineQueueRow mine = rows.firstWhere(
        (WebMineQueueRow r) => r.id == queuedId,
      );
      expect(
        mine.status,
        isNot(WebMineQueueStatus.pending),
        reason: '跑完后行必须离开 pending（done 或 failed 都写了结果）',
      );
      final WebVideoDebugSnapshot afterMine =
          WebVideoFushiPage.debugSnapshot!();
      debugPrint('[web-video-itest] after mine run: $afterMine');

      assertStrictErrors(errors);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
