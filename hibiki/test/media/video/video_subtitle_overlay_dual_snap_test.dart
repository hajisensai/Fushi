import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// TODO-1372 守卫：「两个字幕同时存在，就会时不时地自动跳一下」——组内堆叠槽位必须跨帧
/// 稳定，**已在屏的 cue 不因活动集增减而移动**。
///
/// 根因（修复前）：`_positionCueGroup` 把组内活动 cue 按活动集顺序直接塞进 Column，
/// 贴锚那一格的归属随集合增减翻转——底部组：新进 cue 抢走贴底格、把在屏 cue 顶上去；
/// 顶部组（副字幕置顶）：前一条离场、后一条补位上跳。另有同源缺陷：分组键把「anchor
/// 缺省」与「显式底部居中」、「MarginV<=0」与「无 MarginV」分家，渲染完全相同的 cue
/// 被拆成两组**叠印**在同一位置（互相压字）而非堆叠。
///
/// 修复（libass「Collisions: Normal」语义的槽位版）：跨帧槽位表——已在屏 cue 在可见期
/// 内槽位不变；新 cue 补最靠锚点的空槽、没有才排远端；离场 cue 若仍撑着远端在屏 cue
/// 则留隐形占位；组内全空才重置。分组键做语义归一，渲染相同的 cue 必然同组堆叠。
AudioCue _cue(
  String text,
  int startMs,
  int endMs, {
  SubtitleMarkup? markup,
}) =>
    AudioCue()
      ..bookKey = 'b'
      ..chapterHref = 'ch'
      ..sentenceIndex = 0
      ..textFragmentId = ''
      ..text = text
      ..markup = markup
      ..startMs = startMs
      ..endMs = endMs
      ..audioFileIndex = 0;

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pump();
}

/// 第一个匹配 [label] 的 Text 的 topLeft.dy（stroke/fill 双层同位，取 first 即可）。
double _dy(WidgetTester tester, String label) =>
    tester.getTopLeft(find.text(label).first).dy;

void main() {
  group('TODO-1372 底部组（主字幕）：活动集增减不移动在屏 cue', () {
    testWidgets('重叠 cue 进入：在屏 cue 不动，新 cue 排上方（远离锚点）',
        (WidgetTester tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('甲', 0, 6000), _cue('乙', 3000, 10000)]);

      // 甲 单独在屏：贴底基线。
      c.debugUpdateCueForPosition(1000);
      await _pump(tester, VideoSubtitleOverlay(controller: c));
      final double jia1 = _dy(tester, '甲');

      // 乙 进入重叠窗口：甲 必须原地不动（修复前 乙 抢走贴底格、甲 被顶上去=snap）。
      c.debugUpdateCueForPosition(4000);
      await tester.pump();
      final double jia2 = _dy(tester, '甲');
      final double yi2 = _dy(tester, '乙');
      expect((jia2 - jia1).abs(), lessThan(1.0),
          reason: '已在屏的 甲 不得因 乙 进入活动集而移动（修复前被顶上去）');
      expect(yi2, lessThan(jia2), reason: '新进 cue 应排在远离底部锚点的一侧（上方）');
    });

    testWidgets('重叠 cue 离场：剩余 cue 由隐形占位撑住槽位，不坠回贴底格',
        (WidgetTester tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('甲', 0, 6000), _cue('乙', 3000, 10000)]);

      c.debugUpdateCueForPosition(4000);
      await _pump(tester, VideoSubtitleOverlay(controller: c));
      final double yi1 = _dy(tester, '乙');

      // 甲 离场：乙 保持自己的槽位（libass「在屏期间位置不变」语义）。
      c.debugUpdateCueForPosition(7000);
      await tester.pump();
      final double yi2 = _dy(tester, '乙');
      expect((yi2 - yi1).abs(), lessThan(1.0), reason: '甲 离场后 乙 不得移动（占位保持槽位）');
    });

    testWidgets('槽位复用链：新 cue 补离场空槽，撑着的在屏 cue 全程不动；组空后重置回基线',
        (WidgetTester tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[
        _cue('甲', 0, 4000),
        _cue('乙', 3000, 10000),
        _cue('丙', 5000, 9000),
        _cue('丁', 12000, 15000),
      ]);

      // 甲+乙 重叠：甲 贴底、乙 在上。
      c.debugUpdateCueForPosition(3500);
      await _pump(tester, VideoSubtitleOverlay(controller: c));
      final double jiaBase = _dy(tester, '甲');
      final double yi1 = _dy(tester, '乙');

      // 甲 离场（乙 仍在）：乙 不动。
      c.debugUpdateCueForPosition(4500);
      await tester.pump();
      expect((_dy(tester, '乙') - yi1).abs(), lessThan(1.0));

      // 丙 进入：补 甲 腾出的贴底空槽；乙 仍不动（修复前 乙 被顶上去）。
      c.debugUpdateCueForPosition(6000);
      await tester.pump();
      final double bing = _dy(tester, '丙');
      expect((_dy(tester, '乙') - yi1).abs(), lessThan(1.0),
          reason: '丙 补空槽不得挤动在屏的 乙');
      expect(bing, greaterThan(_dy(tester, '乙')), reason: '丙 应落在贴底空槽（乙 下方）');
      expect((bing - jiaBase).abs(), lessThan(1.0), reason: '丙 复用 甲 的贴底槽位');

      // 丙 离场（乙 仍在）：乙 不动。
      c.debugUpdateCueForPosition(9500);
      await tester.pump();
      expect((_dy(tester, '乙') - yi1).abs(), lessThan(1.0));

      // 全部离场→gap→丁 单独出现：槽位重置，回到贴底基线（不残留占位悬空）。
      c.debugUpdateCueForPosition(11000);
      await tester.pump();
      c.debugUpdateCueForPosition(12500);
      await tester.pump();
      expect((_dy(tester, '丁') - jiaBase).abs(), lessThan(1.0),
          reason: '组清空后新 cue 应回到贴底基线，不残留占位');
    });

    testWidgets('隐形占位不可查词：离场 cue 的字符不参与命中反查', (WidgetTester tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('甲', 0, 6000), _cue('乙', 3000, 10000)]);
      final VideoSubtitleHitTester hitTester = VideoSubtitleHitTester();

      c.debugUpdateCueForPosition(4000);
      await _pump(
          tester,
          VideoSubtitleOverlay(
            controller: c,
            hitTester: hitTester,
            onCharTap: (String s, int i, Rect r) {},
          ));

      // 甲 离场成占位：其原位置命中必须为 null（不可点、不可查词）。
      c.debugUpdateCueForPosition(7000);
      await tester.pump();
      final Offset ghostCenter = tester.getCenter(find.text('甲').first);
      expect(hitTester.hitTest(ghostCenter), isNull,
          reason: '隐形占位不得登记命中（点占位区域应穿透）');
      // 在屏的 乙 照常可命中。
      final SubtitleCharHit? hit =
          hitTester.hitTest(tester.getCenter(find.text('乙').first));
      expect(hit?.sentence, '乙');
    });
  });

  group('TODO-1372 顶部组（副字幕置顶）：活动集增减不移动在屏 cue', () {
    testWidgets('前一条离场：后一条不得补位上跳', (WidgetTester tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('主', 0, 20000)]);
      c.setSecondaryCues(
          <AudioCue>[_cue('つ', 0, 6000), _cue('ぎ', 3000, 10000)]);

      // つ+ぎ 重叠：つ 贴顶、ぎ 在下。
      c.debugUpdateCueForPosition(4000);
      await _pump(tester, VideoSubtitleOverlay(controller: c));
      final double tsu = _dy(tester, 'つ');
      final double gi1 = _dy(tester, 'ぎ');
      expect(gi1, greaterThan(tsu), reason: '新进副字幕 cue 应排在远离顶部锚点的一侧（下方）');

      // つ 离场：ぎ 保持槽位，不上跳（修复前 Column 收缩、ぎ 补位贴顶=snap）。
      c.debugUpdateCueForPosition(7000);
      await tester.pump();
      expect((_dy(tester, 'ぎ') - gi1).abs(), lessThan(1.0),
          reason: 'つ 离场后 ぎ 不得上跳到贴顶格');
    });
  });

  group('TODO-1372 分组键语义归一：渲染相同的 cue 同组堆叠，不再两组叠印', () {
    testWidgets('anchor 缺省 与 显式底部居中(MarginV=0) 同组：重叠时堆叠而非叠印',
        (WidgetTester tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[
        _cue('甲', 0, 8000),
        _cue('乙', 2000, 8000,
            markup: SubtitleMarkup(
              plainText: '乙',
              spans: const <SubtitleSpan>[],
              anchor: const SubtitleAnchor(
                  SubtitleVAlign.bottom, SubtitleHAlign.center),
              cueStyle: const SubtitleCueStyle(marginV: 0),
            )),
      ]);
      c.debugUpdateCueForPosition(3000);
      await _pump(tester, VideoSubtitleOverlay(controller: c));
      // 两条渲染位置语义完全相同（缺省 ≡ 底部居中；MarginV<=0 ≡ 无 MarginV），必须归入
      // 同一组竖排堆叠——修复前分成两组、同一位置互相压字（dy 相同）。
      expect((_dy(tester, '甲') - _dy(tester, '乙')).abs(), greaterThan(20),
          reason: '渲染相同的重叠 cue 应堆叠分离，而非两组叠印在同一位置');
    });
  });
}
