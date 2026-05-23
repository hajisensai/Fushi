import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:multi_value_listenable_builder/multi_value_listenable_builder.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/utils.dart';

/// Base class for audio creator fields (term audio and sentence audio).
/// Contains all shared audio-player logic so concrete subclasses only need
/// to supply identity values (key, label, icon, localised label).
abstract class BaseAudioField extends AudioExportField {
  /// Initialise this field with the predetermined and hardset values.
  BaseAudioField({
    required super.uniqueKey,
    required super.label,
    required super.description,
    required super.icon,
  });

  AudioPlayer _audioPlayer = AudioPlayer();

  final ValueNotifier<Duration> _positionNotifier =
      ValueNotifier<Duration>(Duration.zero);
  final ValueNotifier<Duration?> _durationNotifier =
      ValueNotifier<Duration>(Duration.zero);
  final ValueNotifier<PlayerState?> _playerStateNotifier =
      ValueNotifier<PlayerState?>(null);

  int _audioLoadGeneration = 0;
  Future<void> _audioLoadQueue = Future<void>.value();
  final List<StreamSubscription<dynamic>> _audioSubscriptions = [];
  StreamSubscription<void>? _noisySub;

  /// Build the audio player.
  Widget buildAudioPlayer() {
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          buildPlayButton(),
          buildDurationAndPosition(),
          buildSlider(),
        ],
      ),
    );
  }

  /// Build the disabled audio player.
  Widget buildDisabledPlayer(BuildContext context) {
    return SizedBox(
      height: 48,
      child: IgnorePointer(
        child: Opacity(
          opacity: 0.5,
          child: Row(
            children: [
              Container(
                height: 48,
                width: 48,
                padding: const EdgeInsets.all(16),
                child: adaptiveIndicator(
                  context: context,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const Text(
                '--:-- / --:--',
              ),
              Expanded(
                child: adaptiveSlider(
                  context: context,
                  value: 0,
                  thumbColor: Theme.of(context).colorScheme.onSurfaceVariant,
                  onChanged: (value) {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void setAudioFile({
    required AppModel appModel,
    required CreatorModel creatorModel,
    required File file,
    String? searchTermUsed,
  }) {
    unawaited(initialiseAudio(file));
    super.setAudioFile(
      appModel: appModel,
      creatorModel: creatorModel,
      file: file,
    );
  }

  /// Set up audio for new file.
  Future<void> initialiseAudio(File file) {
    final int generation = ++_audioLoadGeneration;
    _audioLoadQueue = _audioLoadQueue
        .catchError((Object _) {})
        .then((_) => _replaceAudioPlayer(file, generation));
    return _audioLoadQueue;
  }

  Future<void> _replaceAudioPlayer(File file, int generation) async {
    for (final subscription in _audioSubscriptions) {
      await subscription.cancel();
    }
    _audioSubscriptions.clear();

    final AudioPlayer oldPlayer = _audioPlayer;
    await oldPlayer.stop();
    await oldPlayer.dispose();

    final AudioPlayer newPlayer = AudioPlayer();
    if (generation != _audioLoadGeneration) {
      await newPlayer.dispose();
      return;
    }

    _audioPlayer = newPlayer;
    await newPlayer.setFilePath(file.path);
    if (generation != _audioLoadGeneration) {
      if (identical(_audioPlayer, newPlayer)) {
        _audioPlayer = AudioPlayer();
      }
      await newPlayer.dispose();
      return;
    }

    await newPlayer.pause();
    _positionNotifier.value = newPlayer.position;
    _durationNotifier.value = newPlayer.duration ?? Duration.zero;
    _audioSubscriptions.addAll([
      newPlayer.durationStream.listen((duration) {
        _durationNotifier.value = duration;
      }),
      newPlayer.positionStream.listen((position) {
        _positionNotifier.value = position;
      }),
      newPlayer.playerStateStream.listen((playerState) {
        _playerStateNotifier.value = playerState;
      }),
    ]);
  }

  Future<void> _disposeAudioPlayer() async {
    _noisySub?.cancel();
    _noisySub = null;
    for (final subscription in _audioSubscriptions) {
      await subscription.cancel();
    }
    _audioSubscriptions.clear();

    final AudioPlayer oldPlayer = _audioPlayer;
    _audioPlayer = AudioPlayer();
    await oldPlayer.stop();
    await oldPlayer.dispose();
  }

  /// Clears this field's data. The state refresh afterwards is not performed
  /// here and should be performed by the invocation of the clear field button.
  @override
  void clearFieldState({
    required CreatorModel creatorModel,
  }) {
    unawaited(_audioPlayer.stop());
    super.clearFieldState(creatorModel: creatorModel);
  }

  /// Build the play/pause button.
  Widget buildPlayButton() {
    return MultiValueListenableBuilder(
      valueListenables: [
        _playerStateNotifier,
      ],
      builder: (context, values, _) {
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

        return IconButton(
          icon: Icon(iconData, size: 24),
          onPressed: () async {
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
        }

        return Expanded(
          child: adaptiveSlider(
              context: context,
              value: sliderValue <= max ? sliderValue : 0.0,
              max: max,
              onChanged: (progress) {
                _audioPlayer.seek(Duration(milliseconds: progress.floor()));
              }),
        );
      },
    );
  }

  @override
  String? onCreatorOpenAction({
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required DictionaryEntry entry,
    required bool creatorJustLaunched,
    required String? dictionaryName,
  }) {
    return null;
  }

  @override
  Widget buildTopWidget({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required Orientation orientation,
  }) {
    if (isSearching) {
      return buildDisabledPlayer(context);
    }

    if (!showWidget) {
      if (orientation == Orientation.landscape) {
        return const SizedBox(height: 24);
      } else {
        return const SizedBox.shrink();
      }
    }

    return buildAudioPlayer();
  }

  // Executed on close of the creator screen.
  @override
  void onCreatorClose() {
    _audioLoadGeneration++;
    _audioLoadQueue = _audioLoadQueue
        .catchError((Object _) {})
        .then((_) => _disposeAudioPlayer());
    unawaited(_audioLoadQueue);
  }
}
