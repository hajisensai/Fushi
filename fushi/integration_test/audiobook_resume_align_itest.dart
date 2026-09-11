import 'dart:async' show unawaited;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/test_app_launcher.dart';
import 'package:fushi/i18n/strings.g.dart' show t;
import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderFushiPage, charCountsFromChaptersJson;
import 'package:fushi/src/pages/implementations/statistics_center_page.dart'
    show StatisticsCenterPage;
import 'package:fushi/src/stats/study_diag_log.dart' show StudyDiagLog;
import 'package:fushi_audio/fushi_audio.dart'
    show
        AudioCue,
        AudiobookRepository,
        ReaderPosition,
        ReaderPositionRepository,
        SubtitleRematchCodec;
import 'package:fushi_core/fushi_core.dart'
    show EpubBookRow, FushiDatabase, StudySegmentsCompanion, kActivityMediaBook;

import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, readyAppModel, seedAudiobook;
import 'helpers/media_fixtures.dart' show buildSampleCues, kFixtureChapterHref;
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'test_helpers.dart';

/// 有声书重开书起点 + 统计中心「每小时字数」（用户 2026-09-12：「书重新打开有可能和
/// 有声书阅读进度错误，可能落在当前进度前面但是有声书在后面，一旦播放就会跨了很多页
/// 导致阅读速度和阅读量异常」；「阅读速度单位是每小时多少字，顶部方框和每个会话」）
/// 真 app 两段：
///
///   A. 正文存档停在 5%，音频位置写到第 90 句（≈ 90%）→ 重开书，**不按播放**，
///      起点就已在音频处（BUG-2390「带有声书时音频位置为主」）：落库的阅读位置收敛到
///      > 50%，统计诊断流水记 `open resume point … source=audio cue`。
///   C. 播种一段 30 分钟 / 6000 字的会话 → 统计中心总览顶部卡与会话行都显示
///      `12000 字/时`（i18n `stat_speed_cph`）。
///
/// 三端同一份（Windows 离屏 runner / Mac 跨机 / iOS 模拟器）。cue 用 sasayaki 编码
/// 片段（`fushi-cue://s=0&ns=…`）让 cue → 正文位置可精确映射（生产 EPUB+音频匹配后
/// 就是这种 cue）。每段都打 WebView 探针（视口 / 重锚旗 / rAF 是否在跑）——Mac 隐藏
/// runner 下 WebKit 冻结 rAF 曾让重锚旗挂死、位置永不落库（BUG-2465）。
const Key _kWebViewKey = ValueKey<String>('fushi_webview');
const Key _kContentReadyKey = ValueKey<String>('fushi_content_ready');

bool _webViewShown() => find.byKey(_kWebViewKey).evaluate().isNotEmpty;
bool _contentReady() => find.byKey(_kContentReadyKey).evaluate().isNotEmpty;
bool _readerPageGone() => find.byType(ReaderFushiPage).evaluate().isEmpty;

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready,
  String label, {
  int maxPolls = 120,
  Duration step = const Duration(milliseconds: 500),
}) async {
  for (int i = 0; i < maxPolls; i++) {
    await tester.pump(step);
    if (ready()) {
      debugPrint(
        '[resume-align] $label ready after ${i * step.inMilliseconds}ms',
      );
      return;
    }
  }
  fail(
    '$label did not become ready within ${maxPolls * step.inMilliseconds}ms',
  );
}

Future<void> _closeReader(WidgetTester tester) async {
  if (_readerPageGone()) return;
  Navigator.of(tester.element(find.byType(ReaderFushiPage))).pop();
  await _waitFor(tester, _readerPageGone, 'reader closed', maxPolls: 40);
  await tester.pump(const Duration(seconds: 1));
}

/// 开书 → 等正文就绪 → 等落库的阅读位置满足 [accept]（恢复后的首次
/// `_refreshProgress` 500ms 去抖落库）。返回最后读到的位置。
Future<ReaderPosition?> _openAndSettle(
  WidgetTester tester,
  String bookKey,
  ReaderPositionRepository positions,
  String uid,
  bool Function(ReaderPosition pos) accept,
  String label,
) async {
  await openBookViaProductionPath(tester, bookKey);
  await _waitFor(tester, _webViewShown, '$label WebView');
  await _waitFor(tester, _contentReady, '$label content');
  ReaderPosition? last;
  for (int i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    last = await positions.findByBookUid(uid);
    if (last != null && accept(last)) break;
  }
  debugPrint(
    '[resume-align] $label persisted position: section=${last?.sectionIndex} '
    'norm=${last?.normCharOffset} charOffset=${last?.charOffset}',
  );
  // 取证：WebView 侧视口 / 重锚旗 / 进度快照原文 + rAF 是否在跑（重锚旗只在
  // rAF 回调里清；隐藏页面里 rAF 冻结，BUG-2465 改走 setTimeout）。
  final Future<dynamic> Function(String)? runJs =
      ReaderFushiPage.debugEvaluateJavascript;
  if (runJs != null) {
    try {
      final Object? probe = await runJs(_kViewportProbeJs);
      debugPrint('[resume-align] $label webview probe: $probe');
      await runJs(_kArmTimersJs);
      await tester.pump(const Duration(seconds: 1));
      final Object? timers = await runJs(_kReadTimersJs);
      debugPrint('[resume-align] $label webview timers: $timers');
    } catch (e) {
      debugPrint('[resume-align] $label webview probe failed: $e');
    }
  }
  return last;
}

const String _kViewportProbeJs = r'''
(function () {
  var r = window.fushiReader;
  var details = '';
  try { details = window.fushiProgressDetails ? String(window.fushiProgressDetails()) : 'no-fn'; } catch (e) { details = 'err:' + e; }
  var p = -1;
  try { p = r && r.calculateProgress ? r.calculateProgress() : -1; } catch (e) { p = 'err:' + e; }
  return JSON.stringify({
    innerW: window.innerWidth, innerH: window.innerHeight,
    clientW: document.documentElement.clientWidth, clientH: document.documentElement.clientHeight,
    pending: !!(r && r._reanchorPending === true),
    progress: p, details: details,
    scrollW: document.documentElement.scrollWidth, scrollH: document.documentElement.scrollHeight
  });
})()
''';

const String _kArmTimersJs = r'''
(function () {
  window.__fushiRafTicks = 0; window.__fushiTimeoutTicks = 0;
  var step = function () { window.__fushiRafTicks++; if (window.__fushiRafTicks < 30) requestAnimationFrame(step); };
  requestAnimationFrame(step);
  setTimeout(function () { window.__fushiTimeoutTicks++; }, 50);
  return 'armed';
})()
''';

const String _kReadTimersJs = r'''
JSON.stringify({raf: window.__fushiRafTicks, timeout: window.__fushiTimeoutTicks, hidden: document.hidden, vis: document.visibilityState})
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'audiobook resume: reopening lands the reader at the audiobook position; '
    'stats center shows chars/hour on period cards and session rows',
    timeout: const Timeout(Duration(minutes: 12)),
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'resume-align',
        body: () async {
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue, reason: 'home must render');
          await tester.pump(const Duration(seconds: 2));
          final AppModel appModel = await readyAppModel(tester);
          final FushiDatabase db = appModel.database;

          const int cueCount = 100;
          final String bookKey = await seedAudiobook(
            tester,
            title: 'Resume Align Audiobook',
            audioDuration: const Duration(seconds: 260),
            cueCount: cueCount,
          );
          final EpubBookRow? row = await db.getEpubBook(bookKey);
          expect(row, isNotNull);
          final String uid = row!.uid;
          final List<int>? counts = charCountsFromChaptersJson(
            row.chaptersJson,
            row.chapterCount,
          );
          expect(counts, isNotNull, reason: '导入应落每章字数（当前口径）');
          final int chapterChars = counts!.first;
          debugPrint(
            '[resume-align] book=$bookKey uid=$uid chars=$chapterChars',
          );
          expect(chapterChars, greaterThan(1200));

          // cue → 正文映射：第 i 句落在章内 i/cueCount 处（编码片段的偏移是章正文
          // 坐标，与本 fixture 纯日文正文的学习单位坐标基本重合）。
          final List<AudioCue> cues = buildSampleCues(
            bookKey: bookKey,
            chapterHref: kFixtureChapterHref,
            count: cueCount,
          );
          for (int i = 0; i < cues.length; i++) {
            final int ns = (i * chapterChars / cueCount).floor();
            cues[i].textFragmentId = SubtitleRematchCodec.encodeHit(
              sectionIndex: 0,
              normCharStart: ns,
              normCharEnd: ns + 10,
            );
          }
          final AudiobookRepository audio = AudiobookRepository(db);
          await audio.saveCues(bookKey: bookKey, cues: cues);
          await audio.updateFollowAudio(bookKey: bookKey, value: true);
          final ReaderPositionRepository positions = ReaderPositionRepository(
            db,
          );

          try {
            // ── A. 正文存档 5%、音频在第 90 句 → 重开书起点在音频处 ────────
            await positions.save(
              bookUid: uid,
              sectionIndex: 0,
              normCharOffset: 500,
              charOffset: null,
            );
            const int audioCue = 90;
            await audio.updatePositionMs(
              bookKey: bookKey,
              positionMs: cues[audioCue].startMs + 100,
            );
            final int traceBefore = StudyDiagLog.instance.lines.length;

            final ReaderPosition? posA = await _openAndSettle(
              tester,
              bookKey,
              positions,
              uid,
              (ReaderPosition p) => p.normCharOffset > 5000,
              'A',
            );
            expect(posA, isNotNull);
            expect(
              posA!.normCharOffset,
              greaterThan(5000),
              reason: '正文起点必须已在音频处（≈ 90%），不是停在旧的 5%',
            );
            expect(
              appModel.audiobookSession.controller?.isPlaying ?? false,
              isFalse,
              reason: '起点解析不触发播放',
            );
            final List<String> traceA =
                StudyDiagLog.instance.lines.skip(traceBefore).toList();
            expect(
              traceA.any(
                (String l) =>
                    l.contains('open resume point chapter=0') &&
                    l.contains('source=audio cue'),
              ),
              isTrue,
              reason: '诊断流水必须记下起点来源\n${traceA.join('\n')}',
            );
            // 像素证据：重开后正文已在音频处（WebView 截图）+ Flutter 帧。
            final ObserveShot webA = await captureReaderWebView(
              'resume-a-reader-webview',
            );
            final ObserveShot frameA = await captureFlutterFrame(
              tester,
              'resume-a-reader-frame',
            );
            debugPrint(
              '[resume-align] A shots webview=${webA.saved}/${webA.nonBlank} '
              'frame=${frameA.saved}/${frameA.nonBlank}',
            );
            await _closeReader(tester);

            // ── C. 统计中心：顶部卡 + 会话行的字/时 ──────────────────────
            final DateTime now = DateTime.now();
            final DateTime start = now.subtract(const Duration(minutes: 30));
            await db.upsertStudySegment(
              StudySegmentsCompanion(
                uid: const Value('itest-resume-align-seg'),
                deviceId: Value(await db.getOrCreateStudyDeviceId()),
                mediaKind: const Value(kActivityMediaBook),
                mediaKey: Value(bookKey),
                format: const Value('epub'),
                title: const Value('Resume Align Audiobook'),
                startAt: Value(start.millisecondsSinceEpoch),
                endAt: Value(now.millisecondsSinceEpoch),
                dateKey: Value(FushiDatabase.statDateKeyOf(start)),
                hour: Value(start.hour),
                durationMs: const Value(30 * 60000),
                chars: const Value(6000),
                pages: const Value(0),
                updatedAt: Value(now.millisecondsSinceEpoch),
              ),
            );
            final NavigatorState nav = appModel.navigatorKey.currentState!;
            unawaited(
              nav.push(
                MaterialPageRoute<void>(
                  builder: (BuildContext _) => const StatisticsCenterPage(),
                ),
              ),
            );
            final String cph = t.stat_speed_cph(n: '12000');
            await _waitFor(
              tester,
              () => find.textContaining(cph).evaluate().length >= 2,
              'stats center cph ($cph)',
              maxPolls: 40,
            );
            // 时段卡的副行渲染成 `阅读速度: 12000 字/时`（四张卡都含今日，至少一张）；
            // 会话行的量纲串 `… · 6000 字 · 12000 字/时` 不带标签。
            final String cardLine = '${t.stat_reading_speed}: $cph';
            expect(
              find.textContaining(cardLine),
              findsWidgets,
              reason: '顶部时段卡必须显示阅读速度行',
            );
            // 总览是懒构建的 ListView：窄一点的窗口（Mac 1470×835）上「最近会话」区块
            // 在四张卡之下、视口之外，根本没被 build。程序化滚到底再断言（不走手势）。
            final ScrollableState overview = Scrollable.of(
              tester.element(find.textContaining(cardLine).first),
            );
            overview.position.jumpTo(overview.position.maxScrollExtent);
            await tester.pump(const Duration(milliseconds: 300));
            await tester.pump(const Duration(milliseconds: 300));
            final Finder sessionRow = find.byWidgetPredicate((Widget w) {
              if (w is! Text) return false;
              final String? data = w.data;
              return data != null &&
                  data.contains(cph) &&
                  !data.contains(t.stat_reading_speed);
            });
            expect(
              sessionRow,
              findsWidgets,
              reason: '会话行末尾必须带 12000 字/时',
            );
            final ObserveShot statsShot = await captureFlutterFrame(
              tester,
              'stats-center-cph',
            );
            debugPrint(
              '[resume-align] stats shot saved=${statsShot.saved} '
              'nonBlank=${statsShot.nonBlank} path=${statsShot.path}',
            );
            nav.pop();
            await tester.pump(const Duration(seconds: 1));
          } finally {
            await _closeReader(tester);
          }
        },
      );
    },
  );
}
