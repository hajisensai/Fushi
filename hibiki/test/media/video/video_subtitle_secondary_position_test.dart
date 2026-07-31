import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki/src/media/video/video_subtitle_style.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

import '../../pages/video_hibiki_page_source_corpus.dart';

/// 主字幕与副字幕的垂直位置**各自独立**（用户诉求：「主字幕和副字幕能支持分开高度调节」）。
///
/// 根因：此前两层共用 [VideoSubtitleStyle.bottomPadding] 一个字段——主字幕拿它当底距、
/// 强制置顶的副字幕拿它当**顶距**（`_paddingFor` 的顶部分支 `scaledMarginV ?? bottomPadding`），
/// 所以拖「垂直位置」滑杆必然把两层一起挪走。修复：新增
/// [VideoSubtitleStyle.secondaryBottomPadding]（null = 跟随主字幕，旧数据零迁移），
/// overlay 按层取基线（`_layerBaseline`）。
///
/// 分三层验证：
///  ① overlay 真几何——两层同屏时各自吃各自的基线，改主字幕基线不动副字幕。
///  ② 未设置副字幕基线（null）时逐字沿用主字幕基线（历史外观不回归）。
///  ③ 持久化——新字段 round-trip，旧 JSON（无该字段）解码成 null。
AudioCue _cue(String text, int startMs, int endMs) => AudioCue()
  ..bookKey = 'b'
  ..chapterHref = 'ch'
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = text
  ..startMs = startMs
  ..endMs = endMs
  ..audioFileIndex = 0;

Future<void> _pumpOverlay(
  WidgetTester tester,
  VideoPlayerController c, {
  required double bottomPadding,
  double? secondaryBottomPadding,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: VideoSubtitleOverlay(
        controller: c,
        bottomPadding: bottomPadding,
        secondaryBottomPadding: secondaryBottomPadding,
      ),
    ),
  ));
  await tester.pump();
}

/// 该层字幕盒的**外层** padding：主字幕层看 bottom、副字幕层（强制置顶）看 top。
/// controlsVisible 为 null（本测试不挂控制条）时 `_anchoredPadded` 走静态 [Padding]，
/// 故从字幕文本向上找祖先 [Padding]，取该方向上最大的一个（内层字符盒 padding 恒 0/小）。
double _outerPadding(
  WidgetTester tester,
  String text, {
  required bool top,
}) {
  final Iterable<Padding> pads = tester.widgetList<Padding>(
    find.ancestor(of: find.text(text).first, matching: find.byType(Padding)),
  );
  return pads.map((Padding p) {
    final EdgeInsets e = p.padding.resolve(TextDirection.ltr);
    return top ? e.top : e.bottom;
  }).fold<double>(0, (double a, double b) => b > a ? b : a);
}

void main() {
  group('① 主/副字幕位置各自独立（overlay 真几何）', () {
    testWidgets('两层同屏：主字幕吃 bottomPadding，副字幕吃 secondaryBottomPadding',
        (WidgetTester tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('主', 0, 6000)]);
      c.setSecondaryCues(<AudioCue>[_cue('副', 0, 6000)]);
      c.debugUpdateCueForPosition(1000);

      await _pumpOverlay(tester, c,
          bottomPadding: 20, secondaryBottomPadding: 160);

      expect(_outerPadding(tester, '主', top: false), 20,
          reason: '主字幕底距 = 主字幕基线');
      expect(_outerPadding(tester, '副', top: true), 160,
          reason: '副字幕顶距 = 副字幕自己的基线，不再复用主字幕的 20');
    });

    testWidgets('改主字幕基线不牵动副字幕（本诉求的直接守卫）', (WidgetTester tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('主', 0, 6000)]);
      c.setSecondaryCues(<AudioCue>[_cue('副', 0, 6000)]);
      c.debugUpdateCueForPosition(1000);

      await _pumpOverlay(tester, c,
          bottomPadding: 20, secondaryBottomPadding: 160);
      expect(_outerPadding(tester, '副', top: true), 160);

      // 只把主字幕位置拖高：副字幕顶距必须一动不动（回归即两层重新耦合）。
      await _pumpOverlay(tester, c,
          bottomPadding: 200, secondaryBottomPadding: 160);
      expect(_outerPadding(tester, '主', top: false), 200,
          reason: '主字幕跟随自己的新基线');
      expect(_outerPadding(tester, '副', top: true), 160,
          reason: '副字幕不被主字幕位置牵动');
    });

    testWidgets('改副字幕基线不牵动主字幕（反向守卫）', (WidgetTester tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('主', 0, 6000)]);
      c.setSecondaryCues(<AudioCue>[_cue('副', 0, 6000)]);
      c.debugUpdateCueForPosition(1000);

      await _pumpOverlay(tester, c,
          bottomPadding: 30, secondaryBottomPadding: 40);
      await _pumpOverlay(tester, c,
          bottomPadding: 30, secondaryBottomPadding: 220);

      expect(_outerPadding(tester, '主', top: false), 30,
          reason: '主字幕底距不被副字幕位置牵动');
      expect(_outerPadding(tester, '副', top: true), 220);
    });
  });

  group('② null = 跟随主字幕（历史外观不回归）', () {
    testWidgets('secondaryBottomPadding 未设置时副字幕顶距 = 主字幕基线',
        (WidgetTester tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('主', 0, 6000)]);
      c.setSecondaryCues(<AudioCue>[_cue('副', 0, 6000)]);
      c.debugUpdateCueForPosition(1000);

      await _pumpOverlay(tester, c, bottomPadding: 90);

      expect(_outerPadding(tester, '主', top: false), 90);
      expect(_outerPadding(tester, '副', top: true), 90,
          reason: '老用户（没单独调过副字幕）外观与历史像素级一致');
    });
  });

  group('③ 持久化', () {
    test('新字段 round-trip', () {
      const VideoSubtitleStyle s = VideoSubtitleStyle(
        fontSize: 36,
        textColor: Color(0xFFFFFFFF),
        fontWeight: null,
        shadowColor: Color(0xE6000000),
        shadowThickness: null,
        backgroundColor: null,
        backgroundOpacity: 0,
        bottomPadding: 75,
        secondaryBottomPadding: 130,
      );
      final VideoSubtitleStyle back =
          VideoSubtitleStyle.decode(VideoSubtitleStyle.encode(s));
      expect(back.secondaryBottomPadding, 130);
      expect(back.bottomPadding, 75);
    });

    test('旧 JSON（无该字段）解码成 null = 继续跟随主字幕', () {
      final VideoSubtitleStyle old = VideoSubtitleStyle.decode(
        '{"_v":2,"fontSize":36,"backgroundOpacity":0,"bottomPadding":110}',
      );
      expect(old.bottomPadding, 110);
      expect(old.secondaryBottomPadding, isNull,
          reason: '缺字段必须回落到「跟随主字幕」，不能凭空钉一个默认值');
    });

    test('越界值被夹进 [0,400]', () {
      final VideoSubtitleStyle s = VideoSubtitleStyle.decode(
        '{"_v":2,"bottomPadding":75,"secondaryBottomPadding":9999}',
      );
      expect(s.secondaryBottomPadding, 400);
    });

    test('copyWith 只改副字幕基线时不动主字幕', () {
      final VideoSubtitleStyle s =
          VideoSubtitleStyle.defaults.copyWith(secondaryBottomPadding: 150);
      expect(s.secondaryBottomPadding, 150);
      expect(s.bottomPadding, VideoSubtitleStyle.defaults.bottomPadding);
    });
  });

  // ①②③ 只证明「overlay 拿到 secondaryBottomPadding 后几何正确」。设置页滑杆 →
  // VideoSubtitleStyle → 视频页 → overlay 这条**接线**若断掉（删掉滑杆、或
  // layout.part.dart 不再往 overlay 传该参数），上面 8 项照样全绿、用户拖滑杆却
  // 毫无反应——这正是 settings_schema_coverage_test 的 kCoveredElsewhere 登记
  // 'video/Secondary subtitle position' 所声称要覆盖的那半。视频页要真播放器 +
  // media_kit，widget harness 起不来，故这半用源码守卫咬住（与主字幕位置的
  // video_subtitle_push_up_guard_test.dart 同范式）。
  group('④ 设置滑杆 → style → 视频页 → overlay 接线（源码守卫）', () {
    late String schemaSrc;
    late String pageSrc;
    setUpAll(() {
      final File schema = File('lib/src/settings/settings_schema_video.dart');
      expect(schema.existsSync(), isTrue, reason: '视频设置 schema 源文件应存在');
      schemaSrc = schema.readAsStringSync().replaceAll('\r\n', '\n');
      pageSrc = readVideoHibikiSource();
    });

    test('设置页有独立的副字幕位置滑杆，且写的是 secondaryBottomPadding', () {
      expect(schemaSrc, contains("id: 'video.subtitle.position_secondary'"),
          reason: '副字幕垂直位置必须有自己的滑杆，否则用户没有解耦入口');
      expect(schemaSrc, contains('t.video_setting_subtitle_position_secondary'),
          reason: '滑杆标题必须走 i18n key，不能裸字符串');
      // 拖动预览 + 松手落盘两处都必须改副字幕字段；只改一处 = 拖着有效松手回弹
      // 或拖着不动松手才跳。
      expect(
        'copyWith(secondaryBottomPadding: v)'.allMatches(schemaSrc).length,
        greaterThanOrEqualTo(2),
        reason: 'onChanged 预览与 onChangeEnd 落盘都必须写 secondaryBottomPadding',
      );
      // 未单独调过时滑杆显示主字幕当前值（「跟随」语义），不能显示成 0。
      expect(schemaSrc, contains('s.secondaryBottomPadding ?? s.bottomPadding'),
          reason: '未解耦时滑杆初值必须回落到主字幕基线');
    });

    test('主字幕滑杆只写 bottomPadding，不再连带改副字幕', () {
      expect(schemaSrc, contains("id: 'video.subtitle.position'"),
          reason: '主字幕位置滑杆必须保留');
      expect(schemaSrc, isNot(contains('copyWith(bottomPadding: v, ')),
          reason: '主字幕滑杆一次只准改 bottomPadding，联动改副字幕就是本 bug 的回归');
    });

    test('视频页把 style 的副字幕基线真传给 overlay', () {
      expect(pageSrc, contains('secondaryBottomPadding:'),
          reason: 'overlay 必须接上副字幕基线参数，否则滑杆写穿 DB 也不生效');
      expect(pageSrc, contains('_subtitleStyle.secondaryBottomPadding'),
          reason: '传给 overlay 的必须是 style 里的真值，不能钉常量或恒 null');
      expect(pageSrc, contains('bottomPadding: _subtitleStyle.bottomPadding'),
          reason: '主字幕基线接线同时保持不变（相邻功能不被带坏）');
    });
  });
}
