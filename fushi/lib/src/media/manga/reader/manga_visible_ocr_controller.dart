import 'dart:async';

import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// Only the latest viewport is pending. In-flight pages may finish and enter
/// the cache, but leaving a book invalidates every outstanding callback.
class MangaVisibleOcrController {
  MangaVisibleOcrController({
    required this.recognize,
    required this.onPage,
    required this.onError,
    required this.onActivity,
    int concurrency = 1,
  }) : concurrency = concurrency.clamp(1, 3);

  final Future<MokuroImage> Function(int pageIndex) recognize;
  final void Function(int pageIndex, MokuroImage page) onPage;
  final void Function(int pageIndex, Object error, StackTrace stack) onError;
  final void Function(Set<int> pages) onActivity;
  final int concurrency;
  final Set<int> _running = <int>{};
  final Set<int> _completed = <int>{};
  final Set<int> _failed = <int>{};
  List<int> _pending = <int>[];
  bool _closed = false;

  void showPages(Iterable<int> pageIndices, {bool retry = false}) {
    if (_closed) return;
    final Set<int> visible = pageIndices.where((int page) => page >= 0).toSet();
    if (retry) _failed.removeAll(visible);
    _pending = visible
        .where(
          (int page) =>
              !_running.contains(page) &&
              !_completed.contains(page) &&
              !_failed.contains(page),
        )
        .toList();
    _pump();
  }

  /// Manual mode may discard pages left behind, but a repeated viewport
  /// report must not cancel the remaining pages explicitly requested by the
  /// user. This never adds automatic work.
  void retainPendingPages(Iterable<int> pageIndices) {
    if (_closed) return;
    final Set<int> visible = pageIndices.toSet();
    _pending.removeWhere((int page) => !visible.contains(page));
  }

  void _pump() {
    while (!_closed && _running.length < concurrency && _pending.isNotEmpty) {
      final int page = _pending.removeAt(0);
      _running.add(page);
      onActivity(Set<int>.unmodifiable(_running));
      unawaited(_run(page));
    }
  }

  Future<void> _run(int pageIndex) async {
    try {
      final MokuroImage page = await recognize(pageIndex);
      if (_closed) return;
      _completed.add(pageIndex);
      onPage(pageIndex, page);
    } catch (error, stack) {
      if (_closed) return;
      _failed.add(pageIndex);
      onError(pageIndex, error, stack);
    } finally {
      _running.remove(pageIndex);
      if (!_closed) {
        onActivity(Set<int>.unmodifiable(_running));
        _pump();
      }
    }
  }

  void close() {
    _closed = true;
    _pending.clear();
  }
}
