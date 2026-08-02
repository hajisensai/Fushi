import 'dart:async';

import 'package:hibiki/src/utils/misc/volume_key_channel.dart';

/// Owns the process-wide Android volume-key bridge while a manga page is active.
///
/// Android forwards repeated ACTION_DOWN events while a key is held. The
/// controller accepts the first event immediately and rate-limits the repeat
/// stream so a long press cannot queue turns all the way to the end of a book.
class MangaVolumeKeyPagingController {
  MangaVolumeKeyPagingController({
    required this.onPrevious,
    required this.onNext,
    this.throttle = const Duration(milliseconds: 180),
    DateTime Function()? now,
    VolumeKeyChannel? channel,
  })  : _now = now ?? DateTime.now,
        _channel = channel ?? VolumeKeyChannel.instance;

  final void Function() onPrevious;
  final void Function() onNext;
  final Duration throttle;
  final DateTime Function() _now;
  final VolumeKeyChannel _channel;

  bool _owned = false;
  DateTime? _lastAcceptedAt;

  bool get owned => _owned;

  void apply({required bool enabled, required bool platformSupported}) {
    final bool want = enabled && platformSupported;
    if (want == _owned) return;
    _owned = want;
    if (want) {
      _channel.setHandlers(
        onVolumeUp: () => _accept(onPrevious),
        onVolumeDown: () => _accept(onNext),
      );
      unawaited(_channel.setInterceptEnabled(true));
    } else {
      _channel.setHandlers();
      _lastAcceptedAt = null;
      unawaited(_channel.setInterceptEnabled(false));
    }
  }

  void dispose() => apply(enabled: false, platformSupported: true);

  void _accept(void Function() action) {
    final DateTime now = _now();
    final DateTime? previous = _lastAcceptedAt;
    if (previous != null && now.difference(previous) < throttle) return;
    _lastAcceptedAt = now;
    action();
  }
}
