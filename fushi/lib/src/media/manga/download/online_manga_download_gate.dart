/// 在线漫画「章节下载」按运行时的合规门。
///
/// 下载服务本身不挂 `StoreRestrictedCapability.downloads`（见
/// `manga_download_service.dart` 文件头：互联对端漫画在 iOS 是保留的在线源）；
/// Mihon 入口在上游已被 `onlineMangaSource` 门挡住（iOS 根本进不到作品页）。
///
/// Kavita 是用户自己的服务器：直读与「下载到本机」都属于用户自配服务器能力
/// （`userConfiguredServersAvailableOn`，2026-10-27 用户拍板 iOS 也保留——下载的是
/// 用户自有内容的离线副本，不是下载中心），不挂 `downloads`。仍按运行时分流，
/// 消费端（作品页按钮、阅读器「本章未下载」态、下载服务入队）一律问本函数。
library;

import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/models/store_compliance.dart';

/// [runtime] 的章节在当前平台能不能下载。
///
/// [isIOS] 只给测试显式注入平台用；生产留空，走 [userConfiguredServersAvailable]。
bool onlineMangaChapterDownloadsAvailable(
  OnlineMangaRuntimeKind runtime, {
  bool? isIOS,
}) => switch (runtime) {
  OnlineMangaRuntimeKind.kavita =>
    isIOS == null
        ? userConfiguredServersAvailable
        : userConfiguredServersAvailableOn(isIOS: isIOS),
  _ => true,
};
