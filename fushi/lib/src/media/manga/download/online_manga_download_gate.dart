/// 在线漫画「章节下载」按运行时的合规门。
///
/// 下载服务本身不挂 `StoreRestrictedCapability.downloads`（见
/// `manga_download_service.dart` 文件头：互联对端漫画在 iOS 是保留的在线源）；
/// Mihon 入口在上游已被 `onlineMangaSource` 门挡住（iOS 根本进不到作品页）。
///
/// Kavita 不同：它在 iOS 上保留**在线直读**（用户自配的服务器，所有者拍板直读
/// 不设门），但**下载**按与其它下载同一条规则走 `downloads` 能力——所以这里按运行时
/// 分流，消费端（作品页按钮、阅读器「本章未下载」态、下载服务入队）一律问本函数。
library;

import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/models/store_compliance.dart';

/// [runtime] 的章节在当前平台能不能下载。
///
/// [isIOS] 只给测试显式注入平台用；生产留空，走
/// [StoreRestrictedCapability.isAvailable]。
bool onlineMangaChapterDownloadsAvailable(
  OnlineMangaRuntimeKind runtime, {
  bool? isIOS,
}) => switch (runtime) {
  OnlineMangaRuntimeKind.kavita =>
    isIOS == null
        ? StoreRestrictedCapability.downloads.isAvailable
        : StoreRestrictedCapability.downloads.availableOn(isIOS: isIOS),
  _ => true,
};
