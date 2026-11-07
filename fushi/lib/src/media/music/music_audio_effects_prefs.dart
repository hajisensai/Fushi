import 'package:flutter/foundation.dart';
import 'package:fushi/src/media/music/music_audio_effects.dart';
import 'package:fushi/src/models/preferences_repository.dart';

/// 偏好 ↔ [MusicAudioEffects]（总开关与增益沿用 `music_eq_enabled` / `music_eq_gains`，
/// 其余是 `music_eq_preamp_db` / `music_eq_preset` 与 `music_effects_*`，见
/// preference_keys.dart）。读时把越界值夹回范围、坏的增益串回平直。
MusicAudioEffects readMusicAudioEffectsPrefs(PreferencesRepository p) =>
    MusicAudioEffects(
      enabled: p.musicEqEnabled,
      gainsDb: MusicAudioEffects.parseGains(p.musicEqGains),
      preampDb: p.musicEqPreampDb.clamp(
        -kMusicEffectsMaxPreampDb,
        kMusicEffectsMaxPreampDb,
      ),
      bassDb: p.musicEffectsBassDb.clamp(
        -kMusicToneMaxGainDb,
        kMusicToneMaxGainDb,
      ),
      bassHz: p.musicEffectsBassHz,
      trebleDb: p.musicEffectsTrebleDb.clamp(
        -kMusicToneMaxGainDb,
        kMusicToneMaxGainDb,
      ),
      trebleHz: p.musicEffectsTrebleHz,
      balance: p.musicEffectsBalance.clamp(-1, 1),
      width: p.musicEffectsWidth.clamp(0, kMusicStereoWidthMax),
      mono: p.musicEffectsMono,
      swapChannels: p.musicEffectsSwapChannels,
      limiter: p.musicEffectsLimiter,
    );

/// 当前显示的均衡预设（存的预设 + 当前增益，见 [MusicEqPreset.resolve]）。
MusicEqPreset readMusicEqPresetPref(PreferencesRepository p) =>
    MusicEqPreset.resolve(
      p.musicEqPreset,
      MusicAudioEffects.parseGains(p.musicEqGains),
    );

/// 只写与当前偏好不同的项；[preset] 非空时一并记下。平直增益写空串（与旧版一致）。
Future<void> writeMusicAudioEffectsPrefs(
  PreferencesRepository p,
  MusicAudioEffects next, {
  MusicEqPreset? preset,
}) async {
  final MusicAudioEffects cur = readMusicAudioEffectsPrefs(p);
  if (next.enabled != cur.enabled) await p.setMusicEqEnabled(next.enabled);
  if (!listEquals(next.gainsDb, cur.gainsDb)) {
    await p.setMusicEqGains(
      next.isFlat ? '' : MusicAudioEffects.encodeGains(next.gainsDb),
    );
  }
  if (preset != null && preset.wire != p.musicEqPreset) {
    await p.setMusicEqPreset(preset.wire);
  }
  if (next.preampDb != cur.preampDb) await p.setMusicEqPreampDb(next.preampDb);
  if (next.bassDb != cur.bassDb) await p.setMusicEffectsBassDb(next.bassDb);
  if (next.bassHz != cur.bassHz) await p.setMusicEffectsBassHz(next.bassHz);
  if (next.trebleDb != cur.trebleDb) {
    await p.setMusicEffectsTrebleDb(next.trebleDb);
  }
  if (next.trebleHz != cur.trebleHz) {
    await p.setMusicEffectsTrebleHz(next.trebleHz);
  }
  if (next.balance != cur.balance) await p.setMusicEffectsBalance(next.balance);
  if (next.width != cur.width) await p.setMusicEffectsWidth(next.width);
  if (next.mono != cur.mono) await p.setMusicEffectsMono(next.mono);
  if (next.swapChannels != cur.swapChannels) {
    await p.setMusicEffectsSwapChannels(next.swapChannels);
  }
  if (next.limiter != cur.limiter) await p.setMusicEffectsLimiter(next.limiter);
}
