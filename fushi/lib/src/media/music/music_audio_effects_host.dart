import 'package:flutter/foundation.dart';
import 'package:fushi/src/media/music/music_audio_effects.dart';

/// 音效编辑界面（设置里的音效页 / 播放页浮层面板）对宿主要的全部能力。
///
/// 界面只依赖这个窄接口、不 import `AppModel`：音效页被设置 schema / 播放页 / 控制通道
/// 引用，若它再 import `AppModel`，就会把自己拖进 `lib/` 的最大 import 环
/// （`import_cycle_guard_test`）。生产实现是 `AppModel`。
abstract interface class MusicAudioEffectsHost {
  /// 音效偏好被改（任何入口：本界面、控制通道、另一个界面）时通知。
  Listenable get musicAudioEffectsChanges;

  /// 当前音效设置（偏好 → 值对象）。
  MusicAudioEffects get musicAudioEffects;

  /// 当前显示的均衡预设。
  MusicEqPreset get musicEqPreset;

  /// 写音效设置并重新下发到引擎；[preset] 给了就一并记下。
  Future<void> setMusicAudioEffects(
    MusicAudioEffects next, {
    MusicEqPreset? preset,
  });

  /// 当前输出后端能否挂音效滤镜链（不能时界面显示「后端不支持」）。
  bool get musicAudioEffectsSupported;
}
