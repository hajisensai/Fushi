import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_glyph_atlas.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_scene.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_visualizer.dart';

import '../visualizer_test_helpers.dart';

/// [image] 里 alpha 介于 10%~90% 的像素数（字边缘的过渡带越宽越虚）。
Future<int> _softEdgePixels(ui.Image image) async {
  final ByteData bytes = (await image.toByteData())!;
  int n = 0;
  for (int i = 3; i < bytes.lengthInBytes; i += 4) {
    final int a = bytes.getUint8(i);
    if (a > 25 && a < 230) n++;
  }
  return n;
}

/// 经 [LumiereGlyphBatch] 把 [char] 以 [px] 逻辑像素画出来（与场景画字同一条路径）。
Future<ui.Image> _drawGlyph(
  LumiereGlyphAtlases atlases,
  String char,
  double px, {
  double devicePixelRatio = 1,
}) {
  final double side = px * kLumiereGlyphCellRatio;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  final LumiereGlyphBatch batch = LumiereGlyphBatch()
    ..add(
      atlases,
      atlases.slotOf(char)!,
      side / 2,
      side / 2,
      px,
      0,
      0xFFFFFFFF,
      devicePixelRatio: devicePixelRatio,
    );
  batch.flush(canvas);
  return recorder.endRecording().toImage(side.ceil(), side.ceil());
}

/// 直接排字画出来（清晰度的参照）。
Future<ui.Image> _drawDirect(String char, double px) {
  final double side = px * kLumiereGlyphCellRatio;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  final TextPainter p = TextPainter(
    text: TextSpan(text: char, style: const LumiereGlyphStyle().textStyle(px)),
    textDirection: TextDirection.ltr,
  )..layout();
  p.paint(canvas, Offset((side - p.width) / 2, (side - p.height) / 2));
  p.dispose();
  return recorder.endRecording().toImage(side.ceil(), side.ceil());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('分档', () {
    test('最低一档 64，逐档翻倍；顶档受像素预算与上限封顶', () {
      for (final int n in <int>[1, 12, 50, 300, 1200, 4000]) {
        final List<double> tiers = lumiereAtlasTiers(n);
        expect(tiers.first, kLumiereAtlasBaseEm, reason: 'n=$n');
        for (int i = 1; i < tiers.length; i++) {
          expect(tiers[i], greaterThan(tiers[i - 1]), reason: 'n=$n');
        }
        expect(tiers.last, lessThanOrEqualTo(kLumiereAtlasMaxEm));
        if (tiers.length > 1) {
          // 顶档所有字格加起来不超预算。
          final double cell = tiers.last * kLumiereGlyphCellRatio;
          expect(
            n * cell * cell,
            lessThanOrEqualTo(kLumiereAtlasMaxPixels),
            reason: 'n=$n',
          );
        }
      }
      // 字少的歌能画到上限；常见的 300 字日文歌顶档也远大于 64。
      expect(lumiereAtlasTiers(12).last, kLumiereAtlasMaxEm);
      expect(lumiereAtlasTiers(300).last, greaterThan(160));
    });

    test('按物理字号选档：小字用低档；大字先回落已有档并记下要补的档', () async {
      final LumiereGlyphAtlases set = LumiereGlyphAtlases.build(<String>[
        'A',
        'B',
      ], const LumiereGlyphStyle());
      addTearDown(set.dispose);
      expect(set.levelFor(30).em, 64);
      expect(set.wantedEm, isNull);
      // 120 逻辑 px × DPR 2 = 240 物理 px → 256 档（还没画：先用 64，记下 256）。
      expect(set.levelFor(240).em, 64);
      expect(set.wantedEm, 256);
      final LumiereGlyphAtlas big = (await LumiereGlyphAtlas.rasterize(
        set.chars,
        set.style,
        em: 256,
      ))!;
      set.addLevel(big);
      expect(set.wantedEm, isNull);
      expect(identical(set.levelFor(240), big), isTrue);
      // 只略大于一档（≤5%）不换更大的档。
      expect(set.levelFor(66).em, 64);
    });
  });

  group('清晰度', () {
    test('240 px 的大字：补档后边缘与直接排字一样利，旧的 64 档放大明显发虚', () async {
      const double px = 240;
      final LumiereGlyphAtlases set = LumiereGlyphAtlases.build(<String>[
        'H',
        'x',
      ], const LumiereGlyphStyle());
      addTearDown(set.dispose);
      final int reference = await _softEdgePixels(await _drawDirect('H', px));
      final int blurry = await _softEdgePixels(await _drawGlyph(set, 'H', px));
      final double em = set.wantedEm!;
      set.addLevel(
        (await LumiereGlyphAtlas.rasterize(set.chars, set.style, em: em))!,
      );
      final int crisp = await _softEdgePixels(await _drawGlyph(set, 'H', px));
      expect(reference, greaterThan(0));
      // 修前：64 档放大 3.75 倍，过渡带是直接排字的数倍。
      expect(blurry, greaterThan(reference * 2.5), reason: 'blurry=$blurry');
      // 修后：过渡带收窄到放大版的一半以内，与直接排字同一量级（只剩缩小一点点的重采样）。
      expect(
        crisp,
        lessThan(blurry / 2),
        reason: 'crisp=$crisp blurry=$blurry',
      );
      expect(
        crisp,
        lessThanOrEqualTo(reference * 2.2),
        reason: 'crisp=$crisp reference=$reference',
      );
    });

    test('大档分页：每页不超 1024 边长，跨页的字取对页、画得出来', () async {
      final List<String> chars = <String>[
        for (int i = 0; i < 40; i++)
          String.fromCharCode(0x41 + (i % 26)) * (1 + i ~/ 26),
      ];
      final LumiereGlyphAtlas big = (await LumiereGlyphAtlas.rasterize(
        chars,
        const LumiereGlyphStyle(),
        em: 256,
      ))!;
      addTearDown(big.dispose);
      final int perSheet =
          lumiereAtlasSheetColumns(256) * lumiereAtlasSheetColumns(256);
      expect(big.sheets.length, (chars.length / perSheet).ceil());
      for (final ui.Image s in big.sheets) {
        expect(s.width, lessThanOrEqualTo(1024));
        expect(s.height, lessThanOrEqualTo(1024));
      }
      expect(identical(big.sheetOf(chars.length - 1), big.sheets.last), isTrue);
      final Rect r = big.rectOf(chars.length - 1);
      expect(r.right, lessThanOrEqualTo(big.sheets.last.width + 0.5));
      expect(r.bottom, lessThanOrEqualTo(big.sheets.last.height + 0.5));
    });

    test('高 DPR 下按物理像素选档', () async {
      final LumiereGlyphAtlases set = LumiereGlyphAtlases.build(<String>[
        'H',
      ], const LumiereGlyphStyle());
      addTearDown(set.dispose);
      // 60 逻辑 px 在 DPR 1 上 64 档就够；DPR 3 上要 256 档。
      await _drawGlyph(set, 'H', 60);
      expect(set.wantedEm, isNull);
      await _drawGlyph(set, 'H', 60, devicePixelRatio: 3);
      expect(set.wantedEm, 256);
    });
  });

  group('后台重建', () {
    LumiereGlyphs glyphs0() => LumiereGlyphs(<String>[
      '夜',
      '空',
      'に',
      ' ',
      '夜',
    ], const LumiereGlyphStyle(fontFamily: 'A'));

    test('去重、空白不进图集；建场景时最低一档同步就绪', () {
      final LumiereGlyphs g = glyphs0();
      addTearDown(g.dispose);
      expect(g.chars, <String>['夜', '空', 'に']);
      expect(g.current.builtEms, <double>[64]);
      expect(g.current.slotOf('空'), 1);
    });

    test('换字体不阻塞：旧图集画到新的一套就绪再换上，带上旧图集已有的档，旧图集释放', () async {
      final LumiereGlyphs g = glyphs0();
      addTearDown(g.dispose);
      int notified = 0;
      g.changed.addListener(() => notified++);
      final LumiereGlyphAtlases old = g.current;
      old.levelFor(500);
      g.afterFrame();
      await g.settled;
      final List<double> oldEms = old.builtEms.toList()..sort();
      expect(oldEms.length, 2);
      expect(notified, 1);

      const LumiereGlyphStyle b = LumiereGlyphStyle(fontFamily: 'B');
      g.requestStyle(b);
      // 同步返回时还是旧的一套（不在 UI 线程上同步重建）。
      expect(identical(g.current, old), isTrue);
      expect(g.debugPendingStyle, b);
      await g.settled;
      expect(g.current.style, b);
      expect(g.debugPendingStyle, isNull);
      expect(g.current.builtEms.toList()..sort(), oldEms);
      expect(notified, 2);
      expect(old.builtEms, isEmpty, reason: '旧图集已释放');
    });

    test('连续切字体只落到最后一个；切回正在画的字体就作废后台任务', () async {
      final LumiereGlyphs g = glyphs0();
      addTearDown(g.dispose);
      final LumiereGlyphAtlases old = g.current;
      g.requestStyle(const LumiereGlyphStyle(fontFamily: 'B'));
      g.requestStyle(const LumiereGlyphStyle(fontFamily: 'C'));
      g.requestStyle(const LumiereGlyphStyle(fontFamily: 'D'));
      await g.settled;
      expect(g.current.style.fontFamily, 'D');
      expect(old.builtEms, isEmpty);

      final LumiereGlyphAtlases d = g.current;
      g.requestStyle(const LumiereGlyphStyle(fontFamily: 'E'));
      g.requestStyle(const LumiereGlyphStyle(fontFamily: 'D'));
      expect(g.debugPendingStyle, isNull);
      await g.settled;
      expect(identical(g.current, d), isTrue);
    });

    test('回落链 / 字重也算换字体', () async {
      final LumiereGlyphs g = glyphs0();
      addTearDown(g.dispose);
      g.requestStyle(
        const LumiereGlyphStyle(
          fontFamily: 'A',
          fontFamilyFallback: <String>['X'],
        ),
      );
      expect(g.debugPendingStyle, isNotNull);
      await g.settled;
      g.requestStyle(
        const LumiereGlyphStyle(
          fontFamily: 'A',
          fontFamilyFallback: <String>['X'],
          fontWeight: FontWeight.w700,
        ),
      );
      expect(g.debugPendingStyle, isNotNull);
      await g.settled;
      expect(g.current.style.fontWeight, FontWeight.w700);
    });

    test('字体注册表变了（自定义字体加载完）：同字体整套重画', () async {
      final LumiereGlyphs g = glyphs0();
      addTearDown(g.dispose);
      final LumiereGlyphAtlases old = g.current;
      g.reload();
      await g.settled;
      expect(identical(g.current, old), isFalse);
      expect(g.current.style, old.style);
    });

    test('释放后后台任务不再换图集', () async {
      final LumiereGlyphs g = glyphs0();
      g.requestStyle(const LumiereGlyphStyle(fontFamily: 'B'));
      g.dispose();
      await g.settled;
      expect(g.current.style.fontFamily, 'A');
    });
  });

  group('绘光接字体', () {
    testWidgets('换字体不重建场景、只在后台换图集；字体注册表变了就重画图集', (WidgetTester tester) async {
      final FakeVisualizerClock clock = FakeVisualizerClock();
      final LyricVisualizerContext c = visualizerContextFor(
        lumiereVisualizerEntry,
        clock: clock,
      );
      Widget app(String family) => MaterialApp(
        home: DefaultTextStyle(
          style: TextStyle(fontFamily: family),
          child: SizedBox.expand(child: lumiereVisualizerEntry.builder(c)),
        ),
      );
      await tester.pumpWidget(app('A'));
      await tester.pump(const Duration(milliseconds: 16));
      final LumiereVisualizerState state = tester.state(
        find.byType(LumiereVisualizer),
      );
      final LumiereScene scene = state.debugScene!;
      expect(scene.atlas.style.fontFamily, 'A');

      await tester.pumpWidget(app('B'));
      expect(identical(state.debugScene, scene), isTrue, reason: '场景不重建');
      expect(scene.glyphs.debugPendingStyle?.fontFamily, 'B');

      await tester.pumpWidget(app('A'));
      expect(scene.glyphs.debugPendingStyle, isNull);
      await PaintingBinding.instance.handleSystemMessage(<String, Object?>{
        'type': 'fontsChange',
      });
      expect(scene.glyphs.debugPendingStyle?.fontFamily, 'A');

      await tester.pumpWidget(const SizedBox.shrink());
      // 卸载后后台任务看到场景已释放就退出（让零延时的片间定时器走完）。
      for (int i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(tester.takeException(), isNull);
    });
  });
}
