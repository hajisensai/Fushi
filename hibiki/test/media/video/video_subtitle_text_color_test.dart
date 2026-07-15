import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki/src/media/video/video_subtitle_style.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// TODO-1326（用户报「字幕没办法改颜色·加一下」）：给视频字幕**文字颜色**加自定义
/// 设置。模型层（[VideoSubtitleStyle.textColor] 字段 + encode/decode/copyWith）早已就位，
/// 缺的是设置入口 + overlay 真正应用用户色。本文件锁定三件事：
///   1. respectAssStyle 关时，[VideoSubtitleOverlay] 把用户 textColor 渲染成正文填充色；
///   2. respectAssStyle 开但 cue 无 ASS 主色时，回退用用户 textColor（与「尊重 .ass 样式」
///      协调：ASS 主色优先，缺失才用统一外观色——见 markup_test 里 ASS 主色优先的对照）；
///   3. 播放页快捷设置面板（video_quick_settings_sheet）确有把 textColor 落盘的文字色
///      选择行（源码守卫，撤掉入口即红）；
///   4. 用户选的预设色经 copyWith + encode/decode 往返持久化不丢（落库读取）。

VideoPlayerController _stubWithCue(AudioCue cue) {
  final VideoPlayerController c = VideoPlayerController();
  c.setCues(<AudioCue>[cue]);
  c.debugUpdateCueForPosition(cue.startMs + 1);
  return c;
}

AudioCue _plainCue(String text) {
  return AudioCue()
    ..bookKey = 'b'
    ..chapterHref = 'c'
    ..sentenceIndex = 0
    ..textFragmentId = '[data-cue-id="0"]'
    ..text = text
    ..startMs = 0
    ..endMs = 5000
    ..audioFileIndex = 0;
}

AudioCue _markupCue(String text, SubtitleMarkup markup) {
  return _plainCue(text)..markup = markup;
}

/// 读某字符 stroke+fill 双层里的**填充层**（`foreground == null`）；描边层是
/// `foreground != null`（[buildSubtitleStrokePaint] 的画笔）。与 markup_test 同款读法。
Text _fillText(WidgetTester tester, String char) {
  return tester
      .widgetList<Text>(find.text(char))
      .firstWhere((Text t) => t.style?.foreground == null);
}

void main() {
  testWidgets(
      'respectAssStyle OFF: user textColor is applied as the fill color (TODO-1326)',
      (WidgetTester tester) async {
    const Color userColor = Color(0xFF00E5FF); // cyan 预设
    final VideoPlayerController c = _stubWithCue(_plainCue('A'));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VideoSubtitleOverlay(
          controller: c,
          textColor: userColor,
          shadowColor: const Color(0xFF000000),
          shadowThickness: 5,
          respectAssStyle: false,
        ),
      ),
    ));
    await tester.pump();
    expect(_fillText(tester, 'A').style?.color, userColor,
        reason: '统一外观下正文填充色应为用户选的字幕文字颜色');
  });

  testWidgets(
      'respectAssStyle ON but cue has no ASS primary color: falls back to user textColor (TODO-1326)',
      (WidgetTester tester) async {
    const Color userColor = Color(0xFFFFEB3B); // yellow 预设
    // cueStyle 只有 bold，无 primaryColorArgb —— respect 开也应回退用户统一色。
    const SubtitleMarkup markup = SubtitleMarkup(
      plainText: 'A',
      spans: <SubtitleSpan>[],
      cueStyle: SubtitleCueStyle(bold: true),
    );
    final VideoPlayerController c = _stubWithCue(_markupCue('A', markup));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VideoSubtitleOverlay(
          controller: c,
          textColor: userColor,
          shadowThickness: 5,
          respectAssStyle: true,
        ),
      ),
    ));
    await tester.pump();
    expect(_fillText(tester, 'A').style?.color, userColor,
        reason: 'respect 开但 ASS 无主色时应回退用户文字颜色（不冲突、不吞掉用户设置）');
  });

  test(
      'quick settings sheet has a text-color COLOR PICKER row wired to VideoSubtitleStyle.textColor (TODO-1326 调色盘)',
      () {
    // 用户报「字幕颜色应该支持调色盘」：文字色已从固定预设下拉换成 flutter_colorpicker
    // 的 ColorPicker（点行开对话框取任意色）。本守卫锁定新实现——退回预设下拉即红。
    final String sheetSrc =
        File('lib/src/media/video/video_quick_settings_sheet.dart')
            .readAsStringSync()
            .replaceAll('\r\n', '\n');
    expect(sheetSrc.contains('video_setting_subtitle_text_color'), isTrue,
        reason: '必须用文字颜色 i18n 标题 key');
    expect(
        sheetSrc.contains(
            "import 'package:flutter_colorpicker/flutter_colorpicker.dart';"),
        isTrue,
        reason: '必须引入 flutter_colorpicker 调色盘');
    expect(sheetSrc.contains('ColorPicker('), isTrue,
        reason: '必须用 ColorPicker 组件（调色盘取任意色，非固定预设）');
    expect(sheetSrc.contains('_buildSubtitleColorRow('), isTrue,
        reason: '文字/背景色统一走取色行构建器');
    expect(sheetSrc.contains('_style.copyWith(textColor: c)'), isTrue,
        reason: '取色必须落 VideoSubtitleStyle.textColor');
    // 固定预设的旧实现必须彻底移除（否则等于没换成调色盘）。
    expect(sheetSrc.contains('_textColorPresets'), isFalse,
        reason: '固定文字色预设应已移除，改为调色盘');
    expect(sheetSrc.contains('_textColorOptionIndex'), isFalse,
        reason: '固定预设反查下标应随预设一并移除');
  });

  test(
      'user-picked textColor preset round-trips through copyWith + encode/decode (TODO-1326 落库)',
      () {
    const Color preset = Color(0xFF00E676); // green 预设
    final VideoSubtitleStyle picked =
        VideoSubtitleStyle.defaults.copyWith(textColor: preset);
    expect(picked.textColor, preset);
    final VideoSubtitleStyle back =
        VideoSubtitleStyle.decode(VideoSubtitleStyle.encode(picked));
    expect(back.textColor, preset,
        reason: '用户选的字幕文字颜色必须持久化不丢（preferences 层往返）');
  });
}
