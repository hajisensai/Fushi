// 排行榜功能入口的集中开关（2026-10-09 所有者拍板「好友、作品人气先只隐藏入口」）。
//
// 关掉的只是 **UI 入口**：页面类、客户端接口（`LeaderboardClient.friends` /
// `popular` …）与服务端路由全部保留，恢复时把这里改回 true 即可，不用找散落的
// 调用点。所有入口都只经这里判断，不在页面里各写一份。

/// 排行榜各功能入口是否显示。
abstract final class LeaderboardFeatures {
  /// 好友：页头「好友」入口、好友榜（scope = friends）、用户页的加好友按钮。
  static bool friendsEnabled = false;

  /// 作品人气榜：榜单上方「用户 / 作品人气」切换。
  static bool popularWorksEnabled = false;
}
