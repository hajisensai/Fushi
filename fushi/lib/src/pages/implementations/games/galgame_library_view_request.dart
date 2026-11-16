import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_library_query.dart';

/// 游戏首页 → 游戏库的「带着视图跳过去」请求：首页「继续 · 最近」块的「全部 ›」
/// 要按最近游玩倒序看全库，「游玩状态」块点某一档要筛到该状态。
///
/// 游戏库在 [HomeGamePage] 的 IndexedStack 里常驻（急切构建、持有自己的
/// `_view`），只写偏好它看不见，所以除了把新视图落进同一个偏好键（库页还没挂载
/// 时 `initState` 读到的就是它），还要经这条 notifier 通知已挂载的库页就地换视图。
@immutable
class GalgameLibraryViewRequest {
  const GalgameLibraryViewRequest({
    this.sortField,
    this.ascending,
    this.status,
    this.clearStatus = false,
  });

  /// 按最近游玩倒序（「全部 ›」）。
  const GalgameLibraryViewRequest.recentlyPlayed()
    : sortField = GalgameSortField.lastPlayed,
      ascending = false,
      status = null,
      clearStatus = true;

  /// 只看某一游玩状态（「游玩状态」块的图例项）。
  const GalgameLibraryViewRequest.status(GalgamePlayStatus this.status)
    : sortField = null,
      ascending = null,
      clearStatus = false;

  /// null = 不改排序维度。
  final GalgameSortField? sortField;

  /// null = 不改升降序。
  final bool? ascending;

  /// 非 null = 筛到该状态。
  final GalgamePlayStatus? status;

  /// true = 清掉状态筛选（与 [status] 互斥）。
  final bool clearStatus;

  /// 把请求套到 [view] 上（搜索词清空：带着旧搜索词跳过去会让人以为库空了）。
  GalgameLibraryView applyTo(GalgameLibraryView view) => view.copyWith(
    search: '',
    sortField: sortField,
    ascending: ascending,
    status: status,
    clearStatus: clearStatus && status == null,
  );
}

/// 库页监听它：值非 null 时把请求套到当前视图、落偏好，然后置回 null。
final ValueNotifier<GalgameLibraryViewRequest?>
galgameLibraryViewRequestNotifier = ValueNotifier<GalgameLibraryViewRequest?>(
  null,
);
