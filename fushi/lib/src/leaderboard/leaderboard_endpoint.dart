// 排行榜 / 安装统计 / 服务端通知共用的服务地址。单独成叶子文件：只要地址的调用方
// （如 updates/notice_feed.dart）不必 import 读 AppModel 的 leaderboard_service.dart。

/// 排行榜服务的默认地址（store 的 `serverUrl` 可覆盖）。
const String kLeaderboardDefaultBaseUrl = 'https://rank.fushi.moe';
