import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hibiki/src/database/database.dart';

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

    final dateKey = _formatDateKey(start);
    final hour = start.hour;
    _database
        .addHourlyReadingTime(dateKey: dateKey, hour: hour, deltaMs: elapsed)
        .catchError((Object e) {
      debugPrint('[reading-time-tracker] write error: $e');
    });
  }

  static String _formatDateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
