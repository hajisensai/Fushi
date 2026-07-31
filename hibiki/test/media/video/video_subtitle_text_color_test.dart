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

/// 真 ASS 覆盖标签（`{\c&H..&}` 等）经解析器产出的 cue——与 markup_test 同款造法，避免
/// 手搓 [SubtitleSpan] 漏掉解析器真实行为。[index] 区分同句多层拷贝的事件。
AudioCue _assCue(String raw, {int index = 0}) {
  final SubtitleMarkup m = parseSubtitleMarkup(raw);
  return AudioCue()
    ..bookKey = 'b'
    ..chapterHref = 'c'
    ..sentenceIndex = index
    ..textFragmentId = '[data-cue-id="$index"]'
    ..text = m.plainText
    ..markup = m
    ..startMs = 0
    ..endMs = 5000
    ..audioFileIndex = 0;
}

VideoPlayerController _stubWithCues(List<AudioCue> cues) {
  final VideoPlayerController c = VideoPlayerController();
  c.setCues(cues);
  c.debugUpdateCueForPosition(cues.first.startMs + 1);
  return c;
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

  /// BUG-1285（用户报「OP 字幕关闭尊重字幕自带样式变黑了」）：纯字幕模式（respectAssStyle
  /// 关）下行内 `\c`/`\1c` 主色曾以「历史 span 样式」之名不受门控一路穿透——它是这个模式里
  /// 最后一条漏网的颜色通道（`\3c` 描边色、`\1a` 填充透明度、cueStyle 主色、`\t` 颜色动画、
  /// 卡拉 OK SecondaryColour 早已全部按 respect 门控）。多层卡拉 OK 的 OP 歌词把一句拆成多
  /// 条同文本事件，纯字幕模式按文本去重只留发现顺序第一条＝最底的描边/光晕层，那层 `\c`
  /// 是黑色，而本该给它兜底的白描边 `\3c` 与透明填充 `\1a` 又都被正确门控掉 → 整句裸黑字。
  group('BUG-1285 纯字幕模式颜色语义归零（行内 \\c 不穿透）', () {
    testWidgets('OFF: 行内 \\c 黑色不生效，填充恒为用户 textColor',
        (WidgetTester tester) async {
      const Color userColor = Color(0xFF00E5FF);
      final VideoPlayerController c = _stubWithCue(_assCue(r'{\c&H000000&}歌'));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: VideoSubtitleOverlay(
            controller: c,
            textColor: userColor,
            respectAssStyle: false,
          ),
        ),
      ));
      await tester.pump();
      expect(_fillText(tester, '歌').style?.color, userColor,
          reason: '开关文案明示「关闭则一律使用你的外观设置」，行内 \\c 不得穿透');
    });

    testWidgets('OFF: 多层卡拉 OK 同句去重后不落到底层黑色（原始失败路径）',
        (WidgetTester tester) async {
      const Color userColor = Color(0xFF00E5FF);
      // OP 歌词的真实形态：同一句拆成多条同时事件——底层描边/光晕层（黑填充 + 白描边）在
      // 前、文字层在后。纯字幕模式按文本去重只保留第一条，正是黑填充那条。
      final VideoPlayerController c = _stubWithCues(<AudioCue>[
        _assCue(r'{\c&H000000&\3c&HFFFFFF&\bord4}歌', index: 0),
        _assCue(r'{\c&HFFFFFF&}歌', index: 1),
      ]);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: VideoSubtitleOverlay(
            controller: c,
            textColor: userColor,
            respectAssStyle: false,
          ),
        ),
      ));
      await tester.pump();
      final Iterable<Text> fills = tester
          .widgetList<Text>(find.text('歌'))
          .where((Text t) => t.style?.foreground == null);
      expect(fills, isNotEmpty, reason: '去重后仍应渲染该句');
      for (final Text t in fills) {
        expect(t.style?.color, userColor, reason: '任何一层拷贝都不得把 ASS 黑色主色带进纯字幕模式');
      }
    });

    testWidgets('ON: 行内 \\c 照常生效（尊重语义未被误伤）', (WidgetTester tester) async {
      const Color userColor = Color(0xFF00E5FF);
      final VideoPlayerController c = _stubWithCue(_assCue(r'{\c&H0000FF&}歌'));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: VideoSubtitleOverlay(
            controller: c,
            textColor: userColor,
            respectAssStyle: true,
          ),
        ),
      ));
      await tester.pump();
      // ASS 是 &HBBGGRR：&H0000FF& = 红。
      expect(_fillText(tester, '歌').style?.color, const Color(0xFFFF0000),
          reason: '开关打开时 ASS 主色必须优先，修复不得反向破坏尊重路径');
    });
  });

  test(
      'video settings actions layer has a text-color COLOR PICKER row wired to VideoSubtitleStyle.textColor (TODO-1326 调色盘)',
      () {
    // 用户报「字幕颜色应该支持调色盘」：文字色已从固定预设下拉换成 flutter_colorpicker
    // 的 ColorPicker（点行开对话框取任意色）。本守卫锁定新实现——退回预设下拉即红。
    // 阶段B：取色行 builder 从 video_quick_settings_sheet 移入
    // video_settings_actions.dart（buildVideoSubtitleTextColorRow，经 schema 的
    // 'video.player.subtitle_text_color' 自定义项接入面板），守卫改锁 actions 源。
    final String actionsSrc =
        File('lib/src/media/video/video_settings_actions.dart')
            .readAsStringSync()
            .replaceAll('\r\n', '\n');
    expect(actionsSrc.contains('video_setting_subtitle_text_color'), isTrue,
        reason: '必须用文字颜色 i18n 标题 key');
    expect(
        actionsSrc.contains(
            "import 'package:flutter_colorpicker/flutter_colorpicker.dart';"),
        isTrue,
        reason: '必须引入 flutter_colorpicker 调色盘');
    expect(actionsSrc.contains('ColorPicker('), isTrue,
        reason: '必须用 ColorPicker 组件（调色盘取任意色，非固定预设）');
    expect(actionsSrc.contains('_buildSubtitleColorRow('), isTrue,
        reason: '文字/背景色统一走取色行构建器');
    expect(actionsSrc.contains('s.copyWith(textColor: c)'), isTrue,
        reason: '取色必须落 VideoSubtitleStyle.textColor');
    // 固定预设的旧实现必须彻底移除（否则等于没换成调色盘）。
    expect(actionsSrc.contains('_textColorPresets'), isFalse,
        reason: '固定文字色预设应已移除，改为调色盘');
    expect(actionsSrc.contains('_textColorOptionIndex'), isFalse,
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
