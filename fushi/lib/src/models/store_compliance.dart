/// iOS 版在 App Store 上架时**不装配**的那几类能力，以及它们的唯一平台判据。
///
/// 这几类能力（内置外部发现源、在线漫画 / 视频 / 小说扩展源宿主、下载中心）都不是「iOS 做不到」，
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
/// [ModuleId]（「浏览」就是其中之一：发现页、在线扩展源与下载中心 2026-09-27 起
/// 全部收在这个模块里，因此 [ModuleId.browse] 的 `availableOn` 直接委托到这里，
/// 两套门不各判一次）；浏览页内部的每个域再各自问对应的能力值（纵深防御）。
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

  /// 在线漫画源宿主：Mihon 扩展 / mokuro.moe 卷下载。
  ///
  /// 这两者的共同点是**运行时加载第三方仓库提供的内容源**，而不是读用户自己
  /// 导入的本地漫画。iOS 只保留本地导入 + 阅读。
  onlineMangaSource,

  /// 在线视频源宿主：Aniyomi 扩展（与 [onlineMangaSource] 同一个运行时、同一条
  /// 合规理由——运行时加载第三方仓库提供的内容源）。iOS 只保留本地导入 + 播放。
  onlineVideoSource,

  /// 在线小说源宿主：LNReader 插件（同一条合规理由——运行时加载第三方仓库提供
  /// 的内容源，且插件是任意 JS）。iOS 只保留本地导入 + 阅读。
  onlineNovelSource,

  /// 统一下载中心（torrent / 磁力 / 直链队列），含外接 qBittorrent 后端。
  downloads,

  /// 蓝光 AACS 内容解密（含按盘 ID 自动下载 KEYDB 播放配置）。
  ///
  /// 解除光盘的复制保护属于审核指南不允许的形态。iOS 上加密盘的表现与接入解密前
  /// 一致：报「码流仍是 AACS 加密」，不读取、不下载任何播放配置；已解密的副本与
  /// 未加密的原盘照常播放。引擎侧开关是 `aacsDecryptionAvailable`
  /// （`installEngineHostBindings()` 用本值赋值）。
  aacsDecryption;

  /// 本能力在目标平台上**是否存在**（与用户意愿、与运行时能否跑起来都无关）。
  ///
  /// 各值当前判据相同，仍逐个走枚举而不是塌成一个裸常量：它们是互相独立的几条
  /// 合规理由，将来任意一条被单独放开（例如只保留用户自配 OPDS）时，改动面应该
  /// 是这里的一行，而不是回头去把一个被共享的布尔拆开。
  bool availableOn({required bool isIOS}) => !isIOS;

  /// 真实平台上的判据。widget / 页面层用它，避免把平台参数一路透传下去。
  ///
  /// 要在测试里断言「某平台上这条边界如何」，用 [availableOn] 显式注入平台，
  /// 别依赖宿主真实平台——否则同一条用例在 Windows 本机与 macOS CI 上结论相反。
  bool get isAvailable => availableOn(isIOS: Platform.isIOS);
}
