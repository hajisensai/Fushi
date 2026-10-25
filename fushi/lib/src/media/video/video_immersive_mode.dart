import 'package:fushi/src/media/video/video_subtitle_obscure_mode.dart';

enum VideoImmersiveMode {
  full('full'),
  // 「快捷键 + 查词」：沉浸锁定态放行键盘 / 手柄快捷键 + 逐字查词，屏蔽触摸误触。
  // storageValue 保留旧字符串 'seek_and_lookup'（历史标识符曾为 seekAndLookup / 「跳转+查词」），
  // 不改存储值以免破坏存量偏好（Never break userspace）。
  shortcutAndLookup('seek_and_lookup'),
  lookupOnly('lookup_only'),
  unlockOnly('unlock_only');

  const VideoImmersiveMode(this.storageValue);

  final String storageValue;

  static const VideoImmersiveMode fallback = shortcutAndLookup;

  static VideoImmersiveMode fromStorage(String value) {
    for (final VideoImmersiveMode mode in VideoImmersiveMode.values) {
      if (mode.storageValue == value) return mode;
    }
    return fallback;
  }
}

/// 沉浸锁定态下「点画面任意处 = 显示 / 遮回当前主字幕」是否生效（设计案
/// `docs/specs/2026-10-25-video-immersive-one-hand.md` §3.1）。
///
/// 全部成立才生效：沉浸锁定 ∧ 设置「沉浸时点画面显示字幕」开 ∧ 主字幕开着遮蔽
/// （模糊 / 隐藏）∧ 主字幕「遮蔽态允许临时显形」开。最后一条沿用 BUG-2256「显形的全部
/// 来源一起门控」：用户关掉临时显形就是不想被任何方式唤出来。与 [VideoImmersiveMode]
/// 档位无关——显形只是「看一眼」，不触发任何播放动作。
bool videoImmersiveTapRevealsSubtitle({
  required bool immersiveLocked,
  required bool tapRevealEnabled,
  required VideoSubtitleObscureMode obscureMode,
  required bool revealOnInteraction,
}) =>
    immersiveLocked &&
    tapRevealEnabled &&
    obscureMode != VideoSubtitleObscureMode.none &&
    revealOnInteraction;
