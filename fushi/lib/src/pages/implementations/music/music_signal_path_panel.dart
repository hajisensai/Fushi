/// 信号路径面板（设计 §7.4，Roon 式）：源 → 解码 → DSP 链 → 输出，以及只在这里
/// 调的播放控制（音量 / 变速 / 睡眠定时）。数据只来自 mpv 属性与平台回报
/// （[MusicSignalPathSnapshot]），判定是纯函数 [judgeMusicSignalPath]。
/// MD3 / Apple 两套由 [FushiAlertDialog] / [adaptiveSlider] / [adaptiveSegmentedButton]
/// 分派；行错峰进场。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_platform_output.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 打开面板。
Future<void> showMusicSignalPathPanel(
  BuildContext context,
  AppModel appModel,
) => showAppDialog<void>(
  context: context,
  builder: (BuildContext _) => MusicSignalPathPanel(appModel: appModel),
);

/// 纯函数：一环的显示名。
String musicSignalStageLabel(MusicSignalStage stage) => switch (stage) {
  MusicSignalStage.systemMixer => t.music_signal_stage_system_mixer,
  MusicSignalStage.noOutput => t.music_signal_stage_no_output,
  MusicSignalStage.dsdToPcm => t.music_signal_stage_dsd_to_pcm,
  MusicSignalStage.resampler => t.music_signal_stage_resampler,
  MusicSignalStage.formatConversion => t.music_signal_stage_format_conversion,
  MusicSignalStage.channelRemix => t.music_signal_stage_channel_remix,
  MusicSignalStage.volume => t.music_signal_stage_volume,
  MusicSignalStage.replayGain => t.music_signal_stage_replay_gain,
  MusicSignalStage.speed => t.music_signal_stage_speed,
  MusicSignalStage.filters => t.music_signal_stage_filters,
  MusicSignalStage.crossfade => t.music_signal_stage_crossfade,
};

String _khz(int hz) {
  final double k = hz / 1000;
  return k == k.roundToDouble()
      ? '${k.round()} kHz'
      : '${k.toStringAsFixed(1)} kHz';
}

/// 纯函数：mpv 格式 → 一行（`s32 · 96 kHz · stereo`）。
String musicAudioFormatLabel(MusicAudioFormat f) =>
    '${f.packedFormat} · ${_khz(f.sampleRate)} · ${f.channels ?? '${f.channelCount} ch'}';

/// 纯函数：源一行（容器 / 编码 / 采样率 / 位深 / 声道 / 码率），缺的项不写。
String musicSourceLabel(MusicSignalPathSnapshot s) => <String>[
  if (s.codecDescription != null || s.codec != null)
    (s.codec ?? s.codecDescription)!,
  if (s.fileFormat != null) s.fileFormat!,
  if (s.sourceSampleRate != null) _khz(s.sourceSampleRate!),
  if (s.sourceBitDepth != null) '${s.sourceBitDepth} bit',
  if (s.sourceChannelCount != null) '${s.sourceChannelCount} ch',
  if (s.bitrate != null && s.bitrate! > 0)
    '${(s.bitrate! / 1000).round()} kbps',
].join(' · ');

class MusicSignalPathPanel extends StatefulWidget {
  const MusicSignalPathPanel({required this.appModel, super.key});

  final AppModel appModel;

  @override
  State<MusicSignalPathPanel> createState() => _MusicSignalPathPanelState();
}

class _MusicSignalPathPanelState extends State<MusicSignalPathPanel> {
  MusicSignalPathSnapshot? _snapshot;
  Timer? _refresh;

  MusicPlayerEngine get _engine => widget.appModel.musicSession.engine;

  @override
  void initState() {
    super.initState();
    _engine.addListener(_onEngine);
    unawaited(_read());
    // 面板开着时每秒重读一次属性（切歌 / 设备重开 / 用户在别处改了设置都看得到）。
    _refresh = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_read()),
    );
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _engine.removeListener(_onEngine);
    super.dispose();
  }

  void _onEngine() {
    if (mounted) setState(() {});
  }

  Future<void> _read() async {
    final MusicSignalPathSnapshot? s = await _engine.readSignalPath();
    if (!mounted) return;
    setState(() => _snapshot = s);
  }

  @override
  Widget build(BuildContext context) {
    final MusicSignalPathSnapshot? s = _snapshot;
    final List<Widget> rows = s == null
        ? <Widget>[Text(t.music_signal_path_idle)]
        : _rows(context, s);
    return FushiAlertDialog(
      icon: const Icon(FushiIcons.highQuality),
      title: Text(t.music_signal_path_title),
      scrollable: true,
      content: SizedBox(
        width: 440,
        child: FushiEntranceScope(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (int i = 0; i < rows.length; i++)
                FushiStaggeredEntrance(index: i, child: rows[i]),
              ..._controls(context, s),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        FushiDialogAction(
          label: MaterialLocalizations.of(context).closeButtonLabel,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  List<Widget> _rows(BuildContext context, MusicSignalPathSnapshot s) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final MusicSignalPathVerdict v = judgeMusicSignalPath(s);
    final MusicBackendOutputFallback? fallback = _engine.lastOutputFallback;
    final bool bypass = musicOutputBypassesMixer(s);
    final MusicAudioFormat? decoded = s.decoded;
    final MusicAudioFormat? output = s.output;
    return <Widget>[
      _VerdictBanner(verdict: v),
      if (fallback != null)
        _Note(
          icon: FushiIcons.warning,
          color: scheme.error,
          text: switch (fallback.reason) {
            MusicOutputFallbackReason.exclusiveUnavailable =>
              t.music_output_fallback_exclusive,
            MusicOutputFallbackReason.deviceUnavailable =>
              t.music_output_fallback_device,
          },
        ),
      _Section(t.music_signal_path_source),
      _Line(musicSourceLabel(s)),
      _Section(t.music_signal_path_decoder),
      _Line(decoded == null ? '—' : musicAudioFormatLabel(decoded)),
      _Section(t.music_signal_path_dsp),
      _Stage(
        label: musicSignalStageLabel(MusicSignalStage.dsdToPcm),
        active: s.isDsd,
      ),
      _Stage(
        label: musicSignalStageLabel(MusicSignalStage.replayGain),
        active: s.volumeGainDb.abs() > 1e-9,
        detail:
            '${s.volumeGainDb >= 0 ? '+' : ''}'
            '${s.volumeGainDb.toStringAsFixed(2)} dB',
      ),
      _Stage(
        label: musicSignalStageLabel(MusicSignalStage.volume),
        active: v.stages.contains(MusicSignalStage.volume),
        detail: '${s.volume.round()}%',
      ),
      _Stage(
        label: musicSignalStageLabel(MusicSignalStage.speed),
        active: v.stages.contains(MusicSignalStage.speed),
        detail: '×${s.speed.toStringAsFixed(2)}',
      ),
      _Stage(
        label: musicSignalStageLabel(MusicSignalStage.resampler),
        active: v.stages.contains(MusicSignalStage.resampler),
      ),
      _Stage(
        label: musicSignalStageLabel(MusicSignalStage.formatConversion),
        active: v.stages.contains(MusicSignalStage.formatConversion),
      ),
      if (s.userFilters.isNotEmpty)
        _Stage(
          label: musicSignalStageLabel(MusicSignalStage.filters),
          active: true,
          detail: s.userFilters,
        ),
      _Section(t.music_signal_path_output),
      _Line(
        <String>[
          s.audioDeviceDescription ??
              (s.audioDevice == null || s.audioDevice == 'auto'
                  ? t.music_audio_device_auto
                  : s.audioDevice!),
          if (s.currentAo != null) s.currentAo!,
          bypass
              ? t.music_signal_path_mode_exclusive
              : t.music_signal_path_mode_shared,
        ].join(' · '),
      ),
      _Line(output == null ? '—' : musicAudioFormatLabel(output)),
      if (s.platform == MusicOutputPlatform.ios)
        _Note(
          icon: FushiIcons.info,
          color: scheme.onSurfaceVariant,
          text: <String>[
            t.music_signal_path_ios_mixer,
            if (s.iosSampleRate != null) _khz(s.iosSampleRate!.actual.round()),
          ].join(' · '),
        ),
      if (s.platform == MusicOutputPlatform.android &&
          s.androidBitPerfect != null &&
          !s.androidBitPerfect!.enabled)
        _Note(
          icon: FushiIcons.warning,
          color: scheme.error,
          text:
              '${s.androidBitPerfect!.state.wire}'
              '${s.androidBitPerfect!.message == null ? '' : ': ${s.androidBitPerfect!.message}'}',
        ),
    ];
  }

  List<Widget> _controls(BuildContext context, MusicSignalPathSnapshot? s) {
    final AppModel app = widget.appModel;
    final bool androidBitPerfect =
        s?.androidBitPerfect?.state == MusicBitPerfectState.enabled;
    return <Widget>[
      _Section(t.music_volume_title),
      if (androidBitPerfect)
        // bit-perfect 混音属性下系统不做软件音量：音量只能在 DAC 上调。
        _Note(
          icon: FushiIcons.info,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          text: t.music_signal_path_dac_volume_hint,
        )
      else
        adaptiveSlider(
          context: context,
          value: app.musicVolume,
          max: 100,
          divisions: 20,
          label: '${app.musicVolume.round()}%',
          onChanged: (double v) {
            unawaited(app.setMusicVolume(v));
            setState(() {});
          },
        ),
      _Section(t.music_speed_title),
      adaptiveSegmentedButton<double>(
        context: context,
        segments: <ButtonSegment<double>>[
          for (final double speed in const <double>[0.75, 1, 1.25, 1.5])
            ButtonSegment<double>(value: speed, label: Text('×$speed')),
        ],
        selected: <double>{app.musicSpeed},
        onSelectionChanged: (Set<double> v) {
          unawaited(app.setMusicSpeed(v.first));
          setState(() {});
        },
      ),
      _Section(t.music_sleep_title),
      adaptiveSegmentedButton<int>(
        context: context,
        segments: <ButtonSegment<int>>[
          ButtonSegment<int>(value: 0, label: Text(t.music_sleep_off)),
          ButtonSegment<int>(value: -1, label: Text(t.music_sleep_after_track)),
          for (final int m in const <int>[15, 30, 60])
            ButtonSegment<int>(
              value: m,
              label: Text(t.music_sleep_minutes(n: m)),
            ),
        ],
        selected: <int>{_sleepSelection()},
        onSelectionChanged: (Set<int> v) {
          final int m = v.first;
          if (m == 0) {
            _engine.setSleepTimer(null);
          } else if (m == -1) {
            unawaited(_engine.setStopAfterCurrent(true));
          } else {
            _engine.setSleepTimer(Duration(minutes: m));
          }
          _sleepMinutes = m > 0 ? m : null;
        },
      ),
    ];
  }

  int? _sleepMinutes;

  int _sleepSelection() {
    if (_engine.sleepDeadline != null) return _sleepMinutes ?? 15;
    if (_engine.stopAfterCurrent) return -1;
    return 0;
  }
}

class _VerdictBanner extends StatelessWidget {
  const _VerdictBanner({required this.verdict});

  final MusicSignalPathVerdict verdict;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool perfect = verdict.isBitPerfect;
    final String title = switch (verdict.quality) {
      MusicSignalQuality.bitPerfect => t.music_signal_path_bit_perfect,
      MusicSignalQuality.highQuality => t.music_signal_path_high_quality,
      MusicSignalQuality.unknown => t.music_signal_path_idle,
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: perfect ? scheme.primaryContainer : scheme.secondaryContainer,
        borderRadius: FushiDesignTokens.of(context).radii.cardRadius,
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              perfect ? FushiIcons.verified : FushiIcons.highQuality,
              color: perfect ? scheme.onPrimaryContainer : scheme.onSurface,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: context.fushiType.titleSmallEmphasized),
                  if (verdict.stages.isNotEmpty)
                    Text(
                      t.music_signal_path_altered_by(
                        stages: verdict.stages
                            .map(musicSignalStageLabel)
                            .join(' · '),
                      ),
                      style: context.fushiType.bodySmall,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 4),
    child: Text(
      text,
      style: context.fushiType.labelLarge.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

class _Line extends StatelessWidget {
  const _Line(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: context.fushiType.bodyMedium);
}

class _Stage extends StatelessWidget {
  const _Stage({required this.label, required this.active, this.detail});

  final String label;
  final bool active;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label, style: context.fushiType.bodyMedium)),
          if (detail != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(detail!, style: context.fushiType.bodySmall),
            ),
          Text(
            active ? t.music_signal_path_active : t.music_signal_path_inactive,
            style: context.fushiType.labelMedium.copyWith(
              color: active ? scheme.tertiary : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: context.fushiType.bodySmall.copyWith(color: color),
          ),
        ),
      ],
    ),
  );
}
