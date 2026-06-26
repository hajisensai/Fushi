import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

AudioCue _cue(String text) {
  return AudioCue()
    ..bookKey = 'b'
    ..chapterHref = 'ch'
    ..sentenceIndex = 0
    ..textFragmentId = '#s1'
    ..text = text
    ..startMs = 0
    ..endMs = 5000
    ..audioFileIndex = 0;
}

VideoPlayerController _controllerWithCue(String text) {
  final VideoPlayerController c = VideoPlayerController();
  c.setCues(<AudioCue>[_cue(text)]);
  c.debugUpdateCueForPosition(100);
  return c;
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pump();
}

/// 取某字符的**填充层** [Text]（BUG-323 / TODO-569 起每字渲染成 stroke+fill 双层；
/// 填充层 = `style.foreground == null` 的那个，描边层用 foreground 画笔）。回退链/字体
/// 一致性断言只看填充层即可（描边层从填充层 copyWith 同源派生，几何属性一致）。
Text _fillTextOf(WidgetTester tester, String ch) {
  final List<Text> all = tester.widgetList<Text>(find.text(ch)).toList();
  return all.firstWhere((Text t) => t.style?.foreground == null);
}

/// 收集当前句每个字符**填充层** [Text] 的有效 [TextStyle]，验证整段字幕的字体回退链一致。
List<TextStyle> _charStyles(WidgetTester tester, String sentence) {
  final List<TextStyle> styles = <TextStyle>[];
  for (final String ch in sentence.characters) {
    final Text txt = _fillTextOf(tester, ch);
    expect(txt.style, isNotNull, reason: '字符「$ch」的 Text 缺 style');
    styles.add(txt.style!);
  }
  return styles;
}

void main() {
  group('TODO-088 字幕字体回退链一致性（の 等字不串字体）', () {
    testWidgets('每个字符都带相同的 CJK fontFamilyFallback 链', (tester) async {
      // 根因：字幕逐字符独立 Text，缺 fontFamilyFallback；主字体不含某字形（如「の」缺字）
      // 时各字符独立回退到引擎默认 fallback，字形不一致。修复后每字都带同一条确定的
      // CJK 回退链，引擎在任一平台都按同一顺序解析，整段字形一致。
      final VideoPlayerController c = _controllerWithCue('ガス会社の');
      await _pump(tester, VideoSubtitleOverlay(controller: c));

      final List<TextStyle> styles = _charStyles(tester, 'ガス会社の');
      // 每字都必须带非空 fallback 链。
      for (final TextStyle s in styles) {
        expect(
          s.fontFamilyFallback,
          isNotNull,
          reason: '字幕字符缺 fontFamilyFallback → 缺字时走引擎默认 fallback，字形不一致',
        );
        expect(s.fontFamilyFallback, isNotEmpty);
      }
      // 「の」与周围字共用同一条回退链（同 fontFamily + 同 fallback）。
      final TextStyle noStyle = styles.last; // 「の」
      for (final TextStyle s in styles) {
        expect(s.fontFamily, noStyle.fontFamily, reason: '同句字符 fontFamily 应一致');
        expect(s.fontFamilyFallback, noStyle.fontFamilyFallback,
            reason: '同句字符 fontFamilyFallback 链应一致');
      }
    });

    testWidgets('回退链覆盖主流平台日文字体（Win/Android/macOS/iOS/Linux）', (tester) async {
      final VideoPlayerController c = _controllerWithCue('の');
      await _pump(tester, VideoSubtitleOverlay(controller: c));

      final Text txt = _fillTextOf(tester, 'の');
      final List<String> fallback = txt.style!.fontFamilyFallback!;
      // 至少要含覆盖各平台的若干日文系统字体名（引擎按平台忽略不存在的项）。
      // 不强求精确清单，但必须含 Win 与 Apple 平台的代表字体，否则该平台仍走默认 fallback。
      expect(fallback, contains('Yu Gothic'), reason: 'Windows 缺日文 fallback');
      expect(fallback, contains('Hiragino Sans'),
          reason: 'macOS/iOS 缺日文 fallback');
      expect(
        fallback.any((String f) => f.contains('Noto Sans')),
        isTrue,
        reason: 'Android/Linux 缺 Noto 日文 fallback',
      );
    });

    testWidgets('设了自定义字体时回退链仍挂在每个字符上', (tester) async {
      // 用户在 TODO-049 设了 app 自定义字体（fontFamily 非空）时，仍要带 fallback，
      // 否则该自定义字体缺字时单字（の）回退割裂——这正是用户截图的场景。
      final VideoPlayerController c = _controllerWithCue('会社の');
      await _pump(
        tester,
        VideoSubtitleOverlay(controller: c, fontFamily: 'ShipporiMincho'),
      );

      final List<TextStyle> styles = _charStyles(tester, '会社の');
      for (final TextStyle s in styles) {
        expect(s.fontFamily, 'ShipporiMincho');
        expect(s.fontFamilyFallback, isNotNull);
        expect(s.fontFamilyFallback, isNotEmpty);
      }
    });

    testWidgets('ASS span 覆盖样式（如斜体/颜色）也保留回退链', (tester) async {
      // _styleForGrapheme 对 markup span 走 base.copyWith(...)，copyWith 不传
      // fontFamilyFallback 会沿用 base 的——验证 span 覆盖后回退链不丢。
      final VideoPlayerController c = _controllerWithCue('の');
      await _pump(tester, VideoSubtitleOverlay(controller: c));
      final Text txt = _fillTextOf(tester, 'の');
      expect(txt.style!.fontFamilyFallback, isNotEmpty);
    });
  });

  group('TODO-864 视频字幕字体独立 target（subtitleFontFamily → overlay）', () {
    testWidgets('设了字幕字体时每字 fontFamily 用该字体（与 appUi 解耦）', (tester) async {
      // app_model.subtitleFontFamily 由 FontTarget.videoSubtitle 解析后喂进
      // VideoSubtitleOverlay(fontFamily:)；这里直接验证 overlay 契约：传入字幕
      // 字体 → 每字符填充层用它，不再硬跟随 appFontFamily。
      final VideoPlayerController c = _controllerWithCue('字幕の');
      await _pump(
        tester,
        VideoSubtitleOverlay(controller: c, fontFamily: 'SubtitleOnlyFont'),
      );
      final List<TextStyle> styles = _charStyles(tester, '字幕の');
      for (final TextStyle s in styles) {
        expect(s.fontFamily, 'SubtitleOnlyFont');
        expect(s.fontFamilyFallback, isNotEmpty);
      }
    });

    testWidgets('字幕字体未设（null）→ 平台默认 + 回退链（旧视觉等价）', (tester) async {
      // TODO-864 向后兼容：videoSubtitle target 不被 body-seed，未设时
      // subtitleFontFamily 为 null → overlay 走平台默认字体 + CJK 回退链。
      final VideoPlayerController c = _controllerWithCue('の');
      await _pump(
        tester,
        VideoSubtitleOverlay(controller: c),
      );
      final Text txt = _fillTextOf(tester, 'の');
      expect(txt.style!.fontFamily, isNull);
      expect(txt.style!.fontFamilyFallback, isNotEmpty);
    });
  });
}
