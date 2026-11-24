/// 导入面「方式在跑」的状态（两套布局共用，2026-11-24 Cupertino 导入页拆分）：
/// 哪个方式正在跑、跑的时候要不要画进行中（IM14：不弹对话框的流程才画），
/// 以及防重入——任何方式在跑都挡住重复点击。
///
/// M3E（`MaterialImportLayout`）与 Apple（`AppleImportLayout`）各持有一个实例，
/// 不各写一份 `_running` / `_run`。纯状态，与设计系统无关。
library;

import 'package:flutter/foundation.dart';

import 'package:fushi/src/media/import/import_surface_spec.dart';

class ImportRunController extends ChangeNotifier {
  String? _runningId;
  bool _runningShowsProgress = false;
  bool _disposed = false;

  /// 正在跑的方式 id；null = 没有方式在跑。
  String? get runningId => _runningId;

  /// 正在跑的方式是否要画进行中（[ImportMethod.reportsProgress]）。
  bool get runningShowsProgress => _runningShowsProgress;

  /// [method] 此刻是否在转圈（在跑且画进行中）。
  bool isBusy(ImportMethod method) =>
      _runningShowsProgress && _runningId == method.id;

  /// [method] 此刻是否被压暗（别的方式在画进行中）。
  bool isDimmed(ImportMethod method) =>
      _runningShowsProgress && _runningId != method.id;

  /// 跑 [method]：已有方式在跑或本方式禁用时直接返回；Future 结束即收起进行中。
  Future<void> run(ImportMethod method) async {
    if (_runningId != null || !method.enabled) return;
    _runningId = method.id;
    _runningShowsProgress = method.reportsProgress;
    notifyListeners();
    try {
      await method.onTap();
    } finally {
      if (!_disposed) {
        _runningId = null;
        _runningShowsProgress = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
