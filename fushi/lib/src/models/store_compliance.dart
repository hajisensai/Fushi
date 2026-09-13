/// iOS 版在 App Store 上架时**不装配**的那几类能力，以及它们的唯一平台判据。
///
/// 三类能力（内置外部发现源、在线漫画扩展源宿主、下载中心）都不是「iOS 做不到」，
/// 而是「App Store 审核指南不允许」：内置的第三方内容索引/种子源、可加载任意第三方
/// 扩展仓库的漫画源宿主、以及通用 torrent/磁力下载器，都属于会被拒绝上架的形态。
/// 其余平台（Android / Windows / macOS / Linux）不走商店分发，完全不受影响。
///
/// 判据收在本文件的原因与 [ModuleId.availableOn] 一样：合规边界一旦散成各处的
/// `Platform.isIOS`，漏掉任何一处都是**静默过审风险**——本地全绿、上架被拒，而
/// 被拒的那一处从代码里根本看不出来它本该属于这条边界。消费端一律问这里，
/// 新增受限能力只加一个枚举值。
///
/// 与 [ModuleId] 的分工：能被用户在「设置 › 外观 › 功能模块」整体关掉的东西是
/// [ModuleId]（下载中心就是其中之一，因此 [ModuleId.downloads] 的 `availableOn`
/// 直接委托到这里，两套门不各判一次）；而「发现」不是模块——它是书 / 漫画 / 视频
/// 三个库页各自内部的一个视图，没有独立开关，只能由这里门控。
library;

import 'dart:io' show Platform;

/// 一类因商店合规而在 iOS 构建里整体缺席的能力。
enum StoreRestrictedCapability {
  /// 内置外部发现源与各库页的「发现 / 浏览」视图。
  ///
  /// 覆盖 [MediaDiscoveryService] 的内置源（Nyaa / Sukebei / AList / Shinnku）、
  /// 视频域的资源索引器与在线发现 provider，以及承载它们的发现页。用户自配的
  /// OPDS 服务器同样落在这里：它虽是用户自己的书库，但入口与落地能力都是发现页
  /// 的下载入库流程，iOS 上那条流程整体不存在。
  externalDiscovery,

  /// 在线漫画源宿主：Aidoku 仓库 / Mihon 扩展 / mokuro.moe 卷下载。
  ///
  /// 这三者的共同点是**运行时加载第三方仓库提供的内容源**，而不是读用户自己
  /// 导入的本地漫画。iOS 只保留本地导入 + 阅读。
  onlineMangaSource,

  /// 统一下载中心（torrent / 磁力 / 直链队列），含外接 qBittorrent 后端。
  downloads;

  /// 本能力在目标平台上**是否存在**（与用户意愿、与运行时能否跑起来都无关）。
  ///
  /// 三个值当前判据相同，仍逐个走枚举而不是塌成一个裸常量：它们是三条互相独立的
  /// 合规理由，将来任意一条被单独放开（例如只保留用户自配 OPDS）时，改动面应该
  /// 是这里的一行，而不是回头去把一个被共享的布尔拆开。
  bool availableOn({required bool isIOS}) => !isIOS;

  /// 真实平台上的判据。widget / 页面层用它，避免把平台参数一路透传下去。
  ///
  /// 要在测试里断言「某平台上这条边界如何」，用 [availableOn] 显式注入平台，
  /// 别依赖宿主真实平台——否则同一条用例在 Windows 本机与 macOS CI 上结论相反。
  bool get isAvailable => availableOn(isIOS: Platform.isIOS);
}
