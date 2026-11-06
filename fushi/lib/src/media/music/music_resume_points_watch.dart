/// 曲目列表 / 详情看断点（`music_resume.dart`）的增量视图。
///
/// 断点表由 `MusicSession` 写（在播时每 5 s 一笔）；每笔写只动一行，所以写方发
/// [MusicResumePointChange]（哪一首、写成什么 / 删了），看的一方只在**自己那几首**变了
/// 时更新内存里那一格并通知——不整列重查库、不让与这首无关的列表重建。挂上时按块查一次
/// 齐（`FushiDatabase.listMusicResumePoints`）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';

/// 断点表的一笔改动：[row] 为 null = 这首的断点删了（听完 / 回到开头 / 清除）。
@immutable
class MusicResumePointChange {
  const MusicResumePointChange(this.trackUid, this.row);

  final String trackUid;
  final MusicResumePointRow? row;
}

/// 按一组曲目查断点（按块查齐）。
typedef MusicResumePointsLoader =
    Future<Map<String, MusicResumePointRow>> Function(List<String> trackUids);

/// 一组曲目的断点：初次按块查齐，之后只吃 [changes] 里属于这组的改动。
class MusicResumePointsWatch extends ChangeNotifier {
  MusicResumePointsWatch({
    required Stream<MusicResumePointChange> changes,
    required MusicResumePointsLoader load,
  }) : _load = load {
    _sub = changes.listen(_onChange);
  }

  final MusicResumePointsLoader _load;
  late final StreamSubscription<MusicResumePointChange> _sub;

  Set<String> _uids = const <String>{};
  Map<String, MusicResumePointRow> _rows = <String, MusicResumePointRow>{};

  /// 初次查询在途时到的改动：查询结果可能是改动之前的快照，落地后用它们盖回去。
  Map<String, MusicResumePointChange>? _duringLoad;
  int _loadGen = 0;
  bool _disposed = false;

  /// 测试用：初次查询落地。
  @visibleForTesting
  Future<void> loaded = Future<void>.value();

  /// [trackUid] 的断点；没有 / 不在这组里为 null。
  MusicResumePointRow? operator [](String trackUid) => _rows[trackUid];

  /// 换成看 [trackUids]（列表换了曲目）：重查一次齐。
  void watch(Iterable<String> trackUids) {
    _uids = trackUids.toSet();
    final int gen = ++_loadGen;
    final Map<String, MusicResumePointChange> pending =
        <String, MusicResumePointChange>{};
    _duringLoad = pending;
    loaded = _reload(gen, pending);
  }

  Future<void> _reload(
    int gen,
    Map<String, MusicResumePointChange> pending,
  ) async {
    final Map<String, MusicResumePointRow> rows =
        Map<String, MusicResumePointRow>.of(await _load(_uids.toList()));
    if (_disposed || gen != _loadGen) return;
    for (final MusicResumePointChange c in pending.values) {
      _put(rows, c);
    }
    _duringLoad = null;
    _rows = rows;
    notifyListeners();
  }

  void _onChange(MusicResumePointChange change) {
    if (_disposed || !_uids.contains(change.trackUid)) return;
    _duringLoad?[change.trackUid] = change;
    final MusicResumePointRow? before = _rows[change.trackUid];
    _put(_rows, change);
    if (before != _rows[change.trackUid]) notifyListeners();
  }

  static void _put(
    Map<String, MusicResumePointRow> rows,
    MusicResumePointChange change,
  ) {
    final MusicResumePointRow? row = change.row;
    if (row == null) {
      rows.remove(change.trackUid);
    } else {
      rows[change.trackUid] = row;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_sub.cancel());
    super.dispose();
  }
}
