import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_subtitle_obscure_mode.dart';

/// TODO-840 Part B：字幕遮蔽模式三态的 preferences 层 lazy 投影守卫。
///
/// 投影/还原的真相源是 [VideoSubtitleObscureMode] 的纯函数 [blurFlag] / [hideFlag] /
/// [fromFlags]——preferences 写入这两个布尔键、读取时还原。本测试把「向后兼容（新版本
/// 精确还原三态）+ 向前兼容（旧版本只读历史 video_subtitle_blur 键退化成 blur 不丢遮蔽
/// 意图）」钉成不变式，并覆盖三态循环键的顺序。
void main() {
  group('blurFlag / hideFlag projection（写入两键）', () {
    test('none 两键全 false', () {
      expect(VideoSubtitleObscureMode.none.blurFlag, isFalse);
      expect(VideoSubtitleObscureMode.none.hideFlag, isFalse);
    });

    test('blur：历史键 true、判别键 false', () {
      expect(VideoSubtitleObscureMode.blur.blurFlag, isTrue);
      expect(VideoSubtitleObscureMode.blur.hideFlag, isFalse);
    });

    test('hide：历史键 true（向前兼容退化成 blur）、判别键 true', () {
      // 关键：hide 也回写历史键 true，旧版本只读 video_subtitle_blur 时读到「开着」→
      // 退化成模糊而非「关闭」，不丢用户的遮蔽意图。
      expect(VideoSubtitleObscureMode.hide.blurFlag, isTrue);
      expect(VideoSubtitleObscureMode.hide.hideFlag, isTrue);
    });
  });

  group('fromFlags 还原（读取两键）', () {
    test('历史键 false → none（判别键无论何值都不误判成 hide）', () {
      expect(
        VideoSubtitleObscureMode.fromFlags(blurFlag: false, hideFlag: false),
        VideoSubtitleObscureMode.none,
      );
      expect(
        VideoSubtitleObscureMode.fromFlags(blurFlag: false, hideFlag: true),
        VideoSubtitleObscureMode.none,
      );
    });

    test('历史键 true + 判别键 false → blur', () {
      expect(
        VideoSubtitleObscureMode.fromFlags(blurFlag: true, hideFlag: false),
        VideoSubtitleObscureMode.blur,
      );
    });

    test('历史键 true + 判别键 true → hide', () {
      expect(
        VideoSubtitleObscureMode.fromFlags(blurFlag: true, hideFlag: true),
        VideoSubtitleObscureMode.hide,
      );
    });
  });

  group('round-trip（投影后还原回同一三态）', () {
    test('三态写入两键再还原都得回自身', () {
      for (final VideoSubtitleObscureMode mode
          in VideoSubtitleObscureMode.values) {
        final VideoSubtitleObscureMode restored =
            VideoSubtitleObscureMode.fromFlags(
          blurFlag: mode.blurFlag,
          hideFlag: mode.hideFlag,
        );
        expect(restored, mode, reason: '$mode 投影/还原不自洽');
      }
    });
  });

  group('向前兼容：旧版本只读历史 bool 键', () {
    test('blur 与 hide 在旧版本下都读成「遮蔽开启」（blurFlag true）', () {
      // 旧版本只看 video_subtitle_blur（=blurFlag），判别键它不认识。blur/hide 都让
      // blurFlag 为 true，旧版本据此显示「字幕模糊开启」——退化成 blur，遮蔽意图保留。
      expect(VideoSubtitleObscureMode.blur.blurFlag, isTrue);
      expect(VideoSubtitleObscureMode.hide.blurFlag, isTrue);
      expect(VideoSubtitleObscureMode.none.blurFlag, isFalse);
    });
  });

  group('三态循环（快捷键 cycle）', () {
    test('none → blur → hide → none', () {
      expect(VideoSubtitleObscureMode.none.next, VideoSubtitleObscureMode.blur);
      expect(VideoSubtitleObscureMode.blur.next, VideoSubtitleObscureMode.hide);
      expect(VideoSubtitleObscureMode.hide.next, VideoSubtitleObscureMode.none);
    });
  });
}
