/// 远端库来源的**缓存身份**：任何能给库页供清单的来源都必须能说出自己是谁。
///
/// **为什么必须是接口上的抽象成员（BUG-1202）**——远端清单共享 TTL 缓存
/// （`RemoteLibraryCache`）此前按「域」分槽（`books` / `videos`），而互联对端与云盘
/// 备份后端**都**往同一个域槽里写：视频页的取数主干是
/// `_resolveRemoteVideoClient() ?? _resolveCloudRemoteVideoClient()`——它自己都不知道
/// 拿到的是哪一种源（这正是 TODO-2119 按能力分级想要的解耦）。于是「互联拉过的清单」
/// 会在 TTL 内被云盘那次读原样命中，用户在云盘视图里看到互联对端的条目，且不报错。
///
/// 靠「换后端时记得失效」治不了：失效信号只有 `InterconnectSyncBackend
/// .sessionIdentityRevision` 一个，它只在**互联对端身份**变化时自增；关互联开关、
/// 换云盘后端这两条路根本不经过它。而把失效钩子逐个补到每个切换入口，正是
/// BUG-1180 自己批判过、并已经漏过一次的做法。
///
/// 正确做法是让「不同来源」在数据结构上**天然不撞**：缓存槽由 (来源身份, 域) 联合
/// 定位，来源身份由来源自己申报。声明成抽象成员 = 将来新增任何一种远端源，编译器
/// 当场要求它给出身份，不存在「忘了登记」这个失败模式。
abstract class RemoteLibrarySource {
  /// 本来源在远端清单缓存里的身份。
  ///
  /// 口径：**同一个 id 必须意味着「问它要清单会得到同一份东西」**。所以按「哪一种源 +
  /// 哪一个后端」取值，而不是按对象实例（页面每次取数都新建 client 实例，按实例分槽
  /// 等于关掉缓存）。
  ///
  /// 互联对端**内部**换人（改地址 / 改令牌 / 重新配对）不体现在这里——那由
  /// `InterconnectSyncBackend.sessionIdentityRevision` 驱动 `invalidateAll()`，是唯一
  /// 权威的对端身份判据（BUG-1180），本 id 不重复造第二套推断。
  String get remoteLibrarySourceId;
}

/// 互联对端（局域网 hibiki host live 库）的来源身份。
///
/// 全局只有一台「当前对端」（`InterconnectSyncBackend` 是单例），换对端由
/// `sessionIdentityRevision` → `invalidateAll()` 兜底，故不按对端地址细分。
const String kInterconnectRemoteLibrarySourceId = 'interconnect';

/// 云盘备份后端的来源身份：按**后端类型**细分（Google Drive / WebDAV / OneDrive /
/// Dropbox / FTP / SFTP 各一个槽），因为换后端类型是设置页里一个开关就能做到的事，
/// 换完两边的清单毫无关系。
///
/// [backendTypeName] 传 `SyncBackendType.<x>.name`（本文件刻意不 import
/// `sync_backend.dart`：那条链会把整套后端实现拖进来，而这里只需要一个名字）。
///
/// 已知残留：同一后端类型下换账号（如退出 Google Drive A 登录 B）身份不变，TTL 内
/// 仍可能看到上一个账号的清单。上界是 60s 且需要在同一分钟内完成「换账号 + 回库页」，
/// 与本 bug 修掉的「跨源无限期串味」不是一个量级；真要治需要后端侧给出账号级身份
/// 信号，属独立议题，不在此就地推断（推断会错，见 BUG-1180 的教训）。
String cloudRemoteLibrarySourceId(String backendTypeName) =>
    'cloud:$backendTypeName';
