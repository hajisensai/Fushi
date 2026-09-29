import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';

/// Moonlight-style stream settings. Returns the edited settings, or null when
/// dismissed without saving.
Future<GameStreamVideoSettings?> showGameStreamSettingsSheet(
  BuildContext context, {
  required GameStreamVideoSettings initial,
}) {
  return showModalBottomSheet<GameStreamVideoSettings>(
    context: context,
    isScrollControlled: true,
    builder: (BuildContext context) =>
        GameStreamSettingsSheet(initial: initial),
  );
}

class GameStreamSettingsSheet extends StatefulWidget {
  const GameStreamSettingsSheet({required this.initial, super.key});

  final GameStreamVideoSettings initial;

  static const Key saveKey = ValueKey<String>('game-stream-settings-save');

  @override
  State<GameStreamSettingsSheet> createState() =>
      _GameStreamSettingsSheetState();
}

class _GameStreamSettingsSheetState extends State<GameStreamSettingsSheet> {
  late GameStreamVideoSettings _settings = widget.initial;

  /// Bitrate follows the Moonlight table until the user moves the slider.
  late bool _bitrateTouched =
      widget.initial.bitrateKbps !=
      GameStreamVideoSettings.recommendedBitrateKbps(
        maxHeight: widget.initial.maxHeight,
        maxFps: widget.initial.maxFps,
      );

  void _update(GameStreamVideoSettings next) {
    setState(() {
      _settings = _bitrateTouched
          ? next
          : next.copyWith(
              bitrateKbps: GameStreamVideoSettings.recommendedBitrateKbps(
                maxHeight: next.maxHeight,
                maxFps: next.maxFps,
              ),
            );
    });
  }

  static String _heightLabel(int height) => switch (height) {
    2160 => '4K',
    1440 => '1440p',
    _ => '${height}p',
  };

  static String bitrateLabel(int kbps) =>
      '${(kbps / 1000).toStringAsFixed(kbps < 10000 ? 1 : 0)} Mbps';

  String _codecLabel(GameStreamCodec codec) => switch (codec) {
    GameStreamCodec.auto => t.game_stream_settings_codec_auto,
    GameStreamCodec.h264 => 'H.264',
    GameStreamCodec.vp8 => 'VP8',
    GameStreamCodec.vp9 => 'VP9',
    GameStreamCodec.av1 => 'AV1',
  };

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // Log-scale slider: 0.5 → 150 Mbps spans three decades; a linear slider
    // would leave the common 5–30 Mbps range in the first tenth of the track.
    final double minLog = _log(GameStreamVideoSettings.minBitrateKbps);
    final double maxLog = _log(GameStreamVideoSettings.maxBitrateKbps);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.85,
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      t.game_stream_settings_title,
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      _bitrateTouched = false;
                      _settings = const GameStreamVideoSettings().copyWith(
                        bitrateKbps:
                            GameStreamVideoSettings.recommendedBitrateKbps(
                              maxHeight: 1080,
                              maxFps: 60,
                            ),
                      );
                    }),
                    child: Text(t.game_stream_settings_reset),
                  ),
                  FilledButton(
                    key: GameStreamSettingsSheet.saveKey,
                    onPressed: () => Navigator.of(context).pop(_settings),
                    child: Text(t.game_stream_settings_save),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                children: <Widget>[
                  AdaptiveSettingsSegmentedRow<int>(
                    title: t.game_stream_settings_resolution,
                    subtitle: t.game_stream_settings_resolution_hint,
                    segments: <ButtonSegment<int>>[
                      for (final int height
                          in GameStreamVideoSettings.heightChoices)
                        ButtonSegment<int>(
                          value: height,
                          label: Text(_heightLabel(height)),
                        ),
                    ],
                    selected: _settings.maxHeight,
                    onChanged: (int value) =>
                        _update(_settings.copyWith(maxHeight: value)),
                  ),
                  AdaptiveSettingsSegmentedRow<int>(
                    title: t.game_stream_settings_fps,
                    segments: <ButtonSegment<int>>[
                      for (final int fps in GameStreamVideoSettings.fpsChoices)
                        ButtonSegment<int>(value: fps, label: Text('$fps')),
                    ],
                    selected:
                        GameStreamVideoSettings.fpsChoices.contains(
                          _settings.maxFps,
                        )
                        ? _settings.maxFps
                        : 60,
                    onChanged: (int value) =>
                        _update(_settings.copyWith(maxFps: value)),
                  ),
                  AdaptiveSettingsSliderRow(
                    title: t.game_stream_settings_bitrate,
                    readout: bitrateLabel(_settings.bitrateKbps),
                    min: minLog,
                    max: maxLog,
                    step: (maxLog - minLog) / 60,
                    value: _log(_settings.bitrateKbps).clamp(minLog, maxLog),
                    onChanged: (double value) => setState(() {
                      _bitrateTouched = true;
                      _settings = _settings.copyWith(
                        bitrateKbps: _roundBitrate(_exp(value)),
                      );
                    }),
                  ),
                  AdaptiveSettingsSwitchRow(
                    title: t.game_stream_settings_adaptive,
                    subtitle: t.game_stream_settings_adaptive_hint,
                    value: _settings.adaptiveBitrate,
                    onChanged: (bool value) => setState(
                      () => _settings = _settings.copyWith(
                        adaptiveBitrate: value,
                      ),
                    ),
                  ),
                  AdaptiveSettingsSegmentedRow<GameStreamDegradation>(
                    title: t.game_stream_settings_degradation,
                    segments: <ButtonSegment<GameStreamDegradation>>[
                      ButtonSegment<GameStreamDegradation>(
                        value: GameStreamDegradation.balanced,
                        label: Text(
                          t.game_stream_settings_degradation_balanced,
                        ),
                      ),
                      ButtonSegment<GameStreamDegradation>(
                        value: GameStreamDegradation.maintainFramerate,
                        label: Text(
                          t.game_stream_settings_degradation_framerate,
                        ),
                      ),
                      ButtonSegment<GameStreamDegradation>(
                        value: GameStreamDegradation.maintainResolution,
                        label: Text(
                          t.game_stream_settings_degradation_resolution,
                        ),
                      ),
                    ],
                    selected: _settings.degradation,
                    onChanged: (GameStreamDegradation value) => setState(
                      () => _settings = _settings.copyWith(degradation: value),
                    ),
                  ),
                  AdaptiveSettingsSegmentedRow<GameStreamCodec>(
                    title: t.game_stream_settings_codec,
                    subtitle: t.game_stream_settings_codec_hint,
                    segments: <ButtonSegment<GameStreamCodec>>[
                      for (final GameStreamCodec codec
                          in GameStreamCodec.values)
                        ButtonSegment<GameStreamCodec>(
                          value: codec,
                          label: Text(_codecLabel(codec)),
                        ),
                    ],
                    selected: _settings.codec,
                    onChanged: (GameStreamCodec value) => setState(
                      () => _settings = _settings.copyWith(codec: value),
                    ),
                  ),
                  AdaptiveSettingsSegmentedRow<GameStreamInputFocus>(
                    title: t.game_stream_settings_input_focus,
                    subtitle: t.game_stream_settings_input_focus_hint,
                    segments: <ButtonSegment<GameStreamInputFocus>>[
                      ButtonSegment<GameStreamInputFocus>(
                        value: GameStreamInputFocus.background,
                        label: Text(t.game_stream_settings_input_background),
                      ),
                      ButtonSegment<GameStreamInputFocus>(
                        value: GameStreamInputFocus.foreground,
                        label: Text(t.game_stream_settings_input_foreground),
                      ),
                    ],
                    selected: _settings.inputFocus,
                    onChanged: (GameStreamInputFocus value) => setState(
                      () => _settings = _settings.copyWith(inputFocus: value),
                    ),
                  ),
                  AdaptiveSettingsSwitchRow(
                    title: t.game_stream_settings_audio,
                    value: _settings.audio,
                    onChanged: (bool value) => setState(
                      () => _settings = _settings.copyWith(audio: value),
                    ),
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

double _log(int kbps) => math.log(kbps.toDouble());

int _exp(double value) => math.exp(value).round();

/// 0.5–10 Mbps in 0.5 steps, above that whole Mbps: the readout never shows
/// meaningless precision like "23.7 Mbps".
int _roundBitrate(int kbps) {
  final int step = kbps < 10000 ? 500 : 1000;
  return ((kbps / step).round() * step).clamp(
    GameStreamVideoSettings.minBitrateKbps,
    GameStreamVideoSettings.maxBitrateKbps,
  );
}
