/// 音效页（设置 › 音乐 › 输出 › 音效；播放条更多菜单 / 全屏播放页胶囊也进这里）。
///
/// 窄屏单栏：总开关 → 生效提示条 → 预设 chip 组 → 均衡器卡片（频响曲线 + 10 段竖推子 +
/// 前级）→ 音色 → 声场 → 防削波限幅器 → 全部复位。宽屏（本页自身宽度 ≥
/// [kFushiSettingsHomeTwoPaneMinWidth]，与设置页两栏同一判据）双栏：左栏总开关 + 提示条 +
/// 竖排预设 + 全部复位；右栏上方大号频响曲线（可直接拖曲线上的点）+ 竖向前级，下方音色
/// （含限幅器）与声场两张卡。
///
/// 数据只有一份：偏好 → [AppModel.musicAudioEffects]；本页拖动时持有草稿（曲线跟手），
/// 停手 / 松手后经 [AppModel.setMusicAudioEffects] 写回并重新下发 mpv `af`。滤镜链与
/// bit-perfect 判据见 `music_audio_effects.dart`。MD3 / Apple 两套由 Adaptive* 行、
/// [adaptiveSlider] / [adaptiveSwitch] / [FushiChoiceChip] 分派；块级错峰入场、按压缩放。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/music_audio_effects.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_floating_panel.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_music.dart'
    show buildMusicAudioEffectsDestination;
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart'
    show kFushiSettingsHomeTwoPaneMinWidth;

/// 推入独立的音效页（与设置里的子页同一个 destination）。
Future<void> pushMusicAudioEffectsPage(BuildContext context) =>
    Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext _) =>
            const SettingsDetailPage.subPage(buildMusicAudioEffectsDestination),
      ),
    );

/// 预设显示名。
String musicEqPresetLabel(MusicEqPreset p) => switch (p) {
  MusicEqPreset.custom => t.music_eq_preset_custom,
  MusicEqPreset.flat => t.music_eq_preset_flat,
  MusicEqPreset.pop => t.music_eq_preset_pop,
  MusicEqPreset.rock => t.music_eq_preset_rock,
  MusicEqPreset.classical => t.music_eq_preset_classical,
  MusicEqPreset.jazz => t.music_eq_preset_jazz,
  MusicEqPreset.vocal => t.music_eq_preset_vocal,
  MusicEqPreset.electronic => t.music_eq_preset_electronic,
  MusicEqPreset.bassBoost => t.music_eq_preset_bass_boost,
  MusicEqPreset.trebleBoost => t.music_eq_preset_treble_boost,
  MusicEqPreset.headphones => t.music_eq_preset_headphones,
  MusicEqPreset.smallSpeakers => t.music_eq_preset_small_speakers,
};

/// 设置入口副标题：「开 · 人声 · 限幅器」/「已关闭」。
String musicAudioEffectsStatusLabel(
  MusicAudioEffects fx,
  MusicEqPreset preset,
) {
  if (!fx.enabled) return t.music_eq_off;
  return <String>[
    t.music_effects_state_on,
    musicEqPresetLabel(preset),
    if (fx.limiter) t.music_effects_limiter_short,
  ].join(' · ');
}

/// 频率名（`31 Hz` / `1 kHz` / `1.5 kHz`）：单位国际通用，不翻译。
String musicHzLabel(int hz) {
  if (hz < 1000) return '$hz Hz';
  final double k = hz / 1000;
  return k == k.roundToDouble()
      ? '${k.round()} kHz'
      : '${k.toStringAsFixed(1)} kHz';
}

/// 频段短名（推子下方：`31` / `1k`）。
String musicEqBandShortLabel(int hz) => hz >= 1000 ? '${hz ~/ 1000}k' : '$hz';

/// dB 读数（`+3.0 dB`）。
String musicDbLabel(double v, {bool unit = true}) {
  final String n = v.abs() < 0.05
      ? '0'
      : '${v > 0 ? '+' : '−'}${v.abs().toStringAsFixed(1)}';
  return unit ? '$n dB' : n;
}

/// 平衡读数：居中 / `L 30%` / `R 30%`（声道字母国际通用）。
String musicBalanceLabel(double b) {
  final int pct = (b.abs() * 100).round();
  if (pct == 0) return t.music_effects_balance_center;
  return b < 0 ? 'L $pct%' : 'R $pct%';
}

class MusicAudioEffectsBody extends StatefulWidget {
  const MusicAudioEffectsBody({required this.appModel, super.key});

  final AppModel appModel;

  @override
  State<MusicAudioEffectsBody> createState() => _MusicAudioEffectsBodyState();
}

/// 音效编辑的状态（草稿 + 停手写回）：音效页与播放页浮层面板共用一份。
mixin _EffectsEditing<W extends StatefulWidget> on State<W> {
  late MusicAudioEffects _fx;
  late MusicEqPreset _preset;

  /// 未写回的草稿（拖动中）；null = 与偏好一致。
  MusicAudioEffects? _draft;
  MusicEqPreset? _draftPreset;
  Timer? _commitTimer;

  AppModel get _app;

  @override
  void initState() {
    super.initState();
    _reload();
    _app.prefsRepo.addListener(_onPrefs);
  }

  @override
  void dispose() {
    _app.prefsRepo.removeListener(_onPrefs);
    _flush();
    super.dispose();
  }

  void _reload() {
    _fx = _app.musicAudioEffects;
    _preset = _app.musicEqPreset;
  }

  /// 偏好被别处改了（控制通道 / 另一个入口）：没在拖时跟着刷新。
  void _onPrefs() {
    if (_draft != null || !mounted) return;
    setState(_reload);
  }

  MusicAudioEffects get _view => _draft ?? _fx;
  MusicEqPreset get _viewPreset => _draftPreset ?? _preset;

  /// 改一项：立即更新显示；[immediate] 为 false 时（拖动中）停手 150 ms 再写回，避免每帧
  /// 都重建 mpv 滤镜图。
  void _edit(
    MusicAudioEffects next, {
    MusicEqPreset? preset,
    bool immediate = true,
  }) {
    setState(() {
      _draft = next;
      if (preset != null) _draftPreset = preset;
    });
    _commitTimer?.cancel();
    if (immediate) {
      _flush();
    } else {
      _commitTimer = Timer(const Duration(milliseconds: 150), _flush);
    }
  }

  void _flush() {
    _commitTimer?.cancel();
    _commitTimer = null;
    final MusicAudioEffects? d = _draft;
    if (d == null) return;
    final MusicEqPreset? p = _draftPreset;
    unawaited(
      _app.setMusicAudioEffects(d, preset: p).whenComplete(() {
        if (!mounted) return;
        setState(() {
          if (identical(_draft, d)) {
            _draft = null;
            _draftPreset = null;
          }
          _reload();
        });
      }),
    );
  }

  void _setBand(int i, double v, {bool immediate = false}) {
    final List<double> g = List<double>.of(_view.gainsDb);
    g[i] = (v * 2).roundToDouble() / 2;
    _edit(
      _view.copyWith(gainsDb: g),
      preset: MusicEqPreset.custom,
      immediate: immediate,
    );
  }

  void _pickPreset(MusicEqPreset p) {
    final List<double>? gains = p.gainsDb;
    _edit(
      gains == null ? _view : _view.copyWith(gainsDb: List<double>.of(gains)),
      preset: p,
    );
  }

  void _resetAll() {
    _edit(
      MusicAudioEffects(enabled: _view.enabled),
      preset: MusicEqPreset.flat,
    );
  }
}

class _MusicAudioEffectsBodyState extends State<MusicAudioEffectsBody>
    with _EffectsEditing<MusicAudioEffectsBody> {
  @override
  AppModel get _app => widget.appModel;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) =>
          c.maxWidth >= kFushiSettingsHomeTwoPaneMinWidth
          ? _buildWide(context)
          : _buildNarrow(context),
    );
  }

  List<Widget> _staggered(List<Widget> blocks) => <Widget>[
    for (int i = 0; i < blocks.length; i++)
      FushiStaggeredEntrance(index: i, child: blocks[i]),
  ];

  Widget _buildNarrow(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiEntranceScope(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap,
        children: _staggered(<Widget>[
          _masterSection(context),
          _presetSection(context, vertical: false),
          _equalizerSection(context, wide: false),
          _toneSection(context, includeLimiter: false),
          _stageSection(context),
          _limiterSection(context),
          _resetButton(context),
        ]),
      ),
    );
  }

  Widget _buildWide(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiEntranceScope(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: tokens.spacing.card,
        children: <Widget>[
          SizedBox(
            width: 260,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: tokens.spacing.gap,
              children: _staggered(<Widget>[
                _masterSection(context),
                _presetSection(context, vertical: true),
                _resetButton(context),
              ]),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: tokens.spacing.gap,
              children: <Widget>[
                FushiStaggeredEntrance(
                  index: 1,
                  child: _equalizerSection(context, wide: true),
                ),
                FushiStaggeredEntrance(
                  index: 2,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: tokens.spacing.gap,
                    children: <Widget>[
                      Expanded(
                        child: _toneSection(context, includeLimiter: true),
                      ),
                      Expanded(child: _stageSection(context)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------

  Widget _masterSection(BuildContext context) {
    final MusicAudioEffects fx = _view;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool unsupported = !_app.musicSession.engine.capabilities.signalPath;
    return AdaptiveSettingsSection(
      children: <Widget>[
        AdaptiveSettingsSwitchRow(
          key: const ValueKey<String>('music-effects-enabled'),
          title: t.music_effects_enabled_title,
          subtitle: t.music_effects_enabled_hint,
          value: fx.enabled,
          onChanged: (bool v) => _edit(fx.copyWith(enabled: v)),
        ),
        AnimatedSize(
          duration: fushiMotionDuration(context, FushiMotion.short),
          child: fx.isActive
              ? _Note(
                  key: const ValueKey<String>('music-effects-active-banner'),
                  icon: FushiIcons.info,
                  color: cs.primary,
                  text: t.music_effects_active_banner,
                )
              : const SizedBox(width: double.infinity),
        ),
        if (unsupported)
          _Note(
            key: const ValueKey<String>('music-effects-unsupported'),
            icon: FushiIcons.warning,
            color: cs.error,
            text: t.music_effects_unsupported_backend,
          ),
      ],
    );
  }

  Widget _presetSection(BuildContext context, {required bool vertical}) {
    final MusicEqPreset selected = _viewPreset;
    if (vertical) {
      return AdaptiveSettingsSection(
        title: t.music_eq_preset_title,
        children: <Widget>[
          for (final MusicEqPreset p in MusicEqPreset.values)
            FushiPressScale(
              child: AdaptiveSettingsRow(
                key: ValueKey<String>('music-eq-preset-${p.wire}'),
                title: musicEqPresetLabel(p),
                trailing: p == selected
                    ? const FushiIcon(FushiIcons.check)
                    : null,
                onTap: () => _pickPreset(p),
              ),
            ),
        ],
      );
    }
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return AdaptiveSettingsSection(
      title: t.music_eq_preset_title,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.all(tokens.spacing.rowHorizontal / 2),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final MusicEqPreset p in MusicEqPreset.values)
                FushiPressScale(
                  child: FushiChoiceChip(
                    key: ValueKey<String>('music-eq-preset-${p.wire}'),
                    label: Text(musicEqPresetLabel(p)),
                    selected: p == selected,
                    onSelected: (bool _) => _pickPreset(p),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _equalizerSection(BuildContext context, {required bool wide}) {
    final MusicAudioEffects fx = _view;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Widget curve = MusicEqCurve(
      key: const ValueKey<String>('music-eq-curve'),
      effects: fx,
      height: wide ? 220 : 120,
      onBandDrag: (int i, double db) => _setBand(i, db),
      onBandDragEnd: _flush,
    );
    final Widget header = Row(
      children: <Widget>[
        Expanded(
          child: Text(t.music_eq_title, style: context.fushiType.titleSmall),
        ),
        Text(
          t.music_eq_range_hint,
          style: context.fushiType.bodySmall.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
      ],
    );
    final List<Widget> body;
    if (wide) {
      body = <Widget>[
        header,
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: tokens.spacing.gap,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 6,
                children: <Widget>[curve, _bandReadouts(context)],
              ),
            ),
            _VerticalFader(
              key: const ValueKey<String>('music-eq-preamp'),
              top: musicDbLabel(fx.preampDb, unit: false),
              bottom: t.music_eq_preamp_title,
              height: 220,
              value: fx.preampDb,
              limit: kMusicEffectsMaxPreampDb,
              semanticLabel: t.music_eq_preamp_title,
              onChanged: (double v) => _edit(
                fx.copyWith(preampDb: (v * 2).roundToDouble() / 2),
                immediate: false,
              ),
              onChangeEnd: (_) => _flush(),
            ),
          ],
        ),
        _preampHint(context),
      ];
    } else {
      body = <Widget>[
        header,
        curve,
        Row(
          children: <Widget>[
            for (int i = 0; i < kMusicEqualizerBandsHz.length; i++)
              Expanded(
                child: _VerticalFader(
                  key: ValueKey<String>(
                    'music-eq-band-${kMusicEqualizerBandsHz[i]}',
                  ),
                  top: musicDbLabel(fx.gainsDb[i], unit: false),
                  bottom: musicEqBandShortLabel(kMusicEqualizerBandsHz[i]),
                  height: 150,
                  value: fx.gainsDb[i],
                  limit: kMusicEqualizerMaxGainDb,
                  semanticLabel: musicHzLabel(kMusicEqualizerBandsHz[i]),
                  onChanged: (double v) => _setBand(i, v),
                  onChangeEnd: (_) => _flush(),
                ),
              ),
          ],
        ),
        AdaptiveSettingsSliderRow(
          key: const ValueKey<String>('music-eq-preamp'),
          title: t.music_eq_preamp_title,
          readout: musicDbLabel(fx.preampDb),
          value: fx.preampDb,
          min: -kMusicEffectsMaxPreampDb,
          max: kMusicEffectsMaxPreampDb,
          divisions: (kMusicEffectsMaxPreampDb * 4).round(),
          onChanged: (double v) => _edit(
            fx.copyWith(preampDb: (v * 2).roundToDouble() / 2),
            immediate: false,
          ),
          onChangeEnd: (_) => _flush(),
        ),
        _preampHint(context),
      ];
    }
    return AdaptiveSettingsSection(
      children: <Widget>[
        Padding(
          padding: EdgeInsets.all(tokens.spacing.rowHorizontal / 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: tokens.spacing.gap,
            children: body,
          ),
        ),
      ],
    );
  }

  Widget _bandReadouts(BuildContext context) {
    final TextStyle style = context.fushiType.labelSmall.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Row(
      children: <Widget>[
        for (int i = 0; i < kMusicEqualizerBandsHz.length; i++)
          Expanded(
            child: Column(
              children: <Widget>[
                Text(
                  musicDbLabel(_view.gainsDb[i], unit: false),
                  style: style.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                Text(
                  musicEqBandShortLabel(kMusicEqualizerBandsHz[i]),
                  style: style,
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _preampHint(BuildContext context) => Text(
    _view.limiter ? t.music_eq_preamp_hint_limiter : t.music_eq_preamp_hint,
    style: context.fushiType.bodySmall.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );

  Widget _toneSection(BuildContext context, {required bool includeLimiter}) {
    final MusicAudioEffects fx = _view;
    return AdaptiveSettingsSection(
      title: t.music_effects_tone_section,
      children: <Widget>[
        AdaptiveSettingsSliderRow(
          key: const ValueKey<String>('music-effects-bass'),
          title: t.music_effects_bass_title,
          subtitle: t.music_effects_bass_below(hz: musicHzLabel(fx.bassHz)),
          readout: musicDbLabel(fx.bassDb),
          value: fx.bassDb,
          min: -kMusicToneMaxGainDb,
          max: kMusicToneMaxGainDb,
          divisions: (kMusicToneMaxGainDb * 4).round(),
          onChanged: (double v) => _edit(
            fx.copyWith(bassDb: (v * 2).roundToDouble() / 2),
            immediate: false,
          ),
          onChangeEnd: (_) => _flush(),
        ),
        AdaptiveSettingsPickerRow<int>(
          key: const ValueKey<String>('music-effects-bass-hz'),
          title: t.music_effects_bass_freq_title,
          options: <AdaptiveSettingsPickerOption<int>>[
            for (final int hz in kMusicBassFrequenciesHz)
              AdaptiveSettingsPickerOption<int>(
                value: hz,
                label: musicHzLabel(hz),
              ),
          ],
          selected: kMusicBassFrequenciesHz.contains(fx.bassHz)
              ? fx.bassHz
              : kMusicBassDefaultHz,
          onChanged: (int hz) => _edit(fx.copyWith(bassHz: hz)),
        ),
        AdaptiveSettingsSliderRow(
          key: const ValueKey<String>('music-effects-treble'),
          title: t.music_effects_treble_title,
          subtitle: t.music_effects_treble_above(hz: musicHzLabel(fx.trebleHz)),
          readout: musicDbLabel(fx.trebleDb),
          value: fx.trebleDb,
          min: -kMusicToneMaxGainDb,
          max: kMusicToneMaxGainDb,
          divisions: (kMusicToneMaxGainDb * 4).round(),
          onChanged: (double v) => _edit(
            fx.copyWith(trebleDb: (v * 2).roundToDouble() / 2),
            immediate: false,
          ),
          onChangeEnd: (_) => _flush(),
        ),
        AdaptiveSettingsPickerRow<int>(
          key: const ValueKey<String>('music-effects-treble-hz'),
          title: t.music_effects_treble_freq_title,
          options: <AdaptiveSettingsPickerOption<int>>[
            for (final int hz in kMusicTrebleFrequenciesHz)
              AdaptiveSettingsPickerOption<int>(
                value: hz,
                label: musicHzLabel(hz),
              ),
          ],
          selected: kMusicTrebleFrequenciesHz.contains(fx.trebleHz)
              ? fx.trebleHz
              : kMusicTrebleDefaultHz,
          onChanged: (int hz) => _edit(fx.copyWith(trebleHz: hz)),
        ),
        if (includeLimiter) _limiterRow(),
      ],
    );
  }

  Widget _stageSection(BuildContext context) {
    final MusicAudioEffects fx = _view;
    return AdaptiveSettingsSection(
      title: t.music_effects_stage_section,
      summary: t.music_effects_stage_hint,
      children: <Widget>[
        AdaptiveSettingsSliderRow(
          key: const ValueKey<String>('music-effects-balance'),
          title: t.music_effects_balance_title,
          readout: musicBalanceLabel(fx.balance),
          value: fx.balance,
          min: -1,
          max: 1,
          divisions: 40,
          onChanged: (double v) => _edit(
            fx.copyWith(balance: (v * 20).roundToDouble() / 20),
            immediate: false,
          ),
          onChangeEnd: (_) => _flush(),
        ),
        AdaptiveSettingsSliderRow(
          key: const ValueKey<String>('music-effects-width'),
          title: t.music_effects_width_title,
          readout: '${(fx.width * 100).round()}%',
          value: fx.width,
          min: 0,
          max: kMusicStereoWidthMax,
          divisions: (kMusicStereoWidthMax * 20).round(),
          onChanged: (double v) => _edit(
            fx.copyWith(width: (v * 20).roundToDouble() / 20),
            immediate: false,
          ),
          onChangeEnd: (_) => _flush(),
        ),
        AdaptiveSettingsSwitchRow(
          key: const ValueKey<String>('music-effects-mono'),
          title: t.music_effects_mono_title,
          subtitle: t.music_effects_mono_hint,
          value: fx.mono,
          onChanged: (bool v) => _edit(fx.copyWith(mono: v)),
        ),
        AdaptiveSettingsSwitchRow(
          key: const ValueKey<String>('music-effects-swap'),
          title: t.music_effects_swap_title,
          value: fx.swapChannels,
          onChanged: (bool v) => _edit(fx.copyWith(swapChannels: v)),
        ),
      ],
    );
  }

  Widget _limiterRow() {
    final MusicAudioEffects fx = _view;
    final double headroom = musicAudioEffectsAutoHeadroomDb(fx);
    return AdaptiveSettingsSwitchRow(
      key: const ValueKey<String>('music-effects-limiter'),
      title: t.music_effects_limiter_title,
      subtitle: !fx.limiter && headroom >= 0.05
          ? t.music_effects_limiter_hint_headroom(
              db: headroom.toStringAsFixed(1),
            )
          : t.music_effects_limiter_hint,
      value: fx.limiter,
      onChanged: (bool v) => _edit(fx.copyWith(limiter: v)),
    );
  }

  Widget _limiterSection(BuildContext context) =>
      AdaptiveSettingsSection(children: <Widget>[_limiterRow()]);

  Widget _resetButton(BuildContext context) => FushiPressScale(
    child: FushiOutlinedButton(
      key: const ValueKey<String>('music-effects-reset'),
      onPressed: _resetAll,
      child: Text(t.music_effects_reset),
    ),
  );
}

/// 提示条（图标 + 文字，带色调底）。
class _Note extends StatelessWidget {
  const _Note({
    required this.icon,
    required this.color,
    required this.text,
    super.key,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Container(
      margin: EdgeInsets.all(tokens.spacing.rowHorizontal / 2),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: tokens.radii.controlRadius,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 10,
        children: <Widget>[
          FushiIcon(icon, size: 18, color: color),
          Expanded(child: Text(text, style: context.fushiType.bodySmall)),
        ],
      ),
    );
  }
}

/// 竖推子：上读数、下标签，中间是转 90° 的设计系统滑块（MD3 / Apple 各自外观与键盘、
/// 语义增减）。
class _VerticalFader extends StatelessWidget {
  const _VerticalFader({
    required this.top,
    required this.bottom,
    required this.height,
    required this.value,
    required this.limit,
    required this.semanticLabel,
    required this.onChanged,
    required this.onChangeEnd,
    super.key,
  });

  final String top;
  final String bottom;
  final double height;
  final double value;
  final double limit;
  final String semanticLabel;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextStyle style = context.fushiType.labelSmall;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(top, style: style.copyWith(color: cs.primary)),
        SizedBox(
          height: height,
          child: Semantics(
            label: semanticLabel,
            child: RotatedBox(
              quarterTurns: 3,
              child: adaptiveSlider(
                context: context,
                value: value.clamp(-limit, limit),
                min: -limit,
                max: limit,
                divisions: (limit * 4).round(),
                label: musicDbLabel(value),
                onChanged: onChanged,
                onChangeEnd: onChangeEnd,
              ),
            ),
          ),
        ),
        Text(
          bottom,
          style: style.copyWith(color: cs.onSurfaceVariant),
          maxLines: 1,
          overflow: TextOverflow.fade,
          softWrap: false,
        ),
      ],
    );
  }
}

/// 频响曲线：按当前增益（均衡 + 低音 / 高音搁架，FFmpeg 同一套 biquad 公式）实时画；
/// 各段中心画点，横向拖动选最近的一段、纵向拖动改它的增益。
class MusicEqCurve extends StatefulWidget {
  const MusicEqCurve({
    required this.effects,
    required this.height,
    this.onBandDrag,
    this.onBandDragEnd,
    super.key,
  });

  final MusicAudioEffects effects;
  final double height;
  final void Function(int band, double db)? onBandDrag;
  final VoidCallback? onBandDragEnd;

  /// 纵轴范围（±dB）。
  static const double rangeDb = 15;

  static const double _minHz = 20;
  static const double _maxHz = 20000;

  static double xOf(double hz, double width) =>
      width * (math.log(hz / _minHz) / math.log(_maxHz / _minHz));

  static double hzOf(double x, double width) =>
      _minHz * math.pow(_maxHz / _minHz, (x / width).clamp(0, 1));

  static double yOf(double db, double height) =>
      height / 2 - (db.clamp(-rangeDb, rangeDb) / rangeDb) * (height / 2 - 6);

  static double dbOf(double y, double height) =>
      ((height / 2 - y) / (height / 2 - 6)) * rangeDb;

  /// 纯函数：横坐标 [x] 处离得最近的频段（对数频率距离）。
  static int nearestBand(double x, double width) {
    final double hz = hzOf(x, width);
    int best = 0;
    double bestD = double.infinity;
    for (int i = 0; i < kMusicEqualizerBandsHz.length; i++) {
      final double d = (math.log(kMusicEqualizerBandsHz[i] / hz)).abs();
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  @override
  State<MusicEqCurve> createState() => _MusicEqCurveState();
}

class _MusicEqCurveState extends State<MusicEqCurve> {
  /// 这次拖动抓住的那一段（按下时选定，拖动中不换段）。
  int? _band;

  void _drag(Offset p, double width) {
    final int band = _band ??= MusicEqCurve.nearestBand(p.dx, width);
    widget.onBandDrag?.call(
      band,
      MusicEqCurve.dbOf(
        p.dy,
        widget.height,
      ).clamp(-kMusicEqualizerMaxGainDb, kMusicEqualizerMaxGainDb),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool draggable = widget.onBandDrag != null;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double w = c.maxWidth;
        return Semantics(
          label: t.music_eq_curve_label,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: !draggable
                ? null
                : (DragStartDetails d) {
                    _band = null;
                    _drag(d.localPosition, w);
                  },
            onPanUpdate: !draggable
                ? null
                : (DragUpdateDetails d) => _drag(d.localPosition, w),
            onPanEnd: !draggable
                ? null
                : (DragEndDetails _) {
                    _band = null;
                    widget.onBandDragEnd?.call();
                  },
            child: ClipRRect(
              borderRadius: tokens.radii.controlRadius,
              child: CustomPaint(
                size: Size(w, widget.height),
                painter: MusicEqCurvePainter(
                  effects: widget.effects,
                  line: cs.primary,
                  grid: cs.outlineVariant,
                  background: cs.surfaceContainerHighest,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class MusicEqCurvePainter extends CustomPainter {
  MusicEqCurvePainter({
    required this.effects,
    required this.line,
    required this.grid,
    required this.background,
  });

  final MusicAudioEffects effects;
  final Color line;
  final Color grid;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    final Paint gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final double db in <double>[-12, -6, 6, 12]) {
      final double y = MusicEqCurve.yOf(db, h);
      canvas.drawLine(Offset(0, y), Offset(w, y), gridPaint);
    }
    final Paint zero = Paint()
      ..color = grid
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(0, h / 2), Offset(w, h / 2), zero);
    final Path curve = Path();
    final int steps = math.max(48, (w / 3).round());
    for (int i = 0; i <= steps; i++) {
      final double x = w * i / steps;
      final double y = MusicEqCurve.yOf(
        musicAudioEffectsResponseDb(effects, MusicEqCurve.hzOf(x, w)),
        h,
      );
      if (i == 0) {
        curve.moveTo(x, y);
      } else {
        curve.lineTo(x, y);
      }
    }
    final Path fill = Path.from(curve)
      ..lineTo(w, h / 2)
      ..lineTo(0, h / 2)
      ..close();
    canvas.drawPath(fill, Paint()..color = line.withValues(alpha: 0.16));
    canvas.drawPath(
      curve,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );
    final Paint dot = Paint()..color = line;
    for (int i = 0; i < kMusicEqualizerBandsHz.length; i++) {
      final double x = MusicEqCurve.xOf(
        kMusicEqualizerBandsHz[i].toDouble(),
        w,
      );
      canvas.drawCircle(
        Offset(x, MusicEqCurve.yOf(effects.gainsDb[i], h)),
        4,
        dot,
      );
    }
  }

  @override
  bool shouldRepaint(MusicEqCurvePainter old) =>
      old.effects != effects ||
      old.line != line ||
      old.grid != grid ||
      old.background != background;
}

// -----------------------------------------------------------------------------
// 播放页里的音效浮层面板（用户 2026-11-08「音效不做二级界面做个 panel」）
// -----------------------------------------------------------------------------

/// 打开音效浮层面板：标题 + 总开关 + 关闭；一行预设 + 复位；均衡器推子卡；音色与声场卡。
/// 与音效页（设置里那一页）共用 [_EffectsEditing]，改动即时写回、即时下发。
Future<void> showMusicAudioEffectsPanel(
  BuildContext context,
  AppModel appModel,
) => showMusicFloatingPanel(
  context: context,
  maxWidth: 920,
  builder: (BuildContext _) => MusicAudioEffectsPanel(appModel: appModel),
);

class MusicAudioEffectsPanel extends StatefulWidget {
  const MusicAudioEffectsPanel({required this.appModel, super.key});

  final AppModel appModel;

  @override
  State<MusicAudioEffectsPanel> createState() => _MusicAudioEffectsPanelState();
}

class _MusicAudioEffectsPanelState extends State<MusicAudioEffectsPanel>
    with _EffectsEditing<MusicAudioEffectsPanel> {
  @override
  AppModel get _app => widget.appModel;

  @override
  Widget build(BuildContext context) {
    final List<Widget> blocks = <Widget>[
      _header(context),
      _presetRow(context),
      _sectionLabel(context, t.music_eq_title, trailing: t.music_eq_range_hint),
      _eqCard(context),
      _sectionLabel(context, t.music_effects_panel_chain),
      _chainCard(context),
    ];
    return Padding(
      key: const ValueKey<String>('music-effects-panel'),
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      child: FushiEntranceScope(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: <Widget>[
            for (int i = 0; i < blocks.length; i++)
              FushiStaggeredEntrance(index: i, child: blocks[i]),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final MusicAudioEffects fx = _view;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool unsupported = !_app.musicSession.engine.capabilities.signalPath;
    final String sub = unsupported
        ? t.music_effects_unsupported_backend
        : (fx.isActive
              ? t.music_effects_panel_active
              : t.music_effects_panel_bitperfect);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 2,
            children: <Widget>[
              Text(
                t.music_effects_title,
                style: context.fushiType.titleLarge.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                sub,
                key: const ValueKey<String>('music-effects-panel-state'),
                style: context.fushiType.bodySmall.copyWith(
                  color: unsupported
                      ? cs.error
                      : (fx.isActive ? cs.primary : cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
        // 窄屏（底部弹层）放不下文字：只留开关，文字进读屏标签。
        if (musicFloatingPanelFloats(context)) ...<Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              t.music_effects_enabled_title,
              style: context.fushiType.labelMedium.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
        Semantics(
          label: t.music_effects_enabled_title,
          child: KeyedSubtree(
            key: const ValueKey<String>('music-effects-enabled'),
            child: adaptiveSwitch(
              context: context,
              value: fx.enabled,
              onChanged: (bool v) => _edit(fx.copyWith(enabled: v)),
            ),
          ),
        ),
        const SizedBox(width: 4),
        FushiIconButtonControl(
          key: const ValueKey<String>('music-effects-panel-close'),
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          icon: const FushiIcon(FushiIcons.close),
          onPressed: () => unawaited(Navigator.of(context).maybePop()),
        ),
      ],
    );
  }

  Widget _presetRow(BuildContext context) {
    final MusicEqPreset selected = _viewPreset;
    return Row(
      children: <Widget>[
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            primary: false,
            child: Row(
              spacing: 6,
              children: <Widget>[
                for (final MusicEqPreset p in MusicEqPreset.values)
                  if (p != MusicEqPreset.custom || p == selected)
                    FushiPressScale(
                      child: FushiChoiceChip(
                        key: ValueKey<String>('music-eq-preset-${p.wire}'),
                        label: Text(musicEqPresetLabel(p)),
                        selected: p == selected,
                        visualDensity: VisualDensity.compact,
                        onSelected: (bool _) => _pickPreset(p),
                      ),
                    ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        FushiIconButtonControl(
          key: const ValueKey<String>('music-effects-reset'),
          tooltip: t.music_effects_reset,
          icon: const FushiIcon(FushiIcons.refresh),
          onPressed: _resetAll,
        ),
      ],
    );
  }

  Widget _sectionLabel(BuildContext context, String text, {String? trailing}) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              text,
              style: context.fushiType.titleSmall.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (trailing != null)
            Text(
              trailing,
              style: context.fushiType.bodySmall.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, Widget child) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }

  Widget _eqCard(BuildContext context) {
    final MusicAudioEffects fx = _view;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextStyle axis = context.fushiType.labelSmall.copyWith(
      color: cs.onSurfaceVariant,
    );
    final double height = musicFloatingPanelFloats(context) ? 200 : 150;
    final String max = '+${kMusicEqualizerMaxGainDb.round()}';
    final String min = '−${kMusicEqualizerMaxGainDb.round()}';
    return _card(
      context,
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 刻度：与推子轨道同高，夹在读数行与频率行之间。
          Padding(
            padding: const EdgeInsets.only(top: 18, bottom: 18, right: 4),
            child: SizedBox(
              height: height,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Text(max, style: axis),
                  Text('0', style: axis),
                  Text(min, style: axis),
                ],
              ),
            ),
          ),
          for (int i = 0; i < kMusicEqualizerBandsHz.length; i++)
            Expanded(
              child: _VerticalFader(
                key: ValueKey<String>(
                  'music-eq-band-${kMusicEqualizerBandsHz[i]}',
                ),
                top: musicDbLabel(fx.gainsDb[i], unit: false),
                bottom: musicEqBandShortLabel(kMusicEqualizerBandsHz[i]),
                height: height,
                value: fx.gainsDb[i],
                limit: kMusicEqualizerMaxGainDb,
                semanticLabel: musicHzLabel(kMusicEqualizerBandsHz[i]),
                onChanged: (double v) => _setBand(i, v),
                onChangeEnd: (_) => _flush(),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: SizedBox(
              height: height + 36,
              child: VerticalDivider(width: 1, color: cs.outlineVariant),
            ),
          ),
          SizedBox(
            width: 56,
            child: _VerticalFader(
              key: const ValueKey<String>('music-eq-preamp'),
              top: musicDbLabel(fx.preampDb, unit: false),
              bottom: t.music_eq_preamp_title,
              height: height,
              value: fx.preampDb,
              limit: kMusicEffectsMaxPreampDb,
              semanticLabel: t.music_eq_preamp_title,
              onChanged: (double v) => _edit(
                fx.copyWith(preampDb: (v * 2).roundToDouble() / 2),
                immediate: false,
              ),
              onChangeEnd: (_) => _flush(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _toggle(String key, String label, bool on, VoidCallback tap) =>
      FushiPressScale(
        child: FushiChoiceChip(
          key: ValueKey<String>(key),
          label: Text(label),
          selected: on,
          visualDensity: VisualDensity.compact,
          onSelected: (bool _) => tap(),
        ),
      );

  Widget _chainCard(BuildContext context) {
    final MusicAudioEffects fx = _view;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final double headroom = musicAudioEffectsAutoHeadroomDb(fx);
    int nextOf(List<int> options, int current) {
      final int i = options.indexOf(current);
      return options[(i + 1) % options.length];
    }

    final List<Widget> tiles = <Widget>[
      _SliderTile(
        key: const ValueKey<String>('music-effects-bass'),
        title: t.music_effects_bass_title,
        readout: musicDbLabel(fx.bassDb),
        freq: musicHzLabel(fx.bassHz),
        freqTooltip: t.music_effects_bass_freq_title,
        onFreqTap: () => _edit(
          fx.copyWith(bassHz: nextOf(kMusicBassFrequenciesHz, fx.bassHz)),
        ),
        value: fx.bassDb,
        min: -kMusicToneMaxGainDb,
        max: kMusicToneMaxGainDb,
        divisions: (kMusicToneMaxGainDb * 4).round(),
        onChanged: (double v) => _edit(
          fx.copyWith(bassDb: (v * 2).roundToDouble() / 2),
          immediate: false,
        ),
        onChangeEnd: (_) => _flush(),
      ),
      _SliderTile(
        key: const ValueKey<String>('music-effects-treble'),
        title: t.music_effects_treble_title,
        readout: musicDbLabel(fx.trebleDb),
        freq: musicHzLabel(fx.trebleHz),
        freqTooltip: t.music_effects_treble_freq_title,
        onFreqTap: () => _edit(
          fx.copyWith(trebleHz: nextOf(kMusicTrebleFrequenciesHz, fx.trebleHz)),
        ),
        value: fx.trebleDb,
        min: -kMusicToneMaxGainDb,
        max: kMusicToneMaxGainDb,
        divisions: (kMusicToneMaxGainDb * 4).round(),
        onChanged: (double v) => _edit(
          fx.copyWith(trebleDb: (v * 2).roundToDouble() / 2),
          immediate: false,
        ),
        onChangeEnd: (_) => _flush(),
      ),
      _SliderTile(
        key: const ValueKey<String>('music-effects-balance'),
        title: t.music_effects_balance_title,
        readout: musicBalanceLabel(fx.balance),
        value: fx.balance,
        min: -1,
        max: 1,
        divisions: 40,
        onChanged: (double v) => _edit(
          fx.copyWith(balance: (v * 20).roundToDouble() / 20),
          immediate: false,
        ),
        onChangeEnd: (_) => _flush(),
      ),
      _SliderTile(
        key: const ValueKey<String>('music-effects-width'),
        title: t.music_effects_width_title,
        readout: '${(fx.width * 100).round()}%',
        value: fx.width,
        min: 0,
        max: kMusicStereoWidthMax,
        divisions: (kMusicStereoWidthMax * 20).round(),
        onChanged: (double v) => _edit(
          fx.copyWith(width: (v * 20).roundToDouble() / 20),
          immediate: false,
        ),
        onChangeEnd: (_) => _flush(),
      ),
    ];
    return _card(
      context,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: <Widget>[
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) {
              final int cols = c.maxWidth >= 640
                  ? 4
                  : (c.maxWidth >= 360 ? 2 : 1);
              const double gap = 20;
              final double w = (c.maxWidth - gap * (cols - 1)) / cols;
              return Wrap(
                spacing: gap,
                runSpacing: 8,
                children: <Widget>[
                  for (final Widget tile in tiles)
                    SizedBox(width: w, child: tile),
                ],
              );
            },
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              _toggle(
                'music-effects-mono',
                t.music_effects_mono_title,
                fx.mono,
                () => _edit(fx.copyWith(mono: !fx.mono)),
              ),
              _toggle(
                'music-effects-swap',
                t.music_effects_swap_title,
                fx.swapChannels,
                () => _edit(fx.copyWith(swapChannels: !fx.swapChannels)),
              ),
              _toggle(
                'music-effects-limiter',
                t.music_effects_limiter_title,
                fx.limiter,
                () => _edit(fx.copyWith(limiter: !fx.limiter)),
              ),
            ],
          ),
          Text(
            !fx.limiter && headroom >= 0.05
                ? t.music_effects_limiter_hint_headroom(
                    db: headroom.toStringAsFixed(1),
                  )
                : (fx.limiter
                      ? t.music_eq_preamp_hint_limiter
                      : t.music_eq_preamp_hint),
            style: context.fushiType.bodySmall.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 面板里的一格滑块：标题（可带一个点按轮换的频率小标）+ 读数，下面一条滑块。
class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.title,
    required this.readout,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    required this.onChangeEnd,
    this.freq,
    this.freqTooltip,
    this.onFreqTap,
    super.key,
  });

  final String title;
  final String readout;
  final String? freq;
  final String? freqTooltip;
  final VoidCallback? onFreqTap;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String? f = freq;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.fushiType.labelLarge,
              ),
            ),
            if (f != null) ...<Widget>[
              const SizedBox(width: 6),
              Tooltip(
                message: freqTooltip ?? '',
                child: FushiPressScale(
                  child: Material(
                    color: cs.secondaryContainer,
                    shape: const StadiumBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: onFreqTap,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        child: Text(
                          f,
                          style: context.fushiType.labelSmall.copyWith(
                            color: cs.onSecondaryContainer,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
            const Spacer(),
            Text(
              readout,
              style: context.fushiType.labelMedium.copyWith(
                color: cs.primary,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        adaptiveSlider(
          context: context,
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          label: readout,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ],
    );
  }
}
