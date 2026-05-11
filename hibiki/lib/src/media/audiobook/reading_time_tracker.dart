import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hibiki/src/database/database.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';

class ReadingTimeTracker {
  ReadingTimeTracker(this._database);

  final HibikiDatabase _database;
  Timer? _timer;
  DateTime? _tickStart;

  static const _interval = Duration(seconds: 60);

  void start() {
    if (_timer != null) return;
    _tickStart = DateTime.now();
    _timer = Timer.periodic(_interval, (_) => _flush());
  }

  void stop() {
    _flush();
    _timer?.cancel();
    _timer = null;
    _tickStart = null;
  }

  void dispose() {
    stop();
  }

  void _flush() {
    final start = _tickStart;
    if (start == null) return;
    final now = DateTime.now();
    final elapsed = now.difference(start).inMilliseconds;
    if (elapsed <= 0) return;
    _tickStart = now;

    if (start.hour != now.hour || start.day != now.day) {
      final boundary = DateTime(
          start.year, start.month, start.day, start.hour + 1);
      final firstMs = boundary.difference(start).inMilliseconds;
      final secondMs = now.difference(boundary).inMilliseconds;
      if (firstMs > 0) {
        _write(_formatDateKey(start), start.hour, firstMs);
      }
      if (secondMs > 0) {
        _write(_formatDateKey(now), now.hour, secondMs);
      }
    } else {
      _write(_formatDateKey(start), start.hour, elapsed);
    }
  }

  void _write(String dateKey, int hour, int deltaMs) {
    _database
        .addHourlyReadingTime(dateKey: dateKey, hour: hour, deltaMs: deltaMs)
        .catchError((Object e, StackTrace stack) {
      ErrorLogService.instance.log('ReadingTimeTracker.write', e, stack);
      debugPrint('[reading-time-tracker] write error: $e');
    });
  }

  static String _formatDateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
