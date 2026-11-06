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
///
/// **用户自己填地址的服务器不在这条边界里**（用户 2026-10-27 拍板，见
/// [userConfiguredServersAvailableOn]）：OPDS、AList / OpenList、Kavita、
/// Audiobookshelf、Jellyfin / Plex 在 iOS 上照常设置、浏览、阅读 / 串流与下载到本机。
library;

import 'dart:io' show Platform;

/// 一类因商店合规而在 iOS 构建里整体缺席的能力。
enum StoreRestrictedCapability {
  /// 内置外部发现源与各库页的「发现 / 浏览」视图。
  ///
  /// 覆盖 [MediaDiscoveryService] 的内置 / 预置源（CoreAudio、预置 AList 站
  /// erogame.space、Shinnku）、用户添加的 BT 站（Nyaa 式种子索引，落地只有
  /// torrent，归下载中心那条理由）、视频域的资源索引器与在线发现 provider 目录，
  /// 以及只为它们存在的发现页 / 发现子标签。
  ///
  /// **不再覆盖**用户自配的 OPDS / AList 站点 / Audiobookshelf 源（2026-10-27 用户
  /// 拍板，见 [userConfiguredServersAvailableOn]）：iOS 上发现源注册表只登记这些
  /// 用户服务器源，库页「发现」视图在有可用的用户服务器源时照常出现。
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

  /// 在线音源插件宿主：用户安装的 JS 插件接入第三方音乐平台（搜索 / 取流 / 歌词）。同一条
  /// 合规理由——运行时加载并执行第三方代码、接入未授权来源的媒体；iOS 伞形静态库也不编入
  /// JS 引擎。iOS 只保留本地曲库与用户自配的服务器曲库（docs/specs/2026-10-28-music-plugins.md）。
  onlineMusicSource,

  /// 统一下载中心（torrent / 磁力 / 任意直链队列），含外接 qBittorrent 后端。
  ///
  /// 只指**下载中心**这一形态：用户贴任意链接 / 种子、由本 app 代为下载第三方
  /// 来源的媒体。从用户自己的服务器（Kavita / Audiobookshelf / OPDS / AList）
  /// 「下载到本机」是用户自有内容的离线副本，不挂这道门，问
  /// [userConfiguredServersAvailableOn]（2026-10-27 用户拍板）。
  downloads,

  /// 蓝光 AACS 内容解密（含按盘 ID 自动下载 KEYDB 播放配置）。
  ///
  /// 解除光盘的复制保护属于审核指南不允许的形态。iOS 上加密盘的表现与接入解密前
  /// 一致：报「码流仍是 AACS 加密」，不读取、不下载任何播放配置；已解密的副本与
  /// 未加密的原盘照常播放。引擎侧开关是 `aacsDecryptionAvailable`
  /// （`installEngineHostBindings()` 用本值赋值）。
  aacsDecryption,

  /// 应用内的外部打赏 / 赞助入口（GitHub Sponsors、Ko-fi）。
  ///
  /// 审核指南 3.1.1：应用内向开发者付款（含打赏 / 小费）只能走 App 内购买，
  /// 引导到外部支付页的按钮属于会被拒绝上架的形态（只有获批的非营利组织
  /// 募捐例外）。iOS 上设置页不渲染这些入口；仓库 README 等应用外渠道不受影响。
  externalDonation;

  /// 本能力在目标平台上**是否存在**（与用户意愿、与运行时能否跑起来都无关）。
  ///
  /// 各值当前判据相同，仍逐个走枚举而不是塌成一个裸常量：它们是互相独立的几条
  /// 合规理由，将来任意一条被单独放开时，改动面应该是这里的一行，而不是回头去把
  /// 一个被共享的布尔拆开。（用户自配服务器 2026-10-27 放开时走的是另一条路：它
  /// 从来不是一类「受限能力」，拆成了独立判据 [userConfiguredServersAvailableOn]。）
  bool availableOn({required bool isIOS}) => !isIOS;

  /// 真实平台上的判据。widget / 页面层用它，避免把平台参数一路透传下去。
  ///
  /// 要在测试里断言「某平台上这条边界如何」，用 [availableOn] 显式注入平台，
  /// 别依赖宿主真实平台——否则同一条用例在 Windows 本机与 macOS CI 上结论相反。
  bool get isAvailable => availableOn(isIOS: Platform.isIOS);
}

/// 用户自己填地址的服务器在目标平台上是否存在：**不是**受限能力，iOS 也保留
/// （用户 2026-10-27 拍板）。
///
/// 覆盖：用户自配的 OPDS 书目服务器、AList / OpenList 站点、Kavita、
/// Audiobookshelf、Jellyfin / Emby / Plex 媒体服务器——设置入口、浏览、阅读 /
/// 串流，以及从这些服务器「下载到本机」（用户自有内容的离线副本）。
///
/// 理由：App Store 审核指南 5.2.3 限制的是从**未授权的第三方来源**下载 / 保存媒体，
/// 以及促成非法分享；连接用户自己的服务器不在此列。App Store 上大量同类应用即为
/// 先例（KyBook / Panels / Chunky 等 OPDS 阅读器、Komga / Kavita 客户端、
/// ShelfPlayer / plappa 等 Audiobookshelf 客户端）。
///
/// 仍然受限、与本判据无关的（各自的 [StoreRestrictedCapability] 值不变）：内置 /
/// 预置的外部发现源与 provider 目录（[StoreRestrictedCapability.externalDiscovery]），
/// Mihon / Aniyomi / LNReader 扩展宿主（`online*Source`），torrent / 磁力 / 直链
/// 下载中心含外接 qBittorrent（[StoreRestrictedCapability.downloads]）。
///
/// iOS 上也**不预填任何服务器地址**：这些服务器列表默认为空，全部由用户自己添加；
/// 唯一的预置站（AList erogame.space）属于内置源，留在
/// [StoreRestrictedCapability.externalDiscovery] 后面。
///
/// 恒 true 仍保留成函数：消费端（发现源注册表、库页发现视图、Kavita / ABS 下载
/// 按钮）一律问这里而不是省掉判据，将来若要收回只改这一行；守卫
/// `test/build/ios_store_compliance_guard_test.dart` 钉住它与受限集合的分界。
bool userConfiguredServersAvailableOn({required bool isIOS}) => true;

/// 真实平台上的 [userConfiguredServersAvailableOn]。
bool get userConfiguredServersAvailable =>
    userConfiguredServersAvailableOn(isIOS: Platform.isIOS);

/// DVD CSS 解密（随包 libdvdcss，`tool/dvd`）**不是**受限能力：所有者 2026-10-24
/// 拍板五端一致随包，iOS 也链接 libdvdcss（见
/// `docs/specs/2026-10-24-dvd-original-menu.md`「风险」）。
///
/// 这里是预留判据，不是散落的开关：若 App Store 审核以「绕过复制保护」拒绝，回退
/// 办法是 ① 本函数改成 `!isIOS`（或并入 [StoreRestrictedCapability] 作为新值）；
/// ② iOS 的 DVD 库改用 `DVD_MESON_ARGS=-Dlibdvdcss=disabled` 构建
/// （`tool/dvd/build_dvd_libs.sh` 届时放开对 libdvdcss 的硬检查），只播未加密 /
/// 已解密的 ISO。消费端（加密盘的报错文案、能力提示）一律问这里，不另写
/// `Platform.isIOS`。
bool dvdCssDecryptionAvailableOn({required bool isIOS}) => true;

/// 真实平台上的 [dvdCssDecryptionAvailableOn]。
bool get dvdCssDecryptionAvailable =>
    dvdCssDecryptionAvailableOn(isIOS: Platform.isIOS);
