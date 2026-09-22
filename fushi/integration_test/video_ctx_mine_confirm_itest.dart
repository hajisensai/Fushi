// 视频页「调整上下文 → 确认制卡」真机取证（用户 2026-09-22 报：点确认后弹
// 「制卡没能开始——回点制卡按钮时查词弹窗已经关掉了」，即 BUG-2627 那轮把无声失败
// 改成如实提示之后，往返在保护窗口内**仍然**失败）。
//
// 这一跑证明什么：在真 Windows runner 上（真 WebView2 弹窗、真根 Overlay、真对话框）
// 复演原始路径——seed 带 sidecar 字幕的视频 + 生成词典 → 开播放页 → seek 到 cue 内 →
// `debugLookupAt` 在字幕句上查词（与 overlay 点字同一条 `_lookupAt`）→ 在弹窗 DOM 里
// 点「调整上下文」按钮（真走 `openSentenceContextModal` 桥）→ 对话框的确认键 autofocus，
// Enter 即「确认制卡」→ 观察：对话框是否关、失败 toast 是否出现、ErrorLogService 里
// `DictPopupWebview.mineEntryByIndex` 落的是哪一条（无 controller / JS 拒点 / 抛错 /
// 超时）、弹窗 DOM 此刻 `.entry` / `.mine-button` 的真实状态。
//
// 制卡走测试内的假 AnkiConnect（support/fake_ankiconnect.dart）：查重 → ffmpeg 抽
// 媒体 → addNote 全链路真跑，不碰本机真 Anki 集合。BUG-2634 之后「确认」的终点是
// 宿主接受了制卡任务（桥把 payload 交给宿主），不等落地。
//
// 顺带钉 BUG-2633：弹窗开着时，弹窗矩形与 barrier 上的滚轮都不得改视频音量。
//
// 运行（视频 media_kit 需 DWM 窗，必须 -Visible）：
//   fushi/ 下 .\tool\run_windows_itest.ps1 integration_test/video_ctx_mine_confirm_itest.dart -Visible
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart' show t;
import 'package:fushi/src/media/video/video_import_dialog.dart'
    show singleVideoBookUid;
import 'package:fushi/src/media/video/video_volume_overlays.dart'
    show videoVolumeHudProgressKey;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show DictionaryPopupWebView, DictionaryPopupWebViewState;
import 'package:fushi/src/pages/implementations/sentence_context_dialog.dart'
    show SentenceContextDialog;
import 'package:fushi/src/pages/implementations/video_fushi_page.dart'
    show VideoFushiPage, VideoFushiTestHooks;
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart' show VideoBooksCompanion;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit_video/media_kit_video.dart' show Video;

import 'helpers/library_fixture.dart';
import 'helpers/media_fixtures.dart';
import 'helpers/observe_capture.dart';
import 'support/fake_ankiconnect.dart';
import 'support/fake_ankiconnect_setup.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _kSentence = '猫がいる';

Future<Directory> _fixturesDir() async {
  const String testRoot = String.fromEnvironment('FUSHI_TEST_ROOT');
  final Directory dir = testRoot.isEmpty
      ? await Directory.systemTemp.createTemp('hibiki_fixtures_')
      : Directory('$testRoot${Platform.pathSeparator}fixtures');
  await dir.create(recursive: true);
  return dir;
}

/// 播种一条 6s 视频 + 同名 sidecar .srt，两条 cue 都含生成词典里有的「猫」。
Future<String> _seedVideoWithSrt(VideoBookRepository repo) async {
  final Directory dir = await _fixturesDir();
  const String title = 'ctx-mine';
  final String videoPath = '${dir.path}${Platform.pathSeparator}$title.mp4';
  final File videoFile = await generateTestVideo(
    outPath: videoPath,
    duration: const Duration(seconds: 6),
  );
  const String srt = '1\n00:00:00,500 --> 00:00:02,500\n$_kSentence\n\n'
      '2\n00:00:02,600 --> 00:00:04,800\n猫が寝ている\n\n'
      '3\n00:00:04,900 --> 00:00:05,900\n猫が鳴く\n';
  await File('${dir.path}${Platform.pathSeparator}$title.srt')
      .writeAsString(srt);
  final String bookUid = singleVideoBookUid(videoFile.path);
  await repo.saveVideoBook(VideoBooksCompanion(
    bookUid: Value(bookUid),
    title: const Value(title),
    videoPath: Value(videoFile.absolute.path),
  ));
  return bookUid;
}

bool _videoMounted() => find.byType(Video).evaluate().isNotEmpty;

bool _dialogMounted() => find
    .byType(SentenceContextDialog, skipOffstage: false)
    .evaluate()
    .isNotEmpty;

const String _kPopupProbe = r'''
JSON.stringify((() => {
  const root = (window.__fushiRoot || document);
  const first = root.querySelector('.entry');
  const container = first && first.parentNode;
  const entries = container ? container.querySelectorAll(':scope > .entry') : [];
  const b = entries[0] && entries[0].querySelector('.mine-button');
  return {
    entries: entries.length,
    hasMineFn: typeof window.fushiPopupMineEntryByIndex,
    mineButton: !!b,
    mineDisabled: b ? !!b.disabled : null,
    mineOnclickType: b ? typeof b.onclick : null,
    mining: b ? (b.dataset.mining || '') : null,
    adjustButton: !!root.querySelector('.ctx-adjust-button'),
    ctxEnabled: !!window.sentenceContextPreviewEnabled,
    ready: document.readyState,
  };
})())
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('视频「调整上下文 → 确认制卡」回点链路真机取证', (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FakeAnkiConnect? anki;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[ctx-mine] FlutterError: ${details.exceptionAsString()}');
    };

    try {
      await launchFushiTestApp();
      expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
      await tester.pump(const Duration(seconds: 2));

      final AppModel appModel = await readyAppModel(tester);
      expect(await seedDictionary(tester), isTrue, reason: '生成词典须装上');
      // 真实制卡链路（查重 → ffmpeg 抽媒体 → addNote）打到测试内的假 AnkiConnect，
      // 不碰本机真 Anki 集合。
      anki = await FakeAnkiConnect.start();
      await configureFakeAnkiConnect(tester, anki);
      debugPrint('[ctx-mine] fake AnkiConnect on port ${anki.port}');
      final VideoBookRepository repo = VideoBookRepository(appModel.database);
      final String uid = await _seedVideoWithSrt(repo);
      debugPrint('[ctx-mine] seeded uid=$uid');

      final NavigatorState navigator =
          tester.state<NavigatorState>(find.byType(Navigator).first);
      unawaited(navigator.push<void>(MaterialPageRoute<void>(
        builder: (_) => VideoFushiPage(bookUid: uid, repo: repo),
      )));

      VideoFushiTestHooks hooks() =>
          tester.state<State<VideoFushiPage>>(find.byType(VideoFushiPage))
              as VideoFushiTestHooks;
      for (int i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (_videoMounted() &&
            find.byType(VideoFushiPage).evaluate().isNotEmpty &&
            hooks().debugPositionMs != null) {
          break;
        }
      }
      expect(_videoMounted(), isTrue, reason: '播放页应在 20s 内就绪');
      // 等字幕 cue 装载（sidecar srt 异步解析）。
      for (int i = 0; i < 40 && hooks().debugCueCount == 0; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      debugPrint('[ctx-mine] cueCount=${hooks().debugCueCount} '
          'subtitle=${hooks().debugCurrentSubtitleSource}');
      await hooks().debugPause();
      await hooks().debugSeekMs(1200);
      await tester.pump(const Duration(seconds: 1));
      await captureFlutterFrame(tester, '01-video-ready');

      // ── 查词（与字幕 overlay 点字同一条 _lookupAt）────────────────────
      await hooks().debugLookupAt(_kSentence, 0);
      DictionaryPopupWebViewState? webView;
      Object? probe;
      for (int i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        final Finder f =
            find.byType(DictionaryPopupWebView, skipOffstage: false);
        if (f.evaluate().isEmpty) continue;
        for (final Element e in f.evaluate()) {
          final DictionaryPopupWebViewState s =
              (e as StatefulElement).state as DictionaryPopupWebViewState;
          final Object? raw = await s.debugEval(_kPopupProbe);
          if (raw != null &&
              raw.toString().contains('"entries":') &&
              !raw.toString().contains('"entries":0')) {
            webView = s;
            probe = raw;
            break;
          }
        }
        if (webView != null) break;
      }
      debugPrint('[ctx-mine] popup probe after lookup: $probe');
      expect(webView, isNotNull, reason: '查词后弹窗 DOM 里应有词条');
      await captureFlutterFrame(tester, '02-popup-open');

      // ── 滚轮穿透取证（用户同日报：查词框里滚轮翻页，视频音量跟着动）────
      // 与 video_wheel_volume_itest 同一注入范式：hover 到点再发 scroll，走真实
      // hit-test。读播放器音量真值（debugVolume）+ HUD + 弹窗 DOM scrollTop 三样。
      final DictionaryPopupWebViewState popup = webView!;
      // ignore: use_build_context_synchronously
      final RenderBox popupBox = popup.context.findRenderObject()! as RenderBox;
      final Offset popupCenter =
          popupBox.localToGlobal(popupBox.size.center(Offset.zero));
      final RenderBox pageBox =
          tester.renderObject<RenderBox>(find.byType(VideoFushiPage).first);
      final Offset pageTopLeft = pageBox.localToGlobal(Offset.zero);
      final Size pageSize = pageBox.size;
      debugPrint('[ctx-mine] popupRect=${popupBox.localToGlobal(Offset.zero)}'
          '+${popupBox.size} page=$pageTopLeft+$pageSize');
      final TestPointer wheelPointer =
          TestPointer(7, ui.PointerDeviceKind.mouse);
      Future<void> sendWheel(Offset at, double dy) async {
        await tester.sendEventToBinding(wheelPointer.hover(at));
        await tester.sendEventToBinding(wheelPointer.scroll(Offset(0, dy)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
      }

      double? hudVolume() {
        final Finder hud = find.byKey(videoVolumeHudProgressKey);
        if (hud.evaluate().isEmpty) return null;
        final double? v = tester.widget<LinearProgressIndicator>(hud).value;
        return v == null ? null : v * 100.0;
      }

      Future<Object?> popupScrollTop() => popup.debugEval(
          '(document.scrollingElement||document.documentElement).scrollTop');
      final double? volBefore = hooks().debugVolume;
      final Object? scrollBefore = await popupScrollTop();
      for (int i = 0; i < 4; i++) {
        await sendWheel(popupCenter, 80);
      }
      final double? volAfterPopupWheel = hooks().debugVolume;
      final Object? scrollAfter = await popupScrollTop();
      debugPrint('[ctx-mine] WHEEL@popup vol $volBefore -> $volAfterPopupWheel '
          'hud=${hudVolume()} popupScrollTop $scrollBefore -> $scrollAfter');
      await captureFlutterFrame(tester, '02b-after-popup-wheel');
      // BUG-2633：弹窗上的滚轮只滚词典，不改音量（修前：词典滚了 14.5px 的同时
      // 音量 100 → 80 并出 HUD——查词 overlay entry 被 opaque:false 的悬停探针翻成
      // 命中透明，页面级 _handleVideoWheelSignal 在命中路径上）。
      expect(volAfterPopupWheel, volBefore, reason: '弹窗上滚轮不得穿透到视频页改音量');
      expect(hudVolume(), isNull, reason: '弹窗上滚轮不该刷出音量 HUD');
      expect(double.tryParse('$scrollAfter') ?? 0,
          greaterThan(double.tryParse('$scrollBefore') ?? 0),
          reason: '弹窗内容应随滚轮滚动（WebView 仍收得到滚轮）');
      // 弹窗外（barrier 区）滚轮：落在画面区左上角，弹窗在位时 barrier 必须吞掉。
      final Offset barrierPoint = pageTopLeft + const Offset(40, 120);
      for (int i = 0; i < 4; i++) {
        await sendWheel(barrierPoint, 80);
      }
      debugPrint('[ctx-mine] WHEEL@barrier vol $volAfterPopupWheel -> '
          '${hooks().debugVolume} hud=${hudVolume()}');
      expect(hooks().debugVolume, volBefore,
          reason: 'barrier 上的滚轮也不得穿透到视频页改音量');

      // ── 点「调整上下文」（真走 openSentenceContextModal 桥）────────────
      final int logBefore = ErrorLogService.instance.entries.length;
      await popup.debugEval(
          "(function(){var b=document.querySelector('.ctx-adjust-button');"
          "if(!b)return 'no-button';b.click();return 'clicked';})()");
      for (int i = 0; i < 40 && !_dialogMounted(); i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(_dialogMounted(), isTrue, reason: '「选择句子上下文」对话框应打开');
      await tester.pump(const Duration(seconds: 1));
      await captureFlutterFrame(tester, '03-ctx-dialog');
      debugPrint('[ctx-mine] probe while dialog open: '
          '${await popup.debugEval(_kPopupProbe)}');

      // ── 确认制卡：确认键 autofocus，Enter 即确认（焦点驱动）────────────
      debugPrint('[ctx-mine] primaryFocus=${primaryFocus?.debugLabel}');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      final Stopwatch sw = Stopwatch()..start();
      for (int i = 0; i < 240 && _dialogMounted(); i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      sw.stop();
      final bool failedToast =
          find.text(t.popup_ctx_confirm_failed).evaluate().isNotEmpty;
      debugPrint('[ctx-mine] dialogClosed=${!_dialogMounted()} '
          'afterMs=${sw.elapsedMilliseconds} failedToast=$failedToast');
      await captureFlutterFrame(tester, '04-after-confirm');
      final List<ErrorLogEntry> newLogs =
          ErrorLogService.instance.entries.skip(logBefore).toList();
      for (final ErrorLogEntry e in newLogs) {
        debugPrint('[ctx-mine] LOG ${e.source}: ${e.error}');
      }
      debugPrint('[ctx-mine] fakeAnki notes=${anki.notes.length} '
          'addNote=${anki.requestsFor('addNote').length} '
          'canAdd=${anki.requestsFor('canAddNotesWithErrorDetail').length}');
      debugPrint('[ctx-mine] probe after confirm: '
          '${await popup.debugEval(_kPopupProbe)}');
      expect(failedToast, isFalse,
          reason: '回点链路不该报「查词弹窗已经关掉了」：${newLogs.map((e) => e.error)}');

      // BUG-2634 的核心承诺有三条，都得由机器看着，不能只留在 debugPrint 里：
      //   ① 对话框真的关了（不是锁死到超时）；
      expect(_dialogMounted(), isFalse,
          reason: '确认后对话框必须关窗（实测 ${sw.elapsedMilliseconds} ms）');
      //   ② 提前关窗之后制卡**照样跑完并落地**；
      for (int i = 0; i < 120 && anki.requestsFor('addNote').isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(anki.notes, isNotEmpty,
          reason: '提前关窗不等于放弃制卡：假 AnkiConnect 应真的收到 addNote');
      //   ③ 落地的那张卡真的带着句子上下文，不是空草稿。
      //      （空草稿丢失正是 BUG-2627 第二轮的症状：卡制出来了、toast 报成功、
      //      用户刚调的上下文全丢，比原 bug 更隐蔽，只有这条断言看得见。）
      final List<String> landedValues = <String>[
        for (final Map<String, Object?> note in anki.notes)
          ...?(note['fields'] as Map<String, Object?>?)
              ?.values
              .map((Object? v) => '$v'),
      ];
      debugPrint('[ctx-mine] landed field values=$landedValues');
      expect(
        landedValues.any((String v) => v.contains(_kSentence)),
        isTrue,
        reason: '落地的卡必须带上句子上下文；一条都不含 = 关窗后草稿被清掉了。'
            '实测字段值=$landedValues',
      );

      // 直接再回点一次（此刻弹窗已重新可见），把返回值原样打印。留在断言之后，
      // 免得它制的第二张卡污染上面那三条。
      final bool again = await popup.mineEntryByIndex(
        0,
        releaseWhenPayloadConsumed: true,
      );
      debugPrint('[ctx-mine] direct mineEntryByIndex(0) again => $again');
      await tester.pump(const Duration(seconds: 2));
      await captureFlutterFrame(tester, '05-direct-mine');
    } finally {
      FlutterError.onError = oldHandler;
      await anki?.close();
    }
  });
}
