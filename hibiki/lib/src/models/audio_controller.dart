import 'dart:async';

import 'package:audio_service/audio_service.dart' as ag;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/src/utils/misc/Hibiki_audio_handler.dart';

class AudioController {
  Stream<void> get playStream => _playController.stream;
  final StreamController<void> _playController = StreamController.broadcast();

  Stream<Duration> get seekStream => _seekController.stream;
  final StreamController<Duration> _seekController =
      StreamController.broadcast();

  Stream<void> get rewindStream => _rewindController.stream;
  final StreamController<void> _rewindController = StreamController.broadcast();

  Stream<void> get fastForwardStream => _fastForwardController.stream;
  final StreamController<void> _fastForwardController =
      StreamController.broadcast();

  Stream<void> get skipNextStream => _skipNextController.stream;
  final StreamController<void> _skipNextController =
      StreamController.broadcast();

  Stream<void> get skipPreviousStream => _skipPreviousController.stream;
  final StreamController<void> _skipPreviousController =
      StreamController.broadcast();

  Stream<void> get currentMediaPauseStream => _mediaPauseController.stream;
  final StreamController<void> _mediaPauseController =
      StreamController.broadcast();

  Stream<void> get playPauseHeadsetActionStream =>
      _playPauseHeadsetController.stream;
  final StreamController<void> _playPauseHeadsetController =
      StreamController.broadcast();

  Stream<bool> get creatorActiveStream => _creatorActiveController.stream;
  final StreamController<bool> _creatorActiveController =
      StreamController.broadcast();

  HibikiAudioHandler? get audioHandler => _audioHandler;
  HibikiAudioHandler? _audioHandler;

  void emitMediaPause() => _mediaPauseController.add(null);
  void emitCreatorActive(bool active) => _creatorActiveController.add(active);

  Future<void> initialiseHandler() async {
    if (_audioHandler != null) return;

    try {
      _audioHandler = await ag.AudioService.init<HibikiAudioHandler>(
        builder: () => HibikiAudioHandler(
          onPlayPause: () => _playController.add(null),
          onSeek: (pos) => _seekController.add(pos),
          onRewind: () => _rewindController.add(null),
          onFastForward: () => _fastForwardController.add(null),
          onSkipToNext: () => _skipNextController.add(null),
          onSkipToPrevious: () => _skipPreviousController.add(null),
        ),
        config: const ag.AudioServiceConfig(
          androidNotificationChannelId: 'app.hibiki.reader.channel.audio',
          androidNotificationChannelName: 'hibiki',
          androidNotificationIcon: 'drawable/ic_stat_hibiki',
          notificationColor: Colors.black,
          fastForwardInterval: Duration(seconds: 5),
          rewindInterval: Duration(seconds: 5),
        ),
      );
    } catch (e) {
      debugPrint('[Hibiki] AudioService.init failed (non-fatal): $e');
      _audioHandler = HibikiAudioHandler(
        onPlayPause: () => _playController.add(null),
        onSeek: (pos) => _seekController.add(pos),
        onRewind: () => _rewindController.add(null),
        onFastForward: () => _fastForwardController.add(null),
        onSkipToNext: () => _skipNextController.add(null),
        onSkipToPrevious: () => _skipPreviousController.add(null),
      );
    }
  }

  void dispose() {
    _mediaPauseController.close();
    _playPauseHeadsetController.close();
    _creatorActiveController.close();
    _playController.close();
    _seekController.close();
    _rewindController.close();
    _fastForwardController.close();
    _skipNextController.close();
    _skipPreviousController.close();
  }
}
