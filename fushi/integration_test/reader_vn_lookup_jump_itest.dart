import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/i18n/strings.g.dart' show t;
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/epub/epub_importer.dart';

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, readyAppModel, seedDictionary, showBooksTab;
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// BUG-2632：真 VN 正文 → 键盘查词 → 弹窗「从此句播放」回归。
/// 同文重复句排除文本搜索碰巧命中的假通过；混排让学习单位与音频 UTF-16 偏移不同。
/// Windows：tool/run_windows_itest.ps1 -Visible integration_test/reader_vn_lookup_jump_itest.dart
const String _sentence = '猫と hello wonderful world が見える。';
const int _cueCount = 12;
const int _cueDurationMs = 10000;

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

/// 静音 PCM WAV，复用 local_audio_cache_recovery_itest 的 RIFF 布局。
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
  String writingMode,
) async {
  await showBooksTab(tester);
  final String body = List<String>.generate(
    _cueCount,
    (int index) => '<p id="lookup-cue-$index">$_sentence</p>',
  ).join();
  final Uint8List epub = EpubBuilder.assemble(
    title: 'VN lookup jump $writingMode',
    uidPrefix: 'vn-lookup-jump-',
    chapterXhtmls: <String>[
      '<?xml version="1.0" encoding="utf-8"?>'
          '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja">'
          '<head><title>VN lookup jump</title></head><body>$body</body></html>',
    ],
  );
  final String bookKey = await EpubImporter.import(
    db: appModel.database,
    bytes: epub,
    fileName: 'vn_lookup_jump_$writingMode.epub',
  );
  const String testRoot = String.fromEnvironment('FUSHI_TEST_ROOT');
  final Directory fixtureDir = testRoot.isEmpty
      ? await Directory.systemTemp.createTemp('vn_lookup_jump_')
      : Directory('$testRoot/fixtures/vn_lookup_jump');
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

const String _screenJs = r'''
JSON.stringify((function () {
  var r = window.fushiReader;
  var p = r && r.screen ? r.screen.querySelector('p[id^="lookup-cue-"]') : null;
  return { idx: r ? r.currentScreenIndex : -1,
    screens: r && r.screens ? r.screens.length : 0,
    cue: p ? Number(p.id.replace('lookup-cue-', '')) : -1,
    text: p ? p.textContent : null };
})())
''';

const String _caretJs = r'''
JSON.stringify((function () {
  var c = window.fushiCaret;
  return { active: !!(c && c.isActive && c.isActive()),
    ch: c && c.node ? c.node.textContent.substr(c.offset, 1) : '' };
})())
''';

Future<void> _closeReader(WidgetTester tester) async {
  if (find.byType(ReaderFushiPage).evaluate().isEmpty) return;
  Navigator.of(tester.element(find.byType(ReaderFushiPage))).pop();
  await _waitFor(
    tester,
    () => find.byType(ReaderFushiPage).evaluate().isEmpty,
    '阅读器必须能正常关闭',
  );
}

Future<void> _verifyJump(
  WidgetTester tester,
  AppModel appModel,
  String bookKey,
  String writingMode,
) async {
  await ReaderFushiSource.instance.setReaderWritingMode(writingMode);
  await openBookViaProductionPath(tester, bookKey);
  await _waitFor(
    tester,
    () => find
        .byKey(const ValueKey<String>('fushi_content_ready'))
        .evaluate()
        .isNotEmpty,
    'VN 正文必须加载完成',
    polls: 240,
  );
  await _waitFor(
    tester,
    () =>
        (appModel.audiobookSession.controller?.chapterCueCount ?? 0) ==
        _cueCount,
    '合成有声书必须载入全部 cue',
  );
  final AudiobookPlayerController controller =
      appModel.audiobookSession.controller!;
  final _RunJs eval = ReaderFushiPage.debugEvaluateJavascript!;
  final Map<String, dynamic> initial = await _readJs(eval, _screenJs);
  expect(initial['screens'], greaterThan(6));
  _focusReader();
  for (int page = 0; page < 6; page++) {
    final Map<String, dynamic> before = await _readJs(eval, _screenJs);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    bool advanced = false;
    for (int i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      final Map<String, dynamic> after = await _readJs(eval, _screenJs);
      if ((after['idx'] as num) > (before['idx'] as num)) {
        advanced = true;
        break;
      }
    }
    expect(advanced, isTrue, reason: 'PageDown 必须真的前进一屏');
  }
  final Map<String, dynamic> selected = await _readJs(eval, _screenJs);
  final int expectedCue = (selected['cue'] as num).toInt();
  expect(expectedCue, greaterThan(0), reason: '回归必须在章内后方的重复句上查词');
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await _waitFor(
    tester,
    () => ReaderFushiPage.debugCaretSurface?.call() == 'reader',
    '进入正文光标',
  );
  bool onCat = false;
  for (int i = 0; i < 80; i++) {
    final Map<String, dynamic> caret = await _readJs(eval, _caretJs);
    if (caret['active'] == true && caret['ch'] == '猫') {
      onCat = true;
      break;
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(onCat, isTrue, reason: '键盘光标必须落在当前句的 猫');
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await _waitFor(
    tester,
    () => find.byType(DictionaryPopupWebView).evaluate().isNotEmpty,
    '正文光标查词必须打开真实词典弹窗',
  );
  await _waitFor(
    tester,
    () => ReaderFushiPage.debugCaretSurface?.call() == 'popup',
    '真实词典结果渲染后必须把光标交给弹窗',
  );
  final Finder jump = find.byWidgetPredicate(
    (Widget widget) =>
        widget is FushiIconButton && widget.tooltip == t.play_from_cue,
  );
  await _waitFor(tester, () => jump.evaluate().isNotEmpty, '弹窗必须有从此句播放按钮');
  expect(tester.widget<FushiIconButton>(jump).onTap, isNotNull);
  final FocusDriver driver = FocusDriver(tester);
  // 弹窗正文的 Tab 仍是文字光标移动；先按 Up 越过正文顶边进入 Flutter 顶栏。
  expect(
    await driver.focusUntil(
      () => driver.focused?.nearestScope?.debugLabel == 'popupHeader',
      key: LogicalKeyboardKey.arrowUp,
      maxSteps: 30,
    ),
    isTrue,
    reason: '从弹窗正文向上必须进入音频操作顶栏',
  );
  expect(await driver.focusWidget(jump), isTrue, reason: '跳转按钮必须能通过焦点访问');
  await driver.activate();
  await _waitFor(tester, () => controller.isPlaying, '从此句播放必须启动音频');
  await controller.pause();
  final Map<String, dynamic> landed = await _readJs(eval, _screenJs);
  final ObserveShot shot = await captureReaderWebView('vn-lookup-$writingMode');
  debugPrint(
    '[vn-lookup] $writingMode selected=${jsonEncode(selected)} '
    'landed=${jsonEncode(landed)} cue=${controller.currentCue?.sentenceIndex} '
    'positionMs=${controller.position.inMilliseconds} screenshot=${shot.path}',
  );
  expect(
    controller.currentCue?.sentenceIndex,
    expectedCue,
    reason: '重复句必须按章内音频坐标跳到被查词的那一句',
  );
  expect(
    controller.position.inMilliseconds,
    inInclusiveRange(
      expectedCue * _cueDurationMs,
      expectedCue * _cueDurationMs + 3000,
    ),
  );
  expect(landed['cue'], expectedCue, reason: '音频跟随不能把 VN 跳到其它重复句');
  await _closeReader(tester);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'VN lookup play-from-cue keeps the selected repeated sentence',
    timeout: const Timeout(Duration(minutes: 8)),
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'vn-lookup',
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
          final String oldWritingMode = source.readerWritingMode;
          final String oldScreenMode = source.readerVisualNovelScreenMode;
          final int oldRevealSpeed = source.readerVisualNovelRevealSpeed;
          final bool oldLyricsMode = source.lyricsMode;
          try {
            await source.setReaderViewMode('vn');
            await source.setReaderVisualNovelScreenMode('block');
            await source.setReaderVisualNovelRevealSpeed(0);
            await source.setLyricsMode(false);
            for (final String mode in <String>[
              'vertical-rl',
              'horizontal-tb',
            ]) {
              // 关书仍保留阅读位置和后台音频会话，每轮使用独立 fixture 书。
              final String bookKey = await _seedAudiobook(
                tester,
                appModel,
                mode,
              );
              await _verifyJump(tester, appModel, bookKey, mode);
            }
          } finally {
            await appModel.audiobookSession.controller?.pause();
            await _closeReader(tester);
            await source.setReaderViewMode(oldViewMode);
            await source.setReaderWritingMode(oldWritingMode);
            await source.setReaderVisualNovelScreenMode(oldScreenMode);
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
