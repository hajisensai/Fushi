import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

import 'widget_test_helpers.dart';

AudioCue _cue(String t, int s, int e) => AudioCue()
  ..bookKey = 'video/1'
  ..chapterHref = 'video://default'
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = t
  ..startMs = s
  ..endMs = e
  ..audioFileIndex = 0;

/// BUG-838：视频字幕「点字查词」不能被下方进度条的 seek 抢走。
///
/// media_kit `MaterialSeekBar` 的 seek 走**裸 [Listener.onPointerDown]/[Listener.onPointerUp]**
/// （`onPointerUp` 直接 `player.seek(...)`），Listener **不参与手势竞技场** —— 字幕的
/// [_SubtitleCharTapRecognizer] 赢竞技场也拦不住它，只要指针在命中路径上就会 seek。
/// 生产表现：控制条可见时字幕被抬到进度条上缘，进度条的透明触摸热区向上覆盖到字幕底行，
/// 用户点字查词却命中热区 → 跳走。
///
/// 现有 `video_subtitle_overlay_fallthrough_test.dart` 把下层建模成 **opaque
/// [GestureDetector]（竞技场识别器）**，glyph tap 时字幕赢竞技场、下层不触发，测试是绿的 ——
/// 但那模型和生产不符（生产是不进竞技场的 Listener），所以放过了本 bug。本测试把下层建模成
/// 与 media_kit 一致的**裸 [Listener]**，锁死正确行为：
/// - 点字符 glyph → 查词触发，且指针**不**下探到 Listener（seek 被截断，计数 0）。
/// - 点字缝 / 空白 → 不查词，指针**穿透**到 Listener（进度条 seek 照常，计数 1）。
void main() {
  Future<void> pumpOverlayOverSeekListener(
    WidgetTester tester, {
    required VideoPlayerController controller,
    required void Function(String sentence, int graphemeIndex, Rect rect)
        onCharTap,
    required VoidCallback onSeekPointerUp,
  }) async {
    await tester.pumpWidget(buildTestApp(Stack(
      children: <Widget>[
        // 下层：铺满的裸 [Listener]（模拟 media_kit `MaterialSeekBar` 的 seek 命中层）。
        // 关键：用 Listener（不进手势竞技场）而非 GestureDetector —— onPointerUp 无条件
        // 触发，只要指针在命中路径上就 seek。
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerUp: (_) => onSeekPointerUp(),
            child: const SizedBox.expand(),
          ),
        ),
        // 上层：字幕 overlay（Positioned.fill，几何与视频页一致）。
        Positioned.fill(
          child: VideoSubtitleOverlay(
            controller: controller,
            // 与 fallthrough 测试同款小字号：命中容差落在下限 10px，空白点稳落空白区。
            fontSize: 20,
            onCharTap: onCharTap,
          ),
        ),
      ],
    )));
  }

  testWidgets('点字符 → 查词触发且指针不下探到进度条 Listener（seek 被截断）', (tester) async {
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues([_cue('l', 0, 1000)]);

    String? tappedSentence;
    int seekPointerUps = 0;
    await pumpOverlayOverSeekListener(
      tester,
      controller: c,
      onCharTap: (String s, int i, Rect r) => tappedSentence = s,
      onSeekPointerUp: () => seekPointerUps++,
    );

    c.debugUpdateCueForPosition(500);
    await tester.pump();

    // 点字符 'l' 中心 → 命中字符矩形 → 字幕层吸收命中 → 查词，指针到不了下层 Listener。
    await tester.tapAt(tester.getCenter(find.text('l').first));
    await tester.pump();

    expect(tappedSentence, 'l', reason: '命中字符必须触发查词');
    expect(seekPointerUps, 0,
        reason: '命中字符时字幕层吸收命中，指针不下探到进度条 Listener —— seek 不得发生');
  });

  testWidgets('点字幕盒内空白 → 不查词且指针穿透到进度条 Listener（seek 照常）', (tester) async {
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues([_cue('l', 0, 1000)]);

    String? tappedSentence;
    int seekPointerUps = 0;
    await pumpOverlayOverSeekListener(
      tester,
      controller: c,
      onCharTap: (String s, int i, Rect r) => tappedSentence = s,
      onSeekPointerUp: () => seekPointerUps++,
    );

    c.debugUpdateCueForPosition(500);
    await tester.pump();

    // 与 fallthrough 测试同款：字符矩形左上角向盒角偏 (11,5) → 落盒内 padding 空白
    // （距字符矩形 dist² = 146 > 命中容差²（下限 10² = 100）→ 判为空白）。
    final Offset charTopLeft = tester.getTopLeft(find.text('l').first);
    final Offset blank = charTopLeft - const Offset(11, 5);
    await tester.tapAt(blank);
    await tester.pump();

    expect(tappedSentence, isNull, reason: '字符间空白不应查词');
    expect(seekPointerUps, 1,
        reason: '字幕盒空白 tap 必须穿透到进度条 Listener —— 进度条 seek 不被吞');
  });
}
