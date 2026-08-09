// BUG-1331：`\fn@…` 竖排字体未支持 → 整行躺倒、跑出画面左缘。
//
// 用户片源真值（[Nekomoe kissaten&VCB-Studio] Tensei Oujo to Tensai Reijou no Mahou
// Kakumei，PlayResX 1280 / PlayResY 720）：
//
//   Dialogue: 0,...,OP_JP,,0,0,0,,{\fad(250,250)\blur2\fn@A-OTF Kaimin Tsuki Std H\an2\frz270\pos(10,360)}雨上がり…
//
// GDI/VSFilter 约定：`@` 前缀字体的**字形**逆时针预旋转 90°（字顶朝左），文本仍水平排版；
// 作者叠 `\frz270`（顺时针 90°）把行转竖、字形转正。两次旋转抵消才是「字正着、行竖排」。
// 旧实现把 `@` 当噪声剥掉却没人承接竖排语义，`\frz270` 照转 → 只剩单向 90°，整行躺倒。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

import '../../helpers/source_guard.dart';

AudioCue _cueOf(String raw) {
  final SubtitleMarkup m =
      parseSubtitleMarkup(raw, playResX: 1280, playResY: 720);
  return AudioCue()
    ..bookKey = 'b'
    ..chapterHref = 'c'
    ..sentenceIndex = 0
    ..textFragmentId = ''
    ..text = m.plainText
    ..markup = m
    ..startMs = 0
    ..endMs = 5000;
}

Future<void> _pump(WidgetTester tester, AudioCue cue,
    {bool respect = true}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final VideoPlayerController c = VideoPlayerController();
  addTearDown(c.dispose);
  c.setCues(<AudioCue>[cue]);
  c.debugUpdateCueForPosition(1000);
  await tester.pumpWidget(MaterialApp(
    // 关调试横幅：它本身是个 45° 旋转 Transform，会污染旋转扫描。
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: SizedBox(
        width: 1280,
        height: 720,
        child: VideoSubtitleOverlay(controller: c, respectAssStyle: respect),
      ),
    ),
  ));
  await tester.pump();
}

/// 该字形从「屏幕 x 轴正方向」被转到了哪个方向。y 向下坐标系里 (0,-1) = 视觉逆时针 90°。
Offset _glyphAxis(WidgetTester tester, String glyph) {
  final Iterable<Transform> ts = tester.widgetList<Transform>(
    find.ancestor(of: find.text(glyph).first, matching: find.byType(Transform)),
  );
  Offset axis = const Offset(1, 0);
  for (final Transform t in ts) {
    // 取两点之差消掉平移分量，只留旋转/缩放对**方向**的作用。
    axis = MatrixUtils.transformPoint(t.transform, axis) -
        MatrixUtils.transformPoint(t.transform, Offset.zero);
  }
  final double len = axis.distance;
  return len == 0 ? axis : Offset(axis.dx / len, axis.dy / len);
}

void main() {
  group('isAssVerticalFontName（@ 前缀判据）', () {
    test('@ 开头 = 竖排字体', () {
      expect(isAssVerticalFontName('@A-OTF Kaimin Tsuki Std H'), isTrue);
    });
    test('普通字体名 / 空 / null 都不是竖排', () {
      expect(isAssVerticalFontName('A-OTF Kaimin Tsuki Std H'), isFalse);
      expect(isAssVerticalFontName(''), isFalse);
      expect(isAssVerticalFontName(null), isFalse);
    });
    test('@ 只能在开头（家族名内部含 @ 不算）', () {
      expect(isAssVerticalFontName('Foo@Bar'), isFalse);
    });
  });

  group('渲染：@ 字体的字形预旋转（BUG-1331）', () {
    testWidgets('片源真值组合 \\fn@…+\\frz270 → 字形正立（两次旋转抵消）', (tester) async {
      await _pump(
        tester,
        _cueOf(r'{\fn@A-OTF Kaimin Tsuki Std H\an2\frz270\pos(10,360)}雨上がり'),
      );
      final Offset axis = _glyphAxis(tester, '雨');
      // 字形逆时针 90°（@）+ 整行顺时针 90°（\frz270）= 净 0：x 轴仍指向 x 轴。
      expect(axis.dx, closeTo(1, 0.02),
          reason: '@ 与 \\frz270 必须抵消成正立字形；只剩单向 90° 就是用户报的「整行躺倒」');
      expect(axis.dy, closeTo(0, 0.02));
    });

    testWidgets('只有 @ 没有 \\frz：字形逆时针 90°（忠实复现 GDI 预旋转）', (tester) async {
      await _pump(tester, _cueOf(r'{\fn@A-OTF Kaimin Tsuki Std H}雨'));
      final Offset axis = _glyphAxis(tester, '雨');
      expect(axis.dx, closeTo(0, 0.02));
      expect(axis.dy, closeTo(-1, 0.02), reason: 'y 向下坐标系里 (0,-1) = 视觉逆时针 90°');
    });

    testWidgets('无 @ 的普通字体 + \\frz270：字形躺倒（既有行为不变，非竖排）', (tester) async {
      await _pump(
          tester, _cueOf(r'{\fnA-OTF Kaimin Tsuki Std H\frz270\pos(10,360)}雨'));
      final Offset axis = _glyphAxis(tester, '雨');
      expect(axis.dy, closeTo(1, 0.02),
          reason: '没有 @ 就没有预旋转，\\frz270 单向生效——招牌类字幕的既有语义不能被改');
    });

    testWidgets('纯字幕模式（respectAssStyle 关）竖排一并不生效', (tester) async {
      await _pump(
        tester,
        _cueOf(r'{\fn@A-OTF Kaimin Tsuki Std H\an2\frz270\pos(10,360)}雨'),
        respect: false,
      );
      final Offset axis = _glyphAxis(tester, '雨');
      expect(axis.dx, closeTo(1, 0.02), reason: '纯字幕模式位置/样式语义整体归零');
    });

    testWidgets('竖排不改变逐字命中登记（查词照常）', (tester) async {
      await _pump(
        tester,
        _cueOf(r'{\fn@A-OTF Kaimin Tsuki Std H\an2\frz270\pos(10,360)}雨上がり'),
      );
      for (final String ch in <String>['雨', '上', 'が', 'り']) {
        expect(find.text(ch), findsWidgets, reason: '每个 grapheme 仍各自成 widget');
      }
    });
  });

  group('\\frz 变换原点 = \\an 对齐点（BUG-1440：竖排整列左侧出框）', () {
    // 与 [_pump] 同构，但**喂视频分辨率**：`\pos` 只有在 videoWidth/Height 已知时才生效
    // （[_posScreen] 否则返回 null、回落锚点对齐），不喂就测不到绝对定位几何。
    // 容器 1280x720 == PlayRes，故 `\pos` 的坐标就是容器坐标，断言可以直接写数字。
    Future<void> pumpPositioned(WidgetTester tester, AudioCue cue) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.debugVideoWidthOverride = 1280;
      c.debugVideoHeightOverride = 720;
      c.setCues(<AudioCue>[cue]);
      c.debugUpdateCueForPosition(1000);
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: SizedBox(
            width: 1280,
            height: 720,
            child: VideoSubtitleOverlay(controller: c, respectAssStyle: true),
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('片源真值 \\an2\\frz270\\pos(10,360)：整列落在 \\pos 右侧、不越出画面左缘',
        (tester) async {
      await pumpPositioned(
          tester,
          _cueOf(r'{\fn@A-OTF Kaimin Tsuki Std H\an2\frz270'
              r'\pos(10,360)}雨上がり　君は'));
      for (final String ch in <String>['雨', '君']) {
        final Rect r = tester.getRect(find.text(ch).first);
        expect(r.left, greaterThanOrEqualTo(0.0),
            reason: '「$ch」跑出画面左缘了——这正是用户报的「左边出框」');
        expect(r.left, greaterThanOrEqualTo(10.0 - 0.01),
            reason: '绕 \\an2（底边中点）转，整列应在锚点 x=10 右侧；'
                '绕盒中心转会把列整体左移半个行高');
      }
    });

    testWidgets('\\an5 居中锚点的旋转招牌几何不变（既有行为不被这次改动挪动）', (tester) async {
      // \an5 = 中中，对齐点本来就是盒中心 → 新旧原点同一个点，像素级不动。
      await pumpPositioned(tester, _cueOf(r'{\an5\frz30\pos(640,360)}看板'));
      final Rect r = tester.getRect(find.text('看').first);
      expect(r.center.dx, closeTo(640, 60),
          reason: '\\an5 招牌应仍绕自身中心转、留在 \\pos 附近');
    });
  });

  group('源码守卫', () {
    final String src = File('lib/src/media/video/video_subtitle_overlay.dart')
        .readAsStringSync();

    /// 🔴 这两条断言必须锚在**调用方的方法体**里，不能对整份源码裸 `contains`。
    ///
    /// 两个名字的**声明**就在这份源码里（`bool isAssVerticalFontName(` 在文件尾、
    /// `Widget _applyVerticalGlyphRotation(` 在 `_buildCueBox` 之后），所以
    /// `src.contains('isAssVerticalFontName(')` 会被声明自己喂饱——把唯一的调用点
    /// 删干净，守卫照样全绿，等于这条守卫在守自己。合入前变异实测已复现该假绿。
    ///
    /// `containsCodeLine` 另外掩掉注释，注释里提一嘴函数名也不算数。
    test('@ 前缀剥离处必须仍有竖排语义的承接方（不得只剥不接）', () {
      expect(src, contains("name.startsWith('@') ? name.substring(1) : name"),
          reason: '家族名解析仍应剥 @（DirectWrite 家族名不含 @）');

      // 承接方①：字形预旋转必须真的被字符构建路径调用（调用点在 _buildCueBox 内）。
      final String cueBoxBody = methodBody(src, 'Widget _buildCueBox(');
      expect(
          containsCodeLine(cueBoxBody, '_applyVerticalGlyphRotation('), isTrue,
          reason: '字形预旋转必须真的作用到字符渲染上：'
              '_buildCueBox 里没有调用点 = 剥了 @ 却没人转字形，回到 BUG-1331');

      // 承接方②：预旋转内部必须真的据 @ 前缀判据决定转不转。
      final String rotationBody =
          methodBody(src, 'Widget _applyVerticalGlyphRotation(');
      expect(containsCodeLine(rotationBody, 'isAssVerticalFontName('), isTrue,
          reason: '预旋转必须据 isAssVerticalFontName 判据放行，'
              '否则要么全转（非 @ 字体也躺倒）要么全不转（回到 BUG-1331）');
    });

    /// 窗口用 [methodBody] 按花括号配对取，不再拿**下一个方法的注释文本**当结束锚
    /// （原实现是 `src.indexOf('\n  /// span 级静态', fn)`）：那句注释被改写或那个方法
    /// 被挪走，窗口就断在错误位置——守卫会在与竖排毫无关系的改动下炸掉或悄悄扩窗。
    test('预旋转方向锁死为逆时针 90°（-π/2）', () {
      final String body =
          methodBody(src, 'Widget _applyVerticalGlyphRotation(');
      expect(containsCodeLine(body, 'Transform.rotate(angle: -math.pi / 2'),
          isTrue,
          reason: '方向写反（+π/2）会让字形与 \\frz270 叠成 180°，字倒立');
    });
  });
}
