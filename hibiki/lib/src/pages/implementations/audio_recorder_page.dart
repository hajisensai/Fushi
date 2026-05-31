import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/utils.dart';
import 'package:just_audio/just_audio.dart';
import 'package:multi_value_listenable_builder/multi_value_listenable_builder.dart';
import 'package:record/record.dart';
import 'package:hibiki/pages.dart';

/// The content of the dialog used for selecting segmented units of a source
/// text.
class AudioRecorderDialogPage extends BasePage {
  /// Create an instance of this page.
  const AudioRecorderDialogPage({
    required this.filePath,
    required this.onSave,
    super.key,
  });

  /// Path to save audio file to.
  final String filePath;

  /// The callback to be called when a new audio file has been recorded.
  final Function(File) onSave;

  @override
  BasePageState createState() => _AudioRecorderDialogPageState();
}

class _AudioRecorderDialogPageState
    extends BasePageState<AudioRecorderDialogPage> {
  static const double _playerTimeWidthThreshold = 280;

  final AudioRecorder _recorder = AudioRecorder();

  File? _audioFile;

  bool _isRecording = false;
  bool _initialised = false;
  StreamSubscription<void>? _noisySub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlayerState>? _playerStateSub;

  @override
  void dispose() {
    _noisySub?.cancel();
    _durationSub?.cancel();
    _positionSub?.cancel();
    _playerStateSub?.cancel();
    _audioPlayer.dispose();
    _recorder.dispose();
    _positionNotifier.dispose();
    _durationNotifier.dispose();
    _playerStateNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 520,
      maxHeightFactor: 0.92,
      insetPadding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.card,
      ),
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: t.creator_enhancement_audio_recorder,
        leadingIcon: Icons.mic_none_outlined,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: buildContent(),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: actions,
        ),
      ),
    );
  }

  List<Widget> get actions => [
        if (_isRecording) buildStopButton() else buildRecordButton(),
        buildSaveButton(),
      ];

  Widget buildContent() {
    return SizedBox(
      width: double.maxFinite,
      child: _audioFile == null || _isRecording
          ? buildDisabledPlayer()
          : buildAudioPlayer(),
    );
  }

  final AudioPlayer _audioPlayer = AudioPlayer();

  final ValueNotifier<Duration> _positionNotifier =
      ValueNotifier<Duration>(Duration.zero);
  // Consumers (buildSlider/buildDurationAndPosition) always treat this as a
  // non-null Duration, so the notifier is non-nullable and stream nulls are
  // mapped to Duration.zero at the listener (HBK-AUDIT-107).
  final ValueNotifier<Duration> _durationNotifier =
      ValueNotifier<Duration>(Duration.zero);
  final ValueNotifier<PlayerState?> _playerStateNotifier =
      ValueNotifier<PlayerState?>(null);

  /// Build the audio player.
  Widget buildAudioPlayer() {
    return SizedBox(
      height: 48,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final bool showTime =
              constraints.maxWidth >= _playerTimeWidthThreshold;

          return Row(
            children: [
              buildPlayButton(),
              if (showTime) buildDurationAndPosition(),
              Expanded(
                child: buildSlider(),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Build the play/pause button
  Widget buildPlayButton() {
    return MultiValueListenableBuilder(
      valueListenables: [
        _playerStateNotifier,
      ],
      builder: (context, values, _) {
        final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
        PlayerState? playerState = values.elementAt(0);

        IconData iconData = Icons.play_arrow_outlined;

        if (playerState == null ||
            playerState.processingState == ProcessingState.completed) {
          iconData = Icons.play_arrow_outlined;
        } else if (playerState.playing) {
          iconData = Icons.pause_outlined;
        } else {
          iconData = Icons.play_arrow_outlined;
        }

        return HibikiIconButton(
          icon: iconData,
          size: 24,
          padding: EdgeInsets.all(tokens.spacing.gap),
          tooltip: playerState?.playing == true ? t.pause : t.play,
          onTap: () async {
            AudioSession? session;
            if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
              session = await AudioSession.instance;
              await session.configure(
                const AudioSessionConfiguration(
                  avAudioSessionCategory: AVAudioSessionCategory.playback,
                  avAudioSessionCategoryOptions:
                      AVAudioSessionCategoryOptions.duckOthers,
                  avAudioSessionMode: AVAudioSessionMode.defaultMode,
                  avAudioSessionRouteSharingPolicy:
                      AVAudioSessionRouteSharingPolicy.defaultPolicy,
                  avAudioSessionSetActiveOptions:
                      AVAudioSessionSetActiveOptions.none,
                  androidAudioAttributes: AndroidAudioAttributes(
                    contentType: AndroidAudioContentType.music,
                    usage: AndroidAudioUsage.media,
                  ),
                  androidAudioFocusGainType:
                      AndroidAudioFocusGainType.gainTransientMayDuck,
                  androidWillPauseWhenDucked: true,
                ),
              );

              _noisySub?.cancel();
              _noisySub =
                  session.becomingNoisyEventStream.listen((event) async {
                await _audioPlayer.pause();
                session?.setActive(false);
              });
            }

            if (playerState == null ||
                playerState.processingState == ProcessingState.completed) {
              await _audioPlayer.seek(Duration.zero);

              session?.setActive(true);
              await _audioPlayer.play();
              session?.setActive(false);
            } else if (playerState.playing) {
              await _audioPlayer.pause();
              session?.setActive(false);
            } else {
              session?.setActive(true);
              await _audioPlayer.play();
              session?.setActive(false);
            }
          },
        );
      },
    );
  }

  /// Build the player duration label.
  Widget buildDurationAndPosition() {
    return MultiValueListenableBuilder(
      valueListenables: [
        _durationNotifier,
        _positionNotifier,
        _playerStateNotifier,
      ],
      builder: (context, values, _) {
        Duration duration = values.elementAt(0);
        Duration position = values.elementAt(1);
        PlayerState? playerState = values.elementAt(2);

        if (duration == Duration.zero) {
          return const SizedBox.shrink();
        }

        String getPositionText() {
          if (playerState == null ||
              playerState.processingState == ProcessingState.completed) {
            position = Duration.zero;
          }

          return HibikiTimeFormat.getVideoDurationText(position).trim();
        }

        String getDurationText() {
          return HibikiTimeFormat.getVideoDurationText(duration).trim();
        }

        return Text(
          '${getPositionText()} / ${getDurationText()}',
        );
      },
    );
  }

  /// Build the duration slider.
  Widget buildSlider() {
    return MultiValueListenableBuilder(
      valueListenables: [
        _durationNotifier,
        _positionNotifier,
        _playerStateNotifier,
      ],
      builder: (context, values, _) {
        Duration duration = values.elementAt(0);
        Duration position = values.elementAt(1);
        PlayerState? playerState = values.elementAt(2);

        double sliderValue = position.inMilliseconds.toDouble();
        double max = duration.inMilliseconds.toDouble();

        if (playerState == null ||
            playerState.processingState == ProcessingState.completed) {
          sliderValue = 0;
          max = 1.0;
        }

        return gamepadSeekableSlider(
          value: sliderValue <= max ? sliderValue : 0.0,
          max: max,
          step: 5000, // gamepad D-pad Left/Right = seek ±5s
          onChanged: (progress) {
            _audioPlayer.seek(Duration(milliseconds: progress.floor()));
          },
        );
      },
    );
  }

  /// Set up audio for new file.
  Future<void> initialiseAudio(File file) async {
    await _audioPlayer.setFilePath(file.path);
    await _audioPlayer.pause();
    _positionNotifier.value = _audioPlayer.position;
    _durationNotifier.value = _audioPlayer.duration ?? Duration.zero;

    if (!_initialised) {
      _durationSub = _audioPlayer.durationStream.listen((duration) {
        _durationNotifier.value = duration ?? Duration.zero;
      });
      _positionSub = _audioPlayer.positionStream.listen((position) {
        _positionNotifier.value = position;
      });
      _playerStateSub = _audioPlayer.playerStateStream.listen((playerState) {
        _playerStateNotifier.value = playerState;
      });
      _initialised = true;
    }
  }

  /// Buiid the audio player.
  Widget buildDisabledPlayer() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return SizedBox(
      height: 48,
      child: IgnorePointer(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final bool showTime =
                constraints.maxWidth >= _playerTimeWidthThreshold;

            return Row(
              children: [
                if (_isRecording)
                  Container(
                    height: 48,
                    width: 48,
                    padding: EdgeInsets.all(tokens.spacing.card),
                    child: adaptiveIndicator(
                      context: context,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  )
                else
                  Opacity(
                    opacity: 0.5,
                    child: HibikiIconButton(
                      icon: Icons.play_arrow_outlined,
                      size: 24,
                      enabled: false,
                      disabledColor: theme.colorScheme.onSurfaceVariant,
                      padding: EdgeInsets.all(tokens.spacing.gap),
                      tooltip: t.play,
                    ),
                  ),
                if (showTime)
                  const Opacity(
                    opacity: 0.5,
                    child: Text(
                      '--:-- / --:--',
                    ),
                  ),
                Expanded(
                  child: Opacity(
                    opacity: 0.5,
                    child: adaptiveSlider(
                      context: context,
                      value: 0,
                      thumbColor:
                          Theme.of(context).colorScheme.onSurfaceVariant,
                      onChanged: (value) {},
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget buildStopButton() {
    return adaptiveDialogAction(
      context: context,
      isDestructiveAction: true,
      child: Text(
        t.dialog_stop,
      ),
      onPressed: () async {
        await _recorder.stop();
        _audioFile = File(widget.filePath);

        await initialiseAudio(_audioFile!);
        if (!mounted) return;
        setState(() {
          _isRecording = false;
        });
      },
    );
  }

  Widget buildRecordButton() {
    return adaptiveDialogAction(
      context: context,
      child: Text(t.dialog_record),
      onPressed: () async {
        await _audioPlayer.stop();
        if (!await _recorder.hasPermission()) {
          HibikiToast.show(msg: t.microphone_permission_denied);
          return;
        }
        if (!mounted) return;
        setState(() {
          _isRecording = true;
        });
        try {
          await _recorder.start(
            const RecordConfig(encoder: AudioEncoder.aacLc),
            path: widget.filePath,
          );
        } on Exception {
          if (!mounted) return;
          setState(() {
            _isRecording = false;
          });
        }
      },
    );
  }

  Widget buildSaveButton() {
    return adaptiveDialogAction(
      context: context,
      onPressed: executeSave,
      child: Text(t.dialog_save),
    );
  }

  void executeSave() {
    if (_audioFile == null) {
      HibikiToast.show(msg: t.no_audio_file);
      return;
    }

    widget.onSave(_audioFile!);
    Navigator.pop(context);
  }
}
