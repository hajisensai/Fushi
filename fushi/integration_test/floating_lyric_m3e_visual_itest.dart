// 悬浮字幕 M3E 改造的目视取证（Windows）：直接经真通道驱动原生悬浮窗
// （windows/runner/floating_lyric_window.cpp），样式由生产构造函数
// buildFloatingLyricStyle 产出，依次停留在三种状态，外部脚本按窗口标题
// 「Fushi Lyric」抓真屏幕像素（原生分层窗不在 Flutter 渲染树里，
// captureFlutterFrame 抓不到它）。
//
//   phase-1 横排 5 句（当前句居中、primary 色，其余句降亮）
//   phase-2 自动档：前后各 12 句 + 窗口拉高（当前句自动滚到中央）
//   phase-3 竖排（字从上往下、行从右往左）
//
// 每个阶段开始打印 `[fl-visual] phase-N` 并停留 [_hold]。
//
// Run (PowerShell, from fushi/):
//   .\tool\run_windows_itest.ps1 integration_test/floating_lyric_m3e_visual_itest.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_session.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_channel.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_context.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_style.dart';
import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi_audio/fushi_audio.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/library_fixture.dart' show readyAppModel;
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const Duration _hold = Duration(seconds: 8);

const List<String> _lines = <String>[
  '「ここは、どこだ？」',
  '目を覚ますと、見知らぬ天井があった。',
  '大量の人間が転移したそうだな」「はい。',
  'フィットなどという名は知らん',
  'あの悪党の名前は知っておる。最近、奴隷を無理やりに攫うという、噂のな',
  'それで、俺に何をしろと？',
  '話は簡単だ。',
];

List<AudioCue> _cues() => <AudioCue>[
  for (int i = 0; i < _lines.length; i++)
    AudioCue()
      ..bookKey = 'visual'
      ..chapterHref = 'c'
      ..sentenceIndex = i
      ..textFragmentId = '#s$i'
      ..text = _lines[i]
      ..startMs = i * 1000
      ..endMs = i * 1000 + 900
      ..audioFileIndex = 0,
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('floating lyric M3E: multi-line, auto-fill, vertical', (
    WidgetTester tester,
  ) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue);
    final AppModel appModel = await readyAppModel(tester);

    FloatingLyricStyle style({required bool vertical}) {
      final FloatingLyricStyleSettings base = appModel
          .floatingLyricStyleSettings();
      return buildFloatingLyricStyle(
        theme: appModel.theme,
        settings: FloatingLyricStyleSettings(
          fontSize: 26,
          textOpacity: base.textOpacity,
          buttonBgOpacity: base.buttonBgOpacity,
          bgOpacity: 92,
          cornerRadius: base.cornerRadius,
          windowWidth: 0,
          lineHeight: base.lineHeight,
          textPadding: base.textPadding,
          contextOpacity: base.contextOpacity,
          vertical: vertical,
        ),
      );
    }

    Future<void> push(FloatingLyricStyle s) => FloatingLyricChannel.updateStyle(
      fontSize: s.fontSize,
      textColor: s.textColor,
      bgColor: s.bgColor,
      buttonTextColor: s.buttonTextColor,
      buttonBgColor: s.buttonBgColor,
      highlightColor: s.highlightColor,
      activeColor: s.activeColor,
      cornerRadius: s.cornerRadius,
      windowWidth: s.windowWidth,
      styleExtras: s.nativeStyleArgs,
    );

    Future<void> text(int before, int after) {
      final FloatingLyricBlock block = buildFloatingLyricBlockRange(
        cues: _cues(),
        index: 3,
        before: before,
        after: after,
      );
      return FloatingLyricChannel.updateText(
        block.text,
        currentLineStart: block.start,
        currentLineLength: block.length,
      );
    }

    Future<void> hold() async {
      final DateTime until = DateTime.now().add(_hold);
      while (DateTime.now().isBefore(until)) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    try {
      final FloatingLyricStyle horizontal = style(vertical: false);
      expect(
        await FloatingLyricChannel.show(
          fontSize: horizontal.fontSize,
          textColor: horizontal.textColor,
          bgColor: horizontal.bgColor,
          buttonTextColor: horizontal.buttonTextColor,
          buttonBgColor: horizontal.buttonBgColor,
          highlightColor: horizontal.highlightColor,
          activeColor: horizontal.activeColor,
          cornerRadius: horizontal.cornerRadius,
          rect: const FloatingLyricWindowRect(
            left: 400,
            top: 500,
            width: 1100,
            height: 300,
          ),
          styleExtras: horizontal.nativeStyleArgs,
        ),
        isTrue,
      );
      await push(horizontal);

      debugPrint('[fl-visual] phase-1 horizontal 5 lines');
      await text(2, 2);
      await hold();

      debugPrint('[fl-visual] phase-2 auto-fill, tall window');
      await FloatingLyricChannel.hide();
      await FloatingLyricChannel.show(
        fontSize: horizontal.fontSize,
        textColor: horizontal.textColor,
        bgColor: horizontal.bgColor,
        buttonTextColor: horizontal.buttonTextColor,
        buttonBgColor: horizontal.buttonBgColor,
        highlightColor: horizontal.highlightColor,
        activeColor: horizontal.activeColor,
        cornerRadius: horizontal.cornerRadius,
        rect: const FloatingLyricWindowRect(
          left: 400,
          top: 200,
          width: 1100,
          height: 700,
        ),
        styleExtras: horizontal.nativeStyleArgs,
      );
      await push(horizontal);
      await text(12, 12);
      await hold();

      debugPrint('[fl-visual] phase-3 vertical');
      final FloatingLyricStyle vertical = style(vertical: true);
      await FloatingLyricChannel.hide();
      await FloatingLyricChannel.show(
        fontSize: vertical.fontSize,
        textColor: vertical.textColor,
        bgColor: vertical.bgColor,
        buttonTextColor: vertical.buttonTextColor,
        buttonBgColor: vertical.buttonBgColor,
        highlightColor: vertical.highlightColor,
        activeColor: vertical.activeColor,
        cornerRadius: vertical.cornerRadius,
        rect: const FloatingLyricWindowRect(
          left: 600,
          top: 150,
          width: 760,
          height: 720,
        ),
        styleExtras: vertical.nativeStyleArgs,
      );
      await push(vertical);
      await text(2, 2);
      await hold();
      debugPrint('[fl-visual] done');
    } finally {
      await FloatingLyricChannel.hide();
    }
  });
}
