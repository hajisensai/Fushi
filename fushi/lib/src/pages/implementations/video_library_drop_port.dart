/// 视频库落点端口（BUG-4857 / 导入稿 IM2）：「导入」视图的整页落点把落下的
/// 路径交给视频库页（[HomeVideoPage]）现有的那一套分发，不另写一份。
///
/// 两个页面在 [VideoLibraryShell] 里是兄弟（各自保活、各自一层 `DropSurfaceScope`），
/// 导入视图拿不到库页 State；由壳持有一个端口，库页挂上自己的处理函数，导入视图
/// 的落点调 [drop]。库页还没建（只有宿主测试会替换掉库页）时 [drop] 什么都不做。
library;

import 'dart:async' show FutureOr;

import 'package:material_ui/material_ui.dart' show Offset;

import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart'
    show FileDropCallback;

class VideoLibraryDropPort {
  FileDropCallback? _handler;

  /// 是否已有库页挂上处理函数。
  bool get attached => _handler != null;

  /// 库页挂上自己的落点处理（同一时刻只有一个视频库页）。
  void attach(FileDropCallback handler) => _handler = handler;

  /// 库页卸载时撤下；只撤自己挂的那一个（同一实例方法的拆取相等，按 `==` 比）。
  void detach(FileDropCallback handler) {
    if (_handler == handler) _handler = null;
  }

  /// 导入视图的落点回调：转交库页的分发。
  FutureOr<void> drop(List<String> paths, Offset globalPosition) {
    final FileDropCallback? handler = _handler;
    if (handler == null) return null;
    return handler(paths, globalPosition);
  }
}
