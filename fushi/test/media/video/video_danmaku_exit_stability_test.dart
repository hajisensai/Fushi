import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_danmaku_layout.dart';
import 'package:fushi/src/media/video/video_danmaku_model.dart';
import 'package:fushi/src/media/video/video_danmaku_text_metrics.dart';

VideoDanmakuItem _item(int startMs, String text) => VideoDanmakuItem(
      startMs: startMs,
      text: text,
      mode: VideoDanmakuMode.scroll,
      colorArgb: 0xFFFFFFFF,
    );

/// 一条弹幕在某一帧的落位（用于跨帧比对）。
class _Placement {
  const _Placement(this.lane, this.dy);

  final int lane;
  final double dy;
}

void main() {
  // layout 用 TextPainter 实测文本宽高，需要测试 binding 提供字体集合。
  TestWidgetsFlutterBinding.ensureInitialized();

  const Size viewport = Size(400, 200);
  const int scrollMs = 8000;

  group('弹幕退场不牵动其余弹幕（BUG-1607）', () {
    test('a comment leaving the screen never moves the survivors', () {
      // 8 条弹幕每 500ms 一条：它们的生命周期彼此交错，前面的陆续过期而后面的还在
      // 飞。旧实现每帧拿「当前活动集」重跑贪心分配，第一条一过期，后面每条的行号
      // 就整体前移一格 —— 整屏弹幕跟着换行。
      final List<VideoDanmakuItem> items = <VideoDanmakuItem>[
        for (int i = 0; i < 8; i++) _item(i * 500, 'コメント$i'),
      ];
      final VideoDanmakuLayout layout = VideoDanmakuLayout();
      final Map<String, _Placement> firstSeen = <String, _Placement>{};
      final Set<String> retired = <String>{};
      bool sawRetirementWithSurvivors = false;

      for (int positionMs = 0; positionMs <= 12000; positionMs += 100) {
        final VideoDanmakuLayoutSnapshot snapshot = layout.layout(
          items: items,
          positionMs: positionMs,
          viewportSize: viewport,
          maxActive: 20,
          maxLanes: 4,
        );
        final Set<String> onScreen = <String>{};
        for (final VideoDanmakuLayoutEntry entry in snapshot.entries) {
          final String text = entry.item.text;
          onScreen.add(text);
          expect(
            retired.contains(text),
            isFalse,
            reason: '$text 已经退场，不该在 positionMs=$positionMs 又冒出来',
          );
          final _Placement? seen = firstSeen[text];
          if (seen == null) {
            firstSeen[text] = _Placement(entry.lane, entry.position.dy);
            continue;
          }
          // 断言基准是这条弹幕**自己出生那一帧**的落位，不是本帧其它字段推出来的值：
          // 几何退化时基准不会跟着一起偏。
          expect(
            entry.lane,
            seen.lane,
            reason: '$text 在 positionMs=$positionMs 换了行（出生时是第 ${seen.lane} 行）',
          );
          expect(
            entry.position.dy,
            seen.dy,
            reason: '$text 在 positionMs=$positionMs 纵向跳了位',
          );
        }
        for (final String text in firstSeen.keys) {
          if (!onScreen.contains(text)) retired.add(text);
        }
        if (retired.isNotEmpty && onScreen.isNotEmpty) {
          sawRetirementWithSurvivors = true;
        }
      }

      expect(firstSeen, hasLength(8), reason: '8 条弹幕都应该出场过');
      expect(
        sawRetirementWithSurvivors,
        isTrue,
        reason: '样本必须真的出现「有弹幕退场、同时还有弹幕在场」的帧，否则守卫是空转',
      );
      expect(
        firstSeen.values.map((_Placement p) => p.lane).toSet().length,
        lessThan(firstSeen.length),
        reason: '样本必须真的发生行复用，否则测不到「退场后行被重排」',
      );
    });

    test('density-capped comments never pop in mid-flight', () {
      // 密度上限在出生那一刻裁决：当时挤不下的弹幕本次播放就不再出现，而不是等前面
      // 的过期后再凭空冒到画面中间（那同样是「不该发生的位置变化」）。
      final List<VideoDanmakuItem> items = <VideoDanmakuItem>[
        for (int i = 0; i < 12; i++) _item(i * 50, 'c$i'),
      ];
      final VideoDanmakuLayout layout = VideoDanmakuLayout();
      Set<String> visibleAtBirthFrame = <String>{};
      final Set<String> everVisible = <String>{};

      for (int positionMs = 0; positionMs <= 9000; positionMs += 100) {
        final VideoDanmakuLayoutSnapshot snapshot = layout.layout(
          items: items,
          positionMs: positionMs,
          viewportSize: viewport,
          maxActive: 4,
          maxLanes: 4,
        );
        final Set<String> texts = snapshot.entries
            .map((VideoDanmakuLayoutEntry e) => e.item.text)
            .toSet();
        if (positionMs == 600) visibleAtBirthFrame = texts;
        everVisible.addAll(texts);
      }

      expect(visibleAtBirthFrame, hasLength(4), reason: 'maxActive=4 应当只放 4 条');
      expect(
        everVisible,
        equals(visibleAtBirthFrame),
        reason: '被密度上限挡下的弹幕不得在后续帧里凭空出现',
      );
    });
  });

  group('弹幕退场发生在屏幕之外（BUG-1607）', () {
    test('the last rendered frame puts text and its shadow past the edge', () {
      for (final String text in <String>['あ', '短いコメント', 'とても長い' * 8]) {
        final VideoDanmakuLayoutEntry entry = VideoDanmakuLayout()
            .layout(
              items: <VideoDanmakuItem>[_item(0, text)],
              positionMs: scrollMs,
              viewportSize: viewport,
              maxActive: 10,
              maxLanes: 4,
            )
            .entries
            .single;
        // 基准用独立测得的宽度 + 独立的阴影溢出常量，不用 entry 自己的字段。
        final double renderedWidth =
            VideoDanmakuTextMetrics.shared.widthOf(text, 1.0);
        expect(
          entry.position.dx + renderedWidth + kVideoDanmakuShadowOverflow,
          lessThanOrEqualTo(0.0),
          reason: '过期那一帧连阴影都必须已经越过视口左边界（len=${text.length}）',
        );
      }
    });
  });

  group('同一行的前后两条弹幕不叠边（BUG-1607）', () {
    test('a reused lane keeps a real geometric gap between neighbours', () {
      // 「上一条起跑 900ms 后本行就算空了」是拍脑袋常数，与实际清空时间无关：下一条
      // 会在上一条还占着大半屏时被塞进同一行。改成按真实几何判定（前一条尾巴完全
      // 进屏 + 更快的新条不追尾）后，同一行的相邻两条永远留着真实间距。
      final List<VideoDanmakuItem> items = <VideoDanmakuItem>[
        for (int i = 0; i < 8; i++) _item(i * 500, 'コメント$i'),
      ];
      final VideoDanmakuLayout layout = VideoDanmakuLayout();
      bool sawSharedLane = false;
      for (int positionMs = 0; positionMs <= 12000; positionMs += 50) {
        final VideoDanmakuLayoutSnapshot snapshot = layout.layout(
          items: items,
          positionMs: positionMs,
          viewportSize: viewport,
          maxActive: 20,
          maxLanes: 4,
        );
        final Map<int, List<VideoDanmakuLayoutEntry>> byLane =
            <int, List<VideoDanmakuLayoutEntry>>{};
        for (final VideoDanmakuLayoutEntry entry in snapshot.entries) {
          byLane.putIfAbsent(entry.lane, () => <VideoDanmakuLayoutEntry>[]).add(
                entry,
              );
        }
        for (final MapEntry<int, List<VideoDanmakuLayoutEntry>> lane
            in byLane.entries) {
          final List<VideoDanmakuLayoutEntry> row = lane.value
            ..sort((VideoDanmakuLayoutEntry a, VideoDanmakuLayoutEntry b) =>
                a.position.dx.compareTo(b.position.dx));
          if (row.length > 1) sawSharedLane = true;
          for (int i = 1; i < row.length; i++) {
            // 阴影框：文本框左右各多出 kVideoDanmakuShadowOverflow。
            final double leftBoxRight = row[i - 1].position.dx +
                row[i - 1].width +
                kVideoDanmakuShadowOverflow;
            final double rightBoxLeft =
                row[i].position.dx - kVideoDanmakuShadowOverflow;
            expect(
              leftBoxRight,
              lessThanOrEqualTo(rightBoxLeft),
              reason: '第 ${lane.key} 行在 positionMs=$positionMs 出现叠边',
            );
          }
        }
      }
      expect(
        sawSharedLane,
        isTrue,
        reason: '样本必须真的出现「同一行同时挂着两条弹幕」的帧，否则这条守卫是空转',
      );
    });
  });
}
