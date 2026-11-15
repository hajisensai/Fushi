import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/epub/epub_importer.dart';

import 'helpers/focus_driver.dart' show enableFocusNavigation;
import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, readyAppModel, seedDictionary, showBooksTab;
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 「查词后从句首重播」设备验收：真阅读器 + 真有声书播放器 + 键盘光标真查词。
///
/// 每种阅读模式（paginated / continuous / vn）各跑两轮：
/// - 开关关（对照）：关弹窗后从暂停处原地续播（位置 ≥ 暂停点，远离句首）；
/// - 开关开：关弹窗后从被查词所在句的句首重播（位置落在该句起点附近）。
/// 对照组保证这不是假绿：两轮唯一差别是开关，结果必须不同。
///
/// Android 模拟器：flutter test integration_test/reader_lookup_restart_sentence_itest.dart -d emulator-5554
/// Windows：tool/run_windows_itest.ps1 -Visible integration_test/reader_lookup_restart_sentence_itest.dart
const String _sentence = '猫と hello wonderful world が見える。';
const int _cueCount = 12;

/// 每句 30 s：留足键盘光标走到「猫」的时间，句子太短会在查词前播完整本，
/// 「暂停」就成了播完而不是查词暂停（下面有前置断言兜住）。
const int _cueDurationMs = 30000;

/// 起播句；播到句内 [_playIntoCueMs] 后再查词，保证暂停点离句首够远。
const int _startCue = 2;
const int _playIntoCueMs = 3500;

typedef _RunJs = Future<dynamic> Function(String source);

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready,
  String reason, {
  int polls = 120,
}) async {
  for (int i = 0; i < polls; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (ready()) return;
  }
  fail(reason);
}

Future<Map<String, dynamic>> _readJs(_RunJs eval, String source) async {
  final Object? raw = await eval(source);
  return raw is Map
      ? Map<String, dynamic>.from(raw)
      : jsonDecode(raw.toString()) as Map<String, dynamic>;
}

Uint8List _silentWav() {
  const int sampleRate = 8000;
  const int samples = sampleRate * _cueCount * _cueDurationMs ~/ 1000;
  final ByteData bytes = ByteData(44 + samples * 2);
  void ascii(int offset, String value) {
    for (int i = 0; i < value.length; i++) {
      bytes.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  bytes.setUint32(4, bytes.lengthInBytes - 8, Endian.little);
  ascii(8, 'WAVEfmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  bytes.setUint32(40, samples * 2, Endian.little);
  return bytes.buffer.asUint8List();
}

Future<String> _seedAudiobook(
  WidgetTester tester,
  AppModel appModel,
  String label,
) async {
  await showBooksTab(tester);
  final String body = List<String>.generate(
    _cueCount,
    (int index) => '<p id="lookup-cue-$index">$_sentence</p>',
  ).join();
  final Uint8List epub = EpubBuilder.assemble(
    title: 'Lookup restart $label',
    uidPrefix: 'lookup-restart-',
    chapterXhtmls: <String>[
      '<?xml version="1.0" encoding="utf-8"?>'
          '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja">'
          '<head><title>Lookup restart</title></head><body>$body</body></html>',
    ],
  );
  final String bookKey = await EpubImporter.import(
    db: appModel.database,
    bytes: epub,
    fileName: 'lookup_restart_$label.epub',
  );
  const String testRoot = String.fromEnvironment('FUSHI_TEST_ROOT');
  final Directory fixtureDir = testRoot.isEmpty
      ? await Directory.systemTemp.createTemp('lookup_restart_')
      : Directory('$testRoot/fixtures/lookup_restart');
  await fixtureDir.create(recursive: true);
  final File audio = File('${fixtureDir.path}/$bookKey.wav');
  await audio.writeAsBytes(_silentWav(), flush: true);
  final int matchableLength = AudioTextNormalizer.normalize(_sentence).length;
  final List<AudioCue> cues = List<AudioCue>.generate(
    _cueCount,
    (int index) => AudioCue()
      ..bookKey = bookKey
      ..chapterHref = 'chapter-1.xhtml'
      ..sentenceIndex = index
      ..textFragmentId = SubtitleRematchCodec.encodeHit(
        sectionIndex: 0,
        normCharStart: index * matchableLength,
        normCharEnd: (index + 1) * matchableLength,
      )
      ..text = _sentence
      ..startMs = index * _cueDurationMs
      ..endMs = (index + 1) * _cueDurationMs
      ..audioFileIndex = 0,
  );
  final AudiobookRepository repo = AudiobookRepository(appModel.database);
  await repo.replaceAlignment(
    bookKey: bookKey,
    format: 'srt',
    path: audio.path,
  );
  await repo.replaceAudio(bookKey: bookKey, audioPaths: <String>[audio.path]);
  await repo.saveCues(bookKey: bookKey, cues: cues);
  await repo.updateFollowAudio(bookKey: bookKey, value: true);
  return bookKey;
}

/// 光标所在字符，以及它所在段落（= 哪一句 cue）。
const String _caretJs = r'''
JSON.stringify((function () {
  var c = window.fushiCaret;
  var node = c && c.node ? c.node : null;
  var el = node ? (node.nodeType === 1 ? node : node.parentElement) : null;
  var p = el && el.closest ? el.closest('p[id^="lookup-cue-"]') : null;
  return { active: !!(c && c.isActive && c.isActive()),
    ch: node ? node.textContent.substr(c.offset, 1) : '',
    cue: p ? Number(p.id.replace('lookup-cue-', '')) : -1 };
})())
''';

void _focusReader() {
  final Finder webView = find.byKey(const ValueKey<String>('fushi_webview'));
  expect(webView, findsOneWidget);
  bool focused = false;
  webView.evaluate().single.visitAncestorElements((Element ancestor) {
    final Widget widget = ancestor.widget;
    if (widget is Focus &&
        widget.onKeyEvent != null &&
        widget.focusNode != null) {
      widget.focusNode!.requestFocus();
      focused = true;
      return false;
    }
    return true;
  });
  expect(focused, isTrue, reason: '正文必须有可接收合成按键的焦点节点');
}

Future<void> _closeReader(WidgetTester tester) async {
  if (find.byType(ReaderFushiPage).evaluate().isEmpty) return;
  Navigator.of(tester.element(find.byType(ReaderFushiPage))).pop();
  await _waitFor(
    tester,
    () => find.byType(ReaderFushiPage).evaluate().isEmpty,
    '阅读器必须能正常关闭',
  );
}

/// 一轮：起播 → 播进句内 → 键盘光标查词（应暂停）→ Esc 关弹窗 → 读恢复后的位置。
Future<void> _runRound(
  WidgetTester tester,
  AppModel appModel, {
  required String viewMode,
  required bool restart,
}) async {
  final String label = '$viewMode-${restart ? 'on' : 'off'}';
  final ReaderFushiSource source = ReaderFushiSource.instance;
  await source.setReaderViewMode(viewMode);
  await source.setPauseOnLookup(value: true);
  await source.setRestartSentenceAfterLookup(value: restart);

  final String bookKey = await _seedAudiobook(tester, appModel, label);
  await openBookViaProductionPath(tester, bookKey);
  await _waitFor(
    tester,
    () => find
        .byKey(const ValueKey<String>('fushi_content_ready'))
        .evaluate()
        .isNotEmpty,
    '[$label] 正文必须加载完成',
    polls: 240,
  );
  await _waitFor(
    tester,
    () =>
        (appModel.audiobookSession.controller?.chapterCueCount ?? 0) ==
        _cueCount,
    '[$label] 合成有声书必须载入全部 cue',
  );
  final AudiobookPlayerController controller =
      appModel.audiobookSession.controller!;
  final _RunJs eval = ReaderFushiPage.debugEvaluateJavascript!;

  // 从第 _startCue 句起播，播进句内一段。
  await controller.skipToCueIndex(_startCue);
  // 不 await：Android / Darwin 后端上 play() 的 Future 挂到下一次暂停 / 播完才完成
  // （见 AudiobookPlayerController.play 文档），await 会把整轮卡到整本播完。
  unawaited(controller.play());
  await _waitFor(
    tester,
    () =>
        controller.isPlaying &&
        controller.position.inMilliseconds >=
            _startCue * _cueDurationMs + _playIntoCueMs,
    '[$label] 音频必须播进句内',
  );

  // 键盘光标查词：Enter 进入正文光标，Tab 到某句的「猫」，Enter 查词。
  _focusReader();
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await _waitFor(
    tester,
    () => ReaderFushiPage.debugCaretSurface?.call() == 'reader',
    '[$label] 进入正文光标',
  );
  Map<String, dynamic> caret = await _readJs(eval, _caretJs);
  for (int i = 0; i < 80; i++) {
    if (caret['active'] == true && caret['ch'] == '猫') break;
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump(const Duration(milliseconds: 80));
    caret = await _readJs(eval, _caretJs);
  }
  expect(caret['ch'], '猫', reason: '[$label] 键盘光标必须落在某句的「猫」');
  final int lookedUpCue = (caret['cue'] as num).toInt();
  expect(lookedUpCue, greaterThanOrEqualTo(0), reason: '[$label] 光标必须在某句内');
  expect(
    controller.isPlaying,
    isTrue,
    reason: '[$label] 前提：查词那一刻音频还在播（暂停必须来自查词，而不是播完）',
  );

  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await _waitFor(
    tester,
    () => find.byType(DictionaryPopupWebView).evaluate().isNotEmpty,
    '[$label] 正文光标查词必须打开真实词典弹窗',
  );
  await _waitFor(tester, () => !controller.isPlaying, '[$label] 查词时必须暂停');
  final int pausedMs = controller.position.inMilliseconds;
  final int pausedCue = controller.currentCue?.sentenceIndex ?? -1;
  final int pausedCueStartMs = pausedCue * _cueDurationMs;
  expect(
    pausedMs,
    lessThan(_cueCount * _cueDurationMs - 1000),
    reason: '[$label] 前提：暂停点不在音频末尾',
  );
  expect(
    pausedMs - pausedCueStartMs,
    greaterThan(1500),
    reason: '[$label] 前提：暂停点离句首够远，对照才有区分度',
  );
  // 不用 captureFlutterFrame：它先 pumpAndSettle，弹窗动画 / 播放器 tick 下可能等不到 settle。
  final ObserveShot popupShot = await captureReaderWebView(
    'lookup-restart-$label-popup',
  );

  // Esc 关弹窗 → 恢复播放。
  await _waitFor(
    tester,
    () => ReaderFushiPage.debugCaretSurface?.call() == 'popup',
    '[$label] 弹窗渲染后光标交给弹窗',
  );
  for (int i = 0; i < 4 && !controller.isPlaying; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    for (int j = 0; j < 8 && !controller.isPlaying; j++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
  }
  await _waitFor(tester, () => controller.isPlaying, '[$label] 关弹窗后必须恢复播放');
  // 起播后马上采样（只差几百毫秒），还落在恢复点附近。
  final int resumedMs = controller.position.inMilliseconds;
  final int resumedCue = controller.currentCue?.sentenceIndex ?? -1;
  await controller.pause();
  final ObserveShot afterShot = await captureReaderWebView(
    'lookup-restart-$label-after',
  );
  debugPrint(
    '[lookup-restart] $label lookedUpCue=$lookedUpCue pausedCue=$pausedCue '
    'pausedMs=$pausedMs resumedCue=$resumedCue resumedMs=$resumedMs '
    'popupShot=${popupShot.path} afterShot=${afterShot.path}',
  );

  if (restart) {
    expect(resumedCue, lookedUpCue, reason: '[$label] 必须重播被查词所在的那一句');
    expect(
      resumedMs,
      inInclusiveRange(
        lookedUpCue * _cueDurationMs,
        lookedUpCue * _cueDurationMs + 1500,
      ),
      reason: '[$label] 必须从那一句的句首开始',
    );
  } else {
    expect(
      resumedMs,
      greaterThanOrEqualTo(pausedMs - 300),
      reason: '[$label] 开关关：从暂停处原地续播',
    );
    expect(resumedCue, pausedCue, reason: '[$label] 开关关：还在暂停时那一句');
  }

  // 退出光标并关书（关书保留后台音频会话，每轮用独立 fixture 书）。
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pump(const Duration(milliseconds: 300));
  await controller.pause();
  await _closeReader(tester);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'restart sentence after lookup: off resumes in place, on replays the '
    'looked-up sentence from its start (paginated / continuous / vn)',
    timeout: const Timeout(Duration(minutes: 15)),
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'lookup-restart',
        body: () async {
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue);
          final AppModel appModel = await readyAppModel(tester);
          final bool oldFocusNavigation =
              appModel.experimentalFocusNavigationEnabled;
          await enableFocusNavigation(tester);
          expect(await seedDictionary(tester), isTrue);
          final ReaderFushiSource source = ReaderFushiSource.instance;
          final String oldViewMode = source.readerViewMode;
          final bool oldPause = source.pauseOnLookup;
          final bool oldRestart = source.restartSentenceAfterLookup;
          final int oldRevealSpeed = source.readerVisualNovelRevealSpeed;
          final bool oldLyricsMode = source.lyricsMode;
          try {
            await source.setReaderVisualNovelRevealSpeed(0);
            await source.setLyricsMode(false);
            for (final String mode in <String>[
              'paginated',
              'continuous',
              'vn',
            ]) {
              await _runRound(tester, appModel, viewMode: mode, restart: false);
              await _runRound(tester, appModel, viewMode: mode, restart: true);
            }
          } finally {
            await appModel.audiobookSession.controller?.pause();
            await _closeReader(tester);
            await source.setReaderViewMode(oldViewMode);
            await source.setPauseOnLookup(value: oldPause);
            await source.setRestartSentenceAfterLookup(value: oldRestart);
            await source.setReaderVisualNovelRevealSpeed(oldRevealSpeed);
            await source.setLyricsMode(oldLyricsMode);
            await appModel.setExperimentalFocusNavigationEnabled(
              oldFocusNavigation,
            );
          }
        },
      );
    },
  );
}
