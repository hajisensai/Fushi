import 'package:fushi/src/models/store_compliance.dart';

/// 浏览器上的「用 Fushi 阅读（小说）」动作（以及网页小说书的追更）是否可用。
///
/// 把任意网站的连载正文抓进书架、读到末尾自动拉下一章，与 LNReader 在线小说源是
/// 同一类能力、同一道 App Store 合规门；app 内浏览器本身不受这道门约束。判据只问
/// [StoreRestrictedCapability.onlineNovelSource]，不写 `Platform.isIOS`（守卫见
/// `test/build/ios_store_compliance_guard_test.dart`）。
bool webNovelReaderActionAvailable() =>
    StoreRestrictedCapability.onlineNovelSource.isAvailable;
