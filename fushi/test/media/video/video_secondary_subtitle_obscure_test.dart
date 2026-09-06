import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// TODO-1382：视频**副字幕**遮蔽三态（不遮蔽 / 模糊 / 隐藏，镜像主字幕，独立开关）+
/// 快捷键（Shift+G 循环 / Shift+H 隐藏）。用户诉求：「副字幕隐藏……快捷键加一个……
/// 切换遮罩之类的」。
///
/// 分三层验证：
///  ① overlay 真行为——`secondaryHidden` 门控遮蔽副字幕层，主字幕不受影响（widget 测试）。
///     注意隐藏的实现已从「清空活动集」改为「布局照常 + Opacity(0)」：清空后屏幕上没有
///     任何 widget，鼠标无处可悬停，隐藏态就永远显形不了（用户报「隐藏了鼠标放上去也不
///     显示」）。悬停 / 点击显形本身由 video_subtitle_hide_hover_reveal_test.dart 覆盖。
///  ② 快捷键默认键位——两新 action 桌面默认绑 Shift+H / Shift+G（功能测试）。
///  ③ 接线对称守卫——prefs 三态投影键 + 快捷键 action→callback 映射 + layout 传参
///     （源码扫描，覆盖无法直接 widget 测的私有接线）。
AudioCue _cue(String text, int startMs, int endMs) => AudioCue()
  ..bookKey = 'b'
  ..chapterHref = 'ch'
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = text
  ..startMs = startMs
  ..endMs = endMs
  ..audioFileIndex = 0;

/// 该 widget 是否被某个 `opacity == 0` 的 [Opacity] 祖先包住（= 布局在、不绘制）。
/// 隐藏态遮蔽的判据：不能只断言「找不到文本」——那正是被修掉的旧实现。
bool _opaqueZero(WidgetTester tester, Finder of) => tester
    .widgetList<Opacity>(
        find.ancestor(of: of.first, matching: find.byType(Opacity)))
    .any((Opacity o) => o.opacity == 0);

Future<void> _pumpOverlay(
  WidgetTester tester,
  VideoPlayerController c, {
  required bool secondaryHidden,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: VideoSubtitleOverlay(
        controller: c,
        secondaryHidden: secondaryHidden,
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  group('TODO-1382 ① 副字幕隐藏门控（overlay 真行为）', () {
    testWidgets('secondaryHidden=true：副字幕不绘制（Opacity 0）、主字幕照常显示',
        (tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('主', 0, 6000)]);
      c.setSecondaryCues(<AudioCue>[_cue('副', 0, 6000)]);
      c.debugUpdateCueForPosition(1000);

      await _pumpOverlay(tester, c, secondaryHidden: true);

      expect(find.text('主'), findsWidgets, reason: '主字幕不受副字幕隐藏影响');
      expect(_opaqueZero(tester, find.text('主')), isFalse,
          reason: '主字幕没被误遮蔽');
      // 隐藏 = 布局照常、不绘制：cue 仍在树上（否则没有几何可供悬停显形），
      // 但被 opacity 为 0 的 Opacity 包住 → 用户看不见。
      expect(find.text('副'), findsWidgets,
          reason: '隐藏态保留几何（不再整条摘掉），否则鼠标无处可悬停');
      expect(_opaqueZero(tester, find.text('副')), isTrue,
          reason: '副字幕隐藏时不绘制（Opacity 0）');
    });

    testWidgets('secondaryHidden=false：副字幕正常显示（回归守卫）', (tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('主', 0, 6000)]);
      c.setSecondaryCues(<AudioCue>[_cue('副', 0, 6000)]);
      c.debugUpdateCueForPosition(1000);

      await _pumpOverlay(tester, c, secondaryHidden: false);

      expect(find.text('主'), findsWidgets);
      expect(find.text('副'), findsWidgets, reason: '默认不隐藏，副字幕照常渲染');
      expect(_opaqueZero(tester, find.text('副')), isFalse,
          reason: '不隐藏时不得有 Opacity(0) 遮蔽层');
    });
  });

  group('TODO-1382 ② 副字幕遮蔽快捷键默认键位（桌面）', () {
    final Map<ShortcutAction, ShortcutBindingSet> desktop =
        ShortcutDefaults.forPlatform(TargetPlatform.windows);

    bool hasKey(ShortcutAction action, LogicalKeyboardKey key,
        Set<ModifierKey> modifiers) {
      final ShortcutBindingSet? set = desktop[action];
      if (set == null) return false;
      return set.keyboardBindings.any((InputBinding b) =>
          b.key == key &&
          b.modifiers.length == modifiers.length &&
          b.modifiers.containsAll(modifiers));
    }

    test('隐藏副字幕默认 Shift+H（与主字幕 H 对称）', () {
      expect(
        hasKey(ShortcutAction.videoToggleSecondarySubtitleHide,
            LogicalKeyboardKey.keyH, {ModifierKey.shift}),
        isTrue,
      );
    });

    test('循环副字幕遮蔽默认 Shift+G', () {
      expect(
        hasKey(ShortcutAction.videoCycleSecondarySubtitleObscure,
            LogicalKeyboardKey.keyG, {ModifierKey.shift}),
        isTrue,
      );
    });
  });

  group('TODO-1382 ③ 接线对称守卫（源码扫描）', () {
    String readSrc(String path) => File(path).readAsStringSync();

    test('prefs 副字幕三态投影：独立键 + 复用 fromFlags', () {
      final String src = readSrc('lib/src/models/preferences_repository.dart');
      expect(src, contains('videoSecondarySubtitleObscureMode'));
      expect(src, contains("'video_secondary_subtitle_blur'"));
      expect(src, contains("'video_secondary_subtitle_obscure_hide'"));
    });

    test('快捷键 action→callback 映射含两新 action', () {
      final String src =
          readSrc('lib/src/media/video/video_player_shortcuts.dart');
      expect(
        src,
        contains('ShortcutAction.videoCycleSecondarySubtitleObscure:'),
      );
      expect(
        src,
        contains('ShortcutAction.videoToggleSecondarySubtitleHide:'),
      );
    });

    test('layout 把副字幕遮蔽映射成 overlay 两正交标志', () {
      final String src = readSrc(
          'lib/src/pages/implementations/video_fushi/layout.part.dart');
      expect(src, contains('secondaryBlurEnabled:'));
      expect(src, contains('secondaryHidden:'));
      expect(src, contains('appModel.videoSecondarySubtitleObscureMode'));
    });
  });
}
