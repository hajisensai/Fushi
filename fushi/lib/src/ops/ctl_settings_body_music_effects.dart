import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/music_audio_effects.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/pages/implementations/music/music_audio_effects_page.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_destination_id.dart';

/// 音效页（「音乐 › 音效」，正文是自绘的曲线 / 竖推子，走 body 逃生口）在控制通道上的
/// 条目。读写与页面同一处：[AppModel.musicAudioEffects] / [AppModel.setMusicAudioEffects]
/// （写完即重新下发 mpv `af`）。
///
/// - `music.effects.enabled` 总开关；`music.effects.preset` 选预设（写入即套用增益表，
///   `custom` 只记选择不动增益）；
/// - `music.effects.preamp` / `music.effects.band_<Hz>` 前级与各段（dB，0.5 档；改段即
///   落到自定义）；`music.effects.bass` / `treble`（dB）与 `bass_hz` / `treble_hz`；
/// - `music.effects.balance`（−1…1）/ `width`（0…2）/ `mono` / `swap` / `limiter`；
/// - `music.effects.reset` 全部复位（总开关不动）。
List<CtlBodyPage> buildCtlMusicEffectsBodyPages() => <CtlBodyPage>[
  CtlBodyPage(
    breadcrumb: '${t.nav_music} › ${t.music_effects_title}',
    visible: (SettingsContext c) => isSettingsDestinationVisible(
      SettingsDestinationId.music,
      c.appModel.moduleVisibility,
    ),
    items: <SettingsItem>[
      SettingsSwitchItem(
        id: 'music.effects.enabled',
        title: t.music_effects_enabled_title,
        defaultValue: false,
        value: (SettingsContext c) => c.appModel.musicAudioEffects.enabled,
        onChanged: (SettingsContext c, bool v) =>
            _set(c, (MusicAudioEffects fx) => fx.copyWith(enabled: v)),
      ),
      SettingsSegmentedItem<MusicEqPreset>(
        id: 'music.effects.preset',
        title: t.music_eq_preset_title,
        dropdown: true,
        defaultValue: MusicEqPreset.flat,
        options: <SettingsSegmentOption<MusicEqPreset>>[
          for (final MusicEqPreset p in MusicEqPreset.values)
            SettingsSegmentOption<MusicEqPreset>(
              value: p,
              label: musicEqPresetLabel(p),
            ),
        ],
        selected: (SettingsContext c) => c.appModel.musicEqPreset,
        onChanged: (SettingsContext c, MusicEqPreset p) {
          final List<double>? gains = p.gainsDb;
          return _set(
            c,
            (MusicAudioEffects fx) => gains == null
                ? fx
                : fx.copyWith(gainsDb: List<double>.of(gains)),
            preset: p,
          );
        },
      ),
      _db(
        id: 'music.effects.preamp',
        title: t.music_eq_preamp_title,
        limit: kMusicEffectsMaxPreampDb,
        read: (MusicAudioEffects fx) => fx.preampDb,
        write: (MusicAudioEffects fx, double v) => fx.copyWith(preampDb: v),
      ),
      for (int i = 0; i < kMusicEqualizerBandsHz.length; i++)
        _db(
          id: 'music.effects.band_${kMusicEqualizerBandsHz[i]}',
          title: musicHzLabel(kMusicEqualizerBandsHz[i]),
          limit: kMusicEqualizerMaxGainDb,
          read: (MusicAudioEffects fx) => fx.gainsDb[i],
          write: (MusicAudioEffects fx, double v) =>
              fx.copyWith(gainsDb: List<double>.of(fx.gainsDb)..[i] = v),
          preset: MusicEqPreset.custom,
        ),
      _db(
        id: 'music.effects.bass',
        title: t.music_effects_bass_title,
        limit: kMusicToneMaxGainDb,
        read: (MusicAudioEffects fx) => fx.bassDb,
        write: (MusicAudioEffects fx, double v) => fx.copyWith(bassDb: v),
      ),
      _hz(
        id: 'music.effects.bass_hz',
        title: t.music_effects_bass_freq_title,
        values: kMusicBassFrequenciesHz,
        defaultHz: kMusicBassDefaultHz,
        read: (MusicAudioEffects fx) => fx.bassHz,
        write: (MusicAudioEffects fx, int v) => fx.copyWith(bassHz: v),
      ),
      _db(
        id: 'music.effects.treble',
        title: t.music_effects_treble_title,
        limit: kMusicToneMaxGainDb,
        read: (MusicAudioEffects fx) => fx.trebleDb,
        write: (MusicAudioEffects fx, double v) => fx.copyWith(trebleDb: v),
      ),
      _hz(
        id: 'music.effects.treble_hz',
        title: t.music_effects_treble_freq_title,
        values: kMusicTrebleFrequenciesHz,
        defaultHz: kMusicTrebleDefaultHz,
        read: (MusicAudioEffects fx) => fx.trebleHz,
        write: (MusicAudioEffects fx, int v) => fx.copyWith(trebleHz: v),
      ),
      SettingsSliderItem(
        id: 'music.effects.balance',
        title: t.music_effects_balance_title,
        min: -1,
        max: 1,
        divisions: 40,
        defaultValue: 0,
        label: musicBalanceLabel,
        value: (SettingsContext c) => c.appModel.musicAudioEffects.balance,
        onChanged: (SettingsContext c, double v) => _set(
          c,
          (MusicAudioEffects fx) =>
              fx.copyWith(balance: (v.clamp(-1, 1) * 20).roundToDouble() / 20),
        ),
      ),
      SettingsSliderItem(
        id: 'music.effects.width',
        title: t.music_effects_width_title,
        min: 0,
        max: kMusicStereoWidthMax,
        divisions: (kMusicStereoWidthMax * 20).round(),
        defaultValue: 1,
        label: (double v) => '${(v * 100).round()}%',
        value: (SettingsContext c) => c.appModel.musicAudioEffects.width,
        onChanged: (SettingsContext c, double v) => _set(
          c,
          (MusicAudioEffects fx) => fx.copyWith(
            width: (v.clamp(0, kMusicStereoWidthMax) * 20).roundToDouble() / 20,
          ),
        ),
      ),
      _switch(
        id: 'music.effects.mono',
        title: t.music_effects_mono_title,
        read: (MusicAudioEffects fx) => fx.mono,
        write: (MusicAudioEffects fx, bool v) => fx.copyWith(mono: v),
      ),
      _switch(
        id: 'music.effects.swap',
        title: t.music_effects_swap_title,
        read: (MusicAudioEffects fx) => fx.swapChannels,
        write: (MusicAudioEffects fx, bool v) => fx.copyWith(swapChannels: v),
      ),
      _switch(
        id: 'music.effects.limiter',
        title: t.music_effects_limiter_title,
        read: (MusicAudioEffects fx) => fx.limiter,
        write: (MusicAudioEffects fx, bool v) => fx.copyWith(limiter: v),
      ),
      SettingsActionItem(
        id: 'music.effects.reset',
        title: t.music_effects_reset,
        onTap: (SettingsContext c) => _reset(c),
        cli: SettingsCliAction(
          run: (SettingsContext c, Map<String, String> _) async {
            await _reset(c);
            return null;
          },
        ),
      ),
    ],
  ),
];

Future<void> _set(
  SettingsContext c,
  MusicAudioEffects Function(MusicAudioEffects fx) edit, {
  MusicEqPreset? preset,
}) {
  final AppModel app = c.appModel;
  return app.setMusicAudioEffects(edit(app.musicAudioEffects), preset: preset);
}

Future<void> _reset(SettingsContext c) => _set(
  c,
  (MusicAudioEffects fx) => MusicAudioEffects(enabled: fx.enabled),
  preset: MusicEqPreset.flat,
);

SettingsSliderItem _db({
  required String id,
  required String title,
  required double limit,
  required double Function(MusicAudioEffects fx) read,
  required MusicAudioEffects Function(MusicAudioEffects fx, double v) write,
  MusicEqPreset? preset,
}) => SettingsSliderItem(
  id: id,
  title: title,
  min: -limit,
  max: limit,
  divisions: (limit * 4).round(),
  defaultValue: 0,
  label: musicDbLabel,
  value: (SettingsContext c) => read(c.appModel.musicAudioEffects),
  onChanged: (SettingsContext c, double v) => _set(
    c,
    (MusicAudioEffects fx) =>
        write(fx, (v.clamp(-limit, limit) * 2).roundToDouble() / 2),
    preset: preset,
  ),
);

SettingsSegmentedItem<int> _hz({
  required String id,
  required String title,
  required List<int> values,
  required int defaultHz,
  required int Function(MusicAudioEffects fx) read,
  required MusicAudioEffects Function(MusicAudioEffects fx, int v) write,
}) => SettingsSegmentedItem<int>(
  id: id,
  title: title,
  dropdown: true,
  defaultValue: defaultHz,
  options: <SettingsSegmentOption<int>>[
    for (final int hz in values)
      SettingsSegmentOption<int>(value: hz, label: musicHzLabel(hz)),
  ],
  selected: (SettingsContext c) {
    final int hz = read(c.appModel.musicAudioEffects);
    return values.contains(hz) ? hz : defaultHz;
  },
  onChanged: (SettingsContext c, int v) =>
      _set(c, (MusicAudioEffects fx) => write(fx, v)),
);

SettingsSwitchItem _switch({
  required String id,
  required String title,
  required bool Function(MusicAudioEffects fx) read,
  required MusicAudioEffects Function(MusicAudioEffects fx, bool v) write,
}) => SettingsSwitchItem(
  id: id,
  title: title,
  defaultValue: false,
  value: (SettingsContext c) => read(c.appModel.musicAudioEffects),
  onChanged: (SettingsContext c, bool v) =>
      _set(c, (MusicAudioEffects fx) => write(fx, v)),
);
